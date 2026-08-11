import CryptoKit
import Darwin
import Foundation
import Security

/// Fail-closed failures for the local device enrollment identity.
///
/// Descriptions deliberately contain no Keychain bytes, Secure Enclave key references, claim
/// material, device id, authority binding, or Security-framework diagnostics. Callers may surface
/// these descriptions to an operator without turning an error path into a secret-export path.
public enum DeviceEnrollmentIdentityError: Error, Equatable, CustomStringConvertible {
    case invalidBinding
    case hardwareUnavailable
    case persistenceUnavailable
    case corruptState
    case bindingConflict
    case revoked
    case staleKeySet
    case keyOperationFailed

    public var description: String {
        switch self {
        case .invalidBinding:
            "The requested device enrollment identity binding is invalid."
        case .hardwareUnavailable:
            "A hardware-backed device identity is unavailable."
        case .persistenceUnavailable:
            "The device identity Keychain state is unavailable."
        case .corruptState:
            "The persisted device identity failed closed validation."
        case .bindingConflict:
            "A different device enrollment binding already owns the identity slot."
        case .revoked:
            "The device enrollment identity has been revoked."
        case .staleKeySet:
            "The expected device enrollment key set is no longer current."
        case .keyOperationFailed:
            "The hardware-backed device key operation failed."
        }
    }
}

public struct DeviceEnrollmentIdentityBinding: Equatable, Sendable {
    public let deviceId: String
    /// Lower-hex SHA-256 of the canonical signed authority tuple (issuer, audience, project,
    /// stack/archive origins, Company, and Area). A one-time bootstrap id is deliberately absent:
    /// re-bootstrap under the same authority must prove continuity with this same hardware keyset.
    public let authorityBindingSHA256: String

    public init(deviceId: String, authorityBindingSHA256: String) throws {
        guard
            Self.matches(deviceId, pattern: Self.deviceIDPattern),
            Self.matches(authorityBindingSHA256, pattern: Self.digestPattern)
        else {
            throw DeviceEnrollmentIdentityError.invalidBinding
        }
        self.deviceId = deviceId
        self.authorityBindingSHA256 = authorityBindingSHA256
    }

    private static let deviceIDPattern = try! NSRegularExpression(
        pattern: "^[a-z0-9][a-z0-9-]{0,63}$")
    private static let digestPattern = try! NSRegularExpression(
        pattern: "^[a-f0-9]{64}$")

    private static func matches(_ value: String, pattern: NSRegularExpression) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return pattern.firstMatch(in: value, range: range)?.range == range
    }
}

public enum DeviceEnrollmentIdentityState: String, Codable, Equatable, Sendable {
    case active
    case revoked
}

/// Public, non-secret identity metadata safe to persist in local state or send to the control plane.
public struct DeviceEnrollmentIdentityMetadata: Codable, Equatable, Sendable,
    CustomStringConvertible
{
    public let schemaVersion: Int
    public let backend: String
    public let state: DeviceEnrollmentIdentityState
    public let revision: Int
    public let deviceId: String
    public let authorityBindingSHA256: String
    public let keySetId: String
    public let previousKeySetId: String?
    public let proofKeyId: String
    public let proofKeyThumbprint: String
    public let wrappingKeyId: String
    public let wrappingKeyThumbprint: String
    public let createdAt: String
    public let updatedAt: String

    /// Intentionally omits the device/authority binding and all persisted key-reference bytes.
    public var description: String {
        "DeviceEnrollmentIdentityMetadata(state: \(state.rawValue), revision: \(revision), "
            + "keySetId: \(keySetId), backend: \(backend))"
    }
}

