import CryptoKit
import Foundation
import XCTest

@testable import JasnostEnrollmentSecurity

final class DeviceEnrollmentIdentityTests: XCTestCase {
    func testFirstCreateAndRestartReloadSameHardwareKeys() throws {
        let persistence = MemoryIdentityPersistence()
        let backend = FakeHardwareIdentityBackend()
        let binding = try Self.binding()
        let createdAt = try XCTUnwrap(Self.timestamp.date(from: "2026-07-24T08:00:00Z"))

        let first = try Self.vault(persistence, backend).loadOrCreate(
            binding: binding,
            now: createdAt)
        let restarted = try Self.vault(persistence, backend).loadOrCreate(
            binding: binding,
            now: createdAt.addingTimeInterval(60))

        XCTAssertEqual(first.metadata, restarted.metadata)
        XCTAssertEqual(first.proofKey, restarted.proofKey)
        XCTAssertEqual(first.wrappingKey, restarted.wrappingKey)
        XCTAssertEqual(backend.generateCount, 1)
        XCTAssertEqual(backend.restoreCount, 1)
        XCTAssertEqual(persistence.addCount, 1)

        let claim = try restarted.makeClaim(
            bootstrapId: Self.bootstrapA,
            claimId: "jcl_11111111111111111111111111111111",
            issuedAt: "2026-07-24T08:00:00Z",
            expiresAt: "2026-07-24T08:05:00Z")
        let verified = try DeviceBoundEnrollmentCrypto.verifyClaim(claim)
        XCTAssertEqual(verified.payload.deviceId, binding.deviceId)
        XCTAssertEqual(verified.payload.bootstrapId, Self.bootstrapA)
        XCTAssertEqual(
            verified.binding.proofKeyThumbprint,
            restarted.metadata.proofKeyThumbprint)
        XCTAssertEqual(
            verified.binding.wrappingKeyThumbprint,
            restarted.metadata.wrappingKeyThumbprint)
    }

    func testConcurrentFirstCreateReturnsOnlyExactWinner() throws {
        let persistence = MemoryIdentityPersistence()
        let backend = FakeHardwareIdentityBackend()
        let binding = try Self.binding()
        let resultLock = NSLock()
        var results: [Result<DeviceEnrollmentIdentity, Error>] = []

        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            let result = Result {
                try Self.vault(persistence, backend).loadOrCreate(
                    binding: binding,
                    now: Date(timeIntervalSince1970: 1_753_344_000))
            }
            resultLock.lock()
            results.append(result)
            resultLock.unlock()
        }

