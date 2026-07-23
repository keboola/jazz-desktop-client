import CryptoKit
import Foundation
import JasnostCaptureCore

public struct SignedDeviceBundlePayload: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let bundleId: String
    public let generation: Int
    public let issuer: String
    public let audience: String
    public let issuedAt: String
    public let bundleExpiresAt: String
    public let deviceId: String
    public let companyId: String
    public let areaId: String
    public let projectId: String
    public let stackURL: String
    public let archiveIngestURL: String
    public let token: String
    public let tokenId: String
    public let expiresAt: String
    public let tokenBucketScope: JazzArchiveTokenBucketScope
    public let sinkBucketId: String?
    public let componentAccess: [String]
    public let streamSourceId: String?
    public let streamEndpoint: String?

    public var deviceBundle: DeviceBundle {
        DeviceBundle(
            kind: kind,
            deviceId: deviceId,
            stackURL: stackURL,
            projectId: projectId,
            companyId: companyId,
            areaId: areaId,
            archiveIngestURL: archiveIngestURL,
            streamSourceId: streamSourceId,
            streamEndpoint: streamEndpoint,
            token: token,
            tokenId: tokenId,
            expiresAt: expiresAt,
            tokenBucketScope: tokenBucketScope,
            sinkBucketId: sinkBucketId,
            componentAccess: componentAccess)
    }
}

public struct AuthorizedSignedDeviceBundle: Sendable {
    public let payload: SignedDeviceBundlePayload
    public let envelopeDigest: String
    public let acceptance: EnrollmentAcceptanceDecision

    public var bundle: DeviceBundle { payload.deviceBundle }
}

public enum SignedEnrollmentError: Error, Equatable, CustomStringConvertible {
    case trustUnavailable
    case malformedEnvelope
    case invalidBase64URL
    case nonCanonicalProtectedHeader
    case invalidProtectedHeader
    case unsupportedAlgorithm
    case unknownKey
    case invalidSignature
    case nonCanonicalPayload
    case invalidPayload
    case issuerMismatch
    case audienceMismatch
    case notYetValid
    case bundleExpired
    case credentialExpired
    case rollback
    case collision
    case acceptanceStateUnavailable

    public var description: String {
        switch self {
        case .trustUnavailable:
            "No trusted Jazz enrollment issuer is configured on this Mac."
        case .malformedEnvelope:
            "The enrollment bundle is not a flattened signed Jazz bundle."
        case .invalidBase64URL:
            "The signed enrollment bundle contains invalid base64url."
        case .nonCanonicalProtectedHeader:
            "The signed enrollment protected header is not canonical JSON."
        case .invalidProtectedHeader:
            "The signed enrollment protected header is not the required Jazz profile."
        case .unsupportedAlgorithm:
            "The signed enrollment bundle does not use EdDSA."
        case .unknownKey:
            "The enrollment signing key is not trusted by this Mac."
        case .invalidSignature:
            "The enrollment bundle signature is invalid."
        case .nonCanonicalPayload:
            "The signed enrollment payload is not canonical JSON."
        case .invalidPayload:
            "The signed enrollment payload does not satisfy the v2 contract."
        case .issuerMismatch:
            "The enrollment bundle was signed for a different Jazz issuer."
        case .audienceMismatch:
            "The enrollment bundle was signed for a different client audience."
        case .notYetValid:
            "The enrollment bundle was issued in the future."
        case .bundleExpired:
            "The copied enrollment bundle has expired; issue a new one."
        case .credentialExpired:
            "The scoped enrollment credential has expired; issue a new bundle."
        case .rollback:
            "This device has already accepted a newer enrollment generation."
        case .collision:
            "The enrollment generation or bundle id was reused with different signed content."
        case .acceptanceStateUnavailable:
            "The local enrollment replay state is unavailable; import was stopped safely."
        }
    }
}

public struct SignedEnrollmentVerifier: Sendable {
    public static let expectedAlgorithm = "EdDSA"
    public static let expectedType = "application/jazz-device-bundle+jws"

