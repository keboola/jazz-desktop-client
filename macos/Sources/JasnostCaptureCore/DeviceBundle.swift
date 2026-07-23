import Foundation

/// Exact bucket grant represented by a server-issued enrollment bundle. Missing is deliberately
/// distinct from `none`: older bundles may still decode, but cannot pass security validation.
public enum JazzArchiveTokenBucketScope: String, Codable, Equatable, Sendable {
    case sink
    case none
}

/// Canonical, non-secret Jazz Archive control-plane routing. This mirrors the server-side
/// enrollment validator: public hosts require HTTPS, while plain HTTP is accepted only for the
/// three literal loopback hosts used by local development. Ambiguous paths are rejected before
/// Foundation gets a chance to normalize them.
public enum JazzArchiveControlPlaneURL {
    public static func normalize(_ value: String?) -> String? {
        guard let value else { return nil }
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty,
            !candidate.contains("\\"),
            !candidate.contains("?"),
            !candidate.contains("#"),
            candidate.unicodeScalars.allSatisfy({ scalar in
                !CharacterSet.whitespacesAndNewlines.contains(scalar)
                    && !CharacterSet.controlCharacters.contains(scalar)
                    && scalar.value != 0x7f
            }),
            let components = URLComponents(string: candidate),
            components.url != nil,
            let scheme = components.scheme?.lowercased(),
            let rawHost = components.host,
            !rawHost.isEmpty,
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil
        else { return nil }

        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        let isLoopbackHTTP = scheme == "http"
            && ["localhost", "127.0.0.1", "::1"].contains(host)
        guard scheme == "https" || isLoopbackHTTP else { return nil }

        let encodedPath = components.percentEncodedPath
        let lowercasedPath = encodedPath.lowercased()
        // Encoded separators are deliberately refused even when they would decode to an otherwise
        // valid suffix. A proxy and the application must never disagree on route boundaries.
        guard !lowercasedPath.contains("%2f"),
            !lowercasedPath.contains("%5c"),
            let decodedPath = encodedPath.removingPercentEncoding,
            !decodedPath.contains("//"),
            !decodedPath.contains("\\"),
            !decodedPath.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0 == "." || $0 == ".." })
        else { return nil }

        let canonicalEncodedPath = encodedPath.hasSuffix("/")
            ? String(encodedPath.dropLast()) : encodedPath
        let canonicalDecodedPath = decodedPath.hasSuffix("/")
            ? String(decodedPath.dropLast()) : decodedPath
        guard canonicalDecodedPath.hasSuffix("/api/archive-ingests") else { return nil }

        let canonicalHost = host.contains(":") ? "[\(host)]" : host
        let defaultPort = scheme == "https" ? 443 : 80
        let port = components.port.flatMap { $0 == defaultPort ? nil : ":\($0)" } ?? ""
        let canonical = "\(scheme)://\(canonicalHost)\(port)\(canonicalEncodedPath)"
        return URL(string: canonical) == nil ? nil : canonical
    }
}

/// Atomically persisted, non-secret half of an archive enrollment. Keeping the verified project,
/// stack, scope, control-plane route, token id, and expiry in one Codable value prevents a newly
/// imported credential from inheriting stale routing fields from an older device enrollment.
public struct JazzArchiveEnrollmentRouting: Codable, Equatable, Sendable {
    public let projectId: String
    public let stackURL: String
    public let scope: JazzArchiveUploadScope
    public let archiveIngestURL: String
    public let tokenId: String
    public let expiresAt: String
    /// Persist the verified expectation so a later reconnect can distinguish explicit empty scope
    /// from an old enrollment whose scope was never proven.
    public let tokenBucketScope: JazzArchiveTokenBucketScope?
    public let sinkBucketId: String?

    public init(
        projectId: String,
        stackURL: String,
        scope: JazzArchiveUploadScope,
        archiveIngestURL: String,
        tokenId: String,
        expiresAt: String,
        tokenBucketScope: JazzArchiveTokenBucketScope? = nil,
        sinkBucketId: String? = nil
    ) {
        self.projectId = projectId
        self.stackURL = stackURL
        self.scope = scope
        self.archiveIngestURL = archiveIngestURL
        self.tokenId = tokenId
        self.expiresAt = expiresAt
        self.tokenBucketScope = tokenBucketScope
        self.sinkBucketId = sinkBucketId
    }

