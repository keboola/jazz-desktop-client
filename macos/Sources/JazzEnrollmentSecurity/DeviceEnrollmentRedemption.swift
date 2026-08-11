import CryptoKit
import Foundation
import JazzCaptureCore

/// Fail-closed, operator-safe errors for the native device-bound redemption protocol.
///
/// Descriptions deliberately omit bootstrap bearer bytes, URLs, claims, ciphertext, decrypted
/// bundle content, and server response bodies. They are safe to surface in Settings.
public enum DeviceEnrollmentRedemptionError: Error, Equatable, CustomStringConvertible {
    case malformedBootstrap
    case insecureRedemptionRoute
    case bootstrapExpired
    case pendingConflict
    case pendingStateUnavailable
    case malformedContext
    case authorityMismatch
    case malformedResponse
    case unauthorized
    case quarantined
    case serverUnavailable
    case signedBundleMismatch

    public var description: String {
        switch self {
        case .malformedBootstrap:
            "The device enrollment bootstrap is malformed."
        case .insecureRedemptionRoute:
            "The device enrollment redemption route is not a canonical HTTPS endpoint."
        case .bootstrapExpired:
            "The device enrollment bootstrap has expired; issue a new one."
        case .pendingConflict:
            "Another device enrollment is already pending on this Mac."
        case .pendingStateUnavailable:
            "The pending device enrollment Keychain state is unavailable."
        case .malformedContext:
            "The enrollment server returned an invalid device context."
        case .authorityMismatch:
            "The enrollment server context does not match this Mac's trusted enrollment authority."
        case .malformedResponse:
            "The enrollment server returned an invalid redemption response."
        case .unauthorized:
            "The one-time device enrollment authorization was rejected."
        case .quarantined:
            "The device enrollment was quarantined by the server."
        case .serverUnavailable:
            "The device enrollment server is temporarily unavailable."
        case .signedBundleMismatch:
            "The redeemed signed enrollment does not match its reserved device context."
        }
    }
}

