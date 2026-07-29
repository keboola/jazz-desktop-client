import XCTest

@testable import JasnostCaptureCore

final class CaptureJournalRuntimeTests: XCTestCase {
    private actor Gate {
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if open { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            open = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }

    private actor ProjectionRecorder {
        var observationIds: [String] = []
        func append(_ observationId: String) { observationIds.append(observationId) }
    }

    private struct LiveProjectionSnapshot: Sendable {
        let record: JazzArchiveRecord
        let artifacts: [JazzArchiveArtifact]
        let event: ActivityEvent
    }

    private actor LiveProjectionRecorder {
        var values: [LiveProjectionSnapshot] = []

        func append(
            record: JazzArchiveRecord,
            artifacts: [JazzArchiveArtifact],
            event: ActivityEvent
        ) {
            values.append(LiveProjectionSnapshot(
                record: record,
                artifacts: artifacts,
                event: event))
        }

        func recorded() -> [LiveProjectionSnapshot] {
            values
        }
    }

    private struct Fixture {
        var root: URL
        var archiveId: String
        var captureId: String
        var streamId: String
        var sourceId: String
        var actorId: String
        var legacySessionId: String
        var manifest: JazzArchiveManifest
        var session: JazzArchiveSession
        var context: CaptureJournalActivityContext
    }

    private func fixture() -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-runtime-tests-\(UUID().uuidString)")
        let archiveId = Identifiers.newArchiveId()
        let originId = Identifiers.newOriginId()
        let captureId = Identifiers.newCaptureId()
        let streamId = Identifiers.newStreamId()
        let sourceId = Identifiers.newSourceId()
        let actorId = Identifiers.newActorId()
        let legacySessionId = Identifiers.newSessionId()
        let producer = JazzArchiveProducer(
            name: "Jazz Capture", version: "runtime-test", platform: "macOS")
        let manifest = JazzArchiveManifest(
            archiveId: archiveId,
            originId: originId,
            createdAt: "2026-07-22T10:00:00.000Z",
            producer: producer,
            actors: [JazzArchiveActor(
                actorId: actorId,
                kind: .human,
                identityStatus: .identified,
                displayName: "Recorder",
                provenance: JazzArchiveProvenance(factClass: .declared, sources: []))],
            sources: [JazzArchiveSource(
                sourceId: sourceId,
                kind: "macos.native",
                actorId: actorId,
                producer: producer,
                capabilities: ["pointer.click", "screen.capture", "audio.capture"],
                provenance: JazzArchiveProvenance(factClass: .observed, sources: []))],
            sessions: [JazzArchiveSessionRef(
                captureId: captureId, legacySessionId: legacySessionId)],
            extensions: [
                JazzArchiveProjectionReconciler.deliveryPolicyExtension:
                    .string(JazzCaptureDeliveryPolicy.liveCompatibility.rawValue)
            ])
        let session = JazzArchiveSession(
            captureId: captureId,
            legacySessionId: legacySessionId,
            archiveId: archiveId,
            streamIds: [streamId],
            startedAt: "2026-07-22T10:00:00.000Z",
            recorderActorId: actorId,
            sourceIds: [sourceId],
            capturePolicy: JazzArchiveCapturePolicy(
                policyVersion: "consent-v1",
                consentedAt: "2026-07-22T10:00:00.000Z",
                modalities: [.pointer, .accessibility, .screenshots, .narration],
                excludedApplications: [],
                businessDataCapture: false),
            quality: JazzArchiveQuality(status: .complete))
        return Fixture(
            root: root,
            archiveId: archiveId,
            captureId: captureId,
            streamId: streamId,
            sourceId: sourceId,
            actorId: actorId,
            legacySessionId: legacySessionId,
            manifest: manifest,
            session: session,
            context: CaptureJournalActivityContext(
                originId: originId,
                captureId: captureId,
                streamId: streamId,
                sourceId: sourceId,
                actorId: actorId,
                policyVersion: "consent-v1"))
    }