    /// Re-prove a persisted enrollment during launch-time reconnect. Older persisted tuples decode
    /// with an unknown bucket scope and therefore fail closed until the device imports a fresh
    /// server-issued bundle.
    public func validateVerifiedCredential(
        _ verify: KeboolaAPI.TokenVerify,
        now: Date = Date()
    ) throws {
        try DeviceBundle.validateVerifiedCredential(
            verify,
            expectedTokenId: tokenId,
            expectedExpiresAt: expiresAt,
            expectedBucketScope: tokenBucketScope,
            expectedSinkBucketId: sinkBucketId,
            now: now)
    }
}

/// A one-time **enrollment bundle** (ADR 0005, Phase 1) an admin generates in the Data App and the
/// desktop imports instead of pasting a raw Keboola master token. The bundle carries a per-device,
/// scoped, expiring Storage token plus (optionally) the OTLP stream endpoint, so the project master
/// key never lands on a laptop's Keychain.
///
/// Pure Foundation + Codable so parsing and validation are unit-testable with no networking. The
/// executable target (`JasnostCapture`) does the Keychain write and the live `tokens/verify` refusal
/// — this type only decodes and cheaply validates the pasted blob.
///
/// Secret handling: `token` is the device's scoped Storage token and `streamEndpoint` embeds the
/// stream secret in its path. Neither is logged; the caller stores them ONLY in the Keychain (same
/// accounts the legacy-token path uses). `stackURL` is non-secret routing metadata.
public struct DeviceBundle: Codable, Equatable, Sendable {
    /// Discriminator — MUST be ``kind`` for a bundle to be accepted (guards against a raw token or
    /// some other JSON being pasted into the bundle field).
    public static let expectedKind = "jazz-device-bundle"

    /// The bundle's shape discriminator (validated to equal ``expectedKind``).
    public let kind: String
    /// The enrolled device's id (`device_registry` key). Required, non-empty.
    public let deviceId: String
    /// The exact Keboola Storage API stack that minted the token. Newly-issued bundles include it
    /// so dedicated stacks do not depend on the desktop's finite public-stack list. Optional only
    /// for backward compatibility with bundles issued before #197.
    public let stackURL: String?
    /// Keboola project that owns the scoped token. Required whenever archive routing is present;
    /// the desktop compares it with the live `tokens/verify` owner before storing anything.
    public let projectId: String?
    /// Non-secret company/area scope authorized for whole-archive ingest. Older bundles omit these
    /// fields; capture remains available, but queued archives wait for a rotated bundle.
    public let companyId: String?
    public let areaId: String?
    /// Canonical Jazz control-plane base ending in `/api/archive-ingests`. It is routing metadata,
    /// not a signed upload URL and not a credential.
    public let archiveIngestURL: String?
    /// The per-device OTLP stream source id, when the admin provisioned one. Optional in Phase 1 —
    /// the app may register a shared endpoint instead (see ADR 0005).
    public let streamSourceId: String?
    /// The full OTLP ingest URL (path embeds the stream secret). Optional — when absent, the device
    /// keeps whatever endpoint it already has, or the admin supplies it out of band.
    public let streamEndpoint: String?
    /// The device's scoped, expiring Storage token — the one-time reveal. Required, non-empty.
    public let token: String
    /// The scoped token's id (persisted server-side for rotation/revocation). Required, non-empty.
    public let tokenId: String
    /// ISO-8601 expiry of ``token`` (the app re-enrolls before it lapses).
    public let expiresAt: String
    /// Exact expected Storage bucket scope. `none` means exactly zero bucket permissions; absence
    /// is legacy/unknown and therefore cannot pass live credential validation.
    public let tokenBucketScope: JazzArchiveTokenBucketScope?
    /// Required only for `tokenBucketScope = sink`; the verified permission map must be exactly
    /// `{sinkBucketId: "write"}`.
    public let sinkBucketId: String?
    /// The Keboola components the scoped token may run (informational on the device).
    public let componentAccess: [String]?

    enum CodingKeys: String, CodingKey {
        case kind, deviceId, stackURL, projectId, companyId, areaId, archiveIngestURL, streamSourceId,
            streamEndpoint, token, tokenId, expiresAt, tokenBucketScope, sinkBucketId, componentAccess
    }