    private static let envelopeKeys: Set<String> = ["protected", "payload", "signature"]
    private static let protectedKeys: Set<String> = ["alg", "kid", "typ"]
    private static let payloadKeys: Set<String> = [
        "schemaVersion", "kind", "bundleId", "generation", "issuer", "audience", "issuedAt",
        "bundleExpiresAt", "deviceId", "companyId", "areaId", "projectId", "stackURL",
        "archiveIngestURL", "token", "tokenId", "expiresAt", "tokenBucketScope",
        "sinkBucketId", "componentAccess", "streamSourceId", "streamEndpoint",
    ]
    private static let bundleIDPattern = try! NSRegularExpression(
        pattern: "^jdb_[a-f0-9]{32}$")
    private static let scopeIDPattern = try! NSRegularExpression(
        pattern: "^[a-z0-9][a-z0-9-]{0,63}$")
    private static let projectIDPattern = try! NSRegularExpression(pattern: "^[0-9]+$")
    private static let componentPattern = try! NSRegularExpression(
        pattern: "^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$")
    public let trustPolicy: EnrollmentTrustPolicy

    public init(trustPolicy: EnrollmentTrustPolicy) {
        self.trustPolicy = trustPolicy
    }

    public func verify(_ text: String, now: Date = Date()) throws
        -> AuthorizedSignedDeviceBundle
    {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            trimmed.utf8.count <= 200_000,
            let envelopeData = trimmed.data(using: .utf8),
            StrictJSON.hasUniqueObjectKeys(envelopeData),
            let envelope = try? JSONSerialization.jsonObject(with: envelopeData)
                as? [String: Any],
            Set(envelope.keys) == Self.envelopeKeys,
            let protectedSegment = envelope["protected"] as? String,
            let payloadSegment = envelope["payload"] as? String,
            let signatureSegment = envelope["signature"] as? String
        else {
            throw SignedEnrollmentError.malformedEnvelope
        }

        guard
            protectedSegment.utf8.count <= 2_048,
            payloadSegment.utf8.count <= 131_072,
            signatureSegment.utf8.count == 86,
            let protectedData = EnrollmentEncoding.decodeBase64URL(
                protectedSegment,
                maximumBytes: 1_536),
            let payloadData = EnrollmentEncoding.decodeBase64URL(
                payloadSegment,
                maximumBytes: 98_304),
            let signature = EnrollmentEncoding.decodeBase64URL(
                signatureSegment,
                maximumBytes: 64),
            signature.count == 64
        else {
            throw SignedEnrollmentError.invalidBase64URL
        }

        guard StrictJSON.hasUniqueObjectKeys(protectedData) else {
            throw SignedEnrollmentError.invalidProtectedHeader
        }
        guard
            let protected = try? JSONSerialization.jsonObject(with: protectedData)
                as? [String: Any],
            EnrollmentEncoding.canonicalJSONObject(protected) == protectedData
        else {
            throw SignedEnrollmentError.nonCanonicalProtectedHeader
        }
        guard Set(protected.keys) == Self.protectedKeys else {
            throw SignedEnrollmentError.invalidProtectedHeader
        }
        guard protected["alg"] as? String == Self.expectedAlgorithm else {
            throw SignedEnrollmentError.unsupportedAlgorithm
        }
        guard
            protected["typ"] as? String == Self.expectedType,
            let keyID = protected["kid"] as? String,
            EnrollmentEncoding.isValidKeyID(keyID)
        else {
            throw SignedEnrollmentError.invalidProtectedHeader
        }
        guard let publicKey = trustPolicy.publicKey(for: keyID) else {
            throw SignedEnrollmentError.unknownKey
        }

        let signingInput = Data("\(protectedSegment).\(payloadSegment)".utf8)
        guard publicKey.isValidSignature(signature, for: signingInput) else {
            throw SignedEnrollmentError.invalidSignature
        }

        guard StrictJSON.hasUniqueObjectKeys(payloadData) else {
            throw SignedEnrollmentError.invalidPayload
        }
        guard
            let payloadObject = try? JSONSerialization.jsonObject(with: payloadData)
                as? [String: Any],
            EnrollmentEncoding.canonicalJSONObject(payloadObject) == payloadData
        else {
            throw SignedEnrollmentError.nonCanonicalPayload
        }
        guard Set(payloadObject.keys) == Self.payloadKeys else {
            throw SignedEnrollmentError.invalidPayload
        }
        let payload: SignedDeviceBundlePayload
        do {
            payload = try JSONDecoder().decode(SignedDeviceBundlePayload.self, from: payloadData)
        } catch {
            throw SignedEnrollmentError.invalidPayload
        }
        try validate(payload, now: now)

        guard
            let canonicalEnvelope = EnrollmentEncoding.canonicalJSONObject([
                "protected": protectedSegment,
                "payload": payloadSegment,
                "signature": signatureSegment,
            ])
        else {
            throw SignedEnrollmentError.malformedEnvelope
        }
        let envelopeDigest = SHA256.hash(data: canonicalEnvelope)
            .map { String(format: "%02x", $0) }
            .joined()
        return AuthorizedSignedDeviceBundle(
            payload: payload,
            envelopeDigest: envelopeDigest,
            acceptance: .pending)
    }

