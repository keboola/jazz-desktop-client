import CryptoKit
import Foundation
import JasnostCaptureCore
import XCTest

@testable import JasnostEnrollmentSecurity

final class DeviceEnrollmentRedemptionTests: XCTestCase {
    func testUIBootstrapParserAcceptsPrefixedRouteAndRejectsTampering() throws {
        let fixture = try RedemptionHarness.fixture()
        let text = try RedemptionHarness.text(fixture["bootstrap"])
        let parsed = try DeviceRedemptionBootstrap.parse(text)

        XCTAssertEqual(
            parsed.redemptionURL,
            "https://native.example.test/jazz/api/device-enrollment/redemptions/"
                + parsed.bootstrapId)

        var extra = try XCTUnwrap(fixture["bootstrap"] as? [String: Any])
        extra["authorityBindingSHA256"] = String(repeating: "a", count: 64)
        XCTAssertThrowsError(try DeviceRedemptionBootstrap.parse(
            try RedemptionHarness.text(extra)))

        var wrongRoute = try XCTUnwrap(fixture["bootstrap"] as? [String: Any])
        wrongRoute["redemptionURL"] =
            "https://native.example.test/api/device-enrollment/redemptions/"
            + "jbt_99999999999999999999999999999999"
        XCTAssertThrowsError(try DeviceRedemptionBootstrap.parse(
            try RedemptionHarness.text(wrongRoute)))

        let duplicate = text.replacingOccurrences(
            of: #""kind":"jazz-device-redemption-bootstrap""#,
            with:
                #""kind":"jazz-device-redemption-bootstrap","kind":"jazz-device-redemption-bootstrap""#)
        XCTAssertThrowsError(try DeviceRedemptionBootstrap.parse(duplicate))
    }

    func testUnpinnedCopiedBootstrapCannotCreateDeviceIdentity() async throws {
        let fixture = try RedemptionHarness.fixture()
        var bootstrap = try XCTUnwrap(fixture["bootstrap"] as? [String: Any])
        bootstrap["redemptionURL"] =
            "https://attacker.example.test/api/device-enrollment/redemptions/"
            + String(describing: bootstrap["bootstrapId"]!)
        let pending = MemoryRedemptionPendingStore()
        let backend = RedemptionIdentityBackend()
        let coordinator = try RedemptionHarness.coordinator(
            pending: pending,
            backend: backend,
            transport: RedemptionTransport(context: Data()),
            now: RedemptionHarness.date("2026-07-24T09:01:00Z"))

        do {
            _ = try await coordinator.begin(
                RedemptionHarness.text(bootstrap))
            XCTFail("unpinned bootstrap was accepted")
        } catch {
            XCTAssertEqual(
                error as? DeviceEnrollmentRedemptionError,
                .insecureRedemptionRoute)
        }
        XCTAssertNil(try pending.load())
        XCTAssertEqual(backend.generateCount, 0)
    }

    func testRestartRetriesExactClaimBytesThenPolls() async throws {
        let fixture = try RedemptionHarness.fixture()
        let bootstrapText = try RedemptionHarness.text(fixture["bootstrap"])
        let context = try RedemptionHarness.data(fixture["context"])
        let pendingResponse = try RedemptionHarness.data(fixture["pendingResponse"])
        let pending = MemoryRedemptionPendingStore()
        let backend = RedemptionIdentityBackend()
        let identityPersistence = RedemptionIdentityPersistence()
        let transport = RedemptionTransport(
            context: context,
            pending: pendingResponse,
            failFirstSubmit: true)

        let first = try RedemptionHarness.coordinator(
            pending: pending,
            backend: backend,
            identityPersistence: identityPersistence,
            transport: transport,
            now: RedemptionHarness.date("2026-07-24T09:01:00Z"))
        do {
            _ = try await first.begin(bootstrapText)
            XCTFail("the simulated lost response did not fail")
        } catch {
            XCTAssertEqual(
                error as? DeviceEnrollmentRedemptionError,
                .serverUnavailable)
        }
        let firstHasPending = await first.hasPendingEnrollment()
        XCTAssertTrue(firstHasPending)

        let restarted = try RedemptionHarness.coordinator(
            pending: pending,
            backend: backend,
            identityPersistence: identityPersistence,
            transport: transport,
            now: RedemptionHarness.date("2026-07-24T09:01:01Z"))
        let retried = try await restarted.resume()
        XCTAssertNil(retried)
        XCTAssertEqual(transport.submittedClaims.count, 2)
        XCTAssertEqual(
            transport.submittedClaims.first,
            transport.submittedClaims.last)

        let polled = try await restarted.resume()
        XCTAssertNil(polled)
        XCTAssertEqual(transport.pollCount, 1)
        XCTAssertEqual(transport.submittedClaims.count, 2)
    }

    func testExpiredPendingIsAtomicallyReplacedAndExplicitDiscardNeedsNoIdentityChange()
        async throws
    {
        let fixture = try RedemptionHarness.fixture()
        let pending = MemoryRedemptionPendingStore()
        let backend = RedemptionIdentityBackend()
        let unavailable = RedemptionTransport(context: Data(), alwaysFail: true)
        let first = try RedemptionHarness.coordinator(
            pending: pending,
            backend: backend,
            transport: unavailable,
            now: RedemptionHarness.date("2026-07-24T09:01:00Z"))
        do {
            _ = try await first.begin(
                RedemptionHarness.text(fixture["bootstrap"]))
        } catch {
            XCTAssertEqual(
                error as? DeviceEnrollmentRedemptionError,
                .serverUnavailable)
        }

        var replacement = try XCTUnwrap(fixture["bootstrap"] as? [String: Any])
        replacement["bootstrapId"] = "jbt_99999999999999999999999999999999"
        replacement["bundleId"] = "jdb_99999999999999999999999999999999"
        replacement["issuedAt"] = "2026-07-24T09:16:00Z"
        replacement["serverTime"] = "2026-07-24T09:16:00Z"
        replacement["expiresAt"] = "2026-07-24T09:31:00Z"
        replacement["redemptionURL"] =
            "https://native.example.test/jazz/api/device-enrollment/redemptions/"
            + "jbt_99999999999999999999999999999999"
        let second = try RedemptionHarness.coordinator(
            pending: pending,
            backend: backend,
            transport: unavailable,
            now: RedemptionHarness.date("2026-07-24T09:16:01Z"))
        do {
            _ = try await second.begin(
                RedemptionHarness.text(replacement))
        } catch {
            XCTAssertEqual(
                error as? DeviceEnrollmentRedemptionError,
                .serverUnavailable)
        }
        let persisted = try XCTUnwrap(try pending.load())
        let persistedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: persisted) as? [String: Any])
        let persistedBootstrap = try XCTUnwrap(
            persistedObject["bootstrap"] as? [String: Any])
        XCTAssertEqual(
            persistedBootstrap["bootstrapId"] as? String,
            replacement["bootstrapId"] as? String)

