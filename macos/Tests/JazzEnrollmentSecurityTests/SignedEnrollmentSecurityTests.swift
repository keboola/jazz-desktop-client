import CryptoKit
import Darwin
import Foundation
import JazzCaptureCore
import XCTest

@testable import JazzEnrollmentSecurity

final class SignedEnrollmentSecurityTests: XCTestCase {
    private let now = try! XCTUnwrap(Timestamps.parse("2026-07-24T09:35:00Z"))

    func testBothServerGoldensVerifyAndAdvanceOneAtomicPerDeviceLedger() async throws {
        let harness = try Harness()
        let sink = try harness.golden(named: "01-sink-scope.json")
        let archiveOnly = try harness.golden(named: "02-archive-only-none-scope.json")
        let probe = TokenRequestProbe()

        let (first, _) = try await harness.importer.authorizeThen(
            sink.jwsText,
            now: now,
            operation: probe.request)
        XCTAssertEqual(first.acceptance, .first)
        XCTAssertEqual(first.payload.generation, 7)
        XCTAssertEqual(first.payload.tokenBucketScope.rawValue, "sink")
        XCTAssertEqual(
            first.envelopeDigest,
            "ec80eb2df35b457027e5704fe523e45fba7200b12df23c68a4005284281985d2")

        let (advanced, _) = try await harness.importer.authorizeThen(
            archiveOnly.jwsText,
            now: now,
            operation: probe.request)
        XCTAssertEqual(advanced.acceptance, .advanced)
        XCTAssertEqual(advanced.payload.generation, 8)
        XCTAssertNil(advanced.payload.sinkBucketId)
        XCTAssertNil(advanced.payload.streamEndpoint)
        XCTAssertEqual(
            advanced.envelopeDigest,
            "be82b857609ef77165bfc4ea8f7c41fb493dc839179e68ae5b08676c45e19bba")
        XCTAssertEqual(probe.requestCount, 2)

        let records = try harness.store.records()
        XCTAssertEqual(records["mac-finance-01"]?.generation, 8)
        XCTAssertEqual(
            records["mac-finance-01"]?.bundleId,
            "jdb_018ff3a2679a7bd18a5e6c3d4b2a1909")
        let ledger = try String(contentsOf: harness.store.fileURL, encoding: .utf8)
        XCTAssertFalse(ledger.contains("TEST-ARCHIVE-TOKEN"))
        XCTAssertFalse(ledger.contains("stream.example.test"))
    }

    func testByteIdenticalGenerationIsIdempotentAndMayRetryNetwork() async throws {
        let harness = try Harness()
        let fixture = try harness.golden(named: "01-sink-scope.json")
        let probe = TokenRequestProbe()

        let (first, _) = try await harness.importer.authorizeThen(
            fixture.jwsText,
            now: now,
            operation: probe.request)
        let (second, _) = try await harness.importer.authorizeThen(
            fixture.jwsText,
            now: now,
            operation: probe.request)

        XCTAssertEqual(first.acceptance, .first)
        XCTAssertEqual(second.acceptance, .idempotent)
        XCTAssertEqual(first.envelopeDigest, second.envelopeDigest)
        XCTAssertEqual(probe.requestCount, 2)
    }

    func testUnsignedBundleMakesZeroTokenBearingRequests() async throws {
        let harness = try Harness()
        let probe = TokenRequestProbe()
        let unsigned = """
            {"kind":"jazz-device-bundle","token":"8625-1-NOT-A-REAL-TOKEN"}
            """

        await assertRejected(
            .malformedEnvelope,
            text: unsigned,
            harness: harness,
            probe: probe)
    }

    func testTamperedPayloadMakesZeroTokenBearingRequests() async throws {
        let harness = try Harness()
        let fixture = try harness.golden(named: "01-sink-scope.json")
        var payload = try harness.decodedPayload(fixture.jws)
        payload["archiveIngestURL"] = "https://attacker.invalid/api/archive-ingests"
        let tampered = try harness.envelopeText(
            protectedSegment: fixture.jws.protected,
            payloadData: harness.canonical(payload),
            signature: fixture.jws.signature)
        let probe = TokenRequestProbe()

        await assertRejected(
            .invalidSignature,
            text: tampered,
            harness: harness,
            probe: probe)
    }