        let identities = try results.map { try $0.get() }
        XCTAssertEqual(Set(identities.map(\.metadata.keySetId)).count, 1)
        XCTAssertEqual(Set(identities.map(\.metadata.proofKeyId)).count, 1)
        XCTAssertEqual(Set(identities.map(\.metadata.wrappingKeyId)).count, 1)
        XCTAssertEqual(backend.generateCount, 1)
        XCTAssertEqual(persistence.addCount, 1)
    }

    func testExistingSlotRejectsDifferentDeviceOrAuthority() throws {
        let persistence = MemoryIdentityPersistence()
        let backend = FakeHardwareIdentityBackend()
        let vault = Self.vault(persistence, backend)
        _ = try vault.loadOrCreate(binding: Self.binding())

        XCTAssertThrowsError(
            try vault.loadOrCreate(
                binding: Self.binding(
                    authorityBindingSHA256: String(repeating: "b", count: 64)))
        ) { error in
            XCTAssertEqual(
                error as? DeviceEnrollmentIdentityError,
                .bindingConflict)
        }
        XCTAssertThrowsError(
            try vault.loadOrCreate(
                binding: Self.binding(deviceId: "other-device"))
        ) { error in
            XCTAssertEqual(
                error as? DeviceEnrollmentIdentityError,
                .bindingConflict)
        }
        XCTAssertEqual(backend.generateCount, 1)
    }

    func testNewBootstrapUnderSameAuthorityReusesExactHardwareKeySet() throws {
        let persistence = MemoryIdentityPersistence()
        let backend = FakeHardwareIdentityBackend()
        let vault = Self.vault(persistence, backend)
        let identity = try vault.loadOrCreate(binding: Self.binding())

        let firstClaim = try identity.makeClaim(
            bootstrapId: Self.bootstrapA,
            claimId: "jcl_11111111111111111111111111111111",
            issuedAt: "2026-07-24T08:00:00Z",
            expiresAt: "2026-07-24T08:05:00Z")
        let secondClaim = try identity.makeClaim(
            bootstrapId: Self.bootstrapB,
            claimId: "jcl_22222222222222222222222222222222",
            issuedAt: "2026-07-24T08:10:00Z",
            expiresAt: "2026-07-24T08:15:00Z")
        let first = try DeviceBoundEnrollmentCrypto.verifyClaim(firstClaim)
        let second = try DeviceBoundEnrollmentCrypto.verifyClaim(secondClaim)

        XCTAssertEqual(first.payload.bootstrapId, Self.bootstrapA)
        XCTAssertEqual(second.payload.bootstrapId, Self.bootstrapB)
        XCTAssertEqual(first.payload.proofKey, second.payload.proofKey)
        XCTAssertEqual(first.payload.wrappingKey, second.payload.wrappingKey)
        XCTAssertEqual(backend.generateCount, 1)
        XCTAssertEqual(
            try vault.loadOrCreate(binding: Self.binding()).metadata.keySetId,
            identity.metadata.keySetId)
    }

    func testIdentityOpensValidSealForItsPersistedWrappingKey() throws {
        let persistence = MemoryIdentityPersistence()
        let backend = FakeHardwareIdentityBackend()
        let identity = try Self.vault(persistence, backend).loadOrCreate(
            binding: Self.binding())
        let claim = try identity.makeClaim(
            bootstrapId: Self.bootstrapA,
            claimId: Self.claimA,
            issuedAt: "2026-07-24T09:30:00Z",
            expiresAt: "2026-07-24T09:35:00Z")
        let binding = try DeviceBoundEnrollmentCrypto.verifyClaim(claim).binding
        let plaintext = Data("signed-device-bundle-exact-bytes".utf8)
        let sealed = try Self.seal(
            plaintext,
            for: binding,
            descriptor: Self.sealDescriptor)

        XCTAssertEqual(
            try identity.openSealedBundle(
                sealed,
                binding: binding,
                descriptor: Self.sealDescriptor,
                now: try Self.date("2026-07-24T09:32:00Z")),
            plaintext)
    }

    func testSoftwareBackendCannotEnterVault() throws {
        let persistence = MemoryIdentityPersistence()
        let backend = FakeHardwareIdentityBackend(isHardwareBacked: false)
        let vault = Self.vault(persistence, backend)

        XCTAssertThrowsError(
            try vault.loadOrCreate(binding: Self.binding())
        ) { error in
            XCTAssertEqual(
                error as? DeviceEnrollmentIdentityError,
                .hardwareUnavailable)
        }
        XCTAssertNil(try persistence.load())
        XCTAssertEqual(backend.generateCount, 0)
    }

    func testPartialGenerationFailureCannotPublishHalfAKeySet() throws {
        let persistence = MemoryIdentityPersistence()
        let backend = FakeHardwareIdentityBackend(failGeneration: true)
        let vault = Self.vault(persistence, backend)

        XCTAssertThrowsError(
            try vault.loadOrCreate(binding: Self.binding())
        ) { error in
            XCTAssertEqual(
                error as? DeviceEnrollmentIdentityError,
                .keyOperationFailed)
        }
        XCTAssertNil(try persistence.load())
        XCTAssertEqual(persistence.addCount, 0)
    }

    func testTamperedOpaqueReferenceAndMetadataFailClosed() throws {
        let persistence = MemoryIdentityPersistence()
        let backend = FakeHardwareIdentityBackend()
        let binding = try Self.binding()
        let loaded = try Self.vault(persistence, backend).loadOrCreate(
            binding: binding)

        try persistence.mutateJSON {
            $0["proofKeyReference"] = EnrollmentEncoding.encodeBase64URL(
                Data("unknown-handle".utf8))
        }
        XCTAssertThrowsError(
            try Self.vault(persistence, backend).load(binding: binding)
        ) { error in
            XCTAssertEqual(
                error as? DeviceEnrollmentIdentityError,
                .corruptState)
        }
        XCTAssertThrowsError(
            try loaded.makeClaim(
                bootstrapId: Self.bootstrapA,
                claimId: "jcl_11111111111111111111111111111111",
                issuedAt: "2026-07-24T08:00:00Z",
                expiresAt: "2026-07-24T08:05:00Z")
        ) { error in
            XCTAssertEqual(
                error as? DeviceEnrollmentIdentityError,
                .corruptState)
        }

        let cleanPersistence = MemoryIdentityPersistence()
        _ = try Self.vault(cleanPersistence, backend).loadOrCreate(binding: binding)
        try cleanPersistence.mutateJSON {
            $0["deviceId"] = "tampered-device"
        }
        XCTAssertThrowsError(
            try Self.vault(cleanPersistence, backend).metadata()
        ) { error in
            XCTAssertEqual(
                error as? DeviceEnrollmentIdentityError,
                .corruptState)
        }
    }

    func testMalformedOrDuplicateKeyStateFailsClosed() throws {
        let backend = FakeHardwareIdentityBackend()
        let malformed = MemoryIdentityPersistence(
            initial: Data("{\"schemaVersion\":1,\"schemaVersion\":1}".utf8))

        XCTAssertThrowsError(
            try Self.vault(malformed, backend).metadata()
        ) { error in
            XCTAssertEqual(
                error as? DeviceEnrollmentIdentityError,
                .corruptState)
        }
    }

    func testRotationFencesOldKeyUnderSameAuthority() throws {
        let persistence = MemoryIdentityPersistence()
        let backend = FakeHardwareIdentityBackend()
        let vault = Self.vault(persistence, backend)
        let original = try vault.loadOrCreate(binding: Self.binding())
        let binding = try Self.binding()

        let rotated = try vault.rotate(
            expectedKeySetId: original.metadata.keySetId,
            to: binding)
        XCTAssertEqual(rotated.metadata.revision, 2)
        XCTAssertEqual(
            rotated.metadata.previousKeySetId,
            original.metadata.keySetId)
        XCTAssertNotEqual(rotated.metadata.keySetId, original.metadata.keySetId)
        XCTAssertNotEqual(rotated.metadata.proofKeyId, original.metadata.proofKeyId)
        XCTAssertNotEqual(
            rotated.metadata.wrappingKeyId,
            original.metadata.wrappingKeyId)

        XCTAssertThrowsError(
            try original.makeClaim(
                bootstrapId: Self.bootstrapB,
                claimId: "jcl_11111111111111111111111111111111",
                issuedAt: "2026-07-24T08:00:00Z",
                expiresAt: "2026-07-24T08:05:00Z")
        ) { error in
            XCTAssertEqual(
                error as? DeviceEnrollmentIdentityError,
                .staleKeySet)
        }
        XCTAssertThrowsError(
            try vault.rotate(
                expectedKeySetId: original.metadata.keySetId,
                to: binding)
        ) { error in
            XCTAssertEqual(
                error as? DeviceEnrollmentIdentityError,
                .staleKeySet)
        }
    }

    func testRotationCannotCommitBetweenFenceAndSigningOperation() throws {
        let persistence = MemoryIdentityPersistence()
        let operationGate = FakeKeyOperationGate()
        let backend = FakeHardwareIdentityBackend(operationGate: operationGate)
        let vault = Self.vault(persistence, backend)
        let binding = try Self.binding()
        let original = try vault.loadOrCreate(binding: binding)
        let claimResult = LockedResult<Data>()
        let rotationResult = LockedResult<DeviceEnrollmentIdentity>()
        let claimFinished = DispatchSemaphore(value: 0)
        let rotationStarted = DispatchSemaphore(value: 0)
        let rotationFinished = DispatchSemaphore(value: 0)

        operationGate.arm()
        defer { operationGate.release() }
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<Data, Error> = Result {
                try original.makeClaim(
                    bootstrapId: Self.bootstrapA,
                    claimId: "jcl_11111111111111111111111111111111",
                    issuedAt: "2026-07-24T08:00:00Z",
                    expiresAt: "2026-07-24T08:05:00Z")
            }
            claimResult.store(result)
            claimFinished.signal()
        }
        XCTAssertEqual(operationGate.waitUntilEntered(), .success)

        DispatchQueue.global(qos: .userInitiated).async {
            rotationStarted.signal()
            let result: Result<DeviceEnrollmentIdentity, Error> = Result {
                try vault.rotate(
                    expectedKeySetId: original.metadata.keySetId,
                    to: binding)
            }
            rotationResult.store(result)
            rotationFinished.signal()
        }
        XCTAssertEqual(rotationStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(rotationFinished.wait(timeout: .now() + 0.25), .timedOut)

        operationGate.release()
        XCTAssertEqual(claimFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(rotationFinished.wait(timeout: .now() + 2), .success)
        let claim = try XCTUnwrap(claimResult.snapshot()).get()
        _ = try DeviceBoundEnrollmentCrypto.verifyClaim(claim)
        _ = try XCTUnwrap(rotationResult.snapshot()).get()

        XCTAssertThrowsError(
            try original.makeClaim(
                bootstrapId: Self.bootstrapB,
                claimId: "jcl_22222222222222222222222222222222",
                issuedAt: "2026-07-24T08:10:00Z",
                expiresAt: "2026-07-24T08:15:00Z")
        ) { error in
            XCTAssertEqual(
                error as? DeviceEnrollmentIdentityError,
                .staleKeySet)
        }
    }

    func testRevocationCannotCommitBetweenFenceAndSigningOperation() throws {
        let persistence = MemoryIdentityPersistence()
        let operationGate = FakeKeyOperationGate()
        let backend = FakeHardwareIdentityBackend(operationGate: operationGate)
        let vault = Self.vault(persistence, backend)
        let original = try vault.loadOrCreate(binding: Self.binding())
        let claimResult = LockedResult<Data>()
        let revocationResult = LockedResult<DeviceEnrollmentIdentityMetadata>()
        let claimFinished = DispatchSemaphore(value: 0)
        let revocationStarted = DispatchSemaphore(value: 0)
        let revocationFinished = DispatchSemaphore(value: 0)

        operationGate.arm()
        defer { operationGate.release() }
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<Data, Error> = Result {
                try original.makeClaim(
                    bootstrapId: Self.bootstrapA,
                    claimId: "jcl_11111111111111111111111111111111",
                    issuedAt: "2026-07-24T08:00:00Z",
                    expiresAt: "2026-07-24T08:05:00Z")
            }
            claimResult.store(result)
            claimFinished.signal()
        }
        XCTAssertEqual(operationGate.waitUntilEntered(), .success)

        DispatchQueue.global(qos: .userInitiated).async {
            revocationStarted.signal()
            let result: Result<DeviceEnrollmentIdentityMetadata, Error> = Result {
                try vault.revoke(
                    expectedKeySetId: original.metadata.keySetId)
            }
            revocationResult.store(result)
            revocationFinished.signal()
        }
        XCTAssertEqual(revocationStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(revocationFinished.wait(timeout: .now() + 0.25), .timedOut)

        operationGate.release()
        XCTAssertEqual(claimFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(revocationFinished.wait(timeout: .now() + 2), .success)
        let claim = try XCTUnwrap(claimResult.snapshot()).get()
        _ = try DeviceBoundEnrollmentCrypto.verifyClaim(claim)
        XCTAssertEqual(
            try XCTUnwrap(revocationResult.snapshot()).get().state,
            .revoked)

        XCTAssertThrowsError(
            try original.makeClaim(
                bootstrapId: Self.bootstrapB,
                claimId: "jcl_22222222222222222222222222222222",
                issuedAt: "2026-07-24T08:10:00Z",
                expiresAt: "2026-07-24T08:15:00Z")
        ) { error in
            XCTAssertEqual(
                error as? DeviceEnrollmentIdentityError,
                .revoked)
        }
    }

    func testRevocationCannotCommitBetweenFenceAndECDHOperation() throws {
        let persistence = MemoryIdentityPersistence()
        let operationGate = FakeKeyOperationGate()
        let backend = FakeHardwareIdentityBackend(operationGate: operationGate)
        let vault = Self.vault(persistence, backend)
        let original = try vault.loadOrCreate(binding: Self.binding())
        let claim = try original.makeClaim(
            bootstrapId: Self.bootstrapA,
            claimId: Self.claimA,
            issuedAt: "2026-07-24T09:30:00Z",
            expiresAt: "2026-07-24T09:35:00Z")
        let binding = try DeviceBoundEnrollmentCrypto.verifyClaim(claim).binding
        let plaintext = Data("sealed-credential-exact-bytes".utf8)
        let sealed = try Self.seal(
            plaintext,
            for: binding,
            descriptor: Self.sealDescriptor)
        let openResult = LockedResult<Data>()
        let revocationResult = LockedResult<DeviceEnrollmentIdentityMetadata>()
        let openFinished = DispatchSemaphore(value: 0)
        let revocationStarted = DispatchSemaphore(value: 0)
        let revocationFinished = DispatchSemaphore(value: 0)

        operationGate.arm()
        defer { operationGate.release() }
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<Data, Error> = Result {
                try original.openSealedBundle(
                    sealed,
                    binding: binding,
                    descriptor: Self.sealDescriptor,
                    now: try Self.date("2026-07-24T09:32:00Z"))
            }
            openResult.store(result)
            openFinished.signal()
        }
        XCTAssertEqual(operationGate.waitUntilEntered(), .success)

        DispatchQueue.global(qos: .userInitiated).async {
            revocationStarted.signal()
            let result: Result<DeviceEnrollmentIdentityMetadata, Error> = Result {
                try vault.revoke(
                    expectedKeySetId: original.metadata.keySetId)
            }
            revocationResult.store(result)
            revocationFinished.signal()
        }
        XCTAssertEqual(revocationStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(revocationFinished.wait(timeout: .now() + 0.25), .timedOut)

        operationGate.release()
        XCTAssertEqual(openFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(revocationFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(try XCTUnwrap(openResult.snapshot()).get(), plaintext)
        XCTAssertEqual(
            try XCTUnwrap(revocationResult.snapshot()).get().state,
            .revoked)

        XCTAssertThrowsError(
            try original.openSealedBundle(
                sealed,
                binding: binding,
                descriptor: Self.sealDescriptor,
                now: try Self.date("2026-07-24T09:32:00Z"))
        ) { error in
            XCTAssertEqual(
                error as? DeviceEnrollmentIdentityError,
                .revoked)
        }
    }

    func testRotationCannotMoveIdentityToAnotherDevice() throws {
        let persistence = MemoryIdentityPersistence()
        let backend = FakeHardwareIdentityBackend()
        let vault = Self.vault(persistence, backend)
        let original = try vault.loadOrCreate(binding: Self.binding())

        XCTAssertThrowsError(
            try vault.rotate(
                expectedKeySetId: original.metadata.keySetId,
                to: Self.binding(deviceId: "other-device"))
        ) { error in
            XCTAssertEqual(
                error as? DeviceEnrollmentIdentityError,
                .bindingConflict)
        }
        XCTAssertEqual(backend.generateCount, 1)
    }

    func testRotationCannotChangeSignedAuthorityBinding() throws {
        let persistence = MemoryIdentityPersistence()
        let backend = FakeHardwareIdentityBackend()
        let vault = Self.vault(persistence, backend)
        let original = try vault.loadOrCreate(binding: Self.binding())

        XCTAssertThrowsError(
            try vault.rotate(
                expectedKeySetId: original.metadata.keySetId,
                to: Self.binding(
                    authorityBindingSHA256: String(repeating: "b", count: 64)))
        ) { error in
            XCTAssertEqual(
                error as? DeviceEnrollmentIdentityError,
                .bindingConflict)
        }
        XCTAssertEqual(backend.generateCount, 1)
    }

    func testRevocationPersistsTombstoneAndInvalidatesLoadedIdentity() throws {
        let persistence = MemoryIdentityPersistence()
        let backend = FakeHardwareIdentityBackend()
        let vault = Self.vault(persistence, backend)
        let identity = try vault.loadOrCreate(binding: Self.binding())

        let revoked = try vault.revoke(
            expectedKeySetId: identity.metadata.keySetId)
        XCTAssertEqual(revoked.state, .revoked)
        XCTAssertEqual(revoked.revision, 2)
        XCTAssertEqual(
            try vault.revoke(expectedKeySetId: identity.metadata.keySetId),
            revoked)
        let persisted = try XCTUnwrap(try persistence.load())
        let persistedText = try XCTUnwrap(String(data: persisted, encoding: .utf8))
        XCTAssertTrue(persistedText.contains("\"proofKeyReference\":\"\""))
        XCTAssertTrue(persistedText.contains("\"wrappingKeyReference\":\"\""))

        XCTAssertThrowsError(
            try identity.makeClaim(
                bootstrapId: Self.bootstrapA,
                claimId: "jcl_11111111111111111111111111111111",
                issuedAt: "2026-07-24T08:00:00Z",
                expiresAt: "2026-07-24T08:05:00Z")
        ) { error in
            XCTAssertEqual(
                error as? DeviceEnrollmentIdentityError,
                .revoked)
        }
        XCTAssertThrowsError(
            try Self.vault(persistence, backend).loadOrCreate(
                binding: Self.binding())
        ) { error in
            XCTAssertEqual(
                error as? DeviceEnrollmentIdentityError,
                .revoked)
        }
    }

    func testExplicitRotationCanRecoverFromRevokedTombstone() throws {
        let persistence = MemoryIdentityPersistence()
        let backend = FakeHardwareIdentityBackend()
        let vault = Self.vault(persistence, backend)
        let original = try vault.loadOrCreate(binding: Self.binding())
        _ = try vault.revoke(expectedKeySetId: original.metadata.keySetId)
        let replacementBinding = try Self.binding()

        let replacement = try vault.rotate(
            expectedKeySetId: original.metadata.keySetId,
            to: replacementBinding)
        XCTAssertEqual(replacement.metadata.state, .active)
        XCTAssertEqual(replacement.metadata.revision, 3)
        XCTAssertEqual(
            replacement.metadata.previousKeySetId,
            original.metadata.keySetId)
    }

    func testDescriptionsNeverExposeBindingOrKeyReferences() throws {
        let persistence = MemoryIdentityPersistence()
        let backend = FakeHardwareIdentityBackend()
        let identity = try Self.vault(persistence, backend).loadOrCreate(
            binding: Self.binding())
        let persisted = try XCTUnwrap(try persistence.load())
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: persisted) as? [String: Any])
        let proofReference = try XCTUnwrap(object["proofKeyReference"] as? String)
        let wrappingReference = try XCTUnwrap(
            object["wrappingKeyReference"] as? String)

        let rendered = String(describing: identity)
        let debug = String(reflecting: identity)
        for secretOrBinding in [
            "device-a",
            String(repeating: "a", count: 64),
            proofReference,
            wrappingReference,
        ] {
            XCTAssertFalse(rendered.contains(secretOrBinding))
            XCTAssertFalse(debug.contains(secretOrBinding))
        }
        for error in [
            DeviceEnrollmentIdentityError.hardwareUnavailable,
            .persistenceUnavailable,
            .corruptState,
            .bindingConflict,
            .revoked,
            .staleKeySet,
            .keyOperationFailed,
        ] {
            let text = error.description
            XCTAssertFalse(text.contains(proofReference))
            XCTAssertFalse(text.contains(wrappingReference))
        }
    }

    private static func vault(
        _ persistence: MemoryIdentityPersistence,
        _ backend: FakeHardwareIdentityBackend
    ) -> DeviceEnrollmentIdentityVault {
        DeviceEnrollmentIdentityVault(
            persistence: persistence,
            keyBackend: backend)
    }

    private static func binding(
        deviceId: String = "device-a",
        authorityBindingSHA256: String = String(repeating: "a", count: 64)
    ) throws -> DeviceEnrollmentIdentityBinding {
        try DeviceEnrollmentIdentityBinding(
            deviceId: deviceId,
            authorityBindingSHA256: authorityBindingSHA256)
    }

    private static let bootstrapA = "jbt_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private static let bootstrapB = "jbt_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    private static let claimA = "jcl_11111111111111111111111111111111"
    private static let sealDescriptor = DeviceBundleSealDescriptor(
        bundleId: "jdb_11111111111111111111111111111111",
        generation: 1,
        sealedAt: "2026-07-24T09:31:00Z",
        revealExpiresAt: "2026-07-24T09:41:00Z")

    private static func seal(
        _ plaintext: Data,
        for binding: DeviceEnrollmentClaimBinding,
        descriptor: DeviceBundleSealDescriptor
    ) throws -> Data {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let salt = Data(repeating: 0x5a, count: 32)
        let iv = Data(repeating: 0xa5, count: 12)
        let context: [String: Any] = [
            "bootstrapId": binding.bootstrapId,
            "claimId": binding.claimId,
            "deviceId": binding.deviceId,
            "claimSha256": binding.claimSHA256,
            "proofKeyThumbprint": binding.proofKeyThumbprint,
            "wrappingKeyThumbprint": binding.wrappingKeyThumbprint,
            "bundleId": descriptor.bundleId,
            "generation": descriptor.generation,
            "bundleSha256": hexSHA256(plaintext),
            "sealedAt": descriptor.sealedAt,
            "revealExpiresAt": descriptor.revealExpiresAt,
        ]
        let protected: [String: Any] = [
            "alg": "ECDH-ES",
            "enc": "A256GCM",
            "kdf": "HKDF-SHA256",
            "typ": "application/jazz-device-enrollment-sealed+json",
            "cty": "application/jazz-device-bundle+jws",
            "salt": EnrollmentEncoding.encodeBase64URL(salt),
            "epk": [
                "kty": "EC",
                "crv": "P-256",
                "format": "X9.63",
                "publicKey": EnrollmentEncoding.encodeBase64URL(
                    ephemeral.publicKey.x963Representation),
            ],
            "context": context,
        ]
        let protectedBytes = try XCTUnwrap(
            EnrollmentEncoding.canonicalJSONObject(protected))
        let protectedSegment = EnrollmentEncoding.encodeBase64URL(protectedBytes)
        let aad =
            DeviceBoundEnrollmentCrypto.sealAADDomain
            + Data(protectedSegment.utf8)
        let info =
            DeviceBoundEnrollmentCrypto.sealKDFDomain
            + Data(SHA256.hash(data: aad))
        let recipientBytes = try XCTUnwrap(
            EnrollmentEncoding.decodeBase64URL(
                binding.wrappingPublicKey,
                maximumBytes: 65))
        let recipient = try P256.KeyAgreement.PublicKey(
            x963Representation: recipientBytes)
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let key = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: info,
            outputByteCount: 32)
        let sealed = try AES.GCM.seal(
            plaintext,
            using: key,
            nonce: try AES.GCM.Nonce(data: iv),
            authenticating: aad)
        return try XCTUnwrap(
            EnrollmentEncoding.canonicalJSONObject([
                "protected": protectedSegment,
                "iv": EnrollmentEncoding.encodeBase64URL(iv),
                "ciphertext": EnrollmentEncoding.encodeBase64URL(sealed.ciphertext),
                "tag": EnrollmentEncoding.encodeBase64URL(sealed.tag),
            ]))
    }

    private static func date(_ value: String) throws -> Date {
        try XCTUnwrap(timestamp.date(from: value))
    }

    private static func hexSHA256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter
    }()
}

