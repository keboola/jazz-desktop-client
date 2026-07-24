import XCTest

@testable import JasnostCaptureCore

final class JazzArchiveIdentifierTests: XCTestCase {
    func testUUIDv7ByteLayoutUsesUnixMillisecondsVersionAndVariant() {
        let value = Identifiers.uuidV7(
            now: Date(timeIntervalSince1970: 1_700_000_000),
            random: UUID(uuidString: "ffffffff-ffff-4fff-bfff-ffffffffffff")!)

        XCTAssertEqual(value.uuidString.lowercased(), "018bcfe5-6800-7fff-bfff-ffffffffffff")
    }

    func testNewIdentifiersUsePrefixesAndUniqueUUIDv7Values() {
        let generators: [(String, () -> String)] = [
            ("ar-", Identifiers.newArchiveId),
            ("origin-", Identifiers.newOriginId),
            ("s-", Identifiers.newSessionId),
            ("l-", Identifiers.newLabelId),
            ("actor-", Identifiers.newActorId),
            ("src-", Identifiers.newSourceId),
            ("art-", Identifiers.newArtifactId),
            ("asrt-", Identifiers.newAssertionId),
            ("del-", Identifiers.newDeliveryId),
            ("imr-", Identifiers.newImportReceiptId),
            ("dop-", Identifiers.newDownloadOperationId),
            ("coach-", Identifiers.newCoachInteractionId),
            ("prompt-", Identifiers.newCoachPromptId),
            ("batch-", Identifiers.newArchiveBatchId),
            ("installation-", Identifiers.newInstallationId),
            ("cap-", Identifiers.newCaptureId),
            ("stream-", Identifiers.newStreamId),
            ("obs-", Identifiers.newObservationId),
            ("cmt-", Identifiers.newCaptureCommitId),
        ]

        for (prefix, generator) in generators {
            let values = (0..<256).map { _ in generator() }
            XCTAssertEqual(Set(values).count, values.count, "duplicate \(prefix) identifier")
            for value in values {
                XCTAssertTrue(value.hasPrefix(prefix))
                let uuid = String(value.dropFirst(prefix.count))
                XCTAssertNotNil(UUID(uuidString: uuid))
                XCTAssertEqual(Array(uuid)[14], "7", "wrong UUID version in \(value)")
                XCTAssertTrue("89ab".contains(Array(uuid)[19]), "wrong UUID variant in \(value)")
            }
        }
    }
}

final class JazzArchiveServerDownloadContractTests: XCTestCase {
    private let operationId =
        "dop-018bcfe5-6800-7fff-bfff-ffffffffffff"