/// Exact one-time handoff copied from the authenticated web control plane.
///
/// `redemptionURL` is routing, not signed authority. The client obtains authority from the
/// bearer-authenticated context endpoint and independently verifies the eventual bundle against
/// its code-signed issuer policy.
public struct DeviceRedemptionBootstrap: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let bootstrapId: String
    public let deviceId: String
    public let bundleId: String
    public let generation: Int
    public let bearer: String
    public let issuedAt: String
    public let expiresAt: String
    public let serverTime: String
    public let redemptionURL: String

    private static let keys: Set<String> = [
        "schemaVersion", "kind", "bootstrapId", "deviceId", "bundleId", "generation",
        "bearer", "issuedAt", "expiresAt", "serverTime", "redemptionURL",
    ]
    private static let bootstrapID = try! NSRegularExpression(
        pattern: "^jbt_[a-f0-9]{32}$")
    private static let bundleID = try! NSRegularExpression(
        pattern: "^jdb_[a-f0-9]{32}$")
    private static let deviceID = try! NSRegularExpression(
        pattern: "^[a-z0-9][a-z0-9-]{0,63}$")
    private static let bearerPattern = try! NSRegularExpression(
        pattern: "^[A-Za-z0-9_-]{43}$")

    public static func parse(_ text: String) throws -> DeviceRedemptionBootstrap {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            trimmed.utf8.count <= 16_384,
            let data = trimmed.data(using: .utf8),
            StrictJSON.hasUniqueObjectKeys(data),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(object.keys) == keys,
            let value = try? JSONDecoder().decode(DeviceRedemptionBootstrap.self, from: data)
        else {
            throw DeviceEnrollmentRedemptionError.malformedBootstrap
        }
        try value.validate()
        return value
    }

    public var redemptionEndpoint: URL {
        // validate() proves this is non-nil and canonical.
        URL(string: redemptionURL)!
    }

    public var expiresAtDate: Date {
        Timestamps.parse(expiresAt)!
    }

    fileprivate func validate() throws {
        guard
            schemaVersion == 1,
            kind == "jazz-device-redemption-bootstrap",
            Self.matches(bootstrapId, Self.bootstrapID),
            Self.matches(deviceId, Self.deviceID),
            Self.matches(bundleId, Self.bundleID),
            (1...9_007_199_254_740_991).contains(generation),
            Self.matches(bearer, Self.bearerPattern),
            let bearerData = EnrollmentEncoding.decodeBase64URL(
                bearer,
                maximumBytes: 32),
            bearerData.count == 32,
            EnrollmentEncoding.encodeBase64URL(bearerData) == bearer,
            let issued = Self.timestamp(issuedAt),
            let expires = Self.timestamp(expiresAt),
            let server = Self.timestamp(serverTime),
            issued == server,
            expires > issued,
            expires.timeIntervalSince(issued) <= 900
        else {
            throw DeviceEnrollmentRedemptionError.malformedBootstrap
        }
        guard
            let endpoint = URL(string: redemptionURL),
            Self.isCanonicalRedemptionEndpoint(
                endpoint,
                bootstrapID: bootstrapId),
            endpoint.absoluteString == redemptionURL
        else {
            throw DeviceEnrollmentRedemptionError.insecureRedemptionRoute
        }
    }

    private static func isCanonicalRedemptionEndpoint(
        _ url: URL,
        bootstrapID: String
    ) -> Bool {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == "https",
            let host = components.host,
            !host.isEmpty,
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil,
            components.port.map({ (1...65_535).contains($0) }) ?? true
        else {
            return false
        }
        let suffix = "/api/device-enrollment/redemptions/\(bootstrapID)"
        return components.path.hasSuffix(suffix)
            && !components.path.dropLast(suffix.count).contains("//")
    }

    fileprivate static func timestamp(_ value: String) -> Date? {
        guard
            value.range(
                of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$"#,
                options: .regularExpression
            ) != nil
        else {
            return nil
        }
        return Timestamps.parse(value)
    }

    private static func matches(
        _ value: String,
        _ expression: NSRegularExpression
    ) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.firstMatch(in: value, range: range)?.range == range
    }
}

