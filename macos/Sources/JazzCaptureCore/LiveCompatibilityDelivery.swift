import Foundation

/// The two OTLP/JSON signals accepted by the native Jazz liveCompatibility receiver.
public enum JazzLiveCompatibilitySignal: String, Equatable, Sendable {
    case logs
    case traces
}

public enum JazzLiveCompatibilityDeliveryTarget: String, Codable, CaseIterable, Equatable, Sendable {
    case legacy
    case jazz
}

/// Immutable per-session delivery requirements derived from one exact signed enrollment
/// generation. A signed archive-only bundle requires Jazz alone; a signed bundle carrying a
/// legacy stream endpoint requires both destinations. The enrollment envelope digest proves
/// which signed generation selected the policy without persisting the secret-bearing endpoint.
public struct JazzLiveCompatibilityDeliveryRequirements: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let signedEnrollmentEnvelopeDigest: String
    public let requiredDestinations: [JazzLiveCompatibilityDeliveryTarget]

    public init(
        routeBinding: JazzArchiveUploadRouteBinding,
        signedEnvelope: JazzSignedDeviceCredentialEnvelope
    ) throws {
        guard signedEnvelope.routeBinding == routeBinding,
            let digest = routeBinding.signedAuthority?.envelopeDigest
        else { throw JazzArchiveUploadError.credentialBindingMismatch }
        let legacyRequired = try signedEnvelope.signedStreamEndpoint() != nil
        schemaVersion = 1
        signedEnrollmentEnvelopeDigest = digest
        requiredDestinations = legacyRequired ? [.legacy, .jazz] : [.jazz]
        try validate(for: routeBinding)
    }

    public func requires(_ target: JazzLiveCompatibilityDeliveryTarget) -> Bool {
        requiredDestinations.contains(target)
    }

    public func validate(
        for routeBinding: JazzArchiveUploadRouteBinding
    ) throws {
        let allowed: [[JazzLiveCompatibilityDeliveryTarget]] = [
            [.jazz],
            [.legacy, .jazz],
        ]
        guard schemaVersion == 1,
            routeBinding.hasSignedAuthority,
            routeBinding.signedAuthority?.envelopeDigest
                == signedEnrollmentEnvelopeDigest,
            allowed.contains(requiredDestinations)
        else { throw JazzArchiveUploadError.credentialBindingMismatch }
    }
}

/// Non-secret, immutable request authority derived from the exact signed archive route pinned to a
/// capture session. The live endpoint is never accepted from settings or a caller-provided URL:
/// it is a sibling of the authenticated `/api/archive-ingests` route.
public struct JazzLiveCompatibilityRequestPlan: Equatable, Sendable {
    public static let maximumRequestBytes = 4 * 1_024 * 1_024

    public let routeBinding: JazzArchiveUploadRouteBinding
    public let signal: JazzLiveCompatibilitySignal
    public let url: URL
    public let deviceId: String

    public init(
        routeBinding: JazzArchiveUploadRouteBinding,
        signal: JazzLiveCompatibilitySignal
    ) throws {
        let archiveSuffix = "/api/archive-ingests"
        guard routeBinding.hasSignedAuthority,
            JazzArchiveControlPlaneURL.normalize(routeBinding.ingestEndpoint)
                == routeBinding.ingestEndpoint,
            routeBinding.ingestEndpoint.hasSuffix(archiveSuffix)
        else {
            throw JazzArchiveUploadError.credentialBindingMismatch
        }
        let root = String(routeBinding.ingestEndpoint.dropLast(archiveSuffix.count))
        let candidate =
            root + "/api/live-compatibility/v1/" + signal.rawValue
        guard let url = URL(string: candidate),
            url.scheme?.lowercased() == "https"
                || (url.scheme?.lowercased() == "http"
                    && ["localhost", "127.0.0.1", "::1"].contains(
                        url.host?.lowercased() ?? "")),
            url.user == nil,
            url.password == nil,
            url.query == nil,
            url.fragment == nil
        else {
            throw JazzArchiveUploadError.credentialBindingMismatch
        }
        self.routeBinding = routeBinding
        self.signal = signal
        self.url = url
        deviceId = routeBinding.scope.deviceId
    }

    /// Build one credential-bearing request in memory. The scoped token is neither retained by the
    /// plan nor made serializable, and the caller obtains it from its provider for each attempt.
    public func request(
        body: Data,
        credential: JazzArchiveScopedDeviceCredential,
        timeout: TimeInterval = 30
    ) throws -> URLRequest {
        guard !body.isEmpty, body.count <= Self.maximumRequestBytes,
            timeout.isFinite, timeout > 0
        else { throw JazzArchiveUploadError.invalidItem("liveCompatibility request") }
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

/// Payload-bound acknowledgement returned only by Jazz's dedicated native live endpoint. A bare
/// OTLP 2xx never authorizes journaling because it could mean the receiver ignored every canonical
/// item after a mapping drift.
public struct JazzLiveCompatibilityAcceptance: Equatable, Sendable {
    public let acceptedCanonicalItems: Int
    public let payloadDigest: String

    public init(
        responseData: Data,
        expectedPayload: Data,
        expectedCanonicalItems: Int
    ) throws {
        guard expectedCanonicalItems > 0,
            case let .object(root) = try JSONDecoder().decode(
                JazzArchiveJSONValue.self,
                from: responseData),
            Set(root.keys)
                == Set([
                    "schemaVersion",
                    "acceptedCanonicalItems",
                    "payloadDigest",
                ]),
            Self.integer(root["schemaVersion"]) == 1,
            let count = Self.integer(root["acceptedCanonicalItems"]),
            count == expectedCanonicalItems,
            case let .string(digest)? = root["payloadDigest"],
            digest == "sha256:\(JazzArchiveDigest.sha256Hex(expectedPayload))"
        else {
            throw JazzArchiveUploadError.invalidItem(
                "liveCompatibility acceptance")
        }
        acceptedCanonicalItems = count
        payloadDigest = digest
    }

    private static func integer(_ value: JazzArchiveJSONValue?) -> Int? {
        switch value {
        case let .integer(number): return Int(exactly: number)
        case let .unsignedInteger(number): return Int(exactly: number)
        default: return nil
        }
    }
}

/// Durable acknowledgement state for one byte-identical OTLP request. A marker is valid only when
/// it names the digest of the exact persisted payload, so a torn/corrupt companion cannot silently
/// acknowledge different bytes.
public struct JazzLiveCompatibilityDeliveryState: Equatable, Sendable {
    public let payload: Data?
    public let legacyAccepted: Bool
    public let jazzAccepted: Bool
    public let requiredDestinations: [JazzLiveCompatibilityDeliveryTarget]

    public init(
        payload: Data?,
        legacyAccepted: Bool,
        jazzAccepted: Bool,
        requiredDestinations: [JazzLiveCompatibilityDeliveryTarget] = [.legacy, .jazz]
    ) {
        self.payload = payload
        self.legacyAccepted = legacyAccepted
        self.jazzAccepted = jazzAccepted
        self.requiredDestinations = requiredDestinations
    }

    public var isComplete: Bool {
        payload != nil
            && (!requires(.legacy) || legacyAccepted)
            && (!requires(.jazz) || jazzAccepted)
    }

    public func requires(_ target: JazzLiveCompatibilityDeliveryTarget) -> Bool {
        requiredDestinations.contains(target)
    }
}