    private func validate(_ payload: SignedDeviceBundlePayload, now: Date) throws {
        guard
            payload.schemaVersion == 2,
            payload.kind == DeviceBundle.expectedKind,
            Self.matches(payload.bundleId, pattern: Self.bundleIDPattern),
            payload.generation >= 1,
            payload.generation <= 9_007_199_254_740_991,
            payload.issuer.unicodeScalars.count <= 2_048,
            payload.audience.unicodeScalars.count <= 256,
            Self.matches(payload.deviceId, pattern: Self.scopeIDPattern),
            Self.matches(payload.companyId, pattern: Self.scopeIDPattern),
            Self.matches(payload.areaId, pattern: Self.scopeIDPattern),
            Self.matches(payload.projectId, pattern: Self.projectIDPattern),
            payload.stackURL.unicodeScalars.count <= 2_048,
            payload.archiveIngestURL.unicodeScalars.count <= 2_048,
            !payload.token.isEmpty,
            payload.token.unicodeScalars.count <= 8_192,
            !payload.tokenId.isEmpty,
            payload.tokenId.unicodeScalars.count <= 256,
            payload.componentAccess.count <= 128,
            payload.componentAccess == payload.componentAccess.sorted(),
            Set(payload.componentAccess).count == payload.componentAccess.count,
            payload.componentAccess.allSatisfy({
                Self.matches($0, pattern: Self.componentPattern)
            }),
            payload.streamSourceId.map({
                !$0.isEmpty && $0.unicodeScalars.count <= 512
            }) ?? true,
            (payload.streamEndpoint?.unicodeScalars.count ?? 0) <= 8_192
        else {
            throw SignedEnrollmentError.invalidPayload
        }

        guard payload.issuer == trustPolicy.issuer else {
            throw SignedEnrollmentError.issuerMismatch
        }
        guard payload.audience == trustPolicy.audience else {
            throw SignedEnrollmentError.audienceMismatch
        }
        guard
            EnrollmentURLPolicy.isSecureOrigin(payload.issuer),
            KeboolaStack.normalize(payload.stackURL) == payload.stackURL,
            JazzArchiveControlPlaneURL.normalize(payload.archiveIngestURL)
                == payload.archiveIngestURL
        else {
            throw SignedEnrollmentError.invalidPayload
        }
        if let streamEndpoint = payload.streamEndpoint {
            guard EnrollmentURLPolicy.isSecureEndpoint(streamEndpoint) else {
                throw SignedEnrollmentError.invalidPayload
            }
        }
        if payload.streamSourceId != nil, payload.streamEndpoint == nil {
            throw SignedEnrollmentError.invalidPayload
        }

        switch payload.tokenBucketScope {
        case .sink:
            guard
                let sinkBucketID = payload.sinkBucketId,
                !sinkBucketID.isEmpty,
                sinkBucketID.unicodeScalars.count <= 512
            else {
                throw SignedEnrollmentError.invalidPayload
            }
        case .none:
            guard payload.sinkBucketId == nil else {
                throw SignedEnrollmentError.invalidPayload
            }
        }

        guard
            let issuedAt = Timestamps.parse(payload.issuedAt),
            let bundleExpiresAt = Timestamps.parse(payload.bundleExpiresAt),
            let credentialExpiresAt = Timestamps.parse(payload.expiresAt),
            issuedAt.timeIntervalSinceReferenceDate.isFinite,
            bundleExpiresAt.timeIntervalSinceReferenceDate.isFinite,
            credentialExpiresAt.timeIntervalSinceReferenceDate.isFinite,
            bundleExpiresAt > issuedAt,
            credentialExpiresAt >= bundleExpiresAt
        else {
            throw SignedEnrollmentError.invalidPayload
        }
        if issuedAt > now.addingTimeInterval(trustPolicy.clockSkew) {
            throw SignedEnrollmentError.notYetValid
        }
        let earliestAcceptedNow = now.addingTimeInterval(-trustPolicy.clockSkew)
        if earliestAcceptedNow >= bundleExpiresAt {
            throw SignedEnrollmentError.bundleExpired
        }
        if earliestAcceptedNow >= credentialExpiresAt {
            throw SignedEnrollmentError.credentialExpired
        }
    }

    private static func matches(_ value: String, pattern: NSRegularExpression) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return pattern.firstMatch(in: value, range: range)?.range == range
    }
}