/// A loaded key pair. The only private-key capabilities exposed are claim signing and bundle
/// opening. Neither API can return an opaque Secure Enclave reference or a private scalar.
public struct DeviceEnrollmentIdentity: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    public let metadata: DeviceEnrollmentIdentityMetadata
    public let proofKey: DeviceEnrollmentPublicKey
    public let wrappingKey: DeviceEnrollmentPublicKey

    private let signClaim: @Sendable (DeviceEnrollmentClaimPayload) throws -> Data
    private let openBundle:
        @Sendable (
            Data,
            DeviceEnrollmentClaimBinding,
            DeviceBundleSealDescriptor,
            Date
        ) throws -> Data

    fileprivate init(
        metadata: DeviceEnrollmentIdentityMetadata,
        proofKey: DeviceEnrollmentPublicKey,
        wrappingKey: DeviceEnrollmentPublicKey,
        signClaim:
            @escaping @Sendable (
                DeviceEnrollmentClaimPayload
            ) throws -> Data,
        openBundle:
            @escaping @Sendable (
                Data,
                DeviceEnrollmentClaimBinding,
                DeviceBundleSealDescriptor,
                Date
            ) throws -> Data
    ) {
        self.metadata = metadata
        self.proofKey = proofKey
        self.wrappingKey = wrappingKey
        self.signClaim = signClaim
        self.openBundle = openBundle
    }

    public var description: String {
        "DeviceEnrollmentIdentity(\(metadata.description))"
    }

    public var debugDescription: String {
        description
    }

    public func makeClaim(
        bootstrapId: String,
        claimId: String,
        issuedAt: String,
        expiresAt: String
    ) throws -> Data {
        guard metadata.state == .active else {
            throw DeviceEnrollmentIdentityError.revoked
        }
        do {
            return try signClaim(
                DeviceEnrollmentClaimPayload(
                    bootstrapId: bootstrapId,
                    claimId: claimId,
                    deviceId: metadata.deviceId,
                    issuedAt: issuedAt,
                    expiresAt: expiresAt,
                    proofKey: proofKey,
                    wrappingKey: wrappingKey))
        } catch let error as DeviceBoundEnrollmentError {
            throw error
        } catch let error as DeviceEnrollmentIdentityError {
            throw error
        } catch {
            throw DeviceEnrollmentIdentityError.keyOperationFailed
        }
    }

    public func openSealedBundle(
        _ wireBytes: Data,
        binding: DeviceEnrollmentClaimBinding,
        descriptor: DeviceBundleSealDescriptor,
        now: Date
    ) throws -> Data {
        guard metadata.state == .active else {
            throw DeviceEnrollmentIdentityError.revoked
        }
        return try openBundle(
            wireBytes,
            binding,
            descriptor,
            now)
    }
}

struct DeviceEnrollmentGeneratedKeyPair: Sendable {
    let proofReference: Data
    let wrappingReference: Data
    let proofSigner: any DeviceEnrollmentProofSigning
    let wrappingAgreement: any DeviceEnrollmentKeyAgreement
}

protocol DeviceEnrollmentKeyBackend: Sendable {
    var identifier: String { get }
    var isHardwareBacked: Bool { get }
    func generate() throws -> DeviceEnrollmentGeneratedKeyPair
    func restore(
        proofReference: Data,
        wrappingReference: Data
    ) throws -> DeviceEnrollmentGeneratedKeyPair
}

protocol DeviceEnrollmentIdentityPersisting: Sendable {
    func load() throws -> Data?
    /// Returns false when another writer already created the one active slot.
    func addIfAbsent(_ data: Data) throws -> Bool
    /// Atomically replaces an existing slot. Missing is an error.
    func replace(_ data: Data) throws
}

/// Restart-safe, single-slot identity lifecycle.
///
/// Every mutation is serialized by a process-wide lock and, in production, a stable flock sidecar.
/// The Keychain value contains both Secure Enclave opaque representations and all binding metadata,
/// so first creation, rotation, and revocation each have one atomic persistence commit. A caller
/// can never observe or persist only one half of the proof/wrapping pair.
public final class DeviceEnrollmentIdentityVault: @unchecked Sendable {
    private static let processLock = NSLock()

    private let persistence: any DeviceEnrollmentIdentityPersisting
    private let keyBackend: any DeviceEnrollmentKeyBackend
    private let lockFileURL: URL?

    init(
        persistence: any DeviceEnrollmentIdentityPersisting,
        keyBackend: any DeviceEnrollmentKeyBackend,
        lockFileURL: URL? = nil
    ) {
        self.persistence = persistence
        self.keyBackend = keyBackend
        self.lockFileURL = lockFileURL
    }

    /// The only public constructor is the deployed, fail-closed Secure Enclave path. Tests inject
    /// fakes through the internal initializer with `@testable import`.
    public static func production() throws -> DeviceEnrollmentIdentityVault {
        guard SecureEnclave.isAvailable else {
            throw DeviceEnrollmentIdentityError.hardwareUnavailable
        }
        guard
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        else {
            throw DeviceEnrollmentIdentityError.persistenceUnavailable
        }
        let securityDirectory =
            applicationSupport
            .appendingPathComponent("Jazz Capture", isDirectory: true)
            .appendingPathComponent("Security", isDirectory: true)
        return DeviceEnrollmentIdentityVault(
            persistence: KeychainDeviceEnrollmentIdentityPersistence(),
            keyBackend: SecureEnclaveDeviceEnrollmentKeyBackend(),
            lockFileURL:
                securityDirectory
                .appendingPathComponent("device-enrollment-identity-v1.lock"))
    }