    func testAuthorizationBodyIsExactFlatCanonicalContract() throws {
        let request = JazzArchiveServerDownloadRequest(
            ingestId: "ingest-ready-1",
            scope: JazzArchiveServerScope(
                companyId: "acme",
                areaId: "finance",
                deviceId: "device-7"),
            downloadOperationId: operationId)

        XCTAssertEqual(
            String(
                decoding: try request.canonicalAuthorizationBody(),
                as: UTF8.self),
            #"{"areaId":"finance","companyId":"acme","deviceId":"device-7","downloadOperationId":"dop-018bcfe5-6800-7fff-bfff-ffffffffffff"}"#)
    }

    func testHTTPGetV1AcceptsOnlyExactBoundedSignedHTTPSURL() throws {
        let rawURL =
            "https://objects.invalid/archive?X-Signature=abc%2F123&objectKey=opaque"
        let instructions = try JazzArchiveServerDownloadInstructions(download: [
            "transport": .string("http-get/v1"),
            "method": .string("GET"),
            "url": .string(rawURL),
        ])

        XCTAssertEqual(instructions.url.absoluteString, rawURL)
    }

    func testHTTPGetV1RejectsUnsafeProfilesHeadersAndExtraFields() {
        let valid: [String: JazzArchiveJSONValue] = [
            "transport": .string("http-get/v1"),
            "method": .string("GET"),
            "url": .string("https://objects.invalid/signed"),
        ]
        let oversized =
            "https://objects.invalid/" + String(repeating: "a", count: 16_384)
        let unsafe: [[String: JazzArchiveJSONValue]] = [
            valid.merging(["transport": .string("http-get/v2")]) { _, new in new },
            valid.merging(["method": .string("POST")]) { _, new in new },
            valid.merging(["headers": .object(["Range": .string("bytes=0-1")])]) {
                _, new in new
            },
            valid.merging(["providerField": .bool(true)]) { _, new in new },
            valid.merging(["url": .string("http://objects.invalid/signed")]) { _, new in
                new
            },
            valid.merging(["url": .string("https://user@objects.invalid/signed")]) {
                _, new in new
            },
            valid.merging(["url": .string("https://objects.invalid/signed#fragment")]) {
                _, new in new
            },
            valid.merging(["url": .string("https://objects.invalid/a b")]) { _, new in new },
            valid.merging(["url": .string(#"https://objects.invalid/a\b"#)]) { _, new in new },
            valid.merging(["url": .string(oversized)]) { _, new in new },
        ]

        for profile in unsafe {
            XCTAssertThrowsError(
                try JazzArchiveServerDownloadInstructions(download: profile),
                "accepted unsafe download profile: \(profile)")
        }
    }

    func testLegacyFastAPIExtraFieldEnvelopeIsTheOnlyRecoverable422() {
        let exact = Data(
            """
            {"detail":[{"type":"extra_forbidden","loc":["body","downloadOperationId"],"msg":"Extra inputs are not permitted","input":"\(operationId)"}]}
            """.utf8)
        XCTAssertTrue(
            JazzArchiveServerDownloadCompatibility.isLegacyOperationIdRejection(
                statusCode: 422,
                responseBody: exact,
                expectedOperationId: operationId))

        let wrongField = Data(
            """
            {"detail":[{"type":"extra_forbidden","loc":["body","deviceId"],"msg":"Extra inputs are not permitted","input":"device-7"}]}
            """.utf8)
        let wrongOperation = Data(
            """
            {"detail":[{"type":"extra_forbidden","loc":["body","downloadOperationId"],"msg":"Extra inputs are not permitted","input":"dop-018bcfe5-6801-7fff-bfff-ffffffffffff"}]}
            """.utf8)
        let additionalError = Data(
            """
            {"detail":[{"type":"extra_forbidden","loc":["body","downloadOperationId"],"msg":"Extra inputs are not permitted","input":"\(operationId)"},{"type":"missing","loc":["body","deviceId"],"msg":"Field required","input":null}]}
            """.utf8)
        let extraEnvelopeField = Data(
            """
            {"detail":[{"type":"extra_forbidden","loc":["body","downloadOperationId"],"msg":"Extra inputs are not permitted","input":"\(operationId)"}],"recoverable":true}
            """.utf8)
        for body in [wrongField, wrongOperation, additionalError, extraEnvelopeField] {
            XCTAssertFalse(
                JazzArchiveServerDownloadCompatibility.isLegacyOperationIdRejection(
                    statusCode: 422,
                    responseBody: body,
                    expectedOperationId: operationId))
        }
        XCTAssertFalse(
            JazzArchiveServerDownloadCompatibility.isLegacyOperationIdRejection(
                statusCode: 400,
                responseBody: exact,
                expectedOperationId: operationId))
    }
}

final class JazzArchiveDigestTests: XCTestCase {
    func testSHA256KnownVector() {
        XCTAssertEqual(
            JazzArchiveDigest.sha256Hex(Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testCanonicalJSONRejectsIntegersOutsideTheIJSONSafeRange() throws {
        let maximum = Int64(9_007_199_254_740_991)
        XCTAssertEqual(
            String(
                decoding: try JazzArchiveCanonicalJSON.encode(["value": maximum]),
                as: UTF8.self),
            #"{"value":9007199254740991}"#)
        XCTAssertEqual(
            String(
                decoding: try JazzArchiveCanonicalJSON.encode(["value": -maximum]),
                as: UTF8.self),
            #"{"value":-9007199254740991}"#)
        XCTAssertThrowsError(
            try JazzArchiveCanonicalJSON.encode(["value": maximum + 1]))
        XCTAssertThrowsError(
            try JazzArchiveCanonicalJSON.encode(["value": -maximum - 1]))
        XCTAssertThrowsError(
            try JazzArchiveCanonicalJSON.encode(["value": UInt64(maximum) + 1]))
    }

    func testCanonicalJSONRejectsFloatingPointAtOrBeyondTwoToThe53() throws {
        let boundary = 9_007_199_254_740_992.0
        XCTAssertThrowsError(
            try JazzArchiveCanonicalJSON.encode(["value": boundary]))
        XCTAssertThrowsError(
            try JazzArchiveCanonicalJSON.encode(["value": -boundary]))
        XCTAssertThrowsError(
            try JazzArchiveCanonicalJSON.encode(
                JazzArchiveJSONValue.number(boundary)))
        XCTAssertThrowsError(
            try JazzArchiveCanonicalJSON.encode(
                JazzArchiveJSONValue.number(-boundary)))

        for spelling in [
            "9007199254740992.0",
            "9007199254740993.0",
            "-9007199254740992.0",
            "-9007199254740993.0",
        ] {
            let decoded = try JSONDecoder().decode(
                JazzArchiveJSONValue.self,
                from: Data(spelling.utf8))
            XCTAssertThrowsError(
                try JazzArchiveCanonicalJSON.encode(decoded),
                "unsafe JSON spelling was admitted: \(spelling)")
        }
    }
}

final class JazzArchiveDraftStoreTests: XCTestCase {
    private let timestamp = "2026-07-22T10:00:00.000Z"

    private struct TestArchive {
        var archiveId: String
        var originId: String
        var legacySessionId: String
        var captureId: String
        var streamId: String
        var actorId: String
        var sourceId: String
        var manifest: JazzArchiveManifest
        var session: JazzArchiveSession
    }

    private func makeArchive() -> TestArchive {
        let archiveId = Identifiers.newArchiveId()
        let originId = Identifiers.newOriginId()
        let legacySessionId = Identifiers.newSessionId()
        let captureId = Identifiers.newCaptureId()
        let streamId = Identifiers.newStreamId()
        let actorId = Identifiers.newActorId()
        let sourceId = Identifiers.newSourceId()
        let producer = JazzArchiveProducer(
            name: "Jazz Capture", version: "test", platform: "macOS")
        let actor = JazzArchiveActor(
            actorId: actorId,
            kind: .human,
            identityStatus: .identified,
            displayName: "Recorder",
            provenance: JazzArchiveProvenance(factClass: .declared, sources: []))
        let source = JazzArchiveSource(
            sourceId: sourceId,
            kind: "macos.capture-controller",
            actorId: actorId,
            producer: producer,
            provenance: JazzArchiveProvenance(factClass: .observed, sources: []))
        let manifest = JazzArchiveManifest(
            archiveId: archiveId,
            originId: originId,
            originScope: JazzArchiveExternalIdentity(
                namespace: "test.tenant", value: "offline"),
            createdAt: timestamp,
            producer: producer,
            actors: [actor],
            sources: [source],
            sessions: [JazzArchiveSessionRef(
                captureId: captureId, legacySessionId: legacySessionId)])
        let session = JazzArchiveSession(
            captureId: captureId,
            legacySessionId: legacySessionId,
            archiveId: archiveId,
            streamIds: [streamId],
            startedAt: timestamp,
            recorderActorId: actorId,
            sourceIds: [sourceId],
            capturePolicy: JazzArchiveCapturePolicy(
                policyVersion: "consent-v1",
                consentedAt: timestamp,
                modalities: [.pointer, .accessibility],
                excludedApplications: [],
                businessDataCapture: false),
            quality: JazzArchiveQuality(status: .complete))
        return TestArchive(
            archiveId: archiveId,
            originId: originId,
            legacySessionId: legacySessionId,
            captureId: captureId,
            streamId: streamId,
            actorId: actorId,
            sourceId: sourceId,
            manifest: manifest,
            session: session)
    }

    private func record(
        _ fixture: TestArchive,
        sequence: Int,
        observationId: String = Identifiers.newObservationId(),
        streamSequence: Int? = nil,
        sourceId: String? = nil,
        actorId: String? = nil,
        interactionContext: JazzArchiveInteractionContext? = nil
    ) -> ArchiveRecord<ActivityEvent> {
        let event = ActivityEvent(
            sessionId: fixture.legacySessionId,
            eventId: Identifiers.eventId(
                sessionId: fixture.legacySessionId, sequence: sequence),
            sequence: sequence,
            timestamp: timestamp,
            eventType: "click",
            url: "app://com.example.finance")
        return ArchiveRecord(
            event: event,
            observationId: observationId,
            originId: fixture.originId,
            captureId: fixture.captureId,
            streamId: fixture.streamId,
            streamSequence: streamSequence ?? sequence,
            sourceRefs: [JazzArchiveSourceRef(
                sourceId: sourceId ?? fixture.sourceId, role: "trigger")],
            actorRefs: [JazzArchiveActorRef(
                actorId: actorId ?? fixture.actorId,
                role: "performer",
                basis: .declared,
                method: "session_recorder")],
            interactionContext: interactionContext,
            provenance: JazzArchiveProvenance(
                factClass: .observed, sources: [sourceId ?? fixture.sourceId]),
            quality: JazzArchiveQuality(status: .complete),
            privacy: JazzArchivePrivacy(
                status: .captured, policyVersion: "consent-v1"))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("jazz-archive-tests-\(UUID().uuidString)")
    }

    private func artifact(
        _ fixture: TestArchive,
        artifactId: String,
        bytes: Data
    ) -> JazzArchiveArtifact {
        let digest = JazzArchiveDigest.sha256Hex(bytes)
        return JazzArchiveArtifact(
            artifactId: artifactId,
            captureId: fixture.captureId,
            kind: "screenshot",
            content: JazzArchiveArtifactContent(
                path: "blobs/sha256/\(digest.prefix(2))/\(digest)",
                mediaType: "image/jpeg",
                byteLength: Int64(bytes.count),
                sha256: digest),
            sourceRefs: [JazzArchiveSourceRef(
                sourceId: fixture.sourceId, role: "capture")],
            actorRefs: [JazzArchiveActorRef(
                actorId: fixture.actorId,
                role: "performer",
                basis: .declared,
                method: "session_recorder")],
            provenance: JazzArchiveProvenance(
                factClass: .observed, sources: [fixture.sourceId]),
            quality: JazzArchiveQuality(status: .complete),
            privacy: JazzArchivePrivacy(
                status: .captured, policyVersion: "consent-v1"))
    }

    func testCodableShapeKeepsCanonicalAndLegacyIdentitiesSeparate() throws {
        let fixture = makeArchive()
        let context = JazzArchiveInteractionContext(
            application: JazzArchiveApplicationContext(
                identity: JazzArchiveExternalIdentity(
                    namespace: "macos.bundle-id", value: "com.example.finance"),
                name: "Finance"),
            window: JazzArchiveWindowContext(title: "Orders"),
            action: JazzArchiveActionContext(type: "click", modifiers: [.command]),
            target: JazzArchiveTargetContext(
                role: "button",
                locatorCandidates: [JazzArchiveLocatorCandidate(
                    namespace: "macos.ax",
                    kind: "identifier",
                    value: "book-order",
                    stability: .stable,
                    scope: .application)],
                geometry: JazzArchiveGeometry(
                    x: 10, y: 20, width: 100, height: 30,
                    coordinateSpace: .screenPoints,
                    scaleFactor: 2),
                capabilities: ["invoke"]),
            quality: JazzArchiveQuality(status: .complete, confidence: 0.99))
        var value = record(fixture, sequence: 7, interactionContext: context)
        value.extensions = [
            "futureEvidence": .object([
                "verified": .bool(true),
                "samples": .array([.integer(1), .string("kept")]),
            ])
        ]

        let data = try JSONEncoder().encode(value)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["observationId"] as? String, value.observationId)
        XCTAssertEqual(json["originId"] as? String, fixture.originId)
        XCTAssertEqual(json["captureId"] as? String, fixture.captureId)
        XCTAssertEqual(json["streamId"] as? String, fixture.streamId)
        XCTAssertEqual(json["streamSequence"] as? Int, 7)
        XCTAssertNil(json["recordId"])
        XCTAssertNil(json["archiveSequence"])
        XCTAssertNil(json["sessionId"])
        let legacy = try XCTUnwrap(json["legacyCorrelation"] as? [String: Any])
        XCTAssertEqual(legacy["eventId"] as? String, value.payload.eventId)
        let application = try XCTUnwrap(
            (json["interactionContext"] as? [String: Any])?["application"]
                as? [String: Any])
        XCTAssertEqual(application["name"] as? String, "Finance")
        XCTAssertNotNil(json["extensions"])
        XCTAssertEqual(try JSONDecoder().decode(type(of: value), from: data), value)

        let manifestData = try JSONEncoder().encode(fixture.manifest)
        let manifestJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        XCTAssertNotNil(manifestJSON["originId"])
        let ref = try XCTUnwrap((manifestJSON["sessions"] as? [[String: Any]])?.first)
        XCTAssertEqual(ref["captureId"] as? String, fixture.captureId)
        XCTAssertEqual(ref["legacySessionId"] as? String, fixture.legacySessionId)
        XCTAssertNil(ref["sessionId"])
    }

    func testPayloadErasurePreservesCanonicalBytesAndTypedRoundTrip() throws {
        let fixture = makeArchive()
        let typed = record(fixture, sequence: 7)
        let erased = try JazzArchiveRecord(erasing: typed)

        XCTAssertEqual(
            try JazzArchiveCanonicalJSON.encode(erased),
            try JazzArchiveCanonicalJSON.encode(typed))
        XCTAssertEqual(try erased.activityRecord(), typed)
    }

    func testCreateAppendReplayAndEndProducesCommitAndInventory() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = makeArchive()
        let store = JazzArchiveDraftStore(root: root)
        let created = try await store.create(
            manifest: fixture.manifest, session: fixture.session)
        XCTAssertNotEqual(created.inventory.digest, String(repeating: "0", count: 64))

        let batch = try await store.append(
            archiveId: fixture.archiveId,
            captureId: fixture.captureId,
            records: [record(fixture, sequence: 2), record(fixture, sequence: 0)])
        XCTAssertTrue(try XCTUnwrap(batch?.path).hasSuffix(".ndjson"))
        let batchData = try Data(contentsOf: root
            .appendingPathComponent("\(fixture.archiveId).jazz-archive.draft")
            .appendingPathComponent(try XCTUnwrap(batch?.path)))
        XCTAssertTrue(batchData.last == Character("\n").asciiValue)
        XCTAssertEqual(
            String(decoding: batchData, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: true).count,
            2)

        let replay = try await store.records(
            archiveId: fixture.archiveId, captureId: fixture.captureId)
        XCTAssertEqual(replay.map(\.streamSequence), [0, 2])
        let ended = try await store.end(
            archiveId: fixture.archiveId,
            captureId: fixture.captureId,
            endedAt: "2026-07-22T10:01:00.000Z")
        XCTAssertEqual(ended.status, .closed)
        XCTAssertNotNil(ended.captureCommit)

        let commit = try await store.captureCommit(
            archiveId: fixture.archiveId, captureId: fixture.captureId)
        XCTAssertEqual(commit.captureId, fixture.captureId)
        XCTAssertEqual(commit.streamSummaries.first?.observationCount, 2)
        XCTAssertEqual(commit.gaps, [JazzArchiveSequenceGap(
            streamId: fixture.streamId,
            firstSequence: 1,
            lastSequence: 1,
            reason: .unknown)])
        XCTAssertEqual(
            commit.artifactSetDigest,
            JazzArchiveDigest.sha256Hex(Data()))
        let endedManifest = try await store.manifest(archiveId: fixture.archiveId)
        XCTAssertEqual(endedManifest.captureCommits?.first?.commitId, commit.commitId)
        let inventory = try await store.inventory(archiveId: fixture.archiveId)
        XCTAssertEqual(inventory.entries.count, 3)
        XCTAssertTrue(inventory.entries.contains { $0.path.hasSuffix("commit.json") })
    }

    func testExistingArchiveIdentityIsNeverOverwritten() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = makeArchive()
        let store = JazzArchiveDraftStore(root: root)
        let first = try await store.create(
            manifest: fixture.manifest, session: fixture.session)
        do {
            _ = try await store.create(manifest: fixture.manifest, session: fixture.session)
            XCTFail("expected archiveAlreadyExists")
        } catch {
            XCTAssertEqual(error as? JazzArchiveError, .archiveAlreadyExists(fixture.archiveId))
        }
        let reread = try await store.manifest(archiveId: fixture.archiveId)
        XCTAssertEqual(reread.inventory.digest, first.inventory.digest)
    }

    func testObservationStreamAndBatchCollisionsAreRejected() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = makeArchive()
        let store = JazzArchiveDraftStore(root: root)
        _ = try await store.create(manifest: fixture.manifest, session: fixture.session)
        let observationId = Identifiers.newObservationId()
        let batchId = Identifiers.newArchiveBatchId()
        _ = try await store.append(
            archiveId: fixture.archiveId,
            captureId: fixture.captureId,
            records: [record(fixture, sequence: 0, observationId: observationId)],
            batchId: batchId)

        do {
            _ = try await store.append(
                archiveId: fixture.archiveId,
                captureId: fixture.captureId,
                records: [record(
                    fixture, sequence: 1, observationId: observationId, streamSequence: 1)])
            XCTFail("expected duplicate observation")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveError,
                .duplicateIdentifier(kind: "observation", id: observationId))
        }
        do {
            _ = try await store.append(
                archiveId: fixture.archiveId,
                captureId: fixture.captureId,
                records: [record(fixture, sequence: 2, streamSequence: 0)])
            XCTFail("expected duplicate stream sequence")
        } catch let error as JazzArchiveError {
            guard case .duplicateIdentifier(kind: "stream sequence", _) = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        do {
            _ = try await store.append(
                archiveId: fixture.archiveId,
                captureId: fixture.captureId,
                records: [record(fixture, sequence: 3)],
                batchId: batchId)
            XCTFail("expected batchAlreadyExists")
        } catch {
            XCTAssertEqual(error as? JazzArchiveError, .batchAlreadyExists(batchId))
        }
    }

    func testMismatchedOriginDanglingActorSourceAndLegacyCorrelationAreRejected() throws {
        let fixture = makeArchive()
        var wrongOrigin = record(fixture, sequence: 0)
        wrongOrigin.originId = Identifiers.newOriginId()
        XCTAssertThrowsError(
            try wrongOrigin.validate(manifest: fixture.manifest, session: fixture.session)
        ) { error in
            guard case .referenceMismatch(field: "originId", _, _) = error as? JazzArchiveError
            else { return XCTFail("unexpected error: \(error)") }
        }
        XCTAssertThrowsError(try record(
            fixture,
            sequence: 0,
            sourceId: Identifiers.newSourceId()
        ).validate(manifest: fixture.manifest, session: fixture.session)) { error in
            guard case .missingReference(kind: "source", _) = error as? JazzArchiveError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(try record(
            fixture,
            sequence: 0,
            actorId: Identifiers.newActorId()
        ).validate(manifest: fixture.manifest, session: fixture.session)) { error in
            guard case .missingReference(kind: "actor", _) = error as? JazzArchiveError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        var mismatched = record(fixture, sequence: 0)
        mismatched.legacyCorrelation?.eventId = Identifiers.eventId(
            sessionId: fixture.legacySessionId, sequence: 1)
        XCTAssertThrowsError(
            try mismatched.validate(manifest: fixture.manifest, session: fixture.session))
    }

    func testInventoryDetectsTamperedBatch() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = makeArchive()
        let store = JazzArchiveDraftStore(root: root)
        _ = try await store.create(manifest: fixture.manifest, session: fixture.session)
        let appended = try await store.append(
            archiveId: fixture.archiveId,
            captureId: fixture.captureId,
            records: [record(fixture, sequence: 0)])
        let entry = try XCTUnwrap(appended)
        let url = root
            .appendingPathComponent("\(fixture.archiveId).jazz-archive.draft")
            .appendingPathComponent(entry.path)
        try Data("tampered\n".utf8).write(to: url, options: .atomic)
        do {
            _ = try await store.inventory(archiveId: fixture.archiveId)
            XCTFail("expected digest mismatch")
        } catch {
            XCTAssertEqual(error as? JazzArchiveError, .digestMismatch(path: entry.path))
        }
    }

    func testCreateRecoversAfterEveryDurableWriteBoundary() async throws {
        for boundary in JazzArchiveDraftStoreWriteBoundary.createBoundaries {
            try await assertCreateRecovery(after: boundary)
        }
    }

    func testEndRecoversAfterEveryDurableWriteBoundary() async throws {
        for boundary in JazzArchiveDraftStoreWriteBoundary.endBoundaries {
            try await assertEndRecovery(after: boundary)
        }
    }

    func testAppendRecoversAfterEveryDurableWriteBoundary() async throws {
        for boundary in JazzArchiveDraftStoreWriteBoundary.appendBoundaries {
            try await assertAppendRecovery(after: boundary)
        }
    }

    func testArtifactIngestRecoversAfterEveryDurableWriteBoundary() async throws {
        for boundary in JazzArchiveDraftStoreWriteBoundary.artifactBoundaries {
            try await assertArtifactRecovery(after: boundary)
        }
    }

    func testAppendRecoveryPreflightsCASBeforePublishingAnOrphanBatch() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = makeArchive()
        let initial = JazzArchiveDraftStore(root: root)
        _ = try await initial.create(manifest: fixture.manifest, session: fixture.session)
        let batchId = Identifiers.newArchiveBatchId()
        let crashing = JazzArchiveDraftStore(
            root: root, simulatedCrashAfter: .appendIntentPublished)
        do {
            _ = try await crashing.append(
                archiveId: fixture.archiveId,
                captureId: fixture.captureId,
                records: [record(fixture, sequence: 0)],
                batchId: batchId)
            XCTFail("expected simulated append crash")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveDraftStoreSimulatedCrash,
                .after(.appendIntentPublished))
        }

        let manifestURL = root
            .appendingPathComponent("\(fixture.archiveId).jazz-archive.draft")
            .appendingPathComponent("manifest.json")
        var manifestBytes = try Data(contentsOf: manifestURL)
        manifestBytes.append(Character(" ").asciiValue!)
        try manifestBytes.write(to: manifestURL, options: .atomic)

        let relaunched = JazzArchiveDraftStore(root: root)
        do {
            try await relaunched.recover(archiveId: fixture.archiveId)
            XCTFail("expected append CAS conflict")
        } catch let error as JazzArchiveError {
            guard case .transactionConflict("manifest.json") = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        let batchURL = root
            .appendingPathComponent("\(fixture.archiveId).jazz-archive.draft")
            .appendingPathComponent("sessions/\(fixture.captureId)/records/\(batchId).ndjson")
        XCTAssertFalse(FileManager.default.fileExists(atPath: batchURL.path))
    }

    func testPendingCreateNeverAcceptsConflictingContentForTheSameIdentity() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = makeArchive()
        let crashing = JazzArchiveDraftStore(
            root: root, simulatedCrashAfter: .createIntentPublished)
        do {
            _ = try await crashing.create(
                manifest: fixture.manifest, session: fixture.session)
            XCTFail("expected simulated process termination")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveDraftStoreSimulatedCrash,
                .after(.createIntentPublished))
        }

        var conflictingManifest = fixture.manifest
        conflictingManifest.originScope = JazzArchiveExternalIdentity(
            namespace: "test.tenant", value: "different-content")
        let relaunched = JazzArchiveDraftStore(root: root)
        do {
            _ = try await relaunched.create(
                manifest: conflictingManifest, session: fixture.session)
            XCTFail("expected transaction conflict")
        } catch {
            guard case .transactionConflict = error as? JazzArchiveError else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        let recovered = try await relaunched.create(
            manifest: fixture.manifest, session: fixture.session)
        XCTAssertEqual(recovered.originScope, fixture.manifest.originScope)
    }

    func testEndRecoveryPreflightsAllFilesBeforeTouchingConflictingContent() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = makeArchive()
        let initial = JazzArchiveDraftStore(root: root)
        _ = try await initial.create(manifest: fixture.manifest, session: fixture.session)
        _ = try await initial.append(
            archiveId: fixture.archiveId,
            captureId: fixture.captureId,
            records: [record(fixture, sequence: 0)])

        let crashing = JazzArchiveDraftStore(
            root: root, simulatedCrashAfter: .endIntentPublished)
        do {
            _ = try await crashing.end(
                archiveId: fixture.archiveId,
                captureId: fixture.captureId,
                endedAt: "2026-07-22T10:01:00.000Z")
            XCTFail("expected simulated process termination")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveDraftStoreSimulatedCrash,
                .after(.endIntentPublished))
        }

        let archiveURL = root.appendingPathComponent(
            "\(fixture.archiveId).jazz-archive.draft", isDirectory: true)
        let sessionURL = archiveURL.appendingPathComponent(fixture.manifest.sessions[0].path)
        let originalSessionData = try Data(contentsOf: sessionURL)
        let foreignData = Data("foreign-content".utf8)
        try foreignData.write(to: sessionURL, options: .atomic)
        let commitURL = archiveURL.appendingPathComponent(
            fixture.manifest.sessions[0].path
                .split(separator: "/").dropLast().joined(separator: "/") + "/commit.json")

        let relaunched = JazzArchiveDraftStore(root: root)
        do {
            try await relaunched.recover(archiveId: fixture.archiveId)
            XCTFail("expected transaction conflict")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveError,
                .transactionConflict(fixture.manifest.sessions[0].path))
        }
        XCTAssertEqual(try Data(contentsOf: sessionURL), foreignData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: commitURL.path))

        try originalSessionData.write(to: sessionURL, options: .atomic)
        try await relaunched.recover(archiveId: fixture.archiveId)
        let recoveredSession = try await relaunched.session(
            archiveId: fixture.archiveId, captureId: fixture.captureId)
        XCTAssertEqual(recoveredSession.status, .closed)
    }

