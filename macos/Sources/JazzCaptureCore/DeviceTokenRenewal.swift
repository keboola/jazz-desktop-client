import Foundation

/// Unattended device-token renewal — the DECISION half (ADR 0005).
///
/// A device credential lives about an hour. Before this existed an enrolled Mac simply stopped
/// uploading when it lapsed, silently, mid-pilot. The server now exposes
/// `POST …/api/device-enrollment/renewals`: the device presents the credential it already holds
/// plus the non-secret id of that credential, and receives one fresh credential with the SAME
/// scope. Renewal is not a refresh token — it grants nothing the presented credential did not
/// already have, and an expired device must go back through the admin bundle path.
///
/// Everything in this file is pure Foundation and unit-tested in CI (Golden Rule 4): route
/// derivation, request bytes, response validation, failure classification, the renewal schedule
/// and the retry backoff. The executable target (``DeviceTokenRenewer``) owns the URLSession call,
/// the Keychain swap, and the menu-bar surface.
///
/// Secret handling: the renewed token appears only inside ``JazzDeviceTokenRenewalGrant``, which is
/// deliberately non-Codable, redacted in both string conversions, and consumed exactly once by
/// ``JazzSignedDeviceCredentialEnvelope/renewed(with:)``. It never enters a log, a queue, a URL,
/// or UserDefaults.
public enum JazzDeviceTokenRenewalError: Error, Equatable, CustomStringConvertible {
    /// The signed archive route cannot yield a renewal endpoint (unsigned, or not an ingest route).
    case invalidRoute
    /// The device identity or the asserted token id is not a value this client may send.
    case invalidRequest
    /// A 200 response that does not prove it renewed THIS device's credential.
    case invalidResponse(String)
    /// A grant that would change where or with what authority this device delivers.
    case authorityChanged

    public var description: String {
        switch self {
        case .invalidRoute:
            "Device-token renewal requires a signed Jazz Archive enrollment."
        case .invalidRequest:
            "The device-token renewal request identity is invalid."
        case let .invalidResponse(reason):
            "The device-token renewal response was rejected (\(reason))."
        case .authorityChanged:
            "The renewed device credential would change this device's delivery authority."
        }
    }
}

// MARK: - Route

/// The renewal endpoint, derived the same way every other native route is: from the exact signed
/// archive-ingest authority, never from a browser-supplied or user-editable host. Any deployment
/// path prefix is preserved byte-for-byte; only the terminal API resource is replaced.
public struct JazzDeviceTokenRenewalRoute: Equatable, Sendable {
    static let archiveSuffix = "/api/archive-ingests"
    static let renewalSuffix = "/api/device-enrollment/renewals"

    /// Small by construction — a grant is a handful of short fields.
    public static let maximumResponseBytes = 64 * 1_024

    public let url: URL
    public let deviceId: String

    public init(routeBinding: JazzArchiveUploadRouteBinding) throws {
        guard routeBinding.hasSignedAuthority,
            var components = URLComponents(string: routeBinding.ingestEndpoint),
            JazzArchiveControlPlaneURL.normalize(routeBinding.ingestEndpoint)
                == routeBinding.ingestEndpoint,
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil,
            components.percentEncodedPath.hasSuffix(Self.archiveSuffix)
        else { throw JazzDeviceTokenRenewalError.invalidRoute }
        components.percentEncodedPath =
            String(components.percentEncodedPath.dropLast(Self.archiveSuffix.count))
            + Self.renewalSuffix
        guard let url = components.url,
            let scheme = url.scheme?.lowercased(),
            scheme == "https"
                || (scheme == "http"
                    && ["localhost", "127.0.0.1", "::1"].contains(url.host?.lowercased() ?? "")),
            url.query == nil,
            url.fragment == nil
        else { throw JazzDeviceTokenRenewalError.invalidRoute }
        self.url = url
        deviceId = routeBinding.scope.deviceId
    }