    public func loadOrCreate(
        binding: DeviceEnrollmentIdentityBinding,
        now: Date = Date()
    ) throws -> DeviceEnrollmentIdentity {
        try withExclusiveLock {
            if let data = try loadData() {
                return try activeIdentity(from: data, binding: binding)
            }
            guard keyBackend.isHardwareBacked else {
                // This branch is unreachable through `production()`. It keeps an accidentally
                // injected software backend fail-closed outside tests too.
                throw DeviceEnrollmentIdentityError.hardwareUnavailable
            }
            let generated = try generateKeyPair()
            let record = try makeRecord(
                generated: generated,
                binding: binding,
                revision: 1,
                previousKeySetId: "",
                createdAt: now,
                updatedAt: now)
            let data = try encode(record)
            if try persistence.addIfAbsent(data) {
                return try identity(record: record, keyPair: generated)
            }
            // A non-cooperating process may have won `SecItemAdd`. Never keep or return the losing
            // pair; exact-reload the winner and enforce its binding.
            guard let winner = try loadData() else {
                throw DeviceEnrollmentIdentityError.persistenceUnavailable
            }
            return try activeIdentity(from: winner, binding: binding)
        }
    }

    public func load(
        binding: DeviceEnrollmentIdentityBinding
    ) throws -> DeviceEnrollmentIdentity? {
        try withExclusiveLock {
            guard let data = try loadData() else { return nil }
            return try activeIdentity(from: data, binding: binding)
        }
    }

    /// Explicit rotation changes key bytes but never changes device or signed authority binding.
    /// `expectedKeySetId` is a caller-visible fencing value; stale callers cannot rotate a newer
    /// pair. Rotation from a revoked tombstone is allowed for explicitly authorized re-enrollment.
    public func rotate(
        expectedKeySetId: String,
        to binding: DeviceEnrollmentIdentityBinding,
        now: Date = Date()
    ) throws -> DeviceEnrollmentIdentity {
        try withExclusiveLock {
            guard let currentData = try loadData() else {
                throw DeviceEnrollmentIdentityError.persistenceUnavailable
            }
            let current = try decodeAndValidate(
                currentData,
                restoreKeys: true)
            guard current.record.keySetId == expectedKeySetId else {
                throw DeviceEnrollmentIdentityError.staleKeySet
            }
            guard
                current.record.deviceId == binding.deviceId,
                current.record.authorityBindingSHA256
                    == binding.authorityBindingSHA256
            else {
                throw DeviceEnrollmentIdentityError.bindingConflict
            }
            guard current.record.revision < 9_007_199_254_740_991 else {
                throw DeviceEnrollmentIdentityError.corruptState
            }
            let generated = try generateKeyPair()
            let record = try makeRecord(
                generated: generated,
                binding: binding,
                revision: current.record.revision + 1,
                previousKeySetId: current.record.keySetId,
                createdAt: now,
                updatedAt: now)
            try persistence.replace(try encode(record))
            return try identity(record: record, keyPair: generated)
        }
    }

    /// Revocation atomically replaces both opaque key references with a non-secret tombstone.
    /// Exact retries are idempotent; a different expected key set is fenced.
    @discardableResult
    public func revoke(
        expectedKeySetId: String,
        now: Date = Date()
    ) throws -> DeviceEnrollmentIdentityMetadata {
        try withExclusiveLock {
            guard let currentData = try loadData() else {
                throw DeviceEnrollmentIdentityError.persistenceUnavailable
            }
            let current = try decodeAndValidate(currentData, restoreKeys: true)
            guard current.record.keySetId == expectedKeySetId else {
                throw DeviceEnrollmentIdentityError.staleKeySet
            }
            if current.record.state == .revoked {
                return metadata(current.record)
            }
            guard current.record.revision < 9_007_199_254_740_991 else {
                throw DeviceEnrollmentIdentityError.corruptState
            }
            var tombstone = current.record
            tombstone.state = .revoked
            tombstone.revision += 1
            tombstone.updatedAt = Self.timestamp(now)
            tombstone.proofKeyReference = ""
            tombstone.wrappingKeyReference = ""
            try validateRecord(tombstone)
            try persistence.replace(try encode(tombstone))
            return metadata(tombstone)
        }
    }