    func testCompletedEndRejectsAConflictingRetryWithoutReplacingCommit() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = makeArchive()
        let store = JazzArchiveDraftStore(root: root)
        _ = try await store.create(manifest: fixture.manifest, session: fixture.session)
        _ = try await store.append(
            archiveId: fixture.archiveId,
            captureId: fixture.captureId,
            records: [record(fixture, sequence: 0)])
        _ = try await store.end(
            archiveId: fixture.archiveId,
            captureId: fixture.captureId,
            endedAt: "2026-07-22T10:01:00.000Z")
        let original = try await store.captureCommit(
            archiveId: fixture.archiveId, captureId: fixture.captureId)

        do {
            _ = try await store.end(
                archiveId: fixture.archiveId,
                captureId: fixture.captureId,
                endedAt: "2026-07-22T10:01:00.000Z",
                artifactDigests: [
                    Identifiers.newArtifactId(): String(repeating: "a", count: 64)
                ])
            XCTFail("expected conflicting end retry")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveError,
                .sessionEndConflict(fixture.captureId))
        }
        let unchanged = try await store.captureCommit(
            archiveId: fixture.archiveId, captureId: fixture.captureId)
        XCTAssertEqual(unchanged, original)
    }

    private func assertCreateRecovery(
        after boundary: JazzArchiveDraftStoreWriteBoundary
    ) async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = makeArchive()
        let crashing = JazzArchiveDraftStore(root: root, simulatedCrashAfter: boundary)
        do {
            _ = try await crashing.create(
                manifest: fixture.manifest, session: fixture.session)
            XCTFail("expected simulated crash after \(boundary.rawValue)")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveDraftStoreSimulatedCrash,
                .after(boundary),
                boundary.rawValue)
        }

        let relaunched = JazzArchiveDraftStore(root: root)
        let recovered = try await relaunched.create(
            manifest: fixture.manifest, session: fixture.session)
        XCTAssertEqual(recovered.archiveId, fixture.archiveId, boundary.rawValue)
        let session = try await relaunched.session(
            archiveId: fixture.archiveId, captureId: fixture.captureId)
        XCTAssertEqual(session.status, .open, boundary.rawValue)
        let inventory = try await relaunched.inventory(archiveId: fixture.archiveId)
        XCTAssertEqual(inventory.entries.count, 1, boundary.rawValue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root
            .appendingPathComponent(".jazz-transactions", isDirectory: true)
            .appendingPathComponent("create-\(fixture.archiveId)").path))
    }

    private func assertEndRecovery(
        after boundary: JazzArchiveDraftStoreWriteBoundary
    ) async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = makeArchive()
        let initial = JazzArchiveDraftStore(root: root)
        _ = try await initial.create(manifest: fixture.manifest, session: fixture.session)
        _ = try await initial.append(
            archiveId: fixture.archiveId,
            captureId: fixture.captureId,
            records: [record(fixture, sequence: 0)])

        let crashing = JazzArchiveDraftStore(root: root, simulatedCrashAfter: boundary)
        do {
            _ = try await crashing.end(
                archiveId: fixture.archiveId,
                captureId: fixture.captureId,
                endedAt: "2026-07-22T10:01:00.000Z")
            XCTFail("expected simulated crash after \(boundary.rawValue)")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveDraftStoreSimulatedCrash,
                .after(boundary),
                boundary.rawValue)
        }

        let relaunched = JazzArchiveDraftStore(root: root)
        let ended = try await relaunched.end(
            archiveId: fixture.archiveId,
            captureId: fixture.captureId,
            endedAt: "2026-07-22T10:01:00.000Z")
        XCTAssertEqual(ended.status, .closed, boundary.rawValue)
        let firstCommit = try await relaunched.captureCommit(
            archiveId: fixture.archiveId, captureId: fixture.captureId)
        let repeated = try await relaunched.end(
            archiveId: fixture.archiveId,
            captureId: fixture.captureId,
            endedAt: "2026-07-22T10:01:00.000Z")
        XCTAssertEqual(repeated.captureCommit?.commitId, firstCommit.commitId, boundary.rawValue)
        let manifest = try await relaunched.manifest(archiveId: fixture.archiveId)
        XCTAssertEqual(manifest.captureCommits?.count, 1, boundary.rawValue)
        let inventory = try await relaunched.inventory(archiveId: fixture.archiveId)
        XCTAssertEqual(inventory.entries.count, 3, boundary.rawValue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root
            .appendingPathComponent(".jazz-transactions", isDirectory: true)
            .appendingPathComponent(
                "end-\(fixture.archiveId)-\(fixture.captureId)").path))
    }

    private func assertAppendRecovery(
        after boundary: JazzArchiveDraftStoreWriteBoundary
    ) async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = makeArchive()
        let initial = JazzArchiveDraftStore(root: root)
        _ = try await initial.create(manifest: fixture.manifest, session: fixture.session)
        let observation = record(fixture, sequence: 0)
        let batchId = Identifiers.newArchiveBatchId()

        let crashing = JazzArchiveDraftStore(root: root, simulatedCrashAfter: boundary)
        do {
            _ = try await crashing.append(
                archiveId: fixture.archiveId,
                captureId: fixture.captureId,
                records: [observation],
                batchId: batchId)
            XCTFail("expected simulated crash after \(boundary.rawValue)")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveDraftStoreSimulatedCrash,
                .after(boundary),
                boundary.rawValue)
        }

        let relaunched = JazzArchiveDraftStore(root: root)
        let entry = try await relaunched.append(
            archiveId: fixture.archiveId,
            captureId: fixture.captureId,
            records: [observation],
            batchId: batchId)
        XCTAssertNotNil(entry, boundary.rawValue)
        let records = try await relaunched.records(
            archiveId: fixture.archiveId, captureId: fixture.captureId)
        XCTAssertEqual(records, [observation], boundary.rawValue)
        let inventory = try await relaunched.inventory(archiveId: fixture.archiveId)
        XCTAssertEqual(inventory.entries.count, 2, boundary.rawValue)
        XCTAssertEqual(
            inventory.entries.filter { $0.path.hasSuffix("/records/\(batchId).ndjson") }.count,
            1,
            boundary.rawValue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root
            .appendingPathComponent(".jazz-transactions", isDirectory: true)
            .appendingPathComponent(
                "append-\(fixture.archiveId)-\(fixture.captureId)-\(batchId)").path))
    }

    private func assertArtifactRecovery(
        after boundary: JazzArchiveDraftStoreWriteBoundary
    ) async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = makeArchive()
        let initial = JazzArchiveDraftStore(root: root)
        _ = try await initial.create(manifest: fixture.manifest, session: fixture.session)
        let bytes = Data("local screenshot bytes".utf8)
        let artifactId = Identifiers.newArtifactId()
        let document = artifact(fixture, artifactId: artifactId, bytes: bytes)

        let crashing = JazzArchiveDraftStore(root: root, simulatedCrashAfter: boundary)
        do {
            _ = try await crashing.ingestArtifact(
                archiveId: fixture.archiveId,
                captureId: fixture.captureId,
                artifact: document,
                bytes: bytes)
            XCTFail("expected simulated crash after \(boundary.rawValue)")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveDraftStoreSimulatedCrash,
                .after(boundary),
                boundary.rawValue)
        }

        let relaunched = JazzArchiveDraftStore(root: root)
        let recovered = try await relaunched.ingestArtifact(
            archiveId: fixture.archiveId,
            captureId: fixture.captureId,
            artifact: document,
            bytes: bytes)
        XCTAssertEqual(recovered, document, boundary.rawValue)
        let recoveredBytes = try await relaunched.artifactBytes(
            archiveId: fixture.archiveId,
            captureId: fixture.captureId,
            artifactId: artifactId)
        XCTAssertEqual(recoveredBytes, bytes, boundary.rawValue)
        let inventory = try await relaunched.inventory(archiveId: fixture.archiveId)
        XCTAssertEqual(inventory.entries.count, 3, boundary.rawValue)
        XCTAssertEqual(
            inventory.entries.filter { $0.path == document.content.path }.count,
            1,
            boundary.rawValue)
    }

    func testManifestRejectsTraversalAndUnknownActorWithoutReason() throws {
        var fixture = makeArchive()
        fixture.manifest.sessions[0].path = "sessions/../outside.json"
        XCTAssertThrowsError(try fixture.manifest.validate())

        fixture = makeArchive()
        fixture.manifest.actors[0].identityStatus = .unknown
        fixture.manifest.actors[0].identityReason = nil
        XCTAssertThrowsError(try fixture.manifest.validate())
    }
}

