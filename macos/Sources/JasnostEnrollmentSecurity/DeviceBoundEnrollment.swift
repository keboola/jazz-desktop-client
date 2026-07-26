import CryptoKit
import Foundation

public enum DeviceBoundEnrollmentError: Error, Equatable, CustomStringConvertible {
    case malformedClaim
    case invalidClaim
    case invalidClaimProof
    case nonCanonicalSignature
    case malformedSealedBundle
    case invalidProtectedContext
    case contextMismatch
    case wrongRecipient
    case authenticationFailed
    case expired
    case digestMismatch

    public var description: String {
        switch self {
        case .malformedClaim:
            "The device enrollment claim is not canonical strict JSON."
        case .invalidClaim:
            "The device enrollment claim does not satisfy the v1 contract."
        case .invalidClaimProof:
            "The P-256 proof of possession is invalid."
        case .nonCanonicalSignature:
            "The device enrollment proof is not canonical low-S ES256."
        case .malformedSealedBundle:
            "The sealed device bundle is malformed."
        case .invalidProtectedContext:
            "The sealed device bundle protected context is invalid."
        case .contextMismatch:
            "The sealed device bundle belongs to a different claim or bundle."
        case .wrongRecipient:
            "The sealed device bundle is bound to a different wrapping key."
        case .authenticationFailed:
            "The sealed device bundle failed authenticated decryption."
        case .expired:
            "The sealed device bundle reveal has expired."
        case .digestMismatch:
            "The decrypted signed bundle does not match its protected digest."
        }
    }
}

public struct DeviceEnrollmentPublicKey: Codable, Equatable, Sendable {
    public let kty: String
    public let crv: String
    public let format: String
    public let alg: String
    public let use: String
    public let publicKey: String

    public init(
        kty: String = "EC",
        crv: String = "P-256",
        format: String = "X9.63",
        alg: String,
        use: String,
        publicKey: String
    ) {
        self.kty = kty
        self.crv = crv
        self.format = format
        self.alg = alg
        self.use = use
        self.publicKey = publicKey
    }
}

public struct DeviceEnrollmentClaimPayload: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let bootstrapId: String
    public let claimId: String
    public let deviceId: String
    public let issuedAt: String
    public let expiresAt: String
    public let proofKey: DeviceEnrollmentPublicKey
    public let wrappingKey: DeviceEnrollmentPublicKey

    public init(
        schemaVersion: Int = 1,
        kind: String = "jazz-device-enrollment-claim",
        bootstrapId: String,
        claimId: String,
        deviceId: String,
        issuedAt: String,
        expiresAt: String,
        proofKey: DeviceEnrollmentPublicKey,
        wrappingKey: DeviceEnrollmentPublicKey
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.bootstrapId = bootstrapId
        self.claimId = claimId
        self.deviceId = deviceId
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.proofKey = proofKey
        self.wrappingKey = wrappingKey
    }
}

public struct DeviceEnrollmentClaimEnvelope: Codable, Equatable, Sendable {
    public let payload: String
    public let proof: String

    public init(payload: String, proof: String) {
        self.payload = payload
        self.proof = proof
    }
}

public struct DeviceEnrollmentClaimBinding: Equatable, Sendable {
    public let bootstrapId: String
    public let claimId: String
    public let deviceId: String
    public let claimSHA256: String
    public let proofPublicKey: String
    public let proofKeyThumbprint: String
    public let wrappingPublicKey: String
    public let wrappingKeyThumbprint: String

    public init(
        bootstrapId: String,
        claimId: String,
        deviceId: String,
        claimSHA256: String,
        proofPublicKey: String,
        proofKeyThumbprint: String,
        wrappingPublicKey: String,
        wrappingKeyThumbprint: String
    ) {
        self.bootstrapId = bootstrapId
        self.claimId = claimId
        self.deviceId = deviceId
        self.claimSHA256 = claimSHA256
        self.proofPublicKey = proofPublicKey
        self.proofKeyThumbprint = proofKeyThumbprint
        self.wrappingPublicKey = wrappingPublicKey
        self.wrappingKeyThumbprint = wrappingKeyThumbprint
    }
}