        try await second.discardPendingEnrollment()
        let secondHasPending = await second.hasPendingEnrollment()
        XCTAssertFalse(secondHasPending)
        XCTAssertNil(try pending.load())
        XCTAssertEqual(backend.generateCount, 0)
    }

    func testAutomaticPollContractProgresses202To202ToExact200() async throws {
        let http = try RedemptionHarness.fixture()
        let crypto = try RedemptionHarness.deviceBoundFixture()
        var bootstrap = try XCTUnwrap(http["bootstrap"] as? [String: Any])
        bootstrap["issuedAt"] = "2026-07-24T09:30:00Z"
        bootstrap["serverTime"] = "2026-07-24T09:30:00Z"
        bootstrap["expiresAt"] = "2026-07-24T09:41:00Z"
        var context = try XCTUnwrap(http["context"] as? [String: Any])
        context["serverTime"] = "2026-07-24T09:30:00Z"
        context["expiresAt"] = "2026-07-24T09:41:00Z"
        var pendingResponse = try XCTUnwrap(
            http["pendingResponse"] as? [String: Any])
        pendingResponse["claimId"] = "jcl_22222222222222222222222222222222"
        pendingResponse["serverTime"] = "2026-07-24T09:31:00Z"
        pendingResponse["expiresAt"] = "2026-07-24T09:41:00Z"
        let sealedObject = try XCTUnwrap(crypto["sealedBundle"])
        let sealedBytes = try RedemptionHarness.data(sealedObject)
        let expected = try XCTUnwrap(crypto["expected"] as? [String: Any])
        let ready = DeviceRedemptionHTTPResponse(
            statusCode: 200,
            body: sealedBytes,
            headers: [
                "Content-Type": "application/jazz-device-enrollment-sealed+json",
                "ETag": "\"sha256:\(try XCTUnwrap(expected["sealedBundleSha256"] as? String))\"",
                "X-Jazz-Bundle-SHA256":
                    try XCTUnwrap(expected["bundleSha256"] as? String),
                "X-Jazz-Bootstrap-Expires-At": "2026-07-24T09:41:00Z",
            ])
        let transport = RedemptionTransport(
            context: try RedemptionHarness.data(context),
            pending: try RedemptionHarness.data(pendingResponse),
            ready: ready,
            readyAfterPollCount: 2)
        let pending = MemoryRedemptionPendingStore()
        let coordinator = try RedemptionHarness.coordinator(
            pending: pending,
            backend: RedemptionIdentityBackend(useGoldenKeys: true),
            transport: transport,
            now: RedemptionHarness.date("2026-07-24T09:31:00Z"),
            claimID: "jcl_22222222222222222222222222222222")

        let submitted = try await coordinator.begin(
            RedemptionHarness.text(bootstrap))
        XCTAssertNil(submitted)
        let firstPoll = try await coordinator.resume()
        XCTAssertNil(firstPoll)
        let readyResult = try await coordinator.resume()
        let redeemed = try XCTUnwrap(readyResult)
        let encodedBundle = try XCTUnwrap(crypto["signedDeviceBundle"] as? String)

        XCTAssertEqual(
            Data(redeemed.exactSignedBundle.utf8),
            try RedemptionHarness.decodeBase64URL(encodedBundle))
        XCTAssertEqual(transport.pollCount, 2)
        let hasPendingBeforeActivation = await coordinator.hasPendingEnrollment()
        XCTAssertTrue(hasPendingBeforeActivation)

        try await coordinator.completeActivation(
            bootstrapId: redeemed.bootstrapId)
        let hasPendingAfterActivation = await coordinator.hasPendingEnrollment()
        XCTAssertFalse(hasPendingAfterActivation)
    }

    func testReadyRejectsLegacyOrParameterizedContentTypeAndRetainsPending()
        async throws
    {
        for contentType in [
            "application/jazz-device-bundle+json",
            "application/jazz-device-enrollment-sealed+json; charset=utf-8",
        ] {
            let scenario = try RedemptionHarness.goldenScenario(
                contentType: contentType)
            let submitted = try await scenario.coordinator.begin(
                scenario.bootstrapText)
            XCTAssertNil(submitted)
            let pending = try await scenario.coordinator.resume()
            XCTAssertNil(pending)
            do {
                _ = try await scenario.coordinator.resume()
                XCTFail("READY accepted \(contentType)")
            } catch {
                XCTAssertEqual(
                    error as? DeviceEnrollmentRedemptionError,
                    .malformedResponse)
            }
            let retained = await scenario.coordinator.hasPendingEnrollment()
            XCTAssertTrue(retained)
        }
    }
}