    /// One credential-bearing request, built in memory for exactly one attempt. The token is read
    /// from the caller's provider per attempt and is never retained by the route.
    public func request(
        body: Data,
        credential: JazzArchiveScopedDeviceCredential,
        timeout: TimeInterval = 20
    ) throws -> URLRequest {
        guard !body.isEmpty, timeout.isFinite, timeout > 0 else {
            throw JazzDeviceTokenRenewalError.invalidRequest
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(deviceId, forHTTPHeaderField: "X-Jazz-Device-Id")
        credential.withValue {
            request.setValue($0, forHTTPHeaderField: "X-StorageApi-Token")
        }
        request.httpBody = body
        return request
    }
}

// MARK: - Request

/// The exact renewal assertion. `currentTokenId` is the NON-SECRET id of the credential presented
/// in the header — a compare-and-set assertion, never a credential.
///
/// The bytes are a deterministic function of the two identities, which is what makes a dropped
/// response recoverable: the server keeps the just-superseded credential renewal-valid for a
/// bounded grace window, so replaying the identical request (same header token, same asserted id)
/// yields a fresh credential instead of a conflict. A retry therefore MUST NOT re-derive
/// `currentTokenId` from anything but the still-unchanged stored credential.
public struct JazzDeviceTokenRenewalRequest: Equatable, Sendable {
    public static let kind = "jazz-device-token-renewal-request"
    public static let schemaVersion = 1

    public let deviceId: String
    public let currentTokenId: String

    public init(deviceId: String, currentTokenId: String) throws {
        guard Self.isCanonical(deviceId), Self.isCanonical(currentTokenId) else {
            throw JazzDeviceTokenRenewalError.invalidRequest
        }
        self.deviceId = deviceId
        self.currentTokenId = currentTokenId
    }

    public init(routeBinding: JazzArchiveUploadRouteBinding) throws {
        guard routeBinding.hasSignedAuthority else {
            throw JazzDeviceTokenRenewalError.invalidRoute
        }
        try self.init(
            deviceId: routeBinding.scope.deviceId,
            currentTokenId: routeBinding.tokenId)
    }

    /// Deterministic request bytes. Two builds of the same assertion are byte-identical, so an
    /// exact replay after a lost response is trivially exact.
    public func body() throws -> Data {
        struct Payload: Encodable {
            let deviceId: String
            let currentTokenId: String
            let kind: String
            let schemaVersion: Int
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(
            Payload(
                deviceId: deviceId,
                currentTokenId: currentTokenId,
                kind: Self.kind,
                schemaVersion: Self.schemaVersion))
    }

    private static func isCanonical(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 256
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.unicodeScalars.allSatisfy { scalar in
                !CharacterSet.whitespacesAndNewlines.contains(scalar)
                    && !CharacterSet.controlCharacters.contains(scalar)
                    && scalar.value != 0x7f
            }
    }
}

// MARK: - Grant

/// A verified 200 response. Construction IS the verification: a grant exists only when the server
/// renewed this exact device, minted a genuinely different credential, and kept the scope the
/// device already holds. Nothing here is Codable — the token must not be serializable.
public struct JazzDeviceTokenRenewalGrant: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    public static let kind = "jazz-device-token-renewal"
    public static let schemaVersion = 1
    /// Refuse an absurd server-supplied lead time rather than parking renewal for a year.
    public static let maximumRenewAfterSeconds = 30 * 24 * 60 * 60

    public let deviceId: String
    public let tokenId: String
    public let expiresAt: String
    public let expiresAtDate: Date
    public let tokenBucketScope: JazzArchiveTokenBucketScope
    public let sinkBucketId: String?
    public let componentAccess: [String]
    /// The server owns the renewal lead time. `nil` means an older deployment did not supply it and
    /// the client must fall back to its documented legacy fraction.
    public let renewAfterSeconds: Int?
    public let serverTime: String?
    fileprivate let token: String

    public var description: String { "<redacted device token renewal grant>" }
    public var debugDescription: String { description }

