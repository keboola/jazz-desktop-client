import Foundation

/// One atomically replaceable Keychain payload for every request that uses a signed-enrollment
/// Storage token. Keeping the secret, expiry, exact Keboola stack, archive route, scope, and signed
/// authority in one item prevents a crash during rotation from pairing a new token with old
/// UserDefaults routing (or the inverse).
///
/// This Codable value must only be persisted through ``JazzSignedDeviceCredentialVault`` backed by
/// the platform credential store. It must never enter a queue, archive, log, URL, or UserDefaults.
public struct JazzSignedDeviceCredentialEnvelope: Codable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    public let schemaVersion: Int
    public let expiresAt: String
    public let routeBinding: JazzArchiveUploadRouteBinding
    public let enrollmentRouting: JazzArchiveEnrollmentRouting
    /// The source id and endpoint are one signed authority tuple. Both are deliberately present
    /// even when nil: a signed archive-only generation must not inherit a stale manual endpoint.
    public let streamSourceId: String?
    private let streamEndpoint: String?
    private let token: String

    public init(
        schemaVersion: Int = 1,
        token: String,
        expiresAt: String,
        routeBinding: JazzArchiveUploadRouteBinding,
        enrollmentRouting: JazzArchiveEnrollmentRouting,
        streamSourceId: String?,
        streamEndpoint: String?
    ) throws {
        self.schemaVersion = schemaVersion
        self.token = token
        self.expiresAt = expiresAt
        self.routeBinding = routeBinding
        self.enrollmentRouting = enrollmentRouting
        self.streamSourceId = streamSourceId
        self.streamEndpoint = streamEndpoint
        try validate()
    }

    public var description: String { "<redacted signed device credential envelope>" }
    public var debugDescription: String { description }

    public func archiveCredential(
        for pinnedRoute: JazzArchiveUploadRouteBinding,
        now: Date = Date()
    ) throws -> JazzArchiveScopedDeviceCredential {
        try validate(at: now)
        guard pinnedRoute.hasSameDeliveryAuthority(as: routeBinding) else {
            throw JazzArchiveUploadError.credentialBindingMismatch
        }
        return try JazzArchiveScopedDeviceCredential(token)
    }

    public func keboolaCredential(
        now: Date = Date()
    ) throws -> JazzKeboolaRequestCredential {
        try validate(at: now)
        return try JazzKeboolaRequestCredential(
            stackURL: routeBinding.stackURL,
            token: token)
    }

    /// Stream authority is structurally validated but intentionally independent of Storage-token
    /// expiry: an OTLP path secret is a separate credential and remains usable until a newer signed
    /// generation replaces it. A nil result is authoritative, not permission to inherit a legacy
    /// Keychain endpoint.
    public func signedStreamEndpoint() throws -> String? {
        try validate()
        return streamEndpoint
    }

    fileprivate static func decodeValidated(
        _ data: Data
    ) throws -> JazzSignedDeviceCredentialEnvelope {
        do {
            let decoded = try JSONDecoder().decode(Self.self, from: data)
            try decoded.validate()
            return decoded
        } catch let error as JazzArchiveUploadError {
            throw error
        } catch {
            throw JazzArchiveUploadError.credentialBindingMismatch
        }
    }

    fileprivate func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    private func validate(at now: Date? = nil) throws {
        guard schemaVersion == 1,
            !token.isEmpty,
            token.unicodeScalars.count <= 8_192,
            routeBinding.hasSignedAuthority,
            (try? enrollmentRouting.signedUploadRouteBinding()) == routeBinding,
            enrollmentRouting.expiresAt == expiresAt,
            streamSourceId.map({
                !$0.isEmpty && $0.unicodeScalars.count <= 512
            }) ?? true,
            streamEndpoint.map({
                $0.unicodeScalars.count <= 8_192
                    && StreamEndpoint.isSecureSignedEndpoint($0)
                    && StreamEndpoint.normalize($0) == $0
            }) ?? true,
            streamSourceId == nil || streamEndpoint != nil,
            let expiry = Timestamps.parse(expiresAt),
            expiry.timeIntervalSinceReferenceDate.isFinite
        else {
            throw JazzArchiveUploadError.credentialBindingMismatch
        }
        if let now, expiry <= now {
            throw JazzArchiveUploadError.credentialExpired
        }
    }
}