private enum RedemptionHarness {
    static let fixtureURL =
        URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(
            "contract/enrollment/device-bound/http-fixtures/"
                + "01-native-redemption-http.json")

    static func fixture() throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: fixtureURL)) as? [String: Any])
    }

    static func deviceBoundFixture() throws -> [String: Any] {
        let url =
            fixtureURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "fixtures/01-p256-device-bound-redemption.json")
        return try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: url)) as? [String: Any])
    }

    static func data(_ value: Any?) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: try XCTUnwrap(value),
            options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func text(_ value: Any?) throws -> String {
        try XCTUnwrap(String(data: try data(value), encoding: .utf8))
    }

    static func date(_ value: String) throws -> Date {
        try XCTUnwrap(Timestamps.parse(value))
    }

    static func decodeBase64URL(_ value: String) throws -> Data {
        var canonical = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        canonical += String(
            repeating: "=",
            count: (4 - canonical.count % 4) % 4)
        return try XCTUnwrap(Data(base64Encoded: canonical))
    }

    static func goldenScenario(
        contentType: String
    ) throws -> (
        coordinator: DeviceEnrollmentRedemptionCoordinator,
        bootstrapText: String
    ) {
        let http = try fixture()
        let crypto = try deviceBoundFixture()
        var bootstrap = try XCTUnwrap(http["bootstrap"] as? [String: Any])
        bootstrap["issuedAt"] = "2026-07-24T09:30:00Z"
        bootstrap["serverTime"] = "2026-07-24T09:30:00Z"
        bootstrap["expiresAt"] = "2026-07-24T09:41:00Z"
        var context = try XCTUnwrap(http["context"] as? [String: Any])
        context["serverTime"] = "2026-07-24T09:30:00Z"
        context["expiresAt"] = "2026-07-24T09:41:00Z"
        var pendingResponse = try XCTUnwrap(
            http["pendingResponse"] as? [String: Any])
        pendingResponse["claimId"] = "jcl_22222222222222222222222222222222"
        pendingResponse["serverTime"] = "2026-07-24T09:31:00Z"
        pendingResponse["expiresAt"] = "2026-07-24T09:41:00Z"
        let sealedBytes = try data(crypto["sealedBundle"])
        let expected = try XCTUnwrap(crypto["expected"] as? [String: Any])
        let ready = DeviceRedemptionHTTPResponse(
            statusCode: 200,
            body: sealedBytes,
            headers: [
                "Content-Type": contentType,
                "ETag":
                    "\"sha256:\(try XCTUnwrap(expected["sealedBundleSha256"] as? String))\"",
                "X-Jazz-Bundle-SHA256":
                    try XCTUnwrap(expected["bundleSha256"] as? String),
                "X-Jazz-Bootstrap-Expires-At": "2026-07-24T09:41:00Z",
            ])
        let transport = RedemptionTransport(
            context: try data(context),
            pending: try data(pendingResponse),
            ready: ready,
            readyAfterPollCount: 2)
        let coordinator = try coordinator(
            pending: MemoryRedemptionPendingStore(),
            backend: RedemptionIdentityBackend(useGoldenKeys: true),
            transport: transport,
            now: date("2026-07-24T09:31:00Z"),
            claimID: "jcl_22222222222222222222222222222222")
        return (coordinator, try text(bootstrap))
    }

    static func coordinator(
        pending: MemoryRedemptionPendingStore,
        backend: RedemptionIdentityBackend,
        identityPersistence: RedemptionIdentityPersistence =
            RedemptionIdentityPersistence(),
        transport: RedemptionTransport,
        now: Date,
        claimID: String = "jcl_33333333333333333333333333333333"
    ) throws -> DeviceEnrollmentRedemptionCoordinator {
        let trust = try EnrollmentTrustPolicy(
            issuer: "https://jazz.example.test",
            audience: "jazz-desktop-client",
            publicKeysByKeyID: [
                "test-2026-07-rfc8032-1":
                    "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo"
            ])
        return DeviceEnrollmentRedemptionCoordinator(
            pendingStore: pending,
            transport: transport,
            identityVault: DeviceEnrollmentIdentityVault(
                persistence: identityPersistence,
                keyBackend: backend),
            trustPolicy: trust,
            routePolicy: try EnrollmentRedemptionRoutePolicy(
                trustedOrigins: ["https://native.example.test"]),
            claimID: { claimID },
            now: { now })
    }
}