    /// Validate a 200 body against the credential this device currently holds.
    ///
    /// Every mismatch is fail-closed: a grant for another device, a repeat of the id we already
    /// have, an expiry in the past, or a bucket scope that drifted must never reach the Keychain.
    public init(
        responseData: Data,
        request: JazzDeviceTokenRenewalRequest,
        currentRouting: JazzArchiveEnrollmentRouting,
        now: Date
    ) throws {
        guard case let .object(root) = try? JSONDecoder().decode(
            JazzArchiveJSONValue.self,
            from: responseData)
        else { throw JazzDeviceTokenRenewalError.invalidResponse("body is not an object") }

        guard Self.integer(root["schemaVersion"]) == Self.schemaVersion else {
            throw JazzDeviceTokenRenewalError.invalidResponse("schemaVersion")
        }
        guard case let .string(kind)? = root["kind"], kind == Self.kind else {
            throw JazzDeviceTokenRenewalError.invalidResponse("kind")
        }
        guard let deviceId = Self.text(root["deviceId"]), deviceId == request.deviceId else {
            throw JazzDeviceTokenRenewalError.invalidResponse("deviceId")
        }
        guard let tokenId = Self.text(root["tokenId"]), tokenId != request.currentTokenId else {
            throw JazzDeviceTokenRenewalError.invalidResponse("tokenId")
        }
        guard let token = Self.secret(root["token"]) else {
            throw JazzDeviceTokenRenewalError.invalidResponse("token")
        }
        guard let expiresAt = Self.text(root["expiresAt"]),
            let expiry = Timestamps.parse(expiresAt),
            expiry.timeIntervalSinceReferenceDate.isFinite,
            expiry > now
        else { throw JazzDeviceTokenRenewalError.invalidResponse("expiresAt") }

        // The renewed credential must carry exactly the bucket scope the device already proved at
        // enrollment. A broadened (or narrowed) scope is a re-enrollment, not a renewal.
        guard let scopeText = Self.text(root["tokenBucketScope"]),
            let scope = JazzArchiveTokenBucketScope(rawValue: scopeText),
            let currentScope = currentRouting.tokenBucketScope,
            scope == currentScope
        else { throw JazzDeviceTokenRenewalError.invalidResponse("tokenBucketScope") }
        let sinkBucketId = Self.optionalText(root["sinkBucketId"])
        guard sinkBucketId == currentRouting.sinkBucketId,
            (scope == .sink) == (sinkBucketId != nil)
        else { throw JazzDeviceTokenRenewalError.invalidResponse("sinkBucketId") }

        guard let componentAccess = Self.strings(root["componentAccess"]) else {
            throw JazzDeviceTokenRenewalError.invalidResponse("componentAccess")
        }
        let renewAfterSeconds: Int?
        switch root["renewAfterSeconds"] {
        case nil, .some(.null):
            renewAfterSeconds = nil
        default:
            guard let seconds = Self.integer(root["renewAfterSeconds"]),
                seconds >= 1,
                seconds <= Self.maximumRenewAfterSeconds
            else { throw JazzDeviceTokenRenewalError.invalidResponse("renewAfterSeconds") }
            renewAfterSeconds = seconds
        }

        self.deviceId = deviceId
        self.tokenId = tokenId
        self.token = token
        self.expiresAt = expiresAt
        expiresAtDate = expiry
        tokenBucketScope = scope
        self.sinkBucketId = sinkBucketId
        self.componentAccess = componentAccess
        self.renewAfterSeconds = renewAfterSeconds
        serverTime = Self.optionalText(root["serverTime"])
    }

    private static func integer(_ value: JazzArchiveJSONValue?) -> Int? {
        switch value {
        case let .integer(number): Int(exactly: number)
        case let .unsignedInteger(number): Int(exactly: number)
        default: nil
        }
    }

    private static func text(_ value: JazzArchiveJSONValue?) -> String? {
        guard case let .string(text)? = value,
            !text.isEmpty,
            text == text.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        return text
    }

    private static func optionalText(_ value: JazzArchiveJSONValue?) -> String? {
        switch value {
        case nil, .some(.null): nil
        default: text(value)
        }
    }

    /// The credential itself is bounded and free of transport-hostile scalars, but deliberately not
    /// pattern-matched: a Keboola token format change must never strand an enrolled device.
    private static func secret(_ value: JazzArchiveJSONValue?) -> String? {
        guard case let .string(token)? = value,
            !token.isEmpty,
            token.unicodeScalars.count <= 8_192,
            token == token.trimmingCharacters(in: .whitespacesAndNewlines),
            token.unicodeScalars.allSatisfy({ scalar in
                !CharacterSet.controlCharacters.contains(scalar) && scalar.value != 0x7f
            })
        else { return nil }
        return token
    }