    public func metadata() throws -> DeviceEnrollmentIdentityMetadata? {
        try withExclusiveLock {
            guard let data = try loadData() else { return nil }
            return metadata(try decodeAndValidate(data, restoreKeys: true).record)
        }
    }

    private func activeIdentity(
        from data: Data,
        binding: DeviceEnrollmentIdentityBinding
    ) throws -> DeviceEnrollmentIdentity {
        let loaded = try decodeAndValidate(data, restoreKeys: true)
        guard
            loaded.record.deviceId == binding.deviceId,
            loaded.record.authorityBindingSHA256
                == binding.authorityBindingSHA256
        else {
            throw DeviceEnrollmentIdentityError.bindingConflict
        }
        guard loaded.record.state == .active, let keyPair = loaded.keyPair else {
            throw DeviceEnrollmentIdentityError.revoked
        }
        return try identity(record: loaded.record, keyPair: keyPair)
    }

    private func loadData() throws -> Data? {
        do {
            return try persistence.load()
        } catch {
            throw DeviceEnrollmentIdentityError.persistenceUnavailable
        }
    }

    private func generateKeyPair() throws -> DeviceEnrollmentGeneratedKeyPair {
        guard keyBackend.isHardwareBacked else {
            throw DeviceEnrollmentIdentityError.hardwareUnavailable
        }
        do {
            return try keyBackend.generate()
        } catch let error as DeviceEnrollmentIdentityError {
            throw error
        } catch {
            throw DeviceEnrollmentIdentityError.keyOperationFailed
        }
    }

    private struct LoadedRecord {
        let record: PersistedRecord
        let keyPair: DeviceEnrollmentGeneratedKeyPair?
    }

    private func decodeAndValidate(
        _ data: Data,
        restoreKeys: Bool
    ) throws -> LoadedRecord {
        let record: PersistedRecord
        do {
            guard
                !data.isEmpty,
                data.count <= 65_536,
                StrictJSON.hasUniqueObjectKeys(data),
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                Set(object.keys) == PersistedRecord.keys
            else {
                throw DeviceEnrollmentIdentityError.corruptState
            }
            record = try JSONDecoder().decode(PersistedRecord.self, from: data)
            try validateRecord(record)
        } catch let error as DeviceEnrollmentIdentityError {
            throw error
        } catch {
            throw DeviceEnrollmentIdentityError.corruptState
        }
        guard restoreKeys, record.state == .active else {
            return LoadedRecord(record: record, keyPair: nil)
        }
        guard
            let proofReference = decodeReference(record.proofKeyReference),
            let wrappingReference = decodeReference(record.wrappingKeyReference)
        else {
            throw DeviceEnrollmentIdentityError.corruptState
        }
        let restored: DeviceEnrollmentGeneratedKeyPair
        do {
            restored = try keyBackend.restore(
                proofReference: proofReference,
                wrappingReference: wrappingReference)
        } catch {
            throw DeviceEnrollmentIdentityError.corruptState
        }
        guard
            restored.proofReference == proofReference,
            restored.wrappingReference == wrappingReference
        else {
            throw DeviceEnrollmentIdentityError.corruptState
        }
        try validate(record: record, keyPair: restored)
        return LoadedRecord(record: record, keyPair: restored)
    }