public struct VerifiedDeviceEnrollmentClaim: Sendable {
    public let payload: DeviceEnrollmentClaimPayload
    public let binding: DeviceEnrollmentClaimBinding
    public let canonicalPayload: Data
    public let canonicalEnvelope: Data
}

public struct DeviceBundleSealDescriptor: Equatable, Sendable {
    public let bundleId: String
    public let generation: Int
    public let sealedAt: String
    public let revealExpiresAt: String

    public init(
        bundleId: String,
        generation: Int,
        sealedAt: String,
        revealExpiresAt: String
    ) {
        self.bundleId = bundleId
        self.generation = generation
        self.sealedAt = sealedAt
        self.revealExpiresAt = revealExpiresAt
    }
}

/// Authenticated values carried by the protected sealed-bundle context.
///
/// A redemption client needs the descriptor before it can ask the device identity to open the
/// envelope. Exposing only these validated, non-secret values avoids duplicating the strict
/// protected-header parser in the networking layer.
public struct DeviceBundleSealInspection: Equatable, Sendable {
    public let descriptor: DeviceBundleSealDescriptor
    public let bundleSHA256: String

    public init(
        descriptor: DeviceBundleSealDescriptor,
        bundleSHA256: String
    ) {
        self.descriptor = descriptor
        self.bundleSHA256 = bundleSHA256
    }
}

/// Narrow signing boundary used by the device-claim encoder.
///
/// Production implementations may keep the private key in the Secure Enclave. Only the canonical
/// public point and a signature operation cross this boundary; a private scalar is never exposed.
public protocol DeviceEnrollmentProofSigning: Sendable {
    var publicKeyX963Representation: Data { get }
    func signatureRawRepresentation(for message: Data) throws -> Data
}

/// Narrow key-agreement boundary used by sealed enrollment-bundle redemption.
///
/// The caller supplies only a peer public point and the public HKDF inputs. Production
/// implementations perform ECDH with a non-exportable private key and return the derived symmetric
/// key, never the private scalar or the raw shared secret.
public protocol DeviceEnrollmentKeyAgreement: Sendable {
    var publicKeyX963Representation: Data { get }
    func deriveSymmetricKey(
        peerPublicKeyX963Representation: Data,
        salt: Data,
        sharedInfo: Data
    ) throws -> SymmetricKey
}

public enum DeviceBoundEnrollmentCrypto {
    public static let claimProofDomain = Data("JAZZ-DEVICE-ENROLLMENT-CLAIM-V1\0".utf8)
    public static let sealAADDomain = Data("JAZZ-DEVICE-ENROLLMENT-SEAL-AAD-V1\0".utf8)
    public static let sealKDFDomain = Data("JAZZ-DEVICE-ENROLLMENT-SEAL-KDF-V1\0".utf8)