    private static func strings(_ value: JazzArchiveJSONValue?) -> [String]? {
        switch value {
        case nil, .some(.null):
            return []
        case let .some(.array(items)):
            var values: [String] = []
            for item in items {
                guard case let .string(text) = item, !text.isEmpty else { return nil }
                values.append(text)
            }
            return values
        default:
            return nil
        }
    }
}

extension JazzSignedDeviceCredentialEnvelope {
    /// The complete post-renewal tuple, ready for ONE atomic credential-store replacement.
    ///
    /// Only the token, its id, and its expiry move. Issuer/audience/bundle authority, ingest route,
    /// stack, project, company/area/device scope, and the signed stream authority are carried over
    /// unchanged and re-proved: a renewal that would alter where this device delivers, or under
    /// whose authority, is rejected instead of committed.
    public func renewed(
        with grant: JazzDeviceTokenRenewalGrant
    ) throws -> JazzSignedDeviceCredentialEnvelope {
        guard enrollmentRouting.scope.deviceId == grant.deviceId,
            enrollmentRouting.tokenId != grant.tokenId,
            enrollmentRouting.tokenBucketScope == grant.tokenBucketScope,
            enrollmentRouting.sinkBucketId == grant.sinkBucketId
        else { throw JazzDeviceTokenRenewalError.authorityChanged }
        let renewedRouting = JazzArchiveEnrollmentRouting(
            projectId: enrollmentRouting.projectId,
            stackURL: enrollmentRouting.stackURL,
            scope: enrollmentRouting.scope,
            archiveIngestURL: enrollmentRouting.archiveIngestURL,
            tokenId: grant.tokenId,
            expiresAt: grant.expiresAt,
            tokenBucketScope: enrollmentRouting.tokenBucketScope,
            sinkBucketId: enrollmentRouting.sinkBucketId,
            signedAuthority: enrollmentRouting.signedAuthority,
            authorizationProfile: enrollmentRouting.authorizationProfile)
        let renewedBinding = try renewedRouting.signedUploadRouteBinding()
        guard renewedBinding.hasSameDeliveryAuthority(as: routeBinding) else {
            throw JazzDeviceTokenRenewalError.authorityChanged
        }
        return try JazzSignedDeviceCredentialEnvelope(
            token: grant.token,
            expiresAt: grant.expiresAt,
            routeBinding: renewedBinding,
            enrollmentRouting: renewedRouting,
            streamSourceId: streamSourceId,
            streamEndpoint: try signedStreamEndpoint())
    }
}

// MARK: - Failure classification

/// What the device must do next. Only ``retryable`` may be attempted again; every other case stops
/// the schedule so the tray can ask for a reconnect instead of hammering an endpoint that has
/// already given its final answer.
public enum JazzDeviceTokenRenewalDisposition: Equatable, Sendable {
    /// Transient: back off with full jitter and replay the identical request.
    case retryable(String)
    /// The credential can no longer buy a successor. Capture keeps spooling; uploads pause.
    case reenrollmentRequired(String)
    /// This deployment rotates through device-bound enrollment; stop scheduling renewals.
    case unsupportedDeployment(String)
    /// We sent something the server could not accept. Never retried — it would fail identically.
    case clientDefect(String)

    public var isRetryable: Bool {
        if case .retryable = self { return true }
        return false
    }

    /// The one line the menu bar shows. `nil` for a state the user cannot act on.
    public var menuMessage: String? {
        switch self {
        case .retryable:
            nil
        case let .reenrollmentRequired(reason):
            "Reconnect this Mac — device token renewal stopped (\(reason))."
        case .unsupportedDeployment:
            "Reconnect this Mac — this deployment rotates device tokens by re-enrollment."
        case let .clientDefect(reason):
            "Reconnect this Mac — device token renewal was refused (\(reason))."
        }
    }
}

public enum JazzDeviceTokenRenewalFailure {
    /// Codes are matched on their suffix so the wire's `DEVICE_RENEWAL_` prefix is not part of the
    /// contract this client depends on.
    static let prefix = "DEVICE_RENEWAL_"