    private func makeRecord(
        generated: DeviceEnrollmentGeneratedKeyPair,
        binding: DeviceEnrollmentIdentityBinding,
        revision: Int,
        previousKeySetId: String,
        createdAt: Date,
        updatedAt: Date
    ) throws -> PersistedRecord {
        let proof = try publicKey(
            generated.proofSigner.publicKeyX963Representation,
            purpose: "proof")
        let wrapping = try publicKey(
            generated.wrappingAgreement.publicKeyX963Representation,
            purpose: "wrapping")
        let proofThumbprint = try thumbprint(proof.publicKey)
        let wrappingThumbprint = try thumbprint(wrapping.publicKey)
        let record = PersistedRecord(
            schemaVersion: 1,
            kind: "jazz-device-enrollment-identity",
            backend: keyBackend.identifier,
            state: .active,
            revision: revision,
            deviceId: binding.deviceId,
            authorityBindingSHA256: binding.authorityBindingSHA256,
            keySetId: Self.keySetID(
                binding: binding,
                proofPublicKey: proof.publicKey,
                wrappingPublicKey: wrapping.publicKey),
            previousKeySetId: previousKeySetId,
            proofKeyId: Self.keyID(prefix: "jpk", publicKey: proof.publicKey),
            proofKeyThumbprint: proofThumbprint,
            proofPublicKey: proof.publicKey,
            wrappingKeyId: Self.keyID(prefix: "jwk", publicKey: wrapping.publicKey),
            wrappingKeyThumbprint: wrappingThumbprint,
            wrappingPublicKey: wrapping.publicKey,
            createdAt: Self.timestamp(createdAt),
            updatedAt: Self.timestamp(updatedAt),
            proofKeyReference: EnrollmentEncoding.encodeBase64URL(
                generated.proofReference),
            wrappingKeyReference: EnrollmentEncoding.encodeBase64URL(
                generated.wrappingReference))
        try validate(record: record, keyPair: generated)
        return record
    }

    private func validateRecord(_ record: PersistedRecord) throws {
        guard
            record.schemaVersion == 1,
            record.kind == "jazz-device-enrollment-identity",
            record.backend == keyBackend.identifier,
            (1...9_007_199_254_740_991).contains(record.revision),
            (try? DeviceEnrollmentIdentityBinding(
                deviceId: record.deviceId,
                authorityBindingSHA256: record.authorityBindingSHA256)) != nil,
            Self.matches(record.keySetId, pattern: Self.keySetIDPattern),
            record.previousKeySetId.isEmpty
                || Self.matches(record.previousKeySetId, pattern: Self.keySetIDPattern),
            Self.matches(record.proofKeyId, pattern: Self.proofKeyIDPattern),
            Self.matches(record.wrappingKeyId, pattern: Self.wrappingKeyIDPattern),
            EnrollmentEncoding.decodeBase64URL(
                record.proofKeyThumbprint,
                maximumBytes: 32)?.count == 32,
            EnrollmentEncoding.decodeBase64URL(
                record.wrappingKeyThumbprint,
                maximumBytes: 32)?.count == 32,
            Self.parseTimestamp(record.createdAt) != nil,
            let updatedAt = Self.parseTimestamp(record.updatedAt),
            let createdAt = Self.parseTimestamp(record.createdAt),
            updatedAt >= createdAt
        else {
            throw DeviceEnrollmentIdentityError.corruptState
        }
        let binding = try DeviceEnrollmentIdentityBinding(
            deviceId: record.deviceId,
            authorityBindingSHA256: record.authorityBindingSHA256)
        guard
            record.keySetId
                == Self.keySetID(
                    binding: binding,
                    proofPublicKey: record.proofPublicKey,
                    wrappingPublicKey: record.wrappingPublicKey),
            record.proofKeyId
                == Self.keyID(prefix: "jpk", publicKey: record.proofPublicKey),
            record.wrappingKeyId
                == Self.keyID(prefix: "jwk", publicKey: record.wrappingPublicKey),
            record.proofKeyThumbprint == (try thumbprint(record.proofPublicKey)),
            record.wrappingKeyThumbprint == (try thumbprint(record.wrappingPublicKey)),
            record.proofPublicKey != record.wrappingPublicKey
        else {
            throw DeviceEnrollmentIdentityError.corruptState
        }
        switch record.state {
        case .active:
            guard
                decodeReference(record.proofKeyReference) != nil,
                decodeReference(record.wrappingKeyReference) != nil
            else {
                throw DeviceEnrollmentIdentityError.corruptState
            }
        case .revoked:
            guard
                record.proofKeyReference.isEmpty,
                record.wrappingKeyReference.isEmpty
            else {
                throw DeviceEnrollmentIdentityError.corruptState
            }
        }
    }

    private func validate(
        record: PersistedRecord,
        keyPair: DeviceEnrollmentGeneratedKeyPair
    ) throws {
        try validateRecord(record)
        let proof = try publicKey(
            keyPair.proofSigner.publicKeyX963Representation,
            purpose: "proof")
        let wrapping = try publicKey(
            keyPair.wrappingAgreement.publicKeyX963Representation,
            purpose: "wrapping")
        guard
            proof.publicKey == record.proofPublicKey,
            wrapping.publicKey == record.wrappingPublicKey
        else {
            throw DeviceEnrollmentIdentityError.corruptState
        }
    }