    func testUnknownKidMakesZeroTokenBearingRequests() async throws {
        let harness = try Harness()
        let fixture = try harness.golden(named: "01-sink-scope.json")
        let protected: [String: Any] = [
            "alg": "EdDSA",
            "kid": "unknown-but-well-formed",
            "typ": SignedEnrollmentVerifier.expectedType,
        ]
        let text = try harness.envelopeText(
            protectedData: harness.canonical(protected),
            payloadSegment: fixture.jws.payload,
            signature: fixture.jws.signature)
        let probe = TokenRequestProbe()

        await assertRejected(.unknownKey, text: text, harness: harness, probe: probe)
    }

    func testWrongIssuerMakesZeroTokenBearingRequests() async throws {
        let harness = try Harness()
        let fixture = try harness.golden(named: "01-sink-scope.json")
        var payload = try harness.decodedPayload(fixture.jws)
        payload["issuer"] = "https://other.example.test"
        let text = try harness.signedEnvelope(
            protectedSegment: fixture.jws.protected,
            payloadData: harness.canonical(payload))
        let probe = TokenRequestProbe()

        await assertRejected(.issuerMismatch, text: text, harness: harness, probe: probe)
    }

    func testAlgorithmNoneMakesZeroTokenBearingRequests() async throws {
        let harness = try Harness()
        let fixture = try harness.golden(named: "01-sink-scope.json")
        let protected: [String: Any] = [
            "alg": "none",
            "kid": harness.keyFixture.kid,
            "typ": SignedEnrollmentVerifier.expectedType,
        ]
        let text = try harness.envelopeText(
            protectedData: harness.canonical(protected),
            payloadSegment: fixture.jws.payload,
            signature: fixture.jws.signature)
        let probe = TokenRequestProbe()

        await assertRejected(
            .unsupportedAlgorithm,
            text: text,
            harness: harness,
            probe: probe)
    }

    func testExpiredSignedBundleMakesZeroTokenBearingRequests() async throws {
        let harness = try Harness()
        let fixture = try harness.golden(named: "01-sink-scope.json")
        var payload = try harness.decodedPayload(fixture.jws)
        payload["issuedAt"] = "2026-07-24T08:00:00Z"
        payload["bundleExpiresAt"] = "2026-07-24T08:15:00Z"
        let text = try harness.signedEnvelope(
            protectedSegment: fixture.jws.protected,
            payloadData: harness.canonical(payload))
        let probe = TokenRequestProbe()

        await assertRejected(.bundleExpired, text: text, harness: harness, probe: probe)
    }

    func testRollbackMakesNoAdditionalTokenBearingRequest() async throws {
        let harness = try Harness()
        let newest = try harness.golden(named: "02-archive-only-none-scope.json")
        let older = try harness.golden(named: "01-sink-scope.json")
        let probe = TokenRequestProbe()
        _ = try await harness.importer.authorizeThen(
            newest.jwsText,
            now: now,
            operation: probe.request)
        XCTAssertEqual(probe.requestCount, 1)

        await assertRejected(.rollback, text: older.jwsText, harness: harness, probe: probe)
        XCTAssertEqual(probe.requestCount, 1)
    }

    func testGenerationCollisionMakesNoAdditionalTokenBearingRequest() async throws {
        let harness = try Harness()
        let fixture = try harness.golden(named: "01-sink-scope.json")
        let probe = TokenRequestProbe()
        _ = try await harness.importer.authorizeThen(
            fixture.jwsText,
            now: now,
            operation: probe.request)
        XCTAssertEqual(probe.requestCount, 1)

        var collisionPayload = try harness.decodedPayload(fixture.jws)
        collisionPayload["bundleId"] = "jdb_018ff3a2679a7bd18a5e6c3d4b2a1910"
        let collision = try harness.signedEnvelope(
            protectedSegment: fixture.jws.protected,
            payloadData: harness.canonical(collisionPayload))
        await assertRejected(
            .collision,
            text: collision,
            harness: harness,
            probe: probe)
        XCTAssertEqual(probe.requestCount, 1)
    }

    func testMissingTrustAnchorFailsClosedBeforeNetwork() async throws {
        let harness = try Harness(includeTrustAnchor: false)
        let fixture = try harness.golden(named: "01-sink-scope.json")
        let probe = TokenRequestProbe()

        await assertRejected(
            .trustUnavailable,
            text: fixture.jwsText,
            harness: harness,
            probe: probe)
    }