    /// Classify one non-200 response. The code decides; the status decides only when the code is
    /// unknown, absent, or self-contradictory.
    public static func classify(status: Int, code: String?) -> JazzDeviceTokenRenewalDisposition {
        let normalized = code.map { value -> String in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            return trimmed.hasPrefix(prefix) ? String(trimmed.dropFirst(prefix.count)) : trimmed
        }
        switch normalized {
        case "AUTH_REQUIRED":
            return .clientDefect("the request omitted a canonical device credential or identity")
        case "REQUEST_INVALID":
            return .clientDefect("the request payload was rejected")
        case "TOKEN_INVALID":
            return .reenrollmentRequired("the stored credential is no longer valid")
        case "TOKEN_EXPIRED":
            return .reenrollmentRequired("the stored credential expired")
        case "TOKEN_SUPERSEDED":
            return .reenrollmentRequired("the stored credential was superseded")
        case "DEVICE_NOT_ENROLLED":
            return .reenrollmentRequired("this device is not enrolled")
        case "DEVICE_INACTIVE":
            return .reenrollmentRequired("this device was deactivated")
        case "PROJECT_MISMATCH":
            return .reenrollmentRequired("the enrolled project no longer matches")
        case "SCOPE_MISMATCH":
            return .reenrollmentRequired("the credential scope no longer matches the enrollment")
        case "UNSUPPORTED_PROFILE":
            return .unsupportedDeployment("unattended renewal is disabled here")
        case "UNAVAILABLE":
            // The server reuses this code for a failed dependency and keeps that dependency's
            // status. A 4xx carrying it is a refusal, not an outage: never retry it as one.
            return isTransient(status: status)
                ? .retryable("Jazz is temporarily unable to renew (HTTP \(status))")
                : .reenrollmentRequired("Jazz refused to renew the credential (HTTP \(status))")
        default:
            break
        }
        if isTransient(status: status) {
            return .retryable("HTTP \(status)")
        }
        switch status {
        case 401, 403, 409:
            return .reenrollmentRequired("HTTP \(status)")
        default:
            return .clientDefect("unexpected HTTP \(status)")
        }
    }

    /// A transport failure (offline, DNS, TLS, timeout, truncated read) is always retryable — the
    /// entire point of the unbounded backoff is to survive an offline stretch.
    public static func transport(_ reason: String) -> JazzDeviceTokenRenewalDisposition {
        .retryable(reason)
    }

    /// Classify a failure to READ the stored credential before an attempt.
    ///
    /// A read failure is not evidence of a dead enrollment. The credential vault reports a locked,
    /// busy or otherwise unreadable credential store as `credentialUnavailable` — indistinguishable
    /// at this layer from a transient one — and stranding a Mac on "Reconnect this Mac" for a
    /// momentary read error is far worse than retrying. Only a positively terminal state (an
    /// expired credential, or one that no longer matches this enrollment) stops the schedule; every
    /// other read failure backs off and tries again, bounded naturally by the credential's expiry.
    public static func credentialRead(_ error: Error) -> JazzDeviceTokenRenewalDisposition {
        switch error as? JazzArchiveUploadError {
        case .credentialExpired:
            return .reenrollmentRequired("the stored credential expired")
        case .credentialBindingMismatch:
            return .reenrollmentRequired("the stored credential no longer matches this enrollment")
        default:
            return .retryable("the stored credential could not be read")
        }
    }

    /// Extract `{"detail": {"code": …}}`. FastAPI's generic string detail yields nil, which lets
    /// the status decide.
    public static func code(inResponse data: Data) -> String? {
        guard case let .object(root)? = try? JSONDecoder().decode(
            JazzArchiveJSONValue.self,
            from: data),
            case let .object(detail)? = root["detail"],
            case let .string(code)? = detail["code"],
            !code.isEmpty
        else { return nil }
        return code
    }