/// Swift-side golden runner: schema fixtures must remain decodable, semantically linked, and
/// digest-identical to the Foundation models used by the macOS capture client.
final class JazzArchiveGoldenFixtureTests: XCTestCase {
    private struct GoldenRecord {
        var observationId: String
        var streamId: String
        var streamSequence: Int
        var canonicalDigest: String
    }

    func testEveryArchiveGoldenFixtureMatchesSwiftModelsAndJCS() throws {
        let root = try fixturesRoot()
        let fixtureURLs = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
            .filter {
                FileManager.default.fileExists(
                    atPath: $0.appendingPathComponent("manifest.json").path)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(fixtureURLs.isEmpty, "no archive golden fixtures discovered")
        for fixtureURL in fixtureURLs {
            try validateFixture(fixtureURL)
        }
    }

    private func validateFixture(_ fixtureURL: URL) throws {
        let decoder = JSONDecoder()
        let manifest = try decoder.decode(
            JazzArchiveManifest.self,
            from: Data(contentsOf: fixtureURL.appendingPathComponent("manifest.json")))
        try manifest.validate()

        let expectedContentDigest = try XCTUnwrap(
            manifest.contentDigest, "\(fixtureURL.lastPathComponent): missing contentDigest")
        var unsignedManifest = manifest
        unsignedManifest.contentDigest = nil
        XCTAssertEqual(
            JazzArchiveDigest.sha256Hex(
                try JazzArchiveCanonicalJSON.encode(unsignedManifest)),
            expectedContentDigest,
            "\(fixtureURL.lastPathComponent): manifest JCS digest")

        let inventoryURL = fixtureURL.appendingPathComponent(manifest.inventory.path)
        let inventory = try decoder.decode(
            JazzArchiveInventory.self, from: Data(contentsOf: inventoryURL))
        try inventory.validate()
        XCTAssertEqual(
            JazzArchiveDigest.sha256Hex(try JazzArchiveCanonicalJSON.encode(inventory)),
            manifest.inventory.digest,
            "\(fixtureURL.lastPathComponent): inventory JCS digest")
        for entry in inventory.entries {
            let data = try Data(contentsOf: fixtureURL.appendingPathComponent(entry.path))
            XCTAssertEqual(Int64(data.count), entry.byteLength, entry.path)
            XCTAssertEqual(JazzArchiveDigest.sha256Hex(data), entry.sha256, entry.path)
        }

        for sessionRef in manifest.sessions {
            let session = try decoder.decode(
                JazzArchiveSession.self,
                from: Data(contentsOf: fixtureURL.appendingPathComponent(sessionRef.path)))
            try session.validate()
            XCTAssertEqual(session.archiveId, manifest.archiveId)
            XCTAssertEqual(session.captureId, sessionRef.captureId)
            XCTAssertEqual(session.legacySessionId, sessionRef.legacySessionId)
            XCTAssertTrue(manifest.actors.contains { $0.actorId == session.recorderActorId })
            XCTAssertTrue(session.sourceIds.allSatisfy { sourceId in
                manifest.sources.contains { $0.sourceId == sourceId }
            })

            let sessionDirectory = fixtureURL.appendingPathComponent(sessionRef.path)
                .deletingLastPathComponent()
            let artifactsURL = sessionDirectory.appendingPathComponent("artifacts.ndjson")
            let artifacts: [JazzArchiveArtifact]
            if FileManager.default.fileExists(atPath: artifactsURL.path) {
                let artifactData = try Data(contentsOf: artifactsURL)
                artifacts = try String(decoding: artifactData, as: UTF8.self)
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .map { try decoder.decode(JazzArchiveArtifact.self, from: Data($0.utf8)) }
                for artifact in artifacts {
                    try artifact.validate(manifest: manifest, session: session)
                }
            } else {
                artifacts = []
            }
            let recordData = try Data(
                contentsOf: sessionDirectory.appendingPathComponent("records.ndjson"))
            let records = try String(decoding: recordData, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { line -> GoldenRecord in
                    let data = Data(line.utf8)
                    let object = try XCTUnwrap(
                        JSONSerialization.jsonObject(with: data) as? [String: Any])
                    switch try XCTUnwrap(object["recordType"] as? String) {
                    case ArchiveRecord<ActivityEvent>.activityRecordType:
                        let record = try decoder.decode(
                            ArchiveRecord<ActivityEvent>.self, from: data)
                        try record.validate(manifest: manifest, session: session)
                        return GoldenRecord(
                            observationId: record.observationId,
                            streamId: record.streamId,
                            streamSequence: record.streamSequence,
                            canonicalDigest: JazzArchiveDigest.sha256Hex(
                                try JazzArchiveCanonicalJSON.encode(record)))
                    case ArchiveRecord<CaptureCoachInteraction>.coachRecordType:
                        let record = try decoder.decode(
                            ArchiveRecord<CaptureCoachInteraction>.self, from: data)
                        try record.validate(manifest: manifest, session: session)
                        return GoldenRecord(
                            observationId: record.observationId,
                            streamId: record.streamId,
                            streamSequence: record.streamSequence,
                            canonicalDigest: JazzArchiveDigest.sha256Hex(
                                try JazzArchiveCanonicalJSON.encode(record)))
                    case ArchiveRecord<JazzMediaObservation>.mediaRecordType:
                        let record = try decoder.decode(
                            ArchiveRecord<JazzMediaObservation>.self, from: data)
                        try record.validate(
                            manifest: manifest, session: session, artifacts: artifacts)
                        return GoldenRecord(
                            observationId: record.observationId,
                            streamId: record.streamId,
                            streamSequence: record.streamSequence,
                            canonicalDigest: JazzArchiveDigest.sha256Hex(
                                try JazzArchiveCanonicalJSON.encode(record)))
                    default:
                        throw JazzArchiveError.invalidField("unsupported golden recordType")
                    }
                }
            XCTAssertFalse(records.isEmpty)
            XCTAssertEqual(Set(records.map(\.observationId)).count, records.count)
            XCTAssertEqual(
                Set(records.map { "\($0.streamId):\($0.streamSequence)" }).count,
                records.count)

            let commitRef = try XCTUnwrap(session.captureCommit)
            XCTAssertTrue((manifest.captureCommits ?? []).contains(commitRef))
            let commit = try decoder.decode(
                JazzArchiveCaptureCommit.self,
                from: Data(contentsOf: fixtureURL.appendingPathComponent(commitRef.path)))
            try commit.validate()
            XCTAssertEqual(commit.captureId, session.captureId)
            XCTAssertEqual(
                JazzArchiveDigest.sha256Hex(try JazzArchiveCanonicalJSON.encode(commit)),
                commitRef.digest,
                "\(fixtureURL.lastPathComponent): commit JCS digest")

            let orderedLines = records.sorted {
                ($0.streamId, $0.streamSequence, $0.observationId)
                    < ($1.streamId, $1.streamSequence, $1.observationId)
            }.map { record in
                return "\(record.streamId):\(record.streamSequence):\(record.observationId):\(record.canonicalDigest)\n"
            }.joined()
            XCTAssertEqual(
                JazzArchiveDigest.sha256Hex(Data(orderedLines.utf8)),
                commit.orderedObservationDigest,
                "\(fixtureURL.lastPathComponent): ordered record JCS digest")
            let artifactLines = artifacts.sorted { $0.artifactId < $1.artifactId }
                .map { "\($0.artifactId):\($0.content.sha256)\n" }
                .joined()
            XCTAssertEqual(artifacts.count, commit.artifactCount)
            XCTAssertEqual(
                JazzArchiveDigest.sha256Hex(Data(artifactLines.utf8)),
                commit.artifactSetDigest,
                "\(fixtureURL.lastPathComponent): artifact set digest")
        }
    }

    private func fixturesRoot() throws -> URL {
        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while candidate.path != "/" {
            let fixtures = candidate.appendingPathComponent("contract/archive/fixtures")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: fixtures.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            {
                return fixtures
            }
            candidate.deleteLastPathComponent()
        }
        throw JazzArchiveError.invalidField("contract/archive/fixtures not found")
    }
}