    func testEmbeddedFixtureKeyNeverBootstrapsProductionTrust() throws {
        let fixture = try Harness.loadGolden(named: "01-sink-scope.json")
        let wrapper = try String(
            data: JSONEncoder().encode(fixture),
            encoding: .utf8).unwrap()
        let verifierPolicy = EnrollmentTrustBootstrap.load(
            infoDictionary: [
                EnrollmentTrustBootstrap.issuerInfoKey: fixture.expectedPayload.issuer,
                EnrollmentTrustBootstrap.audienceInfoKey: fixture.expectedPayload.audience,
                // Deliberately no out-of-band key dictionary.
            ])

        XCTAssertNil(verifierPolicy)
        let importer = SignedEnrollmentImporter(
            trustPolicy: verifierPolicy,
            acceptanceStore: nil)
        XCTAssertThrowsError(try importer.authorize(wrapper, now: now)) { error in
            XCTAssertEqual(error as? SignedEnrollmentError, .trustUnavailable)
        }
    }

    func testCodeSignedBootstrapShapeLoadsRotationSetAndRejectsInvalidPorts() throws {
        let harness = try Harness()
        let encodedPublicKey = EnrollmentEncoding.encodeBase64URL(
            harness.privateKeyForTests.publicKey.rawRepresentation)
        let policy = try XCTUnwrap(
            EnrollmentTrustBootstrap.load(
                infoDictionary: [
                    EnrollmentTrustBootstrap.issuerInfoKey: "https://jazz.example.test",
                    EnrollmentTrustBootstrap.audienceInfoKey: "jazz-desktop-client",
                    EnrollmentTrustBootstrap.publicKeysInfoKey: [
                        "2026-07-primary": encodedPublicKey,
                        "2026-08-next": encodedPublicKey,
                    ],
                ]))
        XCTAssertEqual(policy.issuer, "https://jazz.example.test")
        XCTAssertNotNil(policy.publicKey(for: "2026-07-primary"))
        XCTAssertNotNil(policy.publicKey(for: "2026-08-next"))

        XCTAssertNil(
            EnrollmentTrustBootstrap.load(
                infoDictionary: [
                    EnrollmentTrustBootstrap.issuerInfoKey:
                        "https://jazz.example.test:99999",
                    EnrollmentTrustBootstrap.audienceInfoKey: "jazz-desktop-client",
                    EnrollmentTrustBootstrap.publicKeysInfoKey: [
                        "2026-07-primary": encodedPublicKey
                    ],
                ]))
        XCTAssertFalse(
            EnrollmentURLPolicy.isSecureEndpoint(
                "https://stream.example.test:99999/source"))
    }

    func testSignedArchiveIngestAcceptsCanonicalPrefixAndLiteralLoopbackOrigins() throws {
        let accepted = [
            "https://jazz.example.test/prefix/api/archive-ingests",
            "http://127.0.0.1:4318/prefix/api/archive-ingests",
            "http://[::1]:4318/api/archive-ingests",
        ]

        for ingestURL in accepted {
            let harness = try Harness()
            let fixture = try harness.golden(named: "01-sink-scope.json")
            var payload = try harness.decodedPayload(fixture.jws)
            payload["archiveIngestURL"] = ingestURL
            let envelope = try harness.signedEnvelope(
                protectedSegment: fixture.jws.protected,
                payloadData: harness.canonical(payload))

            let authorized = try harness.importer.authorize(envelope, now: now)
            XCTAssertEqual(authorized.payload.archiveIngestURL, ingestURL)
            XCTAssertEqual(
                JazzArchiveControlPlaneURL.normalize(ingestURL),
                ingestURL)
        }
    }

    func testSignedArchiveIngestRejectsEveryNonCanonicalRouteBeforeNetwork() async throws {
        let rejected = [
            "https://jazz.example.test/api/archive-ingests/",
            "https://jazz.example.test:443/api/archive-ingests",
            "HTTPS://jazz.example.test/api/archive-ingests",
            "https://jazz.example.test/api/archive-ingests?tenant=other",
            "https://jazz.example.test/prefix/../api/archive-ingests",
        ]

        for ingestURL in rejected {
            let harness = try Harness()
            let fixture = try harness.golden(named: "01-sink-scope.json")
            var payload = try harness.decodedPayload(fixture.jws)
            payload["archiveIngestURL"] = ingestURL
            let envelope = try harness.signedEnvelope(
                protectedSegment: fixture.jws.protected,
                payloadData: harness.canonical(payload))
            let probe = TokenRequestProbe()

            await assertRejected(
                .invalidPayload,
                text: envelope,
                harness: harness,
                probe: probe)
            XCTAssertNotEqual(
                JazzArchiveControlPlaneURL.normalize(ingestURL),
                ingestURL)
        }
    }