    private static let claimEnvelopeKeys: Set<String> = ["payload", "proof"]
    private static let claimPayloadKeys: Set<String> = [
        "schemaVersion", "kind", "bootstrapId", "claimId", "deviceId", "issuedAt",
        "expiresAt", "proofKey", "wrappingKey",
    ]
    private static let keyKeys: Set<String> = [
        "kty", "crv", "format", "alg", "use", "publicKey",
    ]
    private static let ephemeralKeyKeys: Set<String> = [
        "kty", "crv", "format", "publicKey",
    ]
    private static let sealedEnvelopeKeys: Set<String> = [
        "protected", "iv", "ciphertext", "tag",
    ]
    private static let protectedKeys: Set<String> = [
        "alg", "enc", "kdf", "typ", "cty", "salt", "epk", "context",
    ]
    private static let contextKeys: Set<String> = [
        "bootstrapId", "claimId", "deviceId", "claimSha256", "proofKeyThumbprint",
        "wrappingKeyThumbprint", "bundleId", "generation", "bundleSha256", "sealedAt",
        "revealExpiresAt",
    ]
    private static let bootstrapIDPattern = try! NSRegularExpression(
        pattern: "^jbt_[a-f0-9]{32}$")
    private static let claimIDPattern = try! NSRegularExpression(
        pattern: "^jcl_[a-f0-9]{32}$")
    private static let bundleIDPattern = try! NSRegularExpression(
        pattern: "^jdb_[a-f0-9]{32}$")
    private static let deviceIDPattern = try! NSRegularExpression(
        pattern: "^[a-z0-9][a-z0-9-]{0,63}$")
    private static let sha256Pattern = try! NSRegularExpression(
        pattern: "^[a-f0-9]{64}$")
    private static let timestampPattern = try! NSRegularExpression(
        pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$"#)
    private static let p256Order = Data(hex:
        "FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551")
    private static let p256HalfOrder = Data(hex:
        "7FFFFFFF800000007FFFFFFFFFFFFFFFDE737D56D38BCF4279DCE5617E3192A8")
    private static let zeroScalar = Data(repeating: 0, count: 32)

    public static func publicKey(
        _ key: P256.Signing.PublicKey,
        purpose: String
    ) throws -> DeviceEnrollmentPublicKey {
        guard purpose == "proof" else {
            throw DeviceBoundEnrollmentError.invalidClaim
        }
        let raw = key.x963Representation
        try requireCanonicalP256(raw)
        return DeviceEnrollmentPublicKey(
            alg: "ES256",
            use: "sig",
            publicKey: EnrollmentEncoding.encodeBase64URL(raw))
    }

    public static func publicKey(
        _ key: P256.KeyAgreement.PublicKey,
        purpose: String
    ) throws -> DeviceEnrollmentPublicKey {
        guard purpose == "wrapping" else {
            throw DeviceBoundEnrollmentError.invalidClaim
        }
        let raw = key.x963Representation
        try requireCanonicalP256(raw)
        return DeviceEnrollmentPublicKey(
            alg: "ECDH-ES",
            use: "enc",
            publicKey: EnrollmentEncoding.encodeBase64URL(raw))
    }

    public static func makeClaim(
        payload: DeviceEnrollmentClaimPayload,
        proofPrivateKey: P256.Signing.PrivateKey
    ) throws -> Data {
        try makeClaim(
            payload: payload,
            proofSigner: SoftwareDeviceEnrollmentProofSigner(
                privateKey: proofPrivateKey))
    }

    public static func makeClaim(
        payload: DeviceEnrollmentClaimPayload,
        proofSigner: any DeviceEnrollmentProofSigning
    ) throws -> Data {
        let payloadData = try canonicalPayload(payload)
        let expected = try proofSigningKey(payload.proofKey)
        guard
            constantTimeEqual(
                expected.x963Representation,
                proofSigner.publicKeyX963Representation)
        else {
            throw DeviceBoundEnrollmentError.invalidClaim
        }
        let signature = try proofSigner.signatureRawRepresentation(
            for: claimProofDomain + payloadData)
        let lowS = try normalizeLowS(signature)
        let envelope: [String: Any] = [
            "payload": EnrollmentEncoding.encodeBase64URL(payloadData),
            "proof": EnrollmentEncoding.encodeBase64URL(lowS),
        ]
        return try canonicalObject(envelope, error: .malformedClaim)
    }

    public static func verifyClaim(_ envelopeData: Data) throws
        -> VerifiedDeviceEnrollmentClaim
    {
        guard
            !envelopeData.isEmpty,
            envelopeData.count <= 20_000,
            StrictJSON.hasUniqueObjectKeys(envelopeData),
            let envelope = try? JSONSerialization.jsonObject(with: envelopeData)
                as? [String: Any],
            Set(envelope.keys) == claimEnvelopeKeys,
            try canonicalObject(envelope, error: .malformedClaim) == envelopeData,
            let payloadSegment = envelope["payload"] as? String,
            let proofSegment = envelope["proof"] as? String,
            let payloadData = EnrollmentEncoding.decodeBase64URL(
                payloadSegment,
                maximumBytes: 8_192),
            let proof = EnrollmentEncoding.decodeBase64URL(
                proofSegment,
                maximumBytes: 64),
            proof.count == 64
        else {
            throw DeviceBoundEnrollmentError.malformedClaim
        }
        let payload = try decodePayload(payloadData)
        try requireCanonicalLowS(proof)
        let publicKey = try proofSigningKey(payload.proofKey)
        let signature: P256.Signing.ECDSASignature
        do {
            signature = try P256.Signing.ECDSASignature(rawRepresentation: proof)
        } catch {
            throw DeviceBoundEnrollmentError.invalidClaimProof
        }
        guard publicKey.isValidSignature(
            signature,
            for: claimProofDomain + payloadData)
        else {
            throw DeviceBoundEnrollmentError.invalidClaimProof
        }
        let proofThumbprint = try keyThumbprint(payload.proofKey.publicKey)
        let wrappingThumbprint = try keyThumbprint(payload.wrappingKey.publicKey)
        return VerifiedDeviceEnrollmentClaim(
            payload: payload,
            binding: DeviceEnrollmentClaimBinding(
                bootstrapId: payload.bootstrapId,
                claimId: payload.claimId,
                deviceId: payload.deviceId,
                claimSHA256: hexSHA256(payloadData),
                proofPublicKey: payload.proofKey.publicKey,
                proofKeyThumbprint: proofThumbprint,
                wrappingPublicKey: payload.wrappingKey.publicKey,
                wrappingKeyThumbprint: wrappingThumbprint),
            canonicalPayload: payloadData,
            canonicalEnvelope: envelopeData)
    }

    public static func openSealedBundle(
        _ wireBytes: Data,
        wrappingPrivateKey: P256.KeyAgreement.PrivateKey,
        binding: DeviceEnrollmentClaimBinding,
        descriptor: DeviceBundleSealDescriptor,
        now: Date
    ) throws -> Data {
        try openSealedBundle(
            wireBytes,
            wrappingKey: SoftwareDeviceEnrollmentKeyAgreement(
                privateKey: wrappingPrivateKey),
            binding: binding,
            descriptor: descriptor,
            now: now)
    }

    /// Strictly inspect the authenticated-context candidate before opening.
    ///
    /// The returned values are not trusted on their own: ``openSealedBundle`` authenticates the
    /// same protected segment with AES-GCM and binds it to the exact claim. This method exists only
    /// to supply the descriptor that the opening API requires.
    public static func inspectSealedBundle(
        _ wireBytes: Data
    ) throws -> DeviceBundleSealInspection {
        let parsed = try parseSealedBundle(wireBytes)
        guard
            let bundleID = parsed.context["bundleId"] as? String,
            let generation = parsed.context["generation"] as? Int,
            let sealedAt = parsed.context["sealedAt"] as? String,
            let revealExpiresAt = parsed.context["revealExpiresAt"] as? String,
            let bundleSHA256 = parsed.context["bundleSha256"] as? String
        else {
            throw DeviceBoundEnrollmentError.invalidProtectedContext
        }
        return DeviceBundleSealInspection(
            descriptor: DeviceBundleSealDescriptor(
                bundleId: bundleID,
                generation: generation,
                sealedAt: sealedAt,
                revealExpiresAt: revealExpiresAt),
            bundleSHA256: bundleSHA256)
    }

    public static func openSealedBundle(
        _ wireBytes: Data,
        wrappingKey: any DeviceEnrollmentKeyAgreement,
        binding: DeviceEnrollmentClaimBinding,
        descriptor: DeviceBundleSealDescriptor,
        now: Date
    ) throws -> Data {
        let expectedRecipient = try wrappingAgreementKey(binding.wrappingPublicKey)
        guard
            constantTimeEqual(
                expectedRecipient.x963Representation,
                wrappingKey.publicKeyX963Representation)
        else {
            throw DeviceBoundEnrollmentError.wrongRecipient
        }
        let parsed = try parseSealedBundle(wireBytes)
        try requireContext(
            parsed.context,
            binding: binding,
            descriptor: descriptor)
        guard
            let expiry = parseTimestamp(
                parsed.context["revealExpiresAt"] as? String),
            now.addingTimeInterval(-30) < expiry
        else {
            throw DeviceBoundEnrollmentError.expired
        }
        let aad = sealAADDomain + Data(parsed.protectedSegment.utf8)
        let info = sealKDFDomain + Data(SHA256.hash(data: aad))
        let key: SymmetricKey
        do {
            key = try wrappingKey.deriveSymmetricKey(
                peerPublicKeyX963Representation: parsed.ephemeralPublicKey,
                salt: parsed.salt,
                sharedInfo: info)
        } catch {
            throw DeviceBoundEnrollmentError.authenticationFailed
        }
        let nonce: AES.GCM.Nonce
        let sealedBox: AES.GCM.SealedBox
        do {
            nonce = try AES.GCM.Nonce(data: parsed.iv)
            sealedBox = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: parsed.ciphertext,
                tag: parsed.tag)
        } catch {
            throw DeviceBoundEnrollmentError.malformedSealedBundle
        }
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(
                sealedBox,
                using: key,
                authenticating: aad)
        } catch {
            throw DeviceBoundEnrollmentError.authenticationFailed
        }
        guard
            plaintext.count <= 131_072,
            let expectedDigest = parsed.context["bundleSha256"] as? String,
            constantTimeEqual(
                Data(hex: hexSHA256(plaintext)),
                Data(hex: expectedDigest))
        else {
            throw DeviceBoundEnrollmentError.digestMismatch
        }
        return plaintext
    }

    private static func canonicalPayload(
        _ payload: DeviceEnrollmentClaimPayload
    ) throws -> Data {
        let encoded = try JSONEncoder().encode(payload)
        guard
            let object = try? JSONSerialization.jsonObject(with: encoded)
                as? [String: Any],
            Set(object.keys) == claimPayloadKeys
        else {
            throw DeviceBoundEnrollmentError.invalidClaim
        }
        let canonical = try canonicalObject(object, error: .invalidClaim)
        _ = try decodePayload(canonical)
        return canonical
    }

    private static func decodePayload(_ data: Data) throws
        -> DeviceEnrollmentClaimPayload
    {
        guard
            !data.isEmpty,
            data.count <= 8_192,
            StrictJSON.hasUniqueObjectKeys(data),
            let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            Set(object.keys) == claimPayloadKeys,
            try canonicalObject(object, error: .invalidClaim) == data,
            let proofObject = object["proofKey"] as? [String: Any],
            let wrappingObject = object["wrappingKey"] as? [String: Any],
            Set(proofObject.keys) == keyKeys,
            Set(wrappingObject.keys) == keyKeys,
            let payload = try? JSONDecoder().decode(
                DeviceEnrollmentClaimPayload.self,
                from: data)
        else {
            throw DeviceBoundEnrollmentError.invalidClaim
        }
        guard
            payload.schemaVersion == 1,
            payload.kind == "jazz-device-enrollment-claim",
            matches(payload.bootstrapId, bootstrapIDPattern),
            matches(payload.claimId, claimIDPattern),
            matches(payload.deviceId, deviceIDPattern),
            let issuedAt = parseTimestamp(payload.issuedAt),
            let expiresAt = parseTimestamp(payload.expiresAt),
            expiresAt > issuedAt,
            expiresAt.timeIntervalSince(issuedAt) <= 300,
            payload.proofKey.kty == "EC",
            payload.proofKey.crv == "P-256",
            payload.proofKey.format == "X9.63",
            payload.proofKey.alg == "ES256",
            payload.proofKey.use == "sig",
            payload.wrappingKey.kty == "EC",
            payload.wrappingKey.crv == "P-256",
            payload.wrappingKey.format == "X9.63",
            payload.wrappingKey.alg == "ECDH-ES",
            payload.wrappingKey.use == "enc",
            payload.proofKey.publicKey != payload.wrappingKey.publicKey
        else {
            throw DeviceBoundEnrollmentError.invalidClaim
        }
        _ = try proofSigningKey(payload.proofKey)
        _ = try wrappingAgreementKey(payload.wrappingKey.publicKey)
        return payload
    }

    private static func proofSigningKey(
        _ profile: DeviceEnrollmentPublicKey
    ) throws -> P256.Signing.PublicKey {
        guard
            profile.kty == "EC",
            profile.crv == "P-256",
            profile.format == "X9.63",
            profile.alg == "ES256",
            profile.use == "sig",
            let raw = EnrollmentEncoding.decodeBase64URL(
                profile.publicKey,
                maximumBytes: 65)
        else {
            throw DeviceBoundEnrollmentError.invalidClaim
        }
        try requireCanonicalP256(raw)
        do {
            return try P256.Signing.PublicKey(x963Representation: raw)
        } catch {
            throw DeviceBoundEnrollmentError.invalidClaim
        }
    }

    private static func wrappingAgreementKey(_ encoded: String) throws
        -> P256.KeyAgreement.PublicKey
    {
        guard
            let raw = EnrollmentEncoding.decodeBase64URL(
                encoded,
                maximumBytes: 65)
        else {
            throw DeviceBoundEnrollmentError.invalidClaim
        }
        try requireCanonicalP256(raw)
        do {
            return try P256.KeyAgreement.PublicKey(x963Representation: raw)
        } catch {
            throw DeviceBoundEnrollmentError.invalidClaim
        }
    }

    private static func requireCanonicalP256(_ raw: Data) throws {
        guard raw.count == 65, raw.first == 0x04 else {
            throw DeviceBoundEnrollmentError.invalidClaim
        }
    }

    private static func keyThumbprint(_ encoded: String) throws -> String {
        guard
            let raw = EnrollmentEncoding.decodeBase64URL(
                encoded,
                maximumBytes: 65)
        else {
            throw DeviceBoundEnrollmentError.invalidClaim
        }
        try requireCanonicalP256(raw)
        let x = EnrollmentEncoding.encodeBase64URL(raw.subdata(in: 1..<33))
        let y = EnrollmentEncoding.encodeBase64URL(raw.subdata(in: 33..<65))
        let jwk: [String: Any] = [
            "crv": "P-256",
            "kty": "EC",
            "x": x,
            "y": y,
        ]
        return EnrollmentEncoding.encodeBase64URL(
            Data(SHA256.hash(data: try canonicalObject(jwk, error: .invalidClaim))))
    }

    private struct ParsedSealedBundle {
        let protectedSegment: String
        let salt: Data
        let ephemeralPublicKey: Data
        let context: [String: Any]
        let iv: Data
        let ciphertext: Data
        let tag: Data
    }

    private static func parseSealedBundle(_ wireBytes: Data) throws
        -> ParsedSealedBundle
    {
        guard
            !wireBytes.isEmpty,
            wireBytes.count <= 200_000,
            StrictJSON.hasUniqueObjectKeys(wireBytes),
            let envelope = try? JSONSerialization.jsonObject(with: wireBytes)
                as? [String: Any],
            Set(envelope.keys) == sealedEnvelopeKeys,
            try canonicalObject(envelope, error: .malformedSealedBundle)
                == wireBytes,
            let protectedSegment = envelope["protected"] as? String,
            protectedSegment.utf8.count <= 16_384,
            let protectedData = EnrollmentEncoding.decodeBase64URL(
                protectedSegment,
                maximumBytes: 12_288),
            StrictJSON.hasUniqueObjectKeys(protectedData),
            let protected = try? JSONSerialization.jsonObject(with: protectedData)
                as? [String: Any],
            Set(protected.keys) == protectedKeys,
            try canonicalObject(protected, error: .invalidProtectedContext)
                == protectedData,
            protected["alg"] as? String == "ECDH-ES",
            protected["enc"] as? String == "A256GCM",
            protected["kdf"] as? String == "HKDF-SHA256",
            protected["typ"] as? String
                == "application/jazz-device-enrollment-sealed+json",
            protected["cty"] as? String
                == "application/jazz-device-bundle+jws",
            let saltText = protected["salt"] as? String,
            let salt = EnrollmentEncoding.decodeBase64URL(
                saltText,
                maximumBytes: 32),
            salt.count == 32,
            let ephemeral = protected["epk"] as? [String: Any],
            Set(ephemeral.keys) == ephemeralKeyKeys,
            ephemeral["kty"] as? String == "EC",
            ephemeral["crv"] as? String == "P-256",
            ephemeral["format"] as? String == "X9.63",
            let ephemeralText = ephemeral["publicKey"] as? String,
            let ephemeralPublicKey = EnrollmentEncoding.decodeBase64URL(
                ephemeralText,
                maximumBytes: 65),
            ephemeralPublicKey.count == 65,
            ephemeralPublicKey.first == 0x04,
            let context = protected["context"] as? [String: Any],
            Set(context.keys) == contextKeys,
            let ivText = envelope["iv"] as? String,
            let iv = EnrollmentEncoding.decodeBase64URL(
                ivText,
                maximumBytes: 12),
            iv.count == 12,
            let ciphertextText = envelope["ciphertext"] as? String,
            let ciphertext = EnrollmentEncoding.decodeBase64URL(
                ciphertextText,
                maximumBytes: 131_072),
            !ciphertext.isEmpty,
            let tagText = envelope["tag"] as? String,
            let tag = EnrollmentEncoding.decodeBase64URL(
                tagText,
                maximumBytes: 16),
            tag.count == 16
        else {
            throw DeviceBoundEnrollmentError.malformedSealedBundle
        }
        do {
            _ = try P256.KeyAgreement.PublicKey(
                x963Representation: ephemeralPublicKey)
        } catch {
            throw DeviceBoundEnrollmentError.invalidProtectedContext
        }
        try validateContext(context)
        return ParsedSealedBundle(
            protectedSegment: protectedSegment,
            salt: salt,
            ephemeralPublicKey: ephemeralPublicKey,
            context: context,
            iv: iv,
            ciphertext: ciphertext,
            tag: tag)
    }

    private static func validateContext(_ context: [String: Any]) throws {
        guard
            let bootstrapId = context["bootstrapId"] as? String,
            matches(bootstrapId, bootstrapIDPattern),
            let claimId = context["claimId"] as? String,
            matches(claimId, claimIDPattern),
            let deviceId = context["deviceId"] as? String,
            matches(deviceId, deviceIDPattern),
            let claimDigest = context["claimSha256"] as? String,
            matches(claimDigest, sha256Pattern),
            let proofThumbprint = context["proofKeyThumbprint"] as? String,
            EnrollmentEncoding.decodeBase64URL(
                proofThumbprint,
                maximumBytes: 32)?.count == 32,
            let wrappingThumbprint = context["wrappingKeyThumbprint"] as? String,
            EnrollmentEncoding.decodeBase64URL(
                wrappingThumbprint,
                maximumBytes: 32)?.count == 32,
            let bundleId = context["bundleId"] as? String,
            matches(bundleId, bundleIDPattern),
            let generation = context["generation"] as? Int,
            generation >= 1,
            generation <= 9_007_199_254_740_991,
            let bundleDigest = context["bundleSha256"] as? String,
            matches(bundleDigest, sha256Pattern),
            let sealedAtText = context["sealedAt"] as? String,
            let expiresAtText = context["revealExpiresAt"] as? String,
            let sealedAt = parseTimestamp(sealedAtText),
            let expiresAt = parseTimestamp(expiresAtText),
            expiresAt > sealedAt,
            expiresAt.timeIntervalSince(sealedAt) <= 900
        else {
            throw DeviceBoundEnrollmentError.invalidProtectedContext
        }
    }

    private static func requireContext(
        _ context: [String: Any],
        binding: DeviceEnrollmentClaimBinding,
        descriptor: DeviceBundleSealDescriptor
    ) throws {
        guard
            context["bootstrapId"] as? String == binding.bootstrapId,
            context["claimId"] as? String == binding.claimId,
            context["deviceId"] as? String == binding.deviceId,
            context["claimSha256"] as? String == binding.claimSHA256,
            context["proofKeyThumbprint"] as? String
                == binding.proofKeyThumbprint,
            context["wrappingKeyThumbprint"] as? String
                == binding.wrappingKeyThumbprint,
            context["bundleId"] as? String == descriptor.bundleId,
            context["generation"] as? Int == descriptor.generation,
            context["sealedAt"] as? String == descriptor.sealedAt,
            context["revealExpiresAt"] as? String
                == descriptor.revealExpiresAt
        else {
            throw DeviceBoundEnrollmentError.contextMismatch
        }
    }

    private static func requireCanonicalLowS(_ signature: Data) throws {
        guard signature.count == 64 else {
            throw DeviceBoundEnrollmentError.invalidClaimProof
        }
        let r = signature.subdata(in: 0..<32)
        let s = signature.subdata(in: 32..<64)
        guard
            r != zeroScalar,
            s != zeroScalar,
            lexicographicCompare(r, p256Order) < 0,
            lexicographicCompare(s, p256HalfOrder) <= 0
        else {
            throw DeviceBoundEnrollmentError.nonCanonicalSignature
        }
    }

    private static func normalizeLowS(_ signature: Data) throws -> Data {
        guard signature.count == 64 else {
            throw DeviceBoundEnrollmentError.invalidClaimProof
        }
        let r = signature.subdata(in: 0..<32)
        var s = signature.subdata(in: 32..<64)
        if lexicographicCompare(s, p256HalfOrder) > 0 {
            s = subtract(p256Order, s)
        }
        let normalized = r + s
        try requireCanonicalLowS(normalized)
        return normalized
    }

    private static func subtract(_ lhs: Data, _ rhs: Data) -> Data {
        precondition(lhs.count == rhs.count)
        var result = [UInt8](repeating: 0, count: lhs.count)
        var borrow = 0
        let left = [UInt8](lhs)
        let right = [UInt8](rhs)
        for index in stride(from: lhs.count - 1, through: 0, by: -1) {
            var value = Int(left[index]) - Int(right[index]) - borrow
            if value < 0 {
                value += 256
                borrow = 1
            } else {
                borrow = 0
            }
            result[index] = UInt8(value)
        }
        precondition(borrow == 0)
        return Data(result)
    }

    private static func lexicographicCompare(_ lhs: Data, _ rhs: Data) -> Int {
        precondition(lhs.count == rhs.count)
        for (left, right) in zip(lhs, rhs) {
            if left < right { return -1 }
            if left > right { return 1 }
        }
        return 0
    }

    private static func canonicalObject(
        _ value: [String: Any],
        error: DeviceBoundEnrollmentError
    ) throws -> Data {
        guard let data = EnrollmentEncoding.canonicalJSONObject(value) else {
            throw error
        }
        return data
    }

    private static func parseTimestamp(_ value: String?) -> Date? {
        guard
            let value,
            matches(value, timestampPattern)
        else {
            return nil
        }
        return timestampFormatter.date(from: value)
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.isLenient = false
        return formatter
    }()

    private static func matches(
        _ value: String,
        _ pattern: NSRegularExpression
    ) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return pattern.firstMatch(in: value, range: range)?.range == range
    }

    private static func hexSHA256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }
}

private struct SoftwareDeviceEnrollmentProofSigner: DeviceEnrollmentProofSigning {
    let privateKey: P256.Signing.PrivateKey

    var publicKeyX963Representation: Data {
        privateKey.publicKey.x963Representation
    }

    func signatureRawRepresentation(for message: Data) throws -> Data {
        try privateKey.signature(for: message).rawRepresentation
    }
}

private struct SoftwareDeviceEnrollmentKeyAgreement: DeviceEnrollmentKeyAgreement {
    let privateKey: P256.KeyAgreement.PrivateKey

    var publicKeyX963Representation: Data {
        privateKey.publicKey.x963Representation
    }

    func deriveSymmetricKey(
        peerPublicKeyX963Representation: Data,
        salt: Data,
        sharedInfo: Data
    ) throws -> SymmetricKey {
        let peer = try P256.KeyAgreement.PublicKey(
            x963Representation: peerPublicKeyX963Representation)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        return secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: sharedInfo,
            outputByteCount: 32)
    }
}

private extension Data {
    init(hex: String) {
        self.init()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
    }
}