    private func identity(
        record: PersistedRecord,
        keyPair: DeviceEnrollmentGeneratedKeyPair
    ) throws -> DeviceEnrollmentIdentity {
        try validate(record: record, keyPair: keyPair)
        return DeviceEnrollmentIdentity(
            metadata: metadata(record),
            proofKey: try publicKey(
                keyPair.proofSigner.publicKeyX963Representation,
                purpose: "proof"),
            wrappingKey: try publicKey(
                keyPair.wrappingAgreement.publicKeyX963Representation,
                purpose: "wrapping"),
            signClaim: { [self] payload in
                try withAuthorizedKeyUse(
                    expectedKeySetId: record.keySetId
                ) { currentKeyPair in
                    try DeviceBoundEnrollmentCrypto.makeClaim(
                        payload: payload,
                        proofSigner: currentKeyPair.proofSigner)
                }
            },
            openBundle: { [self] wireBytes, binding, descriptor, now in
                try withAuthorizedKeyUse(
                    expectedKeySetId: record.keySetId
                ) { currentKeyPair in
                    try DeviceBoundEnrollmentCrypto.openSealedBundle(
                        wireBytes,
                        wrappingKey: currentKeyPair.wrappingAgreement,
                        binding: binding,
                        descriptor: descriptor,
                        now: now)
                }
            })
    }

    private func withAuthorizedKeyUse<Result>(
        expectedKeySetId: String,
        operation: (DeviceEnrollmentGeneratedKeyPair) throws -> Result
    ) throws -> Result {
        try withExclusiveLock {
            guard let data = try loadData() else {
                throw DeviceEnrollmentIdentityError.persistenceUnavailable
            }
            // Reconstruct both persisted handles as well as checking the key-set fence. An
            // already-loaded capability must stop working if either Keychain reference is
            // corrupted or replaced after it was loaded.
            let loaded = try decodeAndValidate(data, restoreKeys: true)
            guard loaded.record.state == .active else {
                throw DeviceEnrollmentIdentityError.revoked
            }
            guard loaded.record.keySetId == expectedKeySetId else {
                throw DeviceEnrollmentIdentityError.staleKeySet
            }
            guard let keyPair = loaded.keyPair else {
                throw DeviceEnrollmentIdentityError.corruptState
            }
            // The stable process/flock critical section remains held while the freshly restored
            // Secure Enclave handle performs the sign/ECDH operation. Rotation or revocation
            // cannot commit between the fence and private-key use.
            return try operation(keyPair)
        }
    }

    private func metadata(_ record: PersistedRecord) -> DeviceEnrollmentIdentityMetadata {
        DeviceEnrollmentIdentityMetadata(
            schemaVersion: record.schemaVersion,
            backend: record.backend,
            state: record.state,
            revision: record.revision,
            deviceId: record.deviceId,
            authorityBindingSHA256: record.authorityBindingSHA256,
            keySetId: record.keySetId,
            previousKeySetId: record.previousKeySetId.isEmpty
                ? nil : record.previousKeySetId,
            proofKeyId: record.proofKeyId,
            proofKeyThumbprint: record.proofKeyThumbprint,
            wrappingKeyId: record.wrappingKeyId,
            wrappingKeyThumbprint: record.wrappingKeyThumbprint,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt)
    }

    private func publicKey(_ raw: Data, purpose: String) throws
        -> DeviceEnrollmentPublicKey
    {
        do {
            if purpose == "proof" {
                return try DeviceBoundEnrollmentCrypto.publicKey(
                    P256.Signing.PublicKey(x963Representation: raw),
                    purpose: purpose)
            }
            return try DeviceBoundEnrollmentCrypto.publicKey(
                P256.KeyAgreement.PublicKey(x963Representation: raw),
                purpose: purpose)
        } catch {
            throw DeviceEnrollmentIdentityError.corruptState
        }
    }

    private func thumbprint(_ encodedPublicKey: String) throws -> String {
        guard
            let raw = EnrollmentEncoding.decodeBase64URL(
                encodedPublicKey,
                maximumBytes: 65),
            raw.count == 65,
            raw.first == 0x04
        else {
            throw DeviceEnrollmentIdentityError.corruptState
        }
        let jwk: [String: Any] = [
            "crv": "P-256",
            "kty": "EC",
            "x": EnrollmentEncoding.encodeBase64URL(raw.subdata(in: 1..<33)),
            "y": EnrollmentEncoding.encodeBase64URL(raw.subdata(in: 33..<65)),
        ]
        guard let canonical = EnrollmentEncoding.canonicalJSONObject(jwk) else {
            throw DeviceEnrollmentIdentityError.corruptState
        }
        return EnrollmentEncoding.encodeBase64URL(Data(SHA256.hash(data: canonical)))
    }