    func testNonCanonicalSignedPayloadAndUnprotectedHeaderFailClosed() async throws {
        let harness = try Harness()
        let fixture = try harness.golden(named: "01-sink-scope.json")
        let payload = try harness.decodedPayload(fixture.jws)
        let prettyPayload = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let nonCanonical = try harness.signedEnvelope(
            protectedSegment: fixture.jws.protected,
            payloadData: prettyPayload)
        let probe = TokenRequestProbe()
        await assertRejected(
            .nonCanonicalPayload,
            text: nonCanonical,
            harness: harness,
            probe: probe)

        var outer = try fixture.jws.object()
        outer["header"] = ["jwk": fixture.trustedPublicKey]
        let unprotected = try String(
            data: JSONSerialization.data(withJSONObject: outer),
            encoding: .utf8).unwrap()
        await assertRejected(
            .malformedEnvelope,
            text: unprotected,
            harness: harness,
            probe: probe)
    }

    func testDuplicateKeysInEverySignedLayerFailClosedBeforeNetwork() async throws {
        let harness = try Harness()
        let fixture = try harness.golden(named: "01-sink-scope.json")
        let probe = TokenRequestProbe()

        let duplicateEnvelope = """
            {"protected":"\(fixture.jws.protected)","payload":"\(fixture.jws.payload)",\
            "payload":"\(fixture.jws.payload)","signature":"\(fixture.jws.signature)"}
            """
        await assertRejected(
            .malformedEnvelope,
            text: duplicateEnvelope,
            harness: harness,
            probe: probe)

        let duplicateProtected = Data(
            """
            {"alg":"EdDSA","kid":"\(harness.keyFixture.kid)",\
            "kid":"\(harness.keyFixture.kid)",\
            "typ":"\(SignedEnrollmentVerifier.expectedType)"}
            """.utf8)
        let protectedText = try harness.envelopeText(
            protectedData: duplicateProtected,
            payloadSegment: fixture.jws.payload,
            signature: fixture.jws.signature)
        await assertRejected(
            .invalidProtectedHeader,
            text: protectedText,
            harness: harness,
            probe: probe)

        let payloadData = try EnrollmentEncoding.decodeBase64URL(
            fixture.jws.payload,
            maximumBytes: 98_304).unwrap()
        let payloadText = try String(data: payloadData, encoding: .utf8).unwrap()
        let duplicatePayloadText = payloadText.replacingOccurrences(
            of: "\"token\":",
            with: "\"token\":\"attacker-controlled\",\"token\":",
            options: [.literal],
            range: try payloadText.range(of: "\"token\":").unwrap())
        let payloadEnvelope = try harness.signedEnvelope(
            protectedSegment: fixture.jws.protected,
            payloadData: Data(duplicatePayloadText.utf8))
        await assertRejected(
            .invalidPayload,
            text: payloadEnvelope,
            harness: harness,
            probe: probe)

        XCTAssertEqual(probe.requestCount, 0)
    }