    private func event(_ fixture: Fixture, sequence: Int, type: EventType) -> ActivityEvent {
        ActivityEvent(
            sessionId: fixture.legacySessionId,
            eventId: Identifiers.eventId(
                sessionId: fixture.legacySessionId, sequence: sequence),
            sequence: sequence,
            timestamp: "2026-07-22T10:00:0\(sequence).000Z",
            eventType: type.rawValue,
            url: "app://com.example.finance")
    }

    func testCloseDrainsLateAXScreenshotAndNarrationBeforeLocalCommit() async throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let journal = CaptureJournal(root: fixture.root)
        _ = try await journal.begin(manifest: fixture.manifest, session: fixture.session)
        let projections = ProjectionRecorder()
        let runtime = CaptureJournalRuntime(
            journal: journal,
            context: fixture.context,
            projection: { observationId, _ in await projections.append(observationId) })
        let ax = Gate()
        let screenshot = Gate()
        let narration = Gate()

        _ = try await runtime.submit { _ in
            await ax.wait()
            return .observation(CaptureJournalActivityObservation(
                event: self.event(fixture, sequence: 0, type: .click)))
        }
        _ = try await runtime.submit { _ in
            await screenshot.wait()
            return .observation(CaptureJournalActivityObservation(
                event: self.event(fixture, sequence: 1, type: .click),
                artifact: CaptureJournalArtifactInput(
                    bytes: Data("screenshot".utf8),
                    kind: "screenshot",
                    mediaType: "image/jpeg",
                    role: "screenshot",
                    sourceRole: "screen_capture",
                    actorRole: "performer",
                    captureInterval: testScreenshotCaptureInterval(
                        at: "2026-07-22T10:00:01.000Z"),
                    quality: testScreenshotQuality(),
                    privacy: JazzArchivePrivacy(
                        status: .captured, policyVersion: "consent-v1"),
                    extensions: testScreenshotEvidence(
                        at: "2026-07-22T10:00:01.000Z").extensions)))
        }
        _ = try await runtime.submit { _ in
            await narration.wait()
            return .observation(CaptureJournalActivityObservation(
                event: self.event(fixture, sequence: 2, type: .narration),
                artifact: CaptureJournalArtifactInput(
                    bytes: Data("audio".utf8),
                    kind: "narration_audio",
                    mediaType: "audio/mp4",
                    role: "narration_audio",
                    sourceRole: "microphone_capture",
                    actorRole: "narrator",
                    privacy: JazzArchivePrivacy(
                        status: .captured, policyVersion: "consent-v1"))))
        }

        // Actor task scheduling is intentionally unspecified. Seal admissions explicitly before
        // launching the concurrently draining close so this test verifies the runtime barrier,
        // rather than relying on `Task.yield()` to happen to enqueue `close` first.
        try await runtime.sealAdmissions()
        let close = Task {
            try await runtime.close(endedAt: "2026-07-22T10:01:00.000Z")
        }
        do {
            _ = try await runtime.submit { _ in
                .observation(CaptureJournalActivityObservation(
                    event: self.event(fixture, sequence: 3, type: .scroll)))
            }
            XCTFail("closing runtime accepted late input")
        } catch {
            XCTAssertEqual(error as? CaptureJournalRuntimeError, .closed)
        }