/// Server-derived authority fetched before any device claim is sent.
public struct DeviceRedemptionContext: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let operationId: String
    public let bootstrapId: String
    public let deviceId: String
    public let bundleId: String
    public let generation: Int
    public let issuer: String
    public let audience: String
    public let companyId: String
    public let areaId: String
    public let projectId: String
    public let stackURL: String
    public let archiveIngestURL: String
    public let deviceScopeSHA256: String
    public let serverTime: String
    public let expiresAt: String

    private static let keys: Set<String> = [
        "schemaVersion", "kind", "operationId", "bootstrapId", "deviceId", "bundleId",
        "generation", "issuer", "audience", "companyId", "areaId", "projectId", "stackURL",
        "archiveIngestURL", "deviceScopeSHA256", "serverTime", "expiresAt",
    ]
    private static let operationID = try! NSRegularExpression(
        pattern: "^eio_[a-f0-9]{32}$")
    private static let scopeID = try! NSRegularExpression(
        pattern: "^[a-z0-9][a-z0-9-]{0,63}$")
    private static let projectID = try! NSRegularExpression(pattern: "^[0-9]+$")
    private static let digest = try! NSRegularExpression(pattern: "^[a-f0-9]{64}$")

    static func parse(
        _ data: Data,
        bootstrap: DeviceRedemptionBootstrap,
        trustPolicy: EnrollmentTrustPolicy
    ) throws -> DeviceRedemptionContext {
        guard
            !data.isEmpty,
            data.count <= 32_768,
            StrictJSON.hasUniqueObjectKeys(data),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(object.keys) == keys,
            let value = try? JSONDecoder().decode(DeviceRedemptionContext.self, from: data)
        else {
            throw DeviceEnrollmentRedemptionError.malformedContext
        }
        try value.validate(bootstrap: bootstrap, trustPolicy: trustPolicy)
        return value
    }

    var identityBinding: DeviceEnrollmentIdentityBinding {
        get throws {
            try DeviceEnrollmentIdentityBinding(
                deviceId: deviceId,
                authorityBindingSHA256: authorityBindingSHA256)
        }
    }

    var authorityBindingSHA256: String {
        get throws {
            try Self.canonicalDigest([
                "schema": "jazz-device-enrollment-authority/v1",
                "issuer": issuer,
                "audience": audience,
                "companyId": companyId,
                "areaId": areaId,
                "projectId": projectId,
                "stackURL": stackURL,
                "archiveIngestURL": archiveIngestURL,
            ])
        }
    }

    fileprivate func validate(
        bootstrap: DeviceRedemptionBootstrap,
        trustPolicy: EnrollmentTrustPolicy
    ) throws {
        guard
            schemaVersion == 1,
            kind == "jazz-device-redemption-context",
            Self.matches(operationId, Self.operationID),
            bootstrapId == bootstrap.bootstrapId,
            deviceId == bootstrap.deviceId,
            bundleId == bootstrap.bundleId,
            generation == bootstrap.generation,
            issuer == trustPolicy.issuer,
            audience == trustPolicy.audience,
            Self.matches(companyId, Self.scopeID),
            Self.matches(areaId, Self.scopeID),
            Self.matches(projectId, Self.projectID),
            KeboolaStack.normalize(stackURL) == stackURL,
            JazzArchiveControlPlaneURL.normalize(archiveIngestURL) == archiveIngestURL,
            Self.matches(deviceScopeSHA256, Self.digest),
            let server = DeviceRedemptionBootstrap.timestamp(serverTime),
            let expires = DeviceRedemptionBootstrap.timestamp(expiresAt),
            expires > server,
            expiresAt == bootstrap.expiresAt
        else {
            throw DeviceEnrollmentRedemptionError.authorityMismatch
        }
        let expectedScope = try Self.canonicalDigest([
            "schema": "jazz-device-enrollment-scope/v1",
            "deviceId": deviceId,
            "companyId": companyId,
            "areaId": areaId,
            "projectId": projectId,
        ])
        guard expectedScope == deviceScopeSHA256 else {
            throw DeviceEnrollmentRedemptionError.authorityMismatch
        }
        _ = try identityBinding
    }

    private static func canonicalDigest(_ object: [String: Any]) throws -> String {
        guard let bytes = EnrollmentEncoding.canonicalJSONObject(object) else {
            throw DeviceEnrollmentRedemptionError.malformedContext
        }
        return SHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func matches(
        _ value: String,
        _ expression: NSRegularExpression
    ) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.firstMatch(in: value, range: range)?.range == range
    }
}

/// Raw, bounded response returned by the injectable HTTPS boundary.
public struct DeviceRedemptionHTTPResponse: Sendable {
    public let statusCode: Int
    public let body: Data
    public let headers: [String: String]

    public init(
        statusCode: Int,
        body: Data,
        headers: [String: String] = [:]
    ) {
        self.statusCode = statusCode
        self.body = body
        self.headers = Dictionary(
            uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
    }
}

/// The bearer is supplied only as an HTTP header value by the production implementation.
public protocol DeviceRedemptionTransport: Sendable {
    func fetchContext(
        endpoint: URL,
        bearer: String
    ) async throws -> DeviceRedemptionHTTPResponse

    func submitClaim(
        endpoint: URL,
        bearer: String,
        exactClaim: Data
    ) async throws -> DeviceRedemptionHTTPResponse

    func poll(
        endpoint: URL,
        bearer: String
    ) async throws -> DeviceRedemptionHTTPResponse
}

/// Opaque persistence seam. Production stores these exact bytes in one Keychain item.
public protocol DeviceRedemptionPendingStoring: Sendable {
    func load() throws -> Data?
    func replace(_ exactBytes: Data) throws
    func delete() throws
}

public struct RedeemedDeviceEnrollment: Sendable {
    public let bootstrapId: String
    public let exactSignedBundle: String