    func testCanonicalJSONMatchesServerForUnicodeAndUnescapedSlash() async throws {
        let canonical = try EnrollmentEncoding.canonicalJSONObject([
            "z": "Žluťoučký/路径",
            "a": "line\nbreak",
        ]).unwrap()
        XCTAssertEqual(
            String(data: canonical, encoding: .utf8),
            #"{"a":"line\nbreak","z":"Žluťoučký/路径"}"#)

        let harness = try Harness()
        let fixture = try harness.golden(named: "01-sink-scope.json")
        var payload = try harness.decodedPayload(fixture.jws)
        payload["token"] = "Žluťoučký/路径"
        let envelope = try harness.signedEnvelope(
            protectedSegment: fixture.jws.protected,
            payloadData: harness.canonical(payload))
        let probe = TokenRequestProbe()

        let (authorized, _) = try await harness.importer.authorizeThen(
            envelope,
            now: now,
            operation: probe.request)
        XCTAssertEqual(authorized.payload.token, "Žluťoučký/路径")
        XCTAssertEqual(probe.requestCount, 1)

        let canonicalPayload = try harness.canonical(payload)
        let canonicalPayloadText = try String(
            data: canonicalPayload,
            encoding: .utf8).unwrap()
        let escapedSlashPayload = canonicalPayloadText.replacingOccurrences(
            of: "https://jazz.example.test",
            with: #"https:\/\/jazz.example.test"#,
            options: [.literal],
            range: try canonicalPayloadText.range(
                of: "https://jazz.example.test").unwrap())
        let escapedEnvelope = try harness.signedEnvelope(
            protectedSegment: fixture.jws.protected,
            payloadData: Data(escapedSlashPayload.utf8))
        await assertRejected(
            .nonCanonicalPayload,
            text: escapedEnvelope,
            harness: harness,
            probe: probe)
        XCTAssertEqual(probe.requestCount, 1)
    }

    func testSchemaMaxLengthCountsUnicodeScalarsLikeServer() throws {
        let harness = try Harness()
        let fixture = try harness.golden(named: "01-sink-scope.json")
        var payload = try harness.decodedPayload(fixture.jws)
        let token = String(repeating: "😀", count: 8_192)
        XCTAssertEqual(token.unicodeScalars.count, 8_192)
        XCTAssertEqual(token.utf8.count, 32_768)
        payload["token"] = token
        let envelope = try harness.signedEnvelope(
            protectedSegment: fixture.jws.protected,
            payloadData: harness.canonical(payload))

        let authorized = try harness.importer.authorize(envelope, now: now)
        XCTAssertEqual(authorized.payload.token.unicodeScalars.count, 8_192)
        XCTAssertEqual(authorized.acceptance, .first)
    }

    func testGlobalBundleIdentityHistorySurvivesRestart() throws {
        let harness = try Harness()
        let firstID = "jdb_11111111111111111111111111111111"
        let secondID = "jdb_22222222222222222222222222222222"
        let firstDigest = String(repeating: "a", count: 64)
        let secondDigest = String(repeating: "b", count: 64)
        let changedDigest = String(repeating: "c", count: 64)

        XCTAssertEqual(
            try harness.store.authorizeAndRecord(
                deviceId: "mac-finance-01",
                generation: 1,
                bundleId: firstID,
                envelopeDigest: firstDigest,
                acceptedAt: now),
            .first)
        XCTAssertEqual(
            try harness.store.authorizeAndRecord(
                deviceId: "mac-finance-01",
                generation: 2,
                bundleId: secondID,
                envelopeDigest: secondDigest,
                acceptedAt: now),
            .advanced)

        let restarted = FileEnrollmentAcceptanceStore(fileURL: harness.store.fileURL)
        XCTAssertThrowsError(
            try restarted.authorizeAndRecord(
                deviceId: "mac-finance-01",
                generation: 3,
                bundleId: firstID,
                envelopeDigest: changedDigest,
                acceptedAt: now)
        ) { error in
            XCTAssertEqual(error as? SignedEnrollmentError, .collision)
        }
        XCTAssertThrowsError(
            try restarted.authorizeAndRecord(
                deviceId: "mac-operations-02",
                generation: 1,
                bundleId: firstID,
                envelopeDigest: firstDigest,
                acceptedAt: now)
        ) { error in
            XCTAssertEqual(error as? SignedEnrollmentError, .collision)
        }
        XCTAssertEqual(try restarted.records()["mac-finance-01"]?.generation, 2)
    }

    func testIndependentStoresSerializeTheWholeAdmissionUnderSidecarFileLock() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jazz-enrollment-file-lock-\(UUID().uuidString)")
        let ledgerURL = root.appendingPathComponent("acceptance.json")
        let lockURL = FileEnrollmentAcceptanceStore.lockFileURL(for: ledgerURL)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)

        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC,
            S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else {
            return
        }
        let applyFileLock: (Int32, Int32) -> Int32 = flock
        XCTAssertEqual(applyFileLock(descriptor, LOCK_EX), 0)
        var manualLockIsHeld = true
        defer {
            if manualLockIsHeld {
                _ = applyFileLock(descriptor, LOCK_UN)
            }
            _ = Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: root)
        }

        let stores = [
            FileEnrollmentAcceptanceStore(fileURL: ledgerURL),
            FileEnrollmentAcceptanceStore(fileURL: ledgerURL),
        ]
        let bundles = [
            "jdb_11111111111111111111111111111111",
            "jdb_22222222222222222222222222222222",
        ]
        let digests = [
            String(repeating: "a", count: 64),
            String(repeating: "b", count: 64),
        ]
        let acceptedAt = now
        let started = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let outcomes = LockedStrings()

        for index in stores.indices {
            let store = stores[index]
            let bundleID = bundles[index]
            let digest = digests[index]
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                started.signal()
                do {
                    let decision = try store.authorizeAndRecord(
                        deviceId: "mac-finance-01",
                        generation: 1,
                        bundleId: bundleID,
                        envelopeDigest: digest,
                        acceptedAt: acceptedAt)
                    outcomes.append("decision:\(decision.rawValue)")
                } catch let error as SignedEnrollmentError {
                    outcomes.append(
                        error == .collision
                            ? "error:collision"
                            : "error:unexpected-\(error)")
                } catch {
                    outcomes.append("error:unexpected-\(error)")
                }
                group.leave()
            }
        }

        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(group.wait(timeout: .now() + 0.25), .timedOut)

        XCTAssertEqual(applyFileLock(descriptor, LOCK_UN), 0)
        manualLockIsHeld = false
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(
            outcomes.snapshot().sorted(),
            ["decision:first", "error:collision"])

        let records = try FileEnrollmentAcceptanceStore(fileURL: ledgerURL).records()
        XCTAssertEqual(records["mac-finance-01"]?.generation, 1)
        XCTAssertTrue(bundles.contains(records["mac-finance-01"]?.bundleId ?? ""))
    }

    func testAcceptanceFileLockFailureFailsClosedBeforeLedgerMutation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jazz-enrollment-lock-failure-\(UUID().uuidString)")
        let ledgerURL = root.appendingPathComponent("acceptance.json")
        let lockURL = FileEnrollmentAcceptanceStore.lockFileURL(for: ledgerURL)
        try FileManager.default.createDirectory(
            at: lockURL,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = FileEnrollmentAcceptanceStore(fileURL: ledgerURL)
        XCTAssertThrowsError(
            try store.authorizeAndRecord(
                deviceId: "mac-finance-01",
                generation: 1,
                bundleId: "jdb_11111111111111111111111111111111",
                envelopeDigest: String(repeating: "a", count: 64),
                acceptedAt: now)
        ) { error in
            XCTAssertEqual(
                error as? SignedEnrollmentError,
                .acceptanceStateUnavailable)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerURL.path))
        XCTAssertThrowsError(try store.records()) { error in
            XCTAssertEqual(
                error as? SignedEnrollmentError,
                .acceptanceStateUnavailable)
        }
    }

    func testCorruptAcceptanceLedgerFailsClosed() throws {
        let harness = try Harness()
        try FileManager.default.createDirectory(
            at: harness.store.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let corrupt = """
            {"bundles":{"jdb_11111111111111111111111111111111":\
            {"deviceId":"INVALID","envelopeDigest":"ABC","generation":1}},\
            "devices":{},"schemaVersion":2}
            """
        try Data(corrupt.utf8).write(to: harness.store.fileURL)

        XCTAssertThrowsError(try harness.store.records()) { error in
            XCTAssertEqual(
                error as? SignedEnrollmentError,
                .acceptanceStateUnavailable)
        }
    }

    private func assertRejected(
        _ expected: SignedEnrollmentError,
        text: String,
        harness: Harness,
        probe: TokenRequestProbe,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let before = probe.requestCount
        do {
            _ = try await harness.importer.authorizeThen(
                text,
                now: now,
                operation: probe.request)
            XCTFail("Expected signed enrollment rejection", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? SignedEnrollmentError,
                expected,
                file: file,
                line: line)
        }
        XCTAssertEqual(probe.requestCount, before, file: file, line: line)
    }
}