    /// `Retry-After` in delta-seconds. HTTP-date form is intentionally not honoured — it is not
    /// emitted by this route, and a skewed clock must not park renewal indefinitely.
    public static func retryAfter(
        _ header: String?,
        cap: TimeInterval = JazzDeviceTokenRenewalPolicy.backoffCap
    ) -> TimeInterval? {
        guard let header,
            let seconds = Int(header.trimmingCharacters(in: .whitespacesAndNewlines)),
            seconds >= 0
        else { return nil }
        return min(TimeInterval(seconds), cap)
    }

    private static func isTransient(status: Int) -> Bool {
        status == 408 || status == 425 || status == 429 || (500...599).contains(status)
    }
}

// MARK: - Schedule

/// Where a device's renewal schedule is anchored. Persisted as non-secret state and keyed by the
/// token id it describes, so a credential replaced by any other path (an admin bundle import, a
/// device-bound redemption) cannot inherit a stale lead time.
///
/// The anchor is the FIXED point the schedule is measured from. It must be persisted the first
/// time a credential is observed, not recomputed per consultation — a schedule derived from "now"
/// recedes as fast as the clock advances and therefore never arrives.
public struct JazzDeviceTokenRenewalAnchor: Codable, Equatable, Sendable {
    public let tokenId: String
    /// When this Mac began holding this exact credential: the moment a renewal grant was committed,
    /// or — for a credential minted elsewhere (an enrollment bundle, a device-bound redemption) —
    /// the first moment this Mac observed it.
    public let heldSince: Date
    /// The server-supplied lead time. `nil` records that the deployment did not supply one.
    public let renewAfterSeconds: Int?

    public init(tokenId: String, heldSince: Date, renewAfterSeconds: Int?) {
        self.tokenId = tokenId
        self.heldSince = heldSince
        self.renewAfterSeconds = renewAfterSeconds
    }
}

public enum JazzDeviceTokenRenewalPolicy {
    /// A floor between two attempts, so a wake storm or a flapping network cannot hammer the
    /// endpoint.
    public static let minimumInterval: TimeInterval = 60
    public static let backoffBase: TimeInterval = 5
    public static let backoffCap: TimeInterval = 300
    /// Used ONLY when the server did not send `renewAfterSeconds`. The server owns this policy and
    /// may change it per deployment; this fraction exists so an older deployment still rotates.
    public static let legacyLeadFraction: Double = 0.8

    /// The anchor to measure this credential's schedule from, minting a first-seen one when the
    /// stored anchor describes some other credential (or nothing at all).
    ///
    /// The caller MUST persist the result. That is what makes the schedule deterministic: a device
    /// that recomputes "when should I renew?" from the current instant on every consultation, every
    /// wake and every relaunch never reaches the answer.
    public static func anchor(
        existing: JazzDeviceTokenRenewalAnchor?,
        tokenId: String,
        now: Date
    ) -> JazzDeviceTokenRenewalAnchor {
        if let existing, existing.tokenId == tokenId { return existing }
        return JazzDeviceTokenRenewalAnchor(
            tokenId: tokenId,
            heldSince: now,
            renewAfterSeconds: nil)
    }

    /// When the held credential should be renewed — a FIXED instant.
    ///
    /// Deliberately not a function of the current time: the answer must be identical however often
    /// it is asked, or the moment never arrives. With a server lead time it is exactly
    /// `heldSince + renewAfterSeconds`. Without one — an older deployment, or a credential this Mac
    /// did not mint — it is 80 % of the lifetime measured from the same fixed anchor. The result
    /// never lands after expiry: a credential that cannot authenticate cannot renew.
    public static func due(
        anchor: JazzDeviceTokenRenewalAnchor,
        expiresAt: Date
    ) -> Date {
        let candidate: Date
        if let seconds = anchor.renewAfterSeconds {
            candidate = anchor.heldSince.addingTimeInterval(TimeInterval(seconds))
        } else {
            let lifetime = expiresAt.timeIntervalSince(anchor.heldSince)
            candidate =
                lifetime > 0
                ? anchor.heldSince.addingTimeInterval(lifetime * legacyLeadFraction)
                : expiresAt
        }
        return min(candidate, expiresAt)
    }