    public init(
        kind: String = DeviceBundle.expectedKind,
        deviceId: String,
        stackURL: String? = nil,
        projectId: String? = nil,
        companyId: String? = nil,
        areaId: String? = nil,
        archiveIngestURL: String? = nil,
        streamSourceId: String? = nil,
        streamEndpoint: String? = nil,
        token: String,
        tokenId: String,
        expiresAt: String,
        tokenBucketScope: JazzArchiveTokenBucketScope? = nil,
        sinkBucketId: String? = nil,
        componentAccess: [String]? = nil
    ) {
        self.kind = kind
        self.deviceId = deviceId
        self.stackURL = stackURL
        self.projectId = projectId
        self.companyId = companyId
        self.areaId = areaId
        self.archiveIngestURL = archiveIngestURL
        self.streamSourceId = streamSourceId
        self.streamEndpoint = streamEndpoint
        self.token = token
        self.tokenId = tokenId
        self.expiresAt = expiresAt
        self.tokenBucketScope = tokenBucketScope
        self.sinkBucketId = sinkBucketId
        self.componentAccess = componentAccess
    }

    /// The parsed ``expiresAt``, tolerant of fractional seconds; `nil` when absent/unparseable.
    public var expiresAtDate: Date? { Timestamps.parse(expiresAt) }

    /// Canonical stack base used for token verification; `nil` for legacy bundles with no stack.
    public var normalizedStackURL: String? { stackURL.flatMap(KeboolaStack.normalize) }

    public var normalizedArchiveIngestURL: String? {
        JazzArchiveControlPlaneURL.normalize(archiveIngestURL)
    }

    /// Complete delivery routing or nil for a legacy bundle. Partial routing never becomes an
    /// implicit wildcard/default; the client waits for re-bootstrap instead.
    public var archiveUploadScope: JazzArchiveUploadScope? {
        guard let companyId, let areaId else { return nil }
        return try? JazzArchiveUploadScope(
            companyId: companyId, areaId: areaId, deviceId: deviceId)
    }

    public enum ArchiveBindingError: Error, Equatable, CustomStringConvertible {
        case projectMismatch
        case stackMismatch
        case incompleteRouting

        public var description: String {
            switch self {
            case .projectMismatch:
                "The enrollment project does not match the verified device token."
            case .stackMismatch:
                "The enrollment stack does not match the stack that verified the device token."
            case .incompleteRouting:
                "The enrollment bundle does not contain a complete Jazz Archive routing tuple."
            }
        }
    }