    private func decodeReference(_ value: String) -> Data? {
        guard
            !value.isEmpty,
            let data = EnrollmentEncoding.decodeBase64URL(
                value,
                maximumBytes: 16_384),
            !data.isEmpty
        else {
            return nil
        }
        return data
    }

    private func encode(_ record: PersistedRecord) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(record)
            guard data.count <= 65_536 else {
                throw DeviceEnrollmentIdentityError.corruptState
            }
            return data
        } catch let error as DeviceEnrollmentIdentityError {
            throw error
        } catch {
            throw DeviceEnrollmentIdentityError.persistenceUnavailable
        }
    }

    private func withExclusiveLock<Result>(
        _ operation: () throws -> Result
    ) throws -> Result {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }

        guard let lockFileURL else {
            return try operation()
        }
        do {
            try FileManager.default.createDirectory(
                at: lockFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
        } catch {
            throw DeviceEnrollmentIdentityError.persistenceUnavailable
        }
        let descriptor = Darwin.open(
            lockFileURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC,
            S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw DeviceEnrollmentIdentityError.persistenceUnavailable
        }
        guard Self.changeFileLock(descriptor, operation: LOCK_EX) else {
            _ = Darwin.close(descriptor)
            throw DeviceEnrollmentIdentityError.persistenceUnavailable
        }
        let result: Swift.Result<Result, Error>
        do {
            result = .success(try operation())
        } catch {
            result = .failure(error)
        }
        let didUnlock = Self.changeFileLock(descriptor, operation: LOCK_UN)
        let didClose = Darwin.close(descriptor) == 0
        guard didUnlock, didClose else {
            throw DeviceEnrollmentIdentityError.persistenceUnavailable
        }
        return try result.get()
    }

    private static func changeFileLock(_ descriptor: Int32, operation: Int32) -> Bool {
        let apply: (Int32, Int32) -> Int32 = flock
        while apply(descriptor, operation) != 0 {
            guard errno == EINTR else { return false }
        }
        return true
    }

    private static let keySetIDPattern = try! NSRegularExpression(
        pattern: "^jks_[a-f0-9]{64}$")
    private static let proofKeyIDPattern = try! NSRegularExpression(
        pattern: "^jpk_[a-f0-9]{64}$")
    private static let wrappingKeyIDPattern = try! NSRegularExpression(
        pattern: "^jwk_[a-f0-9]{64}$")

    private static func keySetID(
        binding: DeviceEnrollmentIdentityBinding,
        proofPublicKey: String,
        wrappingPublicKey: String
    ) -> String {
        let material =
            Data("JAZZ-DEVICE-KEYSET-V1\0".utf8)
            + Data(binding.deviceId.utf8) + Data([0])
            + Data(binding.authorityBindingSHA256.utf8) + Data([0])
            + Data(proofPublicKey.utf8) + Data([0])
            + Data(wrappingPublicKey.utf8)
        return "jks_\(hexSHA256(material))"
    }

    private static func keyID(prefix: String, publicKey: String) -> String {
        let material = Data(
            "JAZZ-DEVICE-KEY-ID-V1\0\(prefix)\0\(publicKey)".utf8)
        return "\(prefix)_\(hexSHA256(material))"
    }

    private static func hexSHA256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func matches(_ value: String, pattern: NSRegularExpression) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return pattern.firstMatch(in: value, range: range)?.range == range
    }

    private static func timestamp(_ date: Date) -> String {
        timestampFormatter.string(from: date)
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        timestampFormatter.date(from: value)
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

    private struct PersistedRecord: Codable {
        static let keys: Set<String> = [
            "schemaVersion", "kind", "backend", "state", "revision", "deviceId",
            "authorityBindingSHA256", "keySetId", "previousKeySetId",
            "proofKeyId", "proofKeyThumbprint", "proofPublicKey",
            "wrappingKeyId", "wrappingKeyThumbprint", "wrappingPublicKey",
            "createdAt", "updatedAt", "proofKeyReference", "wrappingKeyReference",
        ]

        let schemaVersion: Int
        let kind: String
        let backend: String
        var state: DeviceEnrollmentIdentityState
        var revision: Int
        let deviceId: String
        let authorityBindingSHA256: String
        let keySetId: String
        let previousKeySetId: String
        let proofKeyId: String
        let proofKeyThumbprint: String
        let proofPublicKey: String
        let wrappingKeyId: String
        let wrappingKeyThumbprint: String
        let wrappingPublicKey: String
        let createdAt: String
        var updatedAt: String
        var proofKeyReference: String
        var wrappingKeyReference: String
    }
}