/// A token plus its exact Keboola Storage API authority. The value is intentionally non-Codable
/// and redacted; callers may only use it to build a request or briefly execute a closure.
public struct JazzKeboolaRequestCredential: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    public let stackURL: String
    private let token: String

    fileprivate init(stackURL: String, token: String) throws {
        guard KeboolaStack.normalize(stackURL) == stackURL, !token.isEmpty else {
            throw JazzArchiveUploadError.credentialBindingMismatch
        }
        self.stackURL = stackURL
        self.token = token
    }

    public var description: String { "<redacted Keboola request credential>" }
    public var debugDescription: String { description }

    public func request(
        path: String,
        method: String,
        timeout: TimeInterval
    ) throws -> URLRequest {
        guard path.hasPrefix("/"),
            !path.hasPrefix("//"),
            !path.contains("\\"),
            let url = URL(string: stackURL + path),
            url.scheme?.lowercased() == "https",
            url.host?.isEmpty == false
        else {
            throw JazzArchiveUploadError.credentialBindingMismatch
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue(token, forHTTPHeaderField: "X-StorageApi-Token")
        return request
    }

    public func withValue<Result>(_ body: (String) throws -> Result) rethrows -> Result {
        try body(token)
    }

    public func withValue<Result>(
        _ body: (String) async throws -> Result
    ) async rethrows -> Result {
        try await body(token)
    }
}

/// Minimal atomic secret-slot boundary. A production implementation maps one slot to one Keychain
/// generic-password item; tests inject failures immediately before or after the atomic commit.
public protocol JazzSignedDeviceCredentialPersisting: Sendable {
    func read() throws -> Data?
    func replaceAtomically(with data: Data?) throws
}

public struct JazzSignedDeviceCredentialVault: Sendable {
    private let persistence: any JazzSignedDeviceCredentialPersisting

    public init(persistence: any JazzSignedDeviceCredentialPersisting) {
        self.persistence = persistence
    }

    /// Replace the complete tuple in one persistence operation. The persistence boundary guarantees
    /// that interruption exposes either the prior complete bytes or the new complete bytes.
    public func replace(
        with envelope: JazzSignedDeviceCredentialEnvelope?
    ) throws {
        try persistence.replaceAtomically(with: try envelope?.encoded())
    }

    /// A present but corrupt/incompatible item is an authenticated-mode failure, never permission
    /// to fall back to a raw token and caller-provided stack.
    public func envelope() throws -> JazzSignedDeviceCredentialEnvelope? {
        let data: Data?
        do {
            data = try persistence.read()
        } catch {
            throw JazzArchiveUploadError.credentialUnavailable
        }
        guard let data else { return nil }
        return try JazzSignedDeviceCredentialEnvelope.decodeValidated(data)
    }

    public func archiveCredential(
        for pinnedRoute: JazzArchiveUploadRouteBinding,
        now: Date = Date()
    ) throws -> JazzArchiveScopedDeviceCredential {
        guard let envelope = try envelope() else {
            throw JazzArchiveUploadError.credentialUnavailable
        }
        return try envelope.archiveCredential(for: pinnedRoute, now: now)
    }

    /// Resolve the authority for an ordinary Keboola API request. Signed enrollment always wins
    /// and ignores the caller/settings stack. Legacy raw-token fallback exists only when the atomic
    /// signed slot is genuinely absent; corruption or expiry throws before a request can be built.
    public func keboolaCredential(
        requestedStackURL: String,
        legacyToken: @autoclosure () throws -> String?,
        now: Date = Date()
    ) throws -> JazzKeboolaRequestCredential {
        if let envelope = try envelope() {
            return try envelope.keboolaCredential(now: now)
        }
        guard let stackURL = KeboolaStack.normalize(requestedStackURL),
            let legacyToken = try legacyToken(),
            !legacyToken.isEmpty
        else {
            throw JazzArchiveUploadError.credentialUnavailable
        }
        return try JazzKeboolaRequestCredential(
            stackURL: stackURL,
            token: legacyToken)
    }

    /// Resolve the OTLP authority without ever conflating signed explicit-null with "missing".
    /// The legacy expression is evaluated only when the atomic signed slot is genuinely absent;
    /// present corrupt bytes throw before a stale endpoint can be observed.
    public func streamEndpoint(
        legacyEndpoint: @autoclosure () throws -> String?
    ) throws -> String? {
        if let envelope = try envelope() {
            return try envelope.signedStreamEndpoint()
        }
        guard let legacyEndpoint = try legacyEndpoint() else { return nil }
        return StreamEndpoint.normalize(legacyEndpoint)
    }
}

/// Ordered, non-secret mutation plan for leaving signed mode. The order is security-significant:
/// while a signed envelope exists it masks every legacy projection, so the verified stack and raw
/// token can be prepared before deleting the envelope. Without a signed envelope, an old raw token
/// must be removed before changing its stack; the new raw token is the final authority commit.
public enum JazzLegacyCredentialTransitionOperation: Equatable, Sendable {
    case deleteRawToken
    case deleteRawStream
    case setVerifiedStack
    case setRawToken
    case deleteSignedEnvelope
}

public enum JazzLegacyCredentialTransitionPlan {
    public static func operations(
        signedEnvelopePresent: Bool
    ) -> [JazzLegacyCredentialTransitionOperation] {
        if signedEnvelopePresent {
            return [
                .setVerifiedStack,
                .setRawToken,
                .deleteRawStream,
                .deleteSignedEnvelope,
            ]
        }
        return [
            .deleteRawToken,
            .deleteRawStream,
            .setVerifiedStack,
            .setRawToken,
        ]
    }
}