private final class MemoryIdentityPersistence:
    DeviceEnrollmentIdentityPersisting, @unchecked Sendable
{
    private let lock = NSLock()
    private var data: Data?
    private(set) var addCount = 0

    init(initial: Data? = nil) {
        data = initial
    }

    func load() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    func addIfAbsent(_ newData: Data) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard data == nil else { return false }
        data = newData
        addCount += 1
        return true
    }

    func replace(_ newData: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard data != nil else {
            throw DeviceEnrollmentIdentityError.persistenceUnavailable
        }
        data = newData
    }

    func mutateJSON(_ mutation: (inout [String: Any]) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        var object = try XCTUnwrap(
            data.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            })
        mutation(&object)
        data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

private final class FakeHardwareIdentityBackend:
    DeviceEnrollmentKeyBackend, @unchecked Sendable
{
    struct StoredPair {
        let proofReference: Data
        let wrappingReference: Data
        let proof: P256.Signing.PrivateKey
        let wrapping: P256.KeyAgreement.PrivateKey
    }

    let identifier = "fake-hardware-p256-v1"
    let isHardwareBacked: Bool
    private let failGeneration: Bool
    private let operationGate: FakeKeyOperationGate?
    private let lock = NSLock()
    private var pairs: [Int: StoredPair] = [:]
    private(set) var generateCount = 0
    private(set) var restoreCount = 0

    init(
        isHardwareBacked: Bool = true,
        failGeneration: Bool = false,
        operationGate: FakeKeyOperationGate? = nil
    ) {
        self.isHardwareBacked = isHardwareBacked
        self.failGeneration = failGeneration
        self.operationGate = operationGate
    }

    func generate() throws -> DeviceEnrollmentGeneratedKeyPair {
        lock.lock()
        defer { lock.unlock() }
        generateCount += 1
        if failGeneration {
            throw FakeIdentityBackendFailure.failed
        }
        let identifier = generateCount
        let pair = StoredPair(
            proofReference: Data("proof-handle-\(identifier)".utf8),
            wrappingReference: Data("wrapping-handle-\(identifier)".utf8),
            proof: P256.Signing.PrivateKey(),
            wrapping: P256.KeyAgreement.PrivateKey())
        pairs[identifier] = pair
        return material(pair)
    }

    func restore(
        proofReference: Data,
        wrappingReference: Data
    ) throws -> DeviceEnrollmentGeneratedKeyPair {
        lock.lock()
        defer { lock.unlock() }
        restoreCount += 1
        guard
            let pair = pairs.values.first(where: {
                $0.proofReference == proofReference
                    && $0.wrappingReference == wrappingReference
            })
        else {
            throw FakeIdentityBackendFailure.failed
        }
        return material(pair)
    }

    private func material(_ pair: StoredPair) -> DeviceEnrollmentGeneratedKeyPair {
        DeviceEnrollmentGeneratedKeyPair(
            proofReference: pair.proofReference,
            wrappingReference: pair.wrappingReference,
            proofSigner: FakeIdentityProofSigner(
                privateKey: pair.proof,
                operationGate: operationGate),
            wrappingAgreement: FakeIdentityWrappingAgreement(
                privateKey: pair.wrapping,
                operationGate: operationGate))
    }
}