private final class MemoryRedemptionPendingStore:
    DeviceRedemptionPendingStoring, @unchecked Sendable
{
    private let lock = NSLock()
    private var data: Data?

    func load() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    func replace(_ exactBytes: Data) throws {
        lock.lock()
        data = exactBytes
        lock.unlock()
    }

    func delete() throws {
        lock.lock()
        data = nil
        lock.unlock()
    }
}

private final class RedemptionTransport: DeviceRedemptionTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let context: Data
    private let pending: Data
    private let failFirstSubmit: Bool
    private let alwaysFail: Bool
    private let ready: DeviceRedemptionHTTPResponse?
    private let readyAfterPollCount: Int
    private var didFailSubmit = false
    private(set) var submittedClaims: [Data] = []
    private(set) var pollCount = 0

    init(
        context: Data,
        pending: Data = Data(),
        failFirstSubmit: Bool = false,
        alwaysFail: Bool = false,
        ready: DeviceRedemptionHTTPResponse? = nil,
        readyAfterPollCount: Int = .max
    ) {
        self.context = context
        self.pending = pending
        self.failFirstSubmit = failFirstSubmit
        self.alwaysFail = alwaysFail
        self.ready = ready
        self.readyAfterPollCount = readyAfterPollCount
    }

    func fetchContext(
        endpoint: URL,
        bearer: String
    ) async throws -> DeviceRedemptionHTTPResponse {
        if alwaysFail { throw RedemptionTestError.unavailable }
        return DeviceRedemptionHTTPResponse(statusCode: 200, body: context)
    }

    func submitClaim(
        endpoint: URL,
        bearer: String,
        exactClaim: Data
    ) async throws -> DeviceRedemptionHTTPResponse {
        let shouldFail = lock.withLock {
            submittedClaims.append(exactClaim)
            let value = failFirstSubmit && !didFailSubmit
            didFailSubmit = true
            return value
        }
        if shouldFail { throw RedemptionTestError.unavailable }
        return DeviceRedemptionHTTPResponse(statusCode: 202, body: pending)
    }

    func poll(
        endpoint: URL,
        bearer: String
    ) async throws -> DeviceRedemptionHTTPResponse {
        let currentPollCount = lock.withLock {
            pollCount += 1
            return pollCount
        }
        if currentPollCount >= readyAfterPollCount, let ready {
            return ready
        }
        return DeviceRedemptionHTTPResponse(statusCode: 202, body: pending)
    }
}