    public init(bootstrapId: String, exactSignedBundle: String) {
        self.bootstrapId = bootstrapId
        self.exactSignedBundle = exactSignedBundle
    }
}

public struct DeviceRedemptionPendingIdentity: Equatable, Sendable {
    public let bootstrapId: String
    public let deviceId: String
    public let bundleId: String
    public let generation: Int
    public let issuer: String?
    public let audience: String?

    public init(
        bootstrapId: String,
        deviceId: String,
        bundleId: String,
        generation: Int,
        issuer: String?,
        audience: String?
    ) {
        self.bootstrapId = bootstrapId
        self.deviceId = deviceId
        self.bundleId = bundleId
        self.generation = generation
        self.issuer = issuer
        self.audience = audience
    }
}

/// Restart-safe native redemption coordinator.
///
/// Context is committed before key creation/claim, and exact claim bytes are committed before
/// POST. A crash at any network boundary therefore resumes with the same authority, keys and bytes.
public actor DeviceEnrollmentRedemptionCoordinator {
    private struct PendingRecord: Codable {
        let schemaVersion: Int
        let bootstrap: DeviceRedemptionBootstrap
        var context: DeviceRedemptionContext?
        var exactClaimBase64: String?
        var claimSubmitted: Bool
    }

    private let pendingStore: any DeviceRedemptionPendingStoring
    private let transport: any DeviceRedemptionTransport
    private let identityVault: DeviceEnrollmentIdentityVault
    private let trustPolicy: EnrollmentTrustPolicy
    private let routePolicy: EnrollmentRedemptionRoutePolicy
    private let claimID: @Sendable () -> String
    private let now: @Sendable () -> Date

    public init(
        pendingStore: any DeviceRedemptionPendingStoring,
        transport: any DeviceRedemptionTransport,
        identityVault: DeviceEnrollmentIdentityVault,
        trustPolicy: EnrollmentTrustPolicy,
        routePolicy: EnrollmentRedemptionRoutePolicy,
        claimID: @escaping @Sendable () -> String = {
            "jcl_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.pendingStore = pendingStore
        self.transport = transport
        self.identityVault = identityVault
        self.trustPolicy = trustPolicy
        self.routePolicy = routePolicy
        self.claimID = claimID
        self.now = now
    }

    /// Persist a newly pasted bootstrap before any request and advance it by one network step.
    public func begin(_ text: String) async throws -> RedeemedDeviceEnrollment? {
        let bootstrap = try DeviceRedemptionBootstrap.parse(text)
        guard routePolicy.allows(bootstrap.redemptionEndpoint) else {
            throw DeviceEnrollmentRedemptionError.insecureRedemptionRoute
        }
        guard now().addingTimeInterval(-30) < bootstrap.expiresAtDate else {
            throw DeviceEnrollmentRedemptionError.bootstrapExpired
        }
        if let existing = try loadPending() {
            if existing.bootstrap != bootstrap {
                guard now().addingTimeInterval(-30) >= existing.bootstrap.expiresAtDate else {
                    throw DeviceEnrollmentRedemptionError.pendingConflict
                }
                // Expiry is authenticated by the strict persisted bootstrap record. Delete only
                // that short-lived pending record, never the identity or activated credential.
                try deletePending()
                try persist(
                    PendingRecord(
                        schemaVersion: 1,
                        bootstrap: bootstrap,
                        context: nil,
                        exactClaimBase64: nil,
                        claimSubmitted: false))
            }
        } else {
            try persist(
                PendingRecord(
                    schemaVersion: 1,
                    bootstrap: bootstrap,
                    context: nil,
                    exactClaimBase64: nil,
                    claimSubmitted: false))
        }
        return try await resume()
    }

    /// Resume the exact Keychain state. Returns nil while the durable server worker is pending.
    public func resume() async throws -> RedeemedDeviceEnrollment? {
        guard var pending = try loadPending() else { return nil }
        guard routePolicy.allows(pending.bootstrap.redemptionEndpoint) else {
            throw DeviceEnrollmentRedemptionError.insecureRedemptionRoute
        }
        guard now().addingTimeInterval(-30) < pending.bootstrap.expiresAtDate else {
            throw DeviceEnrollmentRedemptionError.bootstrapExpired
        }

        if pending.context == nil {
            let response: DeviceRedemptionHTTPResponse
            do {
                response = try await transport.fetchContext(
                    endpoint: pending.bootstrap.redemptionEndpoint,
                    bearer: pending.bootstrap.bearer)
            } catch {
                throw DeviceEnrollmentRedemptionError.serverUnavailable
            }
            try requireSuccess(response)
            pending.context = try DeviceRedemptionContext.parse(
                response.body,
                bootstrap: pending.bootstrap,
                trustPolicy: trustPolicy)
            // This commit is deliberately before claim. Context may cease to be readable after the
            // worker advances the device revision, but a restart must retain its original authority.
            try persist(pending)
        }
        let context = pending.context!
        let identity = try identityVault.loadOrCreate(
            binding: context.identityBinding,
            now: now())

        if pending.exactClaimBase64 == nil {
            guard
                let serverTime = Timestamps.parse(context.serverTime),
                let contextExpiry = Timestamps.parse(context.expiresAt)
            else {
                throw DeviceEnrollmentRedemptionError.malformedContext
            }
            let claimExpiry = min(
                serverTime.addingTimeInterval(300),
                contextExpiry.addingTimeInterval(-1))
            guard claimExpiry > serverTime else {
                throw DeviceEnrollmentRedemptionError.bootstrapExpired
            }
            let exactClaim = try identity.makeClaim(
                bootstrapId: pending.bootstrap.bootstrapId,
                claimId: claimID(),
                issuedAt: Self.timestamp(serverTime),
                expiresAt: Self.timestamp(claimExpiry))
            _ = try DeviceBoundEnrollmentCrypto.verifyClaim(exactClaim)
            pending.exactClaimBase64 = exactClaim.base64EncodedString()
            // Exact bytes are durable before POST. A crash after server CAS safely re-POSTs them.
            try persist(pending)
        }
        guard
            let encodedClaim = pending.exactClaimBase64,
            let exactClaim = Data(base64Encoded: encodedClaim)
        else {
            throw DeviceEnrollmentRedemptionError.pendingStateUnavailable
        }

        let response: DeviceRedemptionHTTPResponse
        do {
            if pending.claimSubmitted {
                response = try await transport.poll(
                    endpoint: pending.bootstrap.redemptionEndpoint,
                    bearer: pending.bootstrap.bearer)
            } else {
                response = try await transport.submitClaim(
                    endpoint: pending.bootstrap.redemptionEndpoint,
                    bearer: pending.bootstrap.bearer,
                    exactClaim: exactClaim)
            }
        } catch {
            throw DeviceEnrollmentRedemptionError.serverUnavailable
        }

        if response.statusCode == 202 {
            try validatePending(response.body, pending: pending, exactClaim: exactClaim)
            if !pending.claimSubmitted {
                pending.claimSubmitted = true
                try persist(pending)
            }
            return nil
        }
        try requireSuccess(response)
        return try openAndVerify(
            response,
            pending: pending,
            context: context,
            identity: identity,
            exactClaim: exactClaim)
    }

    /// Remove the bootstrap bearer only after `KeboolaConnection.importBundle` committed the signed
    /// credential envelope. A mismatched completion can never delete another pending enrollment.
    public func completeActivation(bootstrapId: String) throws {
        guard let pending = try loadPending() else { return }
        guard pending.bootstrap.bootstrapId == bootstrapId else {
            throw DeviceEnrollmentRedemptionError.pendingConflict
        }
        try deletePending()
    }

    /// Explicit operator recovery for abandoned, unauthorized, quarantined, or corrupt pending
    /// state. This removes only the short-lived redemption record. It never revokes Secure Enclave
    /// keys or deletes an already activated signed credential.
    public func discardPendingEnrollment() throws {
        try deletePending()
    }

    public func hasPendingEnrollment() -> Bool {
        do {
            return try pendingStore.load() != nil
        } catch {
            // Corruption or Keychain denial is not genuine absence and must block legacy fallback.
            return true
        }
    }

    public func pendingIdentity() throws -> DeviceRedemptionPendingIdentity? {
        guard let pending = try loadPending() else { return nil }
        return DeviceRedemptionPendingIdentity(
            bootstrapId: pending.bootstrap.bootstrapId,
            deviceId: pending.bootstrap.deviceId,
            bundleId: pending.bootstrap.bundleId,
            generation: pending.bootstrap.generation,
            issuer: pending.context?.issuer,
            audience: pending.context?.audience)
    }

    private func openAndVerify(
        _ response: DeviceRedemptionHTTPResponse,
        pending: PendingRecord,
        context: DeviceRedemptionContext,
        identity: DeviceEnrollmentIdentity,
        exactClaim: Data
    ) throws -> RedeemedDeviceEnrollment {
        guard response.body.count <= 200_000 else {
            throw DeviceEnrollmentRedemptionError.malformedResponse
        }
        let envelopeSHA256 = Self.hexSHA256(response.body)
        guard
            response.headers["content-type"]
                == "application/jazz-device-enrollment-sealed+json",
            response.headers["etag"] == "\"sha256:\(envelopeSHA256)\"",
            let headerBundleDigest = response.headers["x-jazz-bundle-sha256"],
            headerBundleDigest.range(
                of: "^[a-f0-9]{64}$",
                options: .regularExpression
            ) != nil,
            response.headers["x-jazz-bootstrap-expires-at"] == pending.bootstrap.expiresAt
        else {
            throw DeviceEnrollmentRedemptionError.malformedResponse
        }
        let claim = try DeviceBoundEnrollmentCrypto.verifyClaim(exactClaim)
        let inspection = try DeviceBoundEnrollmentCrypto.inspectSealedBundle(response.body)
        guard
            inspection.descriptor.bundleId == pending.bootstrap.bundleId,
            inspection.descriptor.generation == pending.bootstrap.generation,
            inspection.descriptor.revealExpiresAt == pending.bootstrap.expiresAt,
            inspection.bundleSHA256 == headerBundleDigest
        else {
            throw DeviceEnrollmentRedemptionError.signedBundleMismatch
        }
        let plaintext = try identity.openSealedBundle(
            response.body,
            binding: claim.binding,
            descriptor: inspection.descriptor,
            now: now())
        guard
            Self.hexSHA256(plaintext) == headerBundleDigest,
            let signedText = String(data: plaintext, encoding: .utf8),
            Data(signedText.utf8) == plaintext
        else {
            throw DeviceEnrollmentRedemptionError.signedBundleMismatch
        }
        let verified = try SignedEnrollmentVerifier(
            trustPolicy: trustPolicy
        ).verify(signedText, now: now())
        let payload = verified.payload
        guard
            payload.bundleId == pending.bootstrap.bundleId,
            payload.generation == pending.bootstrap.generation,
            payload.deviceId == context.deviceId,
            payload.issuer == context.issuer,
            payload.audience == context.audience,
            payload.companyId == context.companyId,
            payload.areaId == context.areaId,
            payload.projectId == context.projectId,
            payload.stackURL == context.stackURL,
            payload.archiveIngestURL == context.archiveIngestURL
        else {
            throw DeviceEnrollmentRedemptionError.signedBundleMismatch
        }
        return RedeemedDeviceEnrollment(
            bootstrapId: pending.bootstrap.bootstrapId,
            exactSignedBundle: signedText)
    }

    private func validatePending(
        _ data: Data,
        pending: PendingRecord,
        exactClaim: Data
    ) throws {
        struct Status: Decodable {
            let schemaVersion: Int
            let kind: String
            let bootstrapId: String
            let deviceId: String
            let bundleId: String
            let generation: Int
            let state: String
            let claimId: String?
            let serverTime: String
            let expiresAt: String
        }
        guard
            !data.isEmpty,
            data.count <= 16_384,
            StrictJSON.hasUniqueObjectKeys(data),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(object.keys).isSubset(of: [
                "schemaVersion", "kind", "bootstrapId", "deviceId", "bundleId", "generation",
                "state", "claimId", "disposition", "serverTime", "expiresAt",
            ]),
            let status = try? JSONDecoder().decode(Status.self, from: data),
            status.schemaVersion == 1,
            status.kind == "jazz-device-redemption-status",
            status.bootstrapId == pending.bootstrap.bootstrapId,
            status.deviceId == pending.bootstrap.deviceId,
            status.bundleId == pending.bootstrap.bundleId,
            status.generation == pending.bootstrap.generation,
            status.state == "pending",
            status.expiresAt == pending.bootstrap.expiresAt
        else {
            throw DeviceEnrollmentRedemptionError.malformedResponse
        }
        if let claimID = status.claimId {
            let verified = try DeviceBoundEnrollmentCrypto.verifyClaim(exactClaim)
            guard verified.binding.claimId == claimID else {
                throw DeviceEnrollmentRedemptionError.malformedResponse
            }
        }
    }

    private func requireSuccess(_ response: DeviceRedemptionHTTPResponse) throws {
        switch response.statusCode {
        case 200:
            return
        case 401:
            throw DeviceEnrollmentRedemptionError.unauthorized
        case 410:
            throw DeviceEnrollmentRedemptionError.bootstrapExpired
        case 423:
            throw DeviceEnrollmentRedemptionError.quarantined
        default:
            throw DeviceEnrollmentRedemptionError.serverUnavailable
        }
    }

    private func loadPending() throws -> PendingRecord? {
        let data: Data?
        do {
            data = try pendingStore.load()
        } catch {
            throw DeviceEnrollmentRedemptionError.pendingStateUnavailable
        }
        guard let data else { return nil }
        guard
            !data.isEmpty,
            data.count <= 300_000,
            StrictJSON.hasUniqueObjectKeys(data),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(object.keys).isSubset(of: [
                "schemaVersion", "bootstrap", "context", "exactClaimBase64", "claimSubmitted",
            ]),
            let record = try? JSONDecoder().decode(PendingRecord.self, from: data),
            record.schemaVersion == 1
        else {
            throw DeviceEnrollmentRedemptionError.pendingStateUnavailable
        }
        do {
            try record.bootstrap.validate()
            guard routePolicy.allows(record.bootstrap.redemptionEndpoint) else {
                throw DeviceEnrollmentRedemptionError.insecureRedemptionRoute
            }
            if let context = record.context {
                try context.validate(
                    bootstrap: record.bootstrap,
                    trustPolicy: trustPolicy)
            }
            if let encodedClaim = record.exactClaimBase64 {
                guard
                    encodedClaim.utf8.count <= 30_000,
                    let exactClaim = Data(base64Encoded: encodedClaim)
                else {
                    throw DeviceEnrollmentRedemptionError.pendingStateUnavailable
                }
                let claim = try DeviceBoundEnrollmentCrypto.verifyClaim(exactClaim)
                guard
                    record.context != nil,
                    claim.payload.bootstrapId == record.bootstrap.bootstrapId,
                    claim.payload.deviceId == record.bootstrap.deviceId
                else {
                    throw DeviceEnrollmentRedemptionError.pendingStateUnavailable
                }
            } else if record.claimSubmitted {
                throw DeviceEnrollmentRedemptionError.pendingStateUnavailable
            }
        } catch let error as DeviceEnrollmentRedemptionError {
            throw error
        } catch {
            throw DeviceEnrollmentRedemptionError.pendingStateUnavailable
        }
        return record
    }

    private func persist(_ record: PendingRecord) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try pendingStore.replace(encoder.encode(record))
        } catch {
            throw DeviceEnrollmentRedemptionError.pendingStateUnavailable
        }
    }

    private func deletePending() throws {
        do {
            try pendingStore.delete()
        } catch {
            throw DeviceEnrollmentRedemptionError.pendingStateUnavailable
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter.string(from: date)
    }

    private static func hexSHA256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