    /// Bind the static bundle tuple to live token verification before any secret or routing is
    /// persisted. Legacy bundles with no archive fields return nil; partially populated bundles
    /// are already rejected by ``parse(_:)`` and also fail closed here for direct construction.
    public func archiveEnrollmentRouting(
        verifiedStackURL: String,
        verifiedProjectId: String
    ) throws -> JazzArchiveEnrollmentRouting? {
        // A server without archive ingest configured may still issue a legacy Stream-capable
        // bundle carrying registry scope/project metadata. Only the presence of an archive route
        // opts this bundle into the all-or-nothing archive tuple.
        guard archiveIngestURL != nil else { return nil }
        guard let projectId = projectId?.trimmingCharacters(in: .whitespacesAndNewlines),
            !projectId.isEmpty,
            let bundleStack = normalizedStackURL,
            let verifiedStack = KeboolaStack.normalize(verifiedStackURL),
            let scope = archiveUploadScope,
            let endpoint = normalizedArchiveIngestURL
        else { throw ArchiveBindingError.incompleteRouting }
        guard projectId == verifiedProjectId.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw ArchiveBindingError.projectMismatch
        }
        guard bundleStack == verifiedStack else { throw ArchiveBindingError.stackMismatch }
        return JazzArchiveEnrollmentRouting(
            projectId: projectId,
            stackURL: verifiedStack,
            scope: scope,
            archiveIngestURL: endpoint,
            tokenId: tokenId,
            expiresAt: expiresAt,
            tokenBucketScope: tokenBucketScope,
            sinkBucketId: sinkBucketId)
    }

    /// Security failures surfaced before a bundle token can enter the Keychain. These cases are
    /// intentionally specific so Settings can tell an operator to rotate a stale or malformed
    /// enrollment instead of presenting it as connected.
    public enum CredentialValidationError: Error, Equatable, CustomStringConvertible {
        case invalidTokenId
        case tokenIdMismatch
        case invalidBundleExpiry
        case missingVerifiedExpiry
        case expiryMismatch
        case credentialExpired
        case missingVerificationField(String)
        case masterToken
        case disabledToken
        case serverReportedExpired
        case excessivePrivilege(String)
        case missingBucketScope
        case inconsistentBucketScope
        case missingBucketPermissions
        case bucketPermissionsMismatch

        public var description: String {
            switch self {
            case .invalidTokenId:
                return "The enrollment token id is empty or malformed."
            case .tokenIdMismatch:
                return "The verified token id does not match the enrollment bundle."
            case .invalidBundleExpiry:
                return "The enrollment bundle does not carry a finite RFC-3339 token expiry."
            case .missingVerifiedExpiry:
                return "The verified token does not report a finite expiry."
            case .expiryMismatch:
                return "The verified token expiry does not match the enrollment bundle."
            case .credentialExpired:
                return "The enrollment token has already expired; issue a new bundle."
            case let .missingVerificationField(field):
                return "The token verification response omitted the required \(field) security field."
            case .masterToken:
                return "A project master token cannot be enrolled on a device."
            case .disabledToken:
                return "The enrollment token has been disabled or revoked."
            case .serverReportedExpired:
                return "The enrollment token is reported as expired."
            case let .excessivePrivilege(field):
                return "The enrollment token has forbidden \(field) privileges."
            case .missingBucketScope:
                return "The enrollment bundle does not declare an exact token bucket scope."
            case .inconsistentBucketScope:
                return "The enrollment bundle's token bucket scope is inconsistent."
            case .missingBucketPermissions:
                return "The token verification response omitted exact bucket permissions."
            case .bucketPermissionsMismatch:
                return "The verified token bucket permissions do not match the enrollment bundle."
            }
        }
    }

    /// Prove that the live `/tokens/verify` result is the exact narrow, finite credential described
    /// by this editable one-time bundle. No missing field is interpreted as false/empty.
    public func validateVerifiedCredential(
        _ verify: KeboolaAPI.TokenVerify,
        now: Date = Date()
    ) throws {
        try Self.validateVerifiedCredential(
            verify,
            expectedTokenId: tokenId,
            expectedExpiresAt: expiresAt,
            expectedBucketScope: tokenBucketScope,
            expectedSinkBucketId: sinkBucketId,
            now: now)
    }

    fileprivate static func validateVerifiedCredential(
        _ verify: KeboolaAPI.TokenVerify,
        expectedTokenId: String,
        expectedExpiresAt: String,
        expectedBucketScope: JazzArchiveTokenBucketScope?,
        expectedSinkBucketId: String?,
        now: Date
    ) throws {
        let normalizedExpectedTokenId = expectedTokenId.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let verifiedTokenId = verify.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedExpectedTokenId.isEmpty, normalizedExpectedTokenId == expectedTokenId,
            !verifiedTokenId.isEmpty, verifiedTokenId == verify.id
        else { throw CredentialValidationError.invalidTokenId }
        guard verify.id == expectedTokenId else {
            throw CredentialValidationError.tokenIdMismatch
        }

        guard let bundleExpiry = Timestamps.parse(expectedExpiresAt),
            bundleExpiry.timeIntervalSinceReferenceDate.isFinite
        else { throw CredentialValidationError.invalidBundleExpiry }
        guard let verifiedExpiryText = verify.expires,
            !verifiedExpiryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let verifiedExpiry = verify.expiresAtDate,
            verifiedExpiry.timeIntervalSinceReferenceDate.isFinite
        else { throw CredentialValidationError.missingVerifiedExpiry }
        guard verifiedExpiry == bundleExpiry else {
            throw CredentialValidationError.expiryMismatch
        }
        guard bundleExpiry > now else {
            throw CredentialValidationError.credentialExpired
        }

        if verify.isMaster {
            throw CredentialValidationError.masterToken
        }
        guard let isMasterToken = verify.isMasterToken else {
            throw CredentialValidationError.missingVerificationField("isMasterToken")
        }
        guard !isMasterToken else {
            throw CredentialValidationError.masterToken
        }
        guard let isDisabled = verify.isDisabled else {
            throw CredentialValidationError.missingVerificationField("isDisabled")
        }
        guard !isDisabled else {
            throw CredentialValidationError.disabledToken
        }
        guard let isExpired = verify.isExpired else {
            throw CredentialValidationError.missingVerificationField("isExpired")
        }
        guard !isExpired else {
            throw CredentialValidationError.serverReportedExpired
        }
        try Self.requireForbiddenPrivilegeAbsent(
            verify.canManageBuckets, field: "canManageBuckets")
        try Self.requireForbiddenPrivilegeAbsent(
            verify.canManageTokens, field: "canManageTokens")
        try Self.requireForbiddenPrivilegeAbsent(
            verify.canReadAllFileUploads, field: "canReadAllFileUploads")

        let expectedBucketPermissions: [String: String]
        switch expectedBucketScope {
        case .some(.sink):
            guard let expectedSinkBucketId,
                !expectedSinkBucketId.isEmpty,
                expectedSinkBucketId
                    == expectedSinkBucketId.trimmingCharacters(in: .whitespacesAndNewlines)
            else { throw CredentialValidationError.inconsistentBucketScope }
            expectedBucketPermissions = [expectedSinkBucketId: "write"]
        case .some(.none):
            guard expectedSinkBucketId == nil else {
                throw CredentialValidationError.inconsistentBucketScope
            }
            expectedBucketPermissions = [:]
        case nil:
            throw CredentialValidationError.missingBucketScope
        }
        guard let bucketPermissions = verify.bucketPermissions else {
            throw CredentialValidationError.missingBucketPermissions
        }
        guard bucketPermissions == expectedBucketPermissions else {
            throw CredentialValidationError.bucketPermissionsMismatch
        }
    }

    private static func requireForbiddenPrivilegeAbsent(
        _ value: Bool?,
        field: String
    ) throws {
        guard let value else {
            throw CredentialValidationError.missingVerificationField(field)
        }
        guard !value else {
            throw CredentialValidationError.excessivePrivilege(field)
        }
    }

    /// Typed parse failures — surfaced verbatim to the admin so a bad paste is self-explaining.
    public enum BundleError: Error, Equatable, CustomStringConvertible {
        /// The blob isn't JSON, or is JSON of the wrong shape (missing required keys).
        case malformed(String)
        /// Valid JSON but not a jazz device bundle (`kind` missing or wrong).
        case notJazzBundle
        /// The bundle decoded but its ``token`` (or ``deviceId``) is empty / obviously invalid.
        case missingToken
        /// A supplied stack URL is not a canonical HTTPS Keboola connection host.
        case invalidStackURL
        /// Archive routing was supplied only partially or its control-plane URL is unsafe.
        case invalidArchiveDelivery

        public var description: String {
            switch self {
            case let .malformed(detail):
                return "That doesn't look like an enrollment bundle (\(detail))."
            case .notJazzBundle:
                return "That JSON isn't a Jazz enrollment bundle (expected kind"
                    + " \"\(DeviceBundle.expectedKind)\")."
            case .missingToken:
                return "The enrollment bundle is missing a device token."
            case .invalidStackURL:
                return "The enrollment bundle contains an invalid Keboola stack URL."
            case .invalidArchiveDelivery:
                return "The enrollment bundle contains incomplete or invalid Jazz Archive routing."
            }
        }
    }

    /// Parse a pasted enrollment bundle. Accepts the raw JSON object, a `data:` URL wrapping it, or a
    /// blob with surrounding whitespace/newlines (people paste from a variety of sources). Validates
    /// the discriminator and the required non-empty fields, and cheaply rejects a token that couldn't
    /// possibly be a scoped device token.
    ///
    /// This is only the CHEAP local gate. The authoritative credential proof stays a live check:
    /// `KeboolaConnection` compares token identity, finite expiry, every privilege flag and the exact
    /// bucket permission map from `tokens/verify` before writing either Keychain account.
    public static func parse(_ text: String) -> Result<DeviceBundle, BundleError> {
        guard let jsonData = jsonPayload(from: text) else {
            return .failure(.malformed("not JSON"))
        }

        // Pre-check the discriminator BEFORE full decode so a wrong-kind blob returns `notJazzBundle`
        // rather than a generic decode error, even when other required keys happen to be present.
        if let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            let kind = (object["kind"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard kind == expectedKind else { return .failure(.notJazzBundle) }
        } else {
            return .failure(.malformed("not a JSON object"))
        }

        let bundle: DeviceBundle
        do {
            bundle = try JSONDecoder().decode(DeviceBundle.self, from: jsonData)
        } catch {
            // A jazz-kind object that still fails to decode is missing a required field
            // (deviceId/token/tokenId/expiresAt) — report it as malformed with the decode detail.
            return .failure(.malformed("\(error)"))
        }

        guard bundle.kind == expectedKind else { return .failure(.notJazzBundle) }

        let token = bundle.token.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceId = bundle.deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !deviceId.isEmpty else { return .failure(.missingToken) }
        let tokenId = bundle.tokenId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tokenId.isEmpty, tokenId == bundle.tokenId,
            bundle.expiresAtDate?.timeIntervalSinceReferenceDate.isFinite == true
        else { return .failure(.malformed("invalid token id or expiry")) }
        // Cheap sanity gate on the token shape (a scoped Storage token is `<projectId>-<...>` with
        // real length). This never *confirms* a scoped token — it only rejects an obviously-wrong
        // one so the admin isn't sent to the network for a paste error. The definitive identity,
        // expiry, privilege and exact bucket-scope proof is the caller's live `tokens/verify` check.
        guard looksLikeStorageToken(token) else { return .failure(.missingToken) }
        if bundle.stackURL != nil, bundle.normalizedStackURL == nil {
            return .failure(.invalidStackURL)
        }
        if bundle.archiveIngestURL != nil,
            (bundle.projectId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
                || bundle.normalizedStackURL == nil
                || bundle.archiveUploadScope == nil
                || bundle.normalizedArchiveIngestURL == nil)
        {
            return .failure(.invalidArchiveDelivery)
        }
        switch bundle.tokenBucketScope {
        case .some(.sink):
            guard let sinkBucketId = bundle.sinkBucketId,
                !sinkBucketId.isEmpty,
                sinkBucketId == sinkBucketId.trimmingCharacters(in: .whitespacesAndNewlines)
            else { return .failure(.malformed("inconsistent token bucket scope")) }
        case .some(.none):
            guard bundle.sinkBucketId == nil else {
                return .failure(.malformed("inconsistent token bucket scope"))
            }
        case nil:
            // Legacy bundles remain parseable so Settings can give a rotation error after live
            // verification; absence is never treated as the explicit empty scope.
            guard bundle.sinkBucketId == nil else {
                return .failure(.malformed("inconsistent token bucket scope"))
            }
        }

        return .success(bundle)
    }

    // MARK: - Internals

    /// Decode the paste into JSON bytes: a bare JSON object, a `data:` URL wrapping one (base64 or
    /// percent-encoded), or either with surrounding whitespace. Returns nil when nothing JSON-shaped
    /// can be recovered.
    private static func jsonPayload(from text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.lowercased().hasPrefix("data:") {
            if let decoded = decodeDataURL(trimmed) { return decoded }
            return nil
        }

        // A bare JSON object (optionally with stray whitespace) — the common case.
        guard trimmed.hasPrefix("{") else { return nil }
        return trimmed.data(using: .utf8)
    }

    /// Extract the payload of a `data:` URL. Supports `;base64` and plain (percent-encoded) bodies;
    /// the media type is ignored (an admin export may use `application/json` or `text/plain`).
    private static func decodeDataURL(_ url: String) -> Data? {
        guard let comma = url.firstIndex(of: ",") else { return nil }
        let meta = url[url.startIndex..<comma].lowercased()
        let payload = String(url[url.index(after: comma)...])
        if meta.contains(";base64") {
            return Data(base64Encoded: payload)
        }
        // Plain data URL: the body is percent-encoded text.
        return (payload.removingPercentEncoding ?? payload).data(using: .utf8)
    }

    /// A cheap, conservative shape check for a Keboola Storage token: `<projectId>-<rest>` where the
    /// project id is numeric and the whole thing has real length. Deliberately permissive — it must
    /// accept every legitimately-minted scoped token; its only job is to reject an empty or clearly
    /// non-token paste so we don't round-trip a typo to the API.
    static func looksLikeStorageToken(_ token: String) -> Bool {
        let parts = token.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let projectId = parts[0]
        let rest = parts[1]
        guard !projectId.isEmpty, projectId.allSatisfy(\.isNumber) else { return false }
        // A real Storage token secret is long; a stray word or id won't clear this floor.
        return rest.count >= 16
    }
}