private final class RedemptionIdentityPersistence:
    DeviceEnrollmentIdentityPersisting, @unchecked Sendable
{
    private let lock = NSLock()
    private var data: Data?

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
}

private final class RedemptionIdentityBackend:
    DeviceEnrollmentKeyBackend, @unchecked Sendable
{
    let identifier = "test-hardware-p256"
    let isHardwareBacked = true
    private let lock = NSLock()
    private var pair: (
        proof: P256.Signing.PrivateKey,
        wrapping: P256.KeyAgreement.PrivateKey
    )?
    private let useGoldenKeys: Bool
    private(set) var generateCount = 0

    init(useGoldenKeys: Bool = false) {
        self.useGoldenKeys = useGoldenKeys
    }

    func generate() throws -> DeviceEnrollmentGeneratedKeyPair {
        lock.lock()
        defer { lock.unlock() }
        generateCount += 1
        let value: (
            proof: P256.Signing.PrivateKey,
            wrapping: P256.KeyAgreement.PrivateKey
        )
        if useGoldenKeys {
            value = (
                proof: try P256.Signing.PrivateKey(
                    rawRepresentation:
                        Data(repeating: 0, count: 31) + Data([1])),
                wrapping: try P256.KeyAgreement.PrivateKey(
                    rawRepresentation:
                        Data(repeating: 0, count: 31) + Data([2])))
        } else {
            value = (
                proof: P256.Signing.PrivateKey(),
                wrapping: P256.KeyAgreement.PrivateKey())
        }
        pair = value
        return material(value)
    }

    func restore(
        proofReference: Data,
        wrappingReference: Data
    ) throws -> DeviceEnrollmentGeneratedKeyPair {
        lock.lock()
        defer { lock.unlock() }
        guard
            proofReference == Data("proof".utf8),
            wrappingReference == Data("wrapping".utf8),
            let pair
        else {
            throw RedemptionTestError.unavailable
        }
        return material(pair)
    }

    private func material(
        _ value: (
            proof: P256.Signing.PrivateKey,
            wrapping: P256.KeyAgreement.PrivateKey
        )
    ) -> DeviceEnrollmentGeneratedKeyPair {
        DeviceEnrollmentGeneratedKeyPair(
            proofReference: Data("proof".utf8),
            wrappingReference: Data("wrapping".utf8),
            proofSigner: RedemptionProofSigner(privateKey: value.proof),
            wrappingAgreement: RedemptionWrappingAgreement(
                privateKey: value.wrapping))
    }
}

private struct RedemptionProofSigner: DeviceEnrollmentProofSigning {
    let privateKey: P256.Signing.PrivateKey

    var publicKeyX963Representation: Data {
        privateKey.publicKey.x963Representation
    }

    func signatureRawRepresentation(for message: Data) throws -> Data {
        try privateKey.signature(for: message).rawRepresentation
    }
}

private struct RedemptionWrappingAgreement: DeviceEnrollmentKeyAgreement {
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

private enum RedemptionTestError: Error {
    case unavailable
}