private final class TokenRequestProbe {
    private(set) var requestCount = 0

    func request(_ authorized: AuthorizedSignedDeviceBundle) async -> String {
        requestCount += 1
        return authorized.payload.tokenId
    }
}

private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private struct Harness {
    let root: URL
    let store: FileEnrollmentAcceptanceStore
    let importer: SignedEnrollmentImporter
    let keyFixture: TestKeyFixture
    private let privateKey: Curve25519.Signing.PrivateKey

    var privateKeyForTests: Curve25519.Signing.PrivateKey { privateKey }

    init(includeTrustAnchor: Bool = true) throws {
        keyFixture = try Self.loadKeyFixture()
        privateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(hex: keyFixture.privateKeySeedHex))
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jazz-enrollment-security-\(UUID().uuidString)")
        store = FileEnrollmentAcceptanceStore(
            fileURL: root.appendingPathComponent("acceptance.json"))
        let defaultPolicy = try EnrollmentTrustPolicy(
            issuer: "https://jazz.example.test",
            audience: "jazz-desktop-client",
            publicKeysByKeyID: [
                keyFixture.kid: EnrollmentEncoding.encodeBase64URL(
                    privateKey.publicKey.rawRepresentation)
            ])
        importer = SignedEnrollmentImporter(
            trustPolicy: includeTrustAnchor ? defaultPolicy : nil,
            acceptanceStore: store)
    }

    func golden(named name: String) throws -> GoldenFixture {
        try Self.loadGolden(named: name)
    }

    static func loadGolden(named name: String) throws -> GoldenFixture {
        try JSONDecoder().decode(
            GoldenFixture.self,
            from: Data(contentsOf: contractFixtureRoot.appendingPathComponent(name)))
    }

    static func loadKeyFixture() throws -> TestKeyFixture {
        try JSONDecoder().decode(
            TestKeyFixture.self,
            from: Data(
                contentsOf: testFixtureRoot
                    .appendingPathComponent("test-only-rfc8032-ed25519-key.json")))
    }

    func decodedPayload(_ jws: FlattenedJWS) throws -> [String: Any] {
        let data = try EnrollmentEncoding.decodeBase64URL(
            jws.payload,
            maximumBytes: 98_304).unwrap()
        return try (JSONSerialization.jsonObject(with: data) as? [String: Any]).unwrap()
    }

    func canonical(_ object: [String: Any]) throws -> Data {
        try EnrollmentEncoding.canonicalJSONObject(object).unwrap()
    }

    func signedEnvelope(
        protectedSegment: String,
        payloadData: Data
    ) throws -> String {
        let payloadSegment = EnrollmentEncoding.encodeBase64URL(payloadData)
        let signature = try privateKey.signature(
            for: Data("\(protectedSegment).\(payloadSegment)".utf8))
        return try envelopeText(
            protectedSegment: protectedSegment,
            payloadSegment: payloadSegment,
            signature: EnrollmentEncoding.encodeBase64URL(signature))
    }

    func envelopeText(
        protectedData: Data,
        payloadSegment: String,
        signature: String
    ) throws -> String {
        try envelopeText(
            protectedSegment: EnrollmentEncoding.encodeBase64URL(protectedData),
            payloadSegment: payloadSegment,
            signature: signature)
    }

    func envelopeText(
        protectedSegment: String,
        payloadData: Data,
        signature: String
    ) throws -> String {
        try envelopeText(
            protectedSegment: protectedSegment,
            payloadSegment: EnrollmentEncoding.encodeBase64URL(payloadData),
            signature: signature)
    }

    func envelopeText(
        protectedSegment: String,
        payloadSegment: String,
        signature: String
    ) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "protected": protectedSegment,
                "payload": payloadSegment,
                "signature": signature,
            ],
            options: [.sortedKeys, .withoutEscapingSlashes])
        return try String(data: data, encoding: .utf8).unwrap()
    }

    private static let contractFixtureRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("contract/enrollment/fixtures")
    }()

    private static let testFixtureRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }()
}

private struct GoldenFixture: Codable {
    let fixtureVersion: Int
    let name: String
    let trustedPublicKey: [String: String]
    let jws: FlattenedJWS
    let expectedPayload: SignedDeviceBundlePayload

    var jwsText: String {
        let data = try! JSONEncoder().encode(jws)
        return String(data: data, encoding: .utf8)!
    }
}

private struct FlattenedJWS: Codable {
    let protected: String
    let payload: String
    let signature: String

    func object() throws -> [String: Any] {
        try (JSONSerialization.jsonObject(with: JSONEncoder().encode(self))
            as? [String: Any]).unwrap()
    }
}

private struct TestKeyFixture: Codable {
    let purpose: String
    let kid: String
    let privateKeySeedHex: String
    let publicKeyHex: String
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

private extension Optional {
    func unwrap(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Wrapped {
        try XCTUnwrap(self, file: file, line: line)
    }
}