private struct FakeIdentityProofSigner: DeviceEnrollmentProofSigning {
    let privateKey: P256.Signing.PrivateKey
    let operationGate: FakeKeyOperationGate?

    var publicKeyX963Representation: Data {
        privateKey.publicKey.x963Representation
    }

    func signatureRawRepresentation(for message: Data) throws -> Data {
        operationGate?.blockIfArmed()
        return try privateKey.signature(for: message).rawRepresentation
    }
}

private struct FakeIdentityWrappingAgreement: DeviceEnrollmentKeyAgreement {
    let privateKey: P256.KeyAgreement.PrivateKey
    let operationGate: FakeKeyOperationGate?

    var publicKeyX963Representation: Data {
        privateKey.publicKey.x963Representation
    }

    func deriveSymmetricKey(
        peerPublicKeyX963Representation: Data,
        salt: Data,
        sharedInfo: Data
    ) throws -> SymmetricKey {
        operationGate?.blockIfArmed()
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

private enum FakeIdentityBackendFailure: Error {
    case failed
}

private final class FakeKeyOperationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)
    private var armed = false

    func arm() {
        lock.lock()
        armed = true
        lock.unlock()
    }

    func blockIfArmed() {
        lock.lock()
        let shouldBlock = armed
        armed = false
        lock.unlock()
        guard shouldBlock else { return }
        entered.signal()
        _ = resume.wait(timeout: .now() + 5)
    }

    func waitUntilEntered() -> DispatchTimeoutResult {
        entered.wait(timeout: .now() + 2)
    }

    func release() {
        resume.signal()
    }
}

private final class LockedResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<Value, Error>?

    func store(_ result: Result<Value, Error>) {
        lock.lock()
        value = result
        lock.unlock()
    }

    func snapshot() -> Result<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