        await ax.release()
        await screenshot.release()
        await narration.release()
        let commit = try await close.value
        XCTAssertEqual(commit.artifactCount, 2)
        XCTAssertEqual(commit.gaps, [])
        let store = JazzArchiveDraftStore(root: fixture.root)
        let records = try await store.records(
            archiveId: fixture.archiveId, captureId: fixture.captureId)
        XCTAssertEqual(records.map(\.payload.eventType), ["click", "click", "narration"])
        XCTAssertEqual(records[1].actorRefs.map(\.role), ["performer"])
        XCTAssertEqual(records[2].actorRefs.map(\.role), ["performer"])
        let screenshotId = try XCTUnwrap(records[1].artifactRefs.first?.artifactId)
        let narrationId = try XCTUnwrap(records[2].artifactRefs.first?.artifactId)
        let screenshotArtifact = try await store.artifact(
            archiveId: fixture.archiveId,
            captureId: fixture.captureId,
            artifactId: screenshotId)
        let narrationArtifact = try await store.artifact(
            archiveId: fixture.archiveId,
            captureId: fixture.captureId,
            artifactId: narrationId)
        XCTAssertEqual(screenshotArtifact.sourceRefs.map(\.role), ["screen_capture"])
        XCTAssertEqual(screenshotArtifact.actorRefs.map(\.role), ["performer"])
        XCTAssertEqual(narrationArtifact.sourceRefs.map(\.role), ["microphone_capture"])
        XCTAssertEqual(narrationArtifact.actorRefs.map(\.role), ["narrator"])
        let projected = await projections.observationIds
        XCTAssertEqual(projected.count, 3)
        let snapshot = await journal.snapshot()
        XCTAssertEqual(snapshot.lifecycle, .committed)
    }

    func testOrderedProjectionHoldsHigherSequenceUntilLowerProducerResolves()
        async throws
    {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let journal = CaptureJournal(root: fixture.root)
        _ = try await journal.begin(
            manifest: fixture.manifest,
            session: fixture.session)
        let firstProducer = Gate()
        let projections = LiveProjectionRecorder()
        let ordered = CaptureJournalOrderedProjection {
            record, artifacts, event in
            await projections.append(
                record: record,
                artifacts: artifacts,
                event: try XCTUnwrap(event))
        }
        let runtime = CaptureJournalRuntime(
            journal: journal,
            context: fixture.context,
            orderedLiveCompatibilityProjection: ordered)

        _ = try await runtime.submit { _ in
            await firstProducer.wait()
            return .observation(
                CaptureJournalActivityObservation(
                    event: self.event(
                        fixture,
                        sequence: 8,
                        type: .click)))
        }
        _ = try await runtime.submit { _ in
            .observation(
                CaptureJournalActivityObservation(
                    event: self.event(
                        fixture,
                        sequence: 9,
                        type: .click)))
        }
        await Task.yield()
        let beforeRelease = await projections.recorded()
        XCTAssertTrue(beforeRelease.isEmpty)

        await firstProducer.release()
        await runtime.waitForAdmittedWork()

        let recorded = await projections.recorded()
        let pendingCount = await ordered.pendingResolutionCount()
        XCTAssertEqual(recorded.map(\.record.streamSequence), [0, 1])
        XCTAssertEqual(recorded.compactMap(\.event.sequence), [8, 9])
        XCTAssertEqual(pendingCount, 0)
    }

    func testOrderedProjectionAdvancesAcrossExplicitGap() async throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let journal = CaptureJournal(root: fixture.root)
        _ = try await journal.begin(
            manifest: fixture.manifest,
            session: fixture.session)
        let firstProducer = Gate()
        let projections = LiveProjectionRecorder()
        let ordered = CaptureJournalOrderedProjection {
            record, artifacts, event in
            await projections.append(
                record: record,
                artifacts: artifacts,
                event: try XCTUnwrap(event))
        }
        let runtime = CaptureJournalRuntime(
            journal: journal,
            context: fixture.context,
            orderedLiveCompatibilityProjection: ordered)

        _ = try await runtime.submit { _ in
            await firstProducer.wait()
            return .gap(
                reason: .captureLoss,
                detail: "simulated producer loss")
        }
        _ = try await runtime.submit { _ in
            .observation(
                CaptureJournalActivityObservation(
                    event: self.event(
                        fixture,
                        sequence: 7,
                        type: .click)))
        }
        await Task.yield()
        let beforeRelease = await projections.recorded()
        XCTAssertTrue(beforeRelease.isEmpty)

        await firstProducer.release()
        await runtime.waitForAdmittedWork()

        let recorded = await projections.recorded()
        let pendingCount = await ordered.pendingResolutionCount()
        XCTAssertEqual(recorded.map(\.record.streamSequence), [1])
        XCTAssertEqual(pendingCount, 0)
    }

    func testProjectionFailureCannotBlockCanonicalCommit() async throws {
        struct ProjectionFailure: Error {}
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let journal = CaptureJournal(root: fixture.root)
        _ = try await journal.begin(manifest: fixture.manifest, session: fixture.session)
        let runtime = CaptureJournalRuntime(
            journal: journal,
            context: fixture.context,
            projection: { _, _ in throw ProjectionFailure() })
        _ = try await runtime.submit { _ in
            .observation(CaptureJournalActivityObservation(
                event: self.event(fixture, sequence: 0, type: .sessionStart)))
        }
        let commit = try await runtime.close(endedAt: "2026-07-22T10:01:00.000Z")
        XCTAssertEqual(commit.streamSummaries.first?.observationCount, 1)
        let projectionErrors = await runtime.recordedProjectionErrors()
        XCTAssertEqual(projectionErrors.count, 1)
    }

    func testLiveProjectionReceivesExactAlreadyPersistedObservationAndArtifact() async throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let journal = CaptureJournal(root: fixture.root)
        _ = try await journal.begin(manifest: fixture.manifest, session: fixture.session)
        let recorder = LiveProjectionRecorder()
        let runtime = CaptureJournalRuntime(
            journal: journal,
            context: fixture.context,
            liveCompatibilityProjection: { record, artifacts, event in
                await recorder.append(
                    record: record,
                    artifacts: artifacts,
                    event: event)
            })
        let inputEvent = event(fixture, sequence: 0, type: .click)
        let artifactId = Identifiers.newArtifactId()
        _ = try await runtime.submit { _ in
            .observation(CaptureJournalActivityObservation(
                event: inputEvent,
                artifact: CaptureJournalArtifactInput(
                    artifactId: artifactId,
                    bytes: Data("canonical screenshot".utf8),
                    kind: "screenshot",
                    mediaType: "image/jpeg",
                    role: "screenshot",
                    sourceRole: "screen_capture",
                    actorRole: "performer",
                    captureInterval: testScreenshotCaptureInterval(
                        at: inputEvent.timestamp),
                    quality: testScreenshotQuality(),
                    privacy: JazzArchivePrivacy(
                        status: .captured,
                        policyVersion: "consent-v1"),
                    extensions: testScreenshotEvidence(
                        at: inputEvent.timestamp).extensions)))
        }
        let commit = try await runtime.close(endedAt: "2026-07-22T10:01:00.000Z")
        let values = await recorder.values
        let projected = try XCTUnwrap(values.first)
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(projected.event, inputEvent)
        XCTAssertEqual(projected.artifacts.count, 1)
        XCTAssertEqual(projected.artifacts.first?.artifactId, artifactId)

        let store = JazzArchiveDraftStore(root: fixture.root)
        let persistedRecords = try await store.records(
            archiveId: fixture.archiveId,
            captureId: fixture.captureId)
        let persistedRecord = try XCTUnwrap(persistedRecords.first)
        let persistedArtifact = try await store.artifact(
            archiveId: fixture.archiveId,
            captureId: fixture.captureId,
            artifactId: artifactId)
        XCTAssertEqual(
            try JazzArchiveCanonicalJSON.encode(projected.record),
            try JazzArchiveCanonicalJSON.encode(
                JazzArchiveRecord(erasing: persistedRecord)))
        XCTAssertEqual(projected.artifacts, [persistedArtifact])
        XCTAssertEqual(commit.artifactCount, 1)
        XCTAssertEqual(commit.streamSummaries.first?.observationCount, 1)
    }

    func testArchiveOnlyObservationExtensionsSurviveCanonicalJournal() async throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let journal = CaptureJournal(root: fixture.root)
        _ = try await journal.begin(manifest: fixture.manifest, session: fixture.session)
        let runtime = CaptureJournalRuntime(journal: journal, context: fixture.context)
        let metadata: [String: JazzArchiveJSONValue] = [
            "dev.jazz.label.declarationMode": .string("guided"),
            "dev.jazz.label.bindingResolution": .string("exact_match"),
            "dev.jazz.label.declarationText": .string("Book the monthly orders"),
        ]
        let boundary: ActivityEvent = {
            var value = event(fixture, sequence: 0, type: .labelStart)
            value.labelId = Identifiers.newLabelId()
            value.label = "Book monthly orders"
            return value
        }()
        _ = try await runtime.submit { _ in
            .observation(CaptureJournalActivityObservation(
                event: boundary,
                extensions: metadata))
        }
        await runtime.waitForAdmittedWork()

        let records = try await JazzArchiveDraftStore(root: fixture.root).records(
            archiveId: fixture.archiveId,
            captureId: fixture.captureId)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].extensions, metadata)
    }

    func testResolutionObserverExposesArtifactOnlyAfterCanonicalPersistence() async throws {
        actor ResolutionBox {
            var values: [CaptureJournalActivityResolution] = []
            func append(_ value: CaptureJournalActivityResolution) { values.append(value) }
        }

        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let journal = CaptureJournal(root: fixture.root)
        _ = try await journal.begin(manifest: fixture.manifest, session: fixture.session)
        let runtime = CaptureJournalRuntime(journal: journal, context: fixture.context)
        let artifactId = Identifiers.newArtifactId()
        let box = ResolutionBox()

        _ = try await runtime.submit({ _ in
            .observation(CaptureJournalActivityObservation(
                event: self.event(fixture, sequence: 0, type: .narration),
                artifact: CaptureJournalArtifactInput(
                    artifactId: artifactId,
                    bytes: Data("spoken answer".utf8),
                    kind: "narration_audio",
                    mediaType: "audio/mp4",
                    role: "narration_audio",
                    sourceRole: "microphone_capture",
                    actorRole: "narrator",
                    privacy: JazzArchivePrivacy(
                        status: .captured, policyVersion: "consent-v1"))))
        }, onResolved: { value in
            await box.append(value)
        })
        await runtime.waitForAdmittedWork()

        let values = await box.values
        guard case let .persisted(_, persistedArtifactId) = values.first else {
            return XCTFail("missing persisted resolution")
        }
        XCTAssertEqual(persistedArtifactId, artifactId)
    }

    func testLargeSparseNarrationUsesSealedFileClaimThroughFinalize() async throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let journal = CaptureJournal(root: fixture.root)
        _ = try await journal.begin(manifest: fixture.manifest, session: fixture.session)
        let runtime = CaptureJournalRuntime(journal: journal, context: fixture.context)
        let artifactId = Identifiers.newArtifactId()
        let writable = try JazzArchiveWritableFileClaim.prepare(
            root: fixture.root,
            archiveId: fixture.archiveId,
            captureId: fixture.captureId,
            artifactId: artifactId,
            fileExtension: "m4a")

        // A sparse file much larger than the fixed read buffer exercises the URL-backed path
        // without allocating an equivalent Data value in the test or production code.
        let byteLength = Int64(JazzArchiveFileIO.chunkSize * 65 + 17)
        let handle = try FileHandle(forWritingTo: writable.recordingURL)
        try handle.write(contentsOf: Data("JAZZ".utf8))
        try handle.truncate(atOffset: UInt64(byteLength))
        try handle.seek(toOffset: UInt64(byteLength - 4))
        try handle.write(contentsOf: Data("END!".utf8))
        try handle.synchronize()
        try handle.close()
        let claimed = try writable.seal()
        XCTAssertFalse(FileManager.default.fileExists(atPath: writable.recordingURL.path))
        let expected = try JazzArchiveFileIO.fingerprint(claimed.url)
        XCTAssertEqual(expected.byteLength, byteLength)
        XCTAssertGreaterThan(expected.byteLength, Int64(JazzArchiveFileIO.chunkSize * 64))

        _ = try await runtime.submit { _ in
            .observation(CaptureJournalActivityObservation(
                event: self.event(fixture, sequence: 0, type: .narration),
                artifact: CaptureJournalArtifactInput(
                    artifactId: artifactId,
                    claimedFile: claimed,
                    kind: "narration_audio",
                    mediaType: "audio/mp4",
                    role: "narration_audio",
                    sourceRole: "microphone_capture",
                    actorRole: "narrator",
                    privacy: JazzArchivePrivacy(
                        status: .captured, policyVersion: "consent-v1"))))
        }
        await runtime.waitForAdmittedWork()
        XCTAssertFalse(FileManager.default.fileExists(atPath: claimed.url.path))

        let store = JazzArchiveDraftStore(root: fixture.root)
        let persisted = try await store.artifactFile(
            archiveId: fixture.archiveId,
            captureId: fixture.captureId,
            artifactId: artifactId)
        XCTAssertEqual(persisted.artifact.content.byteLength, byteLength)
        XCTAssertEqual(try JazzArchiveFileIO.fingerprint(persisted.url), expected)

        _ = try await runtime.close(endedAt: "2026-07-22T10:01:00.000Z")
        let package = try await JazzArchiveFinalizer(root: fixture.root).finalize(
            archiveId: fixture.archiveId,
            snapshotAt: "2026-07-22T10:02:00.000Z")
        let finalizedBlob = package.url.appendingPathComponent(persisted.artifact.content.path)
        XCTAssertEqual(try JazzArchiveFileIO.fingerprint(finalizedBlob), expected)
        XCTAssertTrue(package.inventory.entries.contains(where: {
            $0.path == persisted.artifact.content.path
                && $0.byteLength == expected.byteLength
                && $0.sha256 == expected.sha256
        }))
    }

    func testChangedSealedClaimFailsWithoutPublishingArtifact() async throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let journal = CaptureJournal(root: fixture.root)
        _ = try await journal.begin(manifest: fixture.manifest, session: fixture.session)
        let runtime = CaptureJournalRuntime(journal: journal, context: fixture.context)
        let artifactId = Identifiers.newArtifactId()
        let writable = try JazzArchiveWritableFileClaim.prepare(
            root: fixture.root,
            archiveId: fixture.archiveId,
            captureId: fixture.captureId,
            artifactId: artifactId,
            fileExtension: "m4a")
        try Data("before".utf8).write(to: writable.recordingURL)
        let claimed = try writable.seal()
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: claimed.url.path)
        try Data("after!".utf8).write(to: claimed.url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)],
            ofItemAtPath: claimed.url.path)

        _ = try await runtime.submit { _ in
            .observation(CaptureJournalActivityObservation(
                event: self.event(fixture, sequence: 0, type: .narration),
                artifact: CaptureJournalArtifactInput(
                    artifactId: artifactId,
                    claimedFile: claimed,
                    kind: "narration_audio",
                    mediaType: "audio/mp4",
                    role: "narration_audio",
                    sourceRole: "microphone_capture",
                    actorRole: "narrator",
                    privacy: JazzArchivePrivacy(
                        status: .captured, policyVersion: "consent-v1"))))
        }
        await runtime.waitForAdmittedWork()

        let store = JazzArchiveDraftStore(root: fixture.root)
        do {
            _ = try await store.artifact(
                archiveId: fixture.archiveId,
                captureId: fixture.captureId,
                artifactId: artifactId)
            XCTFail("changed claim was published")
        } catch {
            // No canonical artifact document may reference the rejected mutable input.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: claimed.url.path))
    }

    func testRelaunchReconcilesBothOutboxesAfterCanonicalResolveProjectionCrash() async throws {
        struct SimulatedKillBoundary: Error {}
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let journal = CaptureJournal(root: fixture.root)
        _ = try await journal.begin(manifest: fixture.manifest, session: fixture.session)
        let runtime = CaptureJournalRuntime(
            journal: journal,
            context: fixture.context,
            projection: { _, _ in throw SimulatedKillBoundary() },
            artifactProjection: { _, _ in throw SimulatedKillBoundary() })
        _ = try await runtime.submit { _ in
            .observation(CaptureJournalActivityObservation(
                event: self.event(fixture, sequence: 0, type: .click),
                artifact: CaptureJournalArtifactInput(
                    bytes: Data("canonical screenshot".utf8),
                    kind: "screenshot",
                    mediaType: "image/jpeg",
                    role: "screenshot",
                    sourceRole: "screen_capture",
                    actorRole: "performer",
                    captureInterval: testScreenshotCaptureInterval(
                        at: "2026-07-22T10:00:00.000Z"),
                    quality: testScreenshotQuality(),
                    privacy: JazzArchivePrivacy(
                        status: .captured, policyVersion: "consent-v1"),
                    extensions: testScreenshotEvidence(
                        at: "2026-07-22T10:00:00.000Z").extensions)))
        }
        _ = try await runtime.close(endedAt: "2026-07-22T10:01:00.000Z")

        let spool = EventSpool(root: fixture.root.appendingPathComponent("otlp-spool"))
        let queue = JazzArchiveDeliveryQueue(
            root: fixture.root.appendingPathComponent("artifact-outbox"))
        XCTAssertTrue(spool.pendingBatches().isEmpty)
        let initiallyPendingArtifacts = await queue.pending()
        XCTAssertTrue(initiallyPendingArtifacts.isEmpty)
        let archiveIndex = JazzArchiveLocalIndex(root: fixture.root, eventSpool: spool)
        let visibleBeforeProjection = await archiveIndex.sessions()
        XCTAssertEqual(visibleBeforeProjection.count, 1)
        XCTAssertEqual(visibleBeforeProjection.first?.eventCount, 1)
        XCTAssertEqual(visibleBeforeProjection.first?.pendingCount, 0)

        let reconciler = JazzArchiveProjectionReconciler(
            archiveRoot: fixture.root, eventSpool: spool, artifactQueue: queue)
        let first = try await reconciler.reconcile(archiveId: fixture.archiveId)
        XCTAssertEqual(first.observationCount, 1)
        XCTAssertEqual(first.artifactCount, 1)
        XCTAssertEqual(spool.sessionEvents(sessionId: fixture.legacySessionId).count, 1)
        XCTAssertEqual(spool.pendingBatches().count, 2)
        XCTAssertEqual(
            spool.pendingBatches().filter {
                spool.readLiveArtifactProjection($0) != nil
            }.count,
            1)
        let firstPendingArtifacts = await queue.pending()
        XCTAssertEqual(firstPendingArtifacts.count, 1)

        _ = try await reconciler.reconcile(archiveId: fixture.archiveId)
        XCTAssertEqual(spool.sessionEvents(sessionId: fixture.legacySessionId).count, 1)
        XCTAssertEqual(spool.pendingBatches().count, 2)
        let secondPendingArtifacts = await queue.pending()
        XCTAssertEqual(secondPendingArtifacts, firstPendingArtifacts)
        XCTAssertEqual(
            spool.sessionMeta(sessionId: fixture.legacySessionId)?.endedAt,
            "2026-07-22T10:01:00.000Z")
    }

    func testGlobalPreferenceCannotRetroactivelyProjectConfirmedArchive()
        async throws
    {
        var fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.manifest.extensions = [
            JazzArchiveProjectionReconciler.deliveryPolicyExtension:
                .string(JazzCaptureDeliveryPolicy.confirmedArchive.rawValue)
        ]
        let journal = CaptureJournal(root: fixture.root)
        _ = try await journal.begin(
            manifest: fixture.manifest,
            session: fixture.session)
        let runtime = CaptureJournalRuntime(
            journal: journal,
            context: fixture.context)
        let activityEvent = event(
            fixture,
            sequence: 0,
            type: .click)
        _ = try await runtime.submit { _ in
            .observation(
                CaptureJournalActivityObservation(
                    event: activityEvent))
        }
        _ = try await runtime.close(
            endedAt: "2026-07-22T10:01:00.000Z")

        let spool = EventSpool(
            root: fixture.root.appendingPathComponent("otlp-spool"))
        let queue = JazzArchiveDeliveryQueue(
            root: fixture.root.appendingPathComponent("artifact-outbox"))
        let reconciler = JazzArchiveProjectionReconciler(
            archiveRoot: fixture.root,
            eventSpool: spool,
            artifactQueue: queue)

        let all = await reconciler.reconcileAll()
        XCTAssertTrue(all.isEmpty)
        XCTAssertTrue(spool.pendingBatches().isEmpty)
        do {
            _ = try await reconciler.reconcile(
                archiveId: fixture.archiveId)
            XCTFail("confirmed archive must not gain live delivery authority")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveProjectionReconciliationError,
                .liveCompatibilityNotAuthorized(fixture.archiveId))
        }
    }
}