private struct SecureEnclaveProofSigner: DeviceEnrollmentProofSigning {
    let privateKey: SecureEnclave.P256.Signing.PrivateKey

    var publicKeyX963Representation: Data {
        privateKey.publicKey.x963Representation
    }

    func signatureRawRepresentation(for message: Data) throws -> Data {
        try privateKey.signature(for: message).rawRepresentation
    }
}

private struct SecureEnclaveWrappingAgreement: DeviceEnrollmentKeyAgreement {
    let privateKey: SecureEnclave.P256.KeyAgreement.PrivateKey

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

private struct SecureEnclaveDeviceEnrollmentKeyBackend: DeviceEnrollmentKeyBackend {
    let identifier = "apple-secure-enclave-p256-v1"
    let isHardwareBacked = true

    func generate() throws -> DeviceEnrollmentGeneratedKeyPair {
        guard SecureEnclave.isAvailable else {
            throw DeviceEnrollmentIdentityError.hardwareUnavailable
        }
        do {
            // CryptoKit's dataRepresentation is a device-bound opaque key reference encrypted by
            // the Secure Enclave. It is reloadable on this Mac, but is not a plaintext EC scalar.
            let proof = try SecureEnclave.P256.Signing.PrivateKey(
                compactRepresentable: false,
                accessControl: try accessControl())
            let wrapping = try SecureEnclave.P256.KeyAgreement.PrivateKey(
                compactRepresentable: false,
                accessControl: try accessControl())
            return DeviceEnrollmentGeneratedKeyPair(
                proofReference: proof.dataRepresentation,
                wrappingReference: wrapping.dataRepresentation,
                proofSigner: SecureEnclaveProofSigner(privateKey: proof),
                wrappingAgreement: SecureEnclaveWrappingAgreement(privateKey: wrapping))
        } catch let error as DeviceEnrollmentIdentityError {
            throw error
        } catch {
            throw DeviceEnrollmentIdentityError.keyOperationFailed
        }
    }

    func restore(
        proofReference: Data,
        wrappingReference: Data
    ) throws -> DeviceEnrollmentGeneratedKeyPair {
        guard SecureEnclave.isAvailable else {
            throw DeviceEnrollmentIdentityError.hardwareUnavailable
        }
        do {
            let proof = try SecureEnclave.P256.Signing.PrivateKey(
                dataRepresentation: proofReference)
            let wrapping = try SecureEnclave.P256.KeyAgreement.PrivateKey(
                dataRepresentation: wrappingReference)
            return DeviceEnrollmentGeneratedKeyPair(
                proofReference: proofReference,
                wrappingReference: wrappingReference,
                proofSigner: SecureEnclaveProofSigner(privateKey: proof),
                wrappingAgreement: SecureEnclaveWrappingAgreement(privateKey: wrapping))
        } catch {
            throw DeviceEnrollmentIdentityError.keyOperationFailed
        }
    }

    private func accessControl() throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard
            let control = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                [.privateKeyUsage],
                &error)
        else {
            _ = error?.takeRetainedValue()
            throw DeviceEnrollmentIdentityError.hardwareUnavailable
        }
        return control
    }
}

private struct KeychainDeviceEnrollmentIdentityPersistence:
    DeviceEnrollmentIdentityPersisting
{
    private let service = "dev.jazz.capture.enrollment-identity"
    private let account = "active-secure-enclave-p256-keyset-v1"

    func load() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw DeviceEnrollmentIdentityError.persistenceUnavailable
        }
        return data
    }

    func addIfAbsent(_ data: Data) throws -> Bool {
        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem { return false }
        guard status == errSecSuccess else {
            throw DeviceEnrollmentIdentityError.persistenceUnavailable
        }
        return true
    }

    func replace(_ data: Data) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(
            baseQuery as CFDictionary,
            attributes as CFDictionary)
        guard status == errSecSuccess else {
            throw DeviceEnrollmentIdentityError.persistenceUnavailable
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }
}