    /// Whether an attempt may run now: the schedule is due, no backoff window is open, and the
    /// floor since the last attempt has elapsed.
    ///
    /// `backoffUntil` is what keeps the escalating retry schedule real. Without it the once-a-minute
    /// poll would re-attempt every 60 s and a 300 s backoff would never be longer than 60 s.
    public static func shouldAttempt(
        due: Date,
        lastAttemptAt: Date?,
        backoffUntil: Date? = nil,
        now: Date,
        floor: TimeInterval = minimumInterval
    ) -> Bool {
        guard now >= due else { return false }
        if let backoffUntil, now < backoffUntil { return false }
        guard let lastAttemptAt else { return true }
        return now.timeIntervalSince(lastAttemptAt) >= floor
    }

    /// The earliest instant a next attempt may run, honouring the schedule, an open backoff window,
    /// and the floor.
    public static func nextAttempt(
        due: Date,
        lastAttemptAt: Date?,
        backoffUntil: Date? = nil,
        floor: TimeInterval = minimumInterval
    ) -> Date {
        var candidate = due
        if let backoffUntil { candidate = max(candidate, backoffUntil) }
        if let lastAttemptAt {
            candidate = max(candidate, lastAttemptAt.addingTimeInterval(floor))
        }
        return candidate
    }

    /// Full-jitter exponential backoff: `random(0, min(cap, base · 2^attempt))`.
    ///
    /// `attempt` is zero-based. There is deliberately no attempt limit — while the current
    /// credential has not expired, giving up would strand the device for exactly the reason this
    /// feature exists. `randomFraction` is injected so the sequence is testable.
    public static func backoffDelay(
        attempt: Int,
        randomFraction: Double,
        base: TimeInterval = backoffBase,
        cap: TimeInterval = backoffCap
    ) -> TimeInterval {
        let fraction = randomFraction.isFinite ? min(max(randomFraction, 0), 1) : 1
        return backoffCeiling(attempt: attempt, base: base, cap: cap) * fraction
    }

    /// The un-jittered upper bound of ``backoffDelay(attempt:randomFraction:base:cap:)``.
    public static func backoffCeiling(
        attempt: Int,
        base: TimeInterval = backoffBase,
        cap: TimeInterval = backoffCap
    ) -> TimeInterval {
        guard attempt > 0 else { return min(base, cap) }
        // 2^40 · 5 s already dwarfs the cap; clamping the exponent keeps the multiply finite.
        let exponent = min(attempt, 40)
        return min(base * pow(2, Double(exponent)), cap)
    }

}

// MARK: - Surfaced state

/// What the menu bar knows about renewal. A pilot recording must never stop without anyone
/// noticing, so a terminal state is a visible line — not a log entry.
public enum JazzDeviceTokenRenewalPhase: Equatable, Sendable {
    /// No signed enrollment on this Mac; there is nothing to renew.
    case inactive
    case scheduled(at: Date)
    case renewing
    case retrying(nextAttemptAt: Date, reason: String)
    case stopped(JazzDeviceTokenRenewalDisposition)
}

public struct JazzDeviceTokenRenewalStatus: Equatable, Sendable {
    public let phase: JazzDeviceTokenRenewalPhase
    /// The non-secret id of the credential currently held. Safe to log.
    public let tokenId: String?
    public let expiresAt: Date?

    public init(
        phase: JazzDeviceTokenRenewalPhase = .inactive,
        tokenId: String? = nil,
        expiresAt: Date? = nil
    ) {
        self.phase = phase
        self.tokenId = tokenId
        self.expiresAt = expiresAt
    }

    /// The single menu line, or nil while renewal is healthy (silence is the success signal).
    public var menuMessage: String? {
        switch phase {
        case .inactive, .scheduled, .renewing:
            return nil
        case let .retrying(_, reason):
            return "Device token renewal is retrying — \(reason)."
        case let .stopped(disposition):
            return disposition.menuMessage
        }
    }

    /// Whether the credential can still authenticate. Once it cannot, retrying is pointless.
    public func isCredentialUsable(now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt > now
    }
}
