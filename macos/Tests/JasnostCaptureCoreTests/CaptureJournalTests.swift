import XCTest

@testable import JasnostCaptureCore

final class CaptureJournalTests: XCTestCase {
    private let startedAt = "2026-07-22T10:00:00.000Z"
    private let endedAt = "2026-07-22T10:01:00.000Z"

    private struct Fixture {
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

    private func makeFixture() -> Fixture {
        let archiveId = Identifiers.newArchiveId()
        let originId = Identifiers.newOriginId()
        let legacySessionId = Identifiers.newSessionId()
        let captureId = Identifiers.newCaptureId()
        let streamId = Identifiers.newStreamId()
        let actorId = Identifiers.newActorId()
        let sourceId = Identifiers.newSourceId()
        let producer = JazzArchiveProducer(
            name: "Jazz Capture", version: "journal-test", platform: "macOS")
        let actor = JazzArchiveActor(
            actorId: actorId,
            kind: .human,
            identityStatus: .identified,
            displayName: "Recorder",
            provenance: JazzArchiveProvenance(factClass: .declared, sources: []))
        let source = JazzArchiveSource(
            sourceId: sourceId,
            kind: "macos.capture-journal-test",
            actorId: actorId,
            producer: producer,
            capabilities: ["pointer.click"],
            provenance: JazzArchiveProvenance(factClass: .observed, sources: []))
        let manifest = JazzArchiveManifest(
            archiveId: archiveId,
            originId: originId,
            originScope: JazzArchiveExternalIdentity(
                namespace: "test.tenant", value: "offline"),
            createdAt: startedAt,
            producer: producer,
            contracts: [.activityEvent, .captureCoachInteraction],
            actors: [actor],
            sources: [source],
            sessions: [JazzArchiveSessionRef(
                captureId: captureId, legacySessionId: legacySessionId)])
        let session = JazzArchiveSession(
            captureId: captureId,
            legacySessionId: legacySessionId,
            archiveId: archiveId,
            streamIds: [streamId],
            startedAt: startedAt,
            recorderActorId: actorId,
            sourceIds: [sourceId],
            capturePolicy: JazzArchiveCapturePolicy(
                policyVersion: "consent-v1",
                consentedAt: startedAt,
                modalities: [.pointer, .accessibility],
                excludedApplications: [],
                businessDataCapture: false),
            quality: JazzArchiveQuality(status: .complete))
        return Fixture(
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
        _ fixture: Fixture,
        token: CaptureJournalReservationToken,
        observationId: String = Identifiers.newObservationId(),
        eventType: String = "click"
    ) -> ArchiveRecord<ActivityEvent> {
        record(
            fixture,
            streamSequence: token.streamSequence,
            observationId: observationId,
            eventType: eventType)
    }

    private func record(
        _ fixture: Fixture,
        streamSequence: Int,
        observationId: String = Identifiers.newObservationId(),
        eventType: String = "click"
    ) -> ArchiveRecord<ActivityEvent> {
        let event = ActivityEvent(
            sessionId: fixture.legacySessionId,
            eventId: Identifiers.eventId(
                sessionId: fixture.legacySessionId,
                sequence: streamSequence),
            sequence: streamSequence,
            timestamp: startedAt,
            eventType: eventType,
            url: "app://com.example.finance")
        return ArchiveRecord(
            event: event,
            observationId: observationId,
            originId: fixture.originId,
            captureId: fixture.captureId,
            streamId: fixture.streamId,
            streamSequence: streamSequence,
            sourceRefs: [JazzArchiveSourceRef(
                sourceId: fixture.sourceId, role: "trigger")],
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

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-journal-tests-\(UUID().uuidString)")
    }

    private func coachRecord(
        _ fixture: Fixture,
        token: CaptureJournalReservationToken,
        interactionType: CaptureCoachInteractionType = .shown,
        promptId: String = Identifiers.newCoachPromptId()
    ) -> ArchiveRecord<CaptureCoachInteraction> {
        let assessmentId = "cqa-\(Identifiers.newUUIDv7().uuidString.lowercased())"
        let interaction = CaptureCoachInteraction(
            interactionType: interactionType,
            occurredAt: startedAt,
            promptId: promptId,
            assessmentRef: CaptureCoachAssessmentRef(
                assessmentId: assessmentId,
                revision: 1,
                inputDigest: String(repeating: "a", count: 64)),
            inputWatermark: CaptureCoachInputWatermark(
                captureId: fixture.captureId,
                streams: [CaptureCoachStreamWatermark(
                    streamId: fixture.streamId,
                    throughSequence: max(0, token.streamSequence - 1))]),
            promptSnapshot: CaptureCoachPromptSnapshot(
                text: "What exception are you handling?",
                slot: .exception,
                policyVersion: "coach-test-v1",
                responseModes: [.typedText]))
        return ArchiveRecord(
            interaction: interaction,
            originId: fixture.originId,
            captureId: fixture.captureId,
            streamId: fixture.streamId,
            streamSequence: token.streamSequence,
            sourceRefs: [JazzArchiveSourceRef(
                sourceId: fixture.sourceId, role: "coach_control")],
            actorRefs: [JazzArchiveActorRef(
                actorId: fixture.actorId,
                role: "recipient",
                basis: .declared,
                method: "session_recorder")],
            provenance: JazzArchiveProvenance(
                factClass: .observed, sources: [fixture.sourceId]),
            quality: JazzArchiveQuality(status: .complete),
            privacy: JazzArchivePrivacy(
                status: .captured, policyVersion: "consent-v1"))
    }

    private func coachPrompt(
        _ fixture: Fixture,
        throughSequence: Int
    ) -> CaptureCoachPrompt {
        CaptureCoachPrompt(
            promptId: Identifiers.newCoachPromptId(),
            assessmentRef: CaptureCoachAssessmentRef(
                assessmentId: "cqa-\(Identifiers.newUUIDv7().uuidString.lowercased())",
                revision: 1,
                inputDigest: String(repeating: "c", count: 64)),
            inputWatermark: CaptureCoachInputWatermark(
                captureId: fixture.captureId,
                streams: [CaptureCoachStreamWatermark(
                    streamId: fixture.streamId,
                    throughSequence: throughSequence)]),
            snapshot: CaptureCoachPromptSnapshot(
                text: "What result tells you this step succeeded?",
                slot: .success,
                policyVersion: "coach-test-v1",
                responseModes: [.typedText]))
    }

    func testPrepareSynchronizesJournalFileBeforeDirectoryCommit() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = makeFixture()
        let recorder = CanonicalDurabilityRecorder()
        let journal = CaptureJournal(
            root: root, durability: recorder.value())

        _ = try await journal.prepare(
            manifest: fixture.manifest, session: fixture.session)

        let stateDirectory = root
            .appendingPathComponent(".capture-journal", isDirectory: true)
            .appendingPathComponent(fixture.archiveId, isDirectory: true)
        let stateFile = stateDirectory.appendingPathComponent("state.json")
        let events = recorder.events()
        let fileIndex = try XCTUnwrap(events.firstIndex(
            of: .file(CanonicalDurabilityRecorder.path(stateFile))))
        let directoryIndex = try XCTUnwrap(events.firstIndex(
            of: .directory(CanonicalDurabilityRecorder.path(stateDirectory))))
        let rootIndex = try XCTUnwrap(events.firstIndex(
            of: .directory(CanonicalDurabilityRecorder.path(root))))
        XCTAssertLessThan(fileIndex, directoryIndex)
        XCTAssertLessThan(directoryIndex, rootIndex)
        let snapshot = await journal.snapshot()
        XCTAssertEqual(snapshot.lifecycle, .starting)
    }

    func testPrepareFailsClosedWhenJournalFileCannotBeSynchronized() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = makeFixture()
        let recorder = CanonicalDurabilityRecorder()
        let stateFile = root
            .appendingPathComponent(".capture-journal", isDirectory: true)
            .appendingPathComponent(fixture.archiveId, isDirectory: true)
            .appendingPathComponent("state.json")
        recorder.failOnce(on: .file(CanonicalDurabilityRecorder.path(stateFile)))
        let journal = CaptureJournal(
            root: root, durability: recorder.value())

        do {
            _ = try await journal.prepare(
                manifest: fixture.manifest, session: fixture.session)
            XCTFail("prepare must not report success before journal durability")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveFilesystemDurabilityError,
                .synchronizationFailed)
        }
        let failedSnapshot = await journal.snapshot()
        XCTAssertEqual(failedSnapshot.lifecycle, .idle)
        XCTAssertNil(failedSnapshot.archiveId)
        XCTAssertNil(failedSnapshot.captureId)

        let recovered = try await CaptureJournal(
            root: root,
            durability: foundationTestFilesystemDurability()
        ).reopen(archiveId: fixture.archiveId)
        XCTAssertEqual(recovered.lifecycle, .recording)
    }

    func testArtifactBytesAndMetadataAreDurableBeforeCommitAndSurviveRelaunch()
        async throws
    {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = makeFixture()
        let journal = CaptureJournal(root: root)
        _ = try await journal.begin(manifest: fixture.manifest, session: fixture.session)

        let observationToken = try await journal.reserve(streamId: fixture.streamId)
        let observationId = Identifiers.newObservationId()
        let artifactToken = try await journal.reserveArtifact()
        let bytes = Data("artifact bytes captured offline".utf8)
        let artifact = try await journal.ingestArtifact(
            artifactToken,
            bytes: bytes,
            kind: "test_blob",
            mediaType: "application/octet-stream",
            sourceRefs: [JazzArchiveSourceRef(
                sourceId: fixture.sourceId, role: "capture")],
            actorRefs: [JazzArchiveActorRef(
                actorId: fixture.actorId,
                role: "performer",
                basis: .declared,
                method: "session_recorder")],
            observationRefs: [observationId],
            provenance: JazzArchiveProvenance(
                factClass: .observed, sources: [fixture.sourceId]),
            quality: JazzArchiveQuality(status: .complete),
            privacy: JazzArchivePrivacy(
                status: .captured, policyVersion: "consent-v1"))
        var observation = record(
            fixture,
            token: observationToken,
            observationId: observationId)
        observation.artifactRefs = [JazzArchiveArtifactRef(
            artifactId: artifact.artifactId, role: "attachment")]
        try await journal.resolveObservation(observationToken, record: observation)

        let store = JazzArchiveDraftStore(root: root)
        let persistedArtifact = try await store.artifact(
            archiveId: fixture.archiveId,
            captureId: fixture.captureId,
            artifactId: artifact.artifactId)
        XCTAssertEqual(persistedArtifact, artifact)
        let persistedBytes = try await store.artifactBytes(
            archiveId: fixture.archiveId,
            captureId: fixture.captureId,
            artifactId: artifact.artifactId)
        XCTAssertEqual(persistedBytes, bytes)

        let relaunched = CaptureJournal(root: root)
        let reopened = try await relaunched.reopen(archiveId: fixture.archiveId)
        XCTAssertEqual(reopened.resolvedArtifactCount, 1)
        XCTAssertEqual(reopened.pendingArtifactCount, 0)
        _ = try await relaunched.closeInput()
        _ = try await relaunched.beginDraining()
        let commit = try await relaunched.commit(endedAt: endedAt)
        XCTAssertEqual(commit.artifactCount, 1)
        XCTAssertEqual(commit.gaps, [])
    }

    func testCoordinatorWriterRehydratesFromJournalAndOfflineDoesNotBlockCommit()
        async throws
    {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = makeFixture()
        let journal = CaptureJournal(root: root)
        _ = try await journal.begin(manifest: fixture.manifest, session: fixture.session)
        let activityToken = try await journal.reserve(streamId: fixture.streamId)
        try await journal.resolveObservation(
            activityToken, record: record(fixture, token: activityToken))

        let context = CaptureCoachRecordContext(
            originId: fixture.originId,
            captureId: fixture.captureId,
            streamId: fixture.streamId,
            sourceRefs: [JazzArchiveSourceRef(
                sourceId: fixture.sourceId, role: "coach_control")],
            actorRefs: [JazzArchiveActorRef(
                actorId: fixture.actorId,
                role: "recipient",
                basis: .declared,
                method: "session_recorder")],
            provenance: JazzArchiveProvenance(
                factClass: .observed, sources: [fixture.sourceId]),
            quality: JazzArchiveQuality(status: .complete),
            privacy: JazzArchivePrivacy(
                status: .captured, policyVersion: "consent-v1"))
        let writer = CaptureCoachJournalWriter(journal: journal, context: context)
        let coordinator = try CaptureCoachCoordinator(
            captureId: fixture.captureId,
            policy: CaptureCoachPolicy(cooldownSeconds: 0),
            recorder: writer)
        let actionDate = Date(timeIntervalSince1970: 1_784_716_800)
        _ = try await coordinator.reportUnavailable(.offline, at: actionDate)
        let candidate = coachPrompt(fixture, throughSequence: 0)
        _ = try await coordinator.receive(candidate, at: actionDate.addingTimeInterval(1))
        _ = try await coordinator.dismiss(
            promptId: candidate.promptId, at: actionDate.addingTimeInterval(2))

        // Relaunch both actors and rebuild coordinator state solely from archive evidence.
        let relaunchedJournal = CaptureJournal(root: root)
        _ = try await relaunchedJournal.reopen(archiveId: fixture.archiveId)
        let relaunchedWriter = CaptureCoachJournalWriter(
            journal: relaunchedJournal, context: context)
        let recovered = try await CaptureCoachCoordinator.recovering(
            archiveId: fixture.archiveId,
            captureId: fixture.captureId,
            store: JazzArchiveDraftStore(root: root),
            policy: CaptureCoachPolicy(cooldownSeconds: 0),
            recorder: relaunchedWriter)
        let recoveredCoachSnapshot = await recovered.snapshot()
        XCTAssertNil(recoveredCoachSnapshot.outstandingPrompt)

        _ = try await relaunchedJournal.closeInput()
        _ = try await relaunchedJournal.beginDraining()
        let commit = try await relaunchedJournal.commit(endedAt: endedAt)
        XCTAssertEqual(commit.streamSummaries.first?.observationCount, 5)
        XCTAssertTrue(commit.gaps.isEmpty)
        let records = try await JazzArchiveDraftStore(root: root).allRecords(
            archiveId: fixture.archiveId, captureId: fixture.captureId)
        XCTAssertEqual(records.map(\.recordType), [
            ArchiveRecord<ActivityEvent>.activityRecordType,
            ArchiveRecord<CaptureCoachInteraction>.coachRecordType,
            ArchiveRecord<CaptureCoachInteraction>.coachRecordType,
            ArchiveRecord<CaptureCoachInteraction>.coachRecordType,
            ArchiveRecord<CaptureCoachInteraction>.coachRecordType,
        ])
        let coachTypes = try records.dropFirst().map {
            try $0.coachInteractionRecord().payload.interactionType
        }
        XCTAssertEqual(coachTypes, [.unavailable, .received, .shown, .dismissed])
        let coachActorRefs = try records.dropFirst().map {
            try $0.coachInteractionRecord().actorRefs
        }
        XCTAssertEqual(coachActorRefs.dropLast().map(\.count), [0, 0, 0])
        XCTAssertEqual(coachActorRefs.last, context.actorRefs)
    }

    func testCoachInteractionUsesTheSameDurableSequenceAndSurvivesIntentRecovery()
        async throws
    {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = makeFixture()
        let journal = CaptureJournal(root: root)
        _ = try await journal.begin(manifest: fixture.manifest, session: fixture.session)

        let activityToken = try await journal.reserve(streamId: fixture.streamId)
        try await journal.resolveObservation(
            activityToken, record: record(fixture, token: activityToken))
        let coachToken = try await journal.reserve(streamId: fixture.streamId)
        let coach = coachRecord(fixture, token: coachToken)

        // Force a failure after the journal has persisted the coach intent but before archive append.
        let draft = root.appendingPathComponent(
            "\(fixture.archiveId).jazz-archive.draft", isDirectory: true)
        let heldDraft = root.appendingPathComponent("held-coach-draft", isDirectory: true)
        try FileManager.default.moveItem(at: draft, to: heldDraft)
        do {
            try await journal.resolveObservation(coachToken, record: coach)
            XCTFail("expected archiveNotFound")
        } catch {
            XCTAssertEqual(error as? JazzArchiveError, .archiveNotFound(fixture.archiveId))
        }
        try FileManager.default.moveItem(at: heldDraft, to: draft)

        let relaunched = CaptureJournal(root: root)
        let recovered = try await relaunched.reopen(archiveId: fixture.archiveId)
        XCTAssertEqual(recovered.resolvedObservationCount, 2)

        let store = JazzArchiveDraftStore(root: root)
        let allRecords = try await store.allRecords(
            archiveId: fixture.archiveId, captureId: fixture.captureId)
        XCTAssertEqual(allRecords.map(\.recordType), [
            ArchiveRecord<ActivityEvent>.activityRecordType,
            ArchiveRecord<CaptureCoachInteraction>.coachRecordType,
        ])
        XCTAssertEqual(try allRecords[1].coachInteractionRecord(), coach)
        let activityOnly = try await store.records(
            archiveId: fixture.archiveId, captureId: fixture.captureId)
        XCTAssertEqual(activityOnly.map(\.streamSequence), [0])

        _ = try await relaunched.closeInput()
        _ = try await relaunched.beginDraining()
        let commit = try await relaunched.commit(endedAt: endedAt)
        XCTAssertEqual(commit.streamSummaries.first?.observationCount, 2)
        XCTAssertTrue(commit.gaps.isEmpty)
    }

    func testIdleAndStartingRecoveryCreatesDraftBeforeRecording() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = makeFixture()
        let journal = CaptureJournal(root: root)

        let idle = await journal.snapshot()
        XCTAssertEqual(idle.lifecycle, .idle)
        let starting = try await journal.prepare(
            manifest: fixture.manifest, session: fixture.session)
        XCTAssertEqual(starting.lifecycle, .starting)
        let recoverable = await journal.recoverableArchiveIds()
        XCTAssertEqual(recoverable, [fixture.archiveId])

        // A new actor represents a process relaunch: `starting` completes idempotently.
        let relaunched = CaptureJournal(root: root)
        let recovered = try await relaunched.reopen(archiveId: fixture.archiveId)
        XCTAssertEqual(recovered.lifecycle, .recording)
        XCTAssertEqual(recovered.nextSequenceByStream, [fixture.streamId: 0])
        _ = try await JazzArchiveDraftStore(root: root).manifest(archiveId: fixture.archiveId)
    }

    func testRecordingClosingInputAndDrainingSurviveRelaunch() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = makeFixture()
        let journal = CaptureJournal(root: root)
        let recording = try await journal.begin(
            manifest: fixture.manifest, session: fixture.session)
        XCTAssertEqual(recording.lifecycle, .recording)

        var relaunched = CaptureJournal(root: root)
        var recovered = try await relaunched.reopen(archiveId: fixture.archiveId)
        XCTAssertEqual(recovered.lifecycle, .recording)

        recovered = try await relaunched.closeInput()
        XCTAssertEqual(recovered.lifecycle, .closingInput)
        relaunched = CaptureJournal(root: root)
        recovered = try await relaunched.reopen(archiveId: fixture.archiveId)
        XCTAssertEqual(recovered.lifecycle, .closingInput)

        recovered = try await relaunched.beginDraining()
        XCTAssertEqual(recovered.lifecycle, .draining)
        relaunched = CaptureJournal(root: root)
        recovered = try await relaunched.reopen(archiveId: fixture.archiveId)
        XCTAssertEqual(recovered.lifecycle, .draining)
    }

    func testInterruptedRecoveryCommitsResolvedEvidenceAndExplicitlyGapsLateWork()
        async throws
    {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = makeFixture()
        let journal = CaptureJournal(root: root)
        _ = try await journal.begin(manifest: fixture.manifest, session: fixture.session)
        let completed = try await journal.reserve(streamId: fixture.streamId)
        try await journal.resolveObservation(
            completed, record: record(fixture, token: completed))
        _ = try await journal.reserve(streamId: fixture.streamId)
        _ = try await journal.reserveArtifact(
            metadata: ["kind": .string("screenshot")])

        let relaunched = CaptureJournal(root: root)
        let commit = try await relaunched.recoverInterrupted(
            archiveId: fixture.archiveId,
            endedAt: "2026-07-22T12:00:00.000Z")
        XCTAssertEqual(commit.streamSummaries.first?.observationCount, 1)
        XCTAssertEqual(commit.gaps.count, 1)
        XCTAssertEqual(commit.gaps.first?.firstSequence, 1)
        XCTAssertEqual(commit.gaps.first?.reason, .recoveryTruncation)
        XCTAssertEqual(commit.artifactCount, 0)
        let snapshot = await relaunched.snapshot()
        XCTAssertEqual(snapshot.lifecycle, .committed)
        let session = try await JazzArchiveDraftStore(root: root).session(
            archiveId: fixture.archiveId, captureId: fixture.captureId)
        XCTAssertEqual(session.status, .recovered)
        let recoverable = await relaunched.recoverableArchiveIds()
        XCTAssertTrue(recoverable.isEmpty)
    }

    func testCommittedStateSurvivesRelaunchAndRejectsAllFurtherWork() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = makeFixture()
        let journal = CaptureJournal(root: root)
        _ = try await journal.begin(manifest: fixture.manifest, session: fixture.session)
        let token = try await journal.reserve(streamId: fixture.streamId)
        let observation = record(fixture, token: token)
        try await journal.resolveObservation(token, record: observation)
        _ = try await journal.closeInput()
        _ = try await journal.beginDraining()
        let commit = try await journal.commit(endedAt: endedAt)
        XCTAssertEqual(commit.streamSummaries.first?.observationCount, 1)
        let recoverable = await journal.recoverableArchiveIds()
        XCTAssertEqual(recoverable, [])

        do {
            try await journal.resolveObservation(token, record: observation)
            XCTFail("expected appendAfterCommit")
        } catch {
            XCTAssertEqual(error as? CaptureJournalError, .appendAfterCommit)
        }
        do {
            _ = try await journal.reserve(streamId: fixture.streamId)
            XCTFail("expected appendAfterCommit")
        } catch {
            XCTAssertEqual(error as? CaptureJournalError, .appendAfterCommit)
        }

        let relaunched = CaptureJournal(root: root)
        let recovered = try await relaunched.reopen(archiveId: fixture.archiveId)
        XCTAssertEqual(recovered.lifecycle, .committed)
        XCTAssertEqual(recovered.resolvedObservationCount, 1)
    }

    func testCommitRejectsPendingReservationsAndArtifactsThenCommitsResolvedMetadata()
        async throws
    {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = makeFixture()
        let journal = CaptureJournal(root: root)
        _ = try await journal.begin(manifest: fixture.manifest, session: fixture.session)

        let observationToken = try await journal.reserve(streamId: fixture.streamId)
        try await journal.resolveObservation(
            observationToken, record: record(fixture, token: observationToken))
        let pendingToken = try await journal.reserve(streamId: fixture.streamId)
        let artifactToken = try await journal.reserveArtifact(
            metadata: ["mediaType": .string("image/png")])
        _ = try await journal.closeInput()
        _ = try await journal.beginDraining()

        do {
            _ = try await journal.commit(endedAt: endedAt)
            XCTFail("expected pending work")
        } catch {
            XCTAssertEqual(
                error as? CaptureJournalError,
                .pendingWork(reservations: 1, artifacts: 1))
        }

        try await journal.resolveGap(
            pendingToken, reason: .captureLoss, detail: "producer terminated")
        let digest = String(repeating: "a", count: 64)
        try await journal.resolveArtifact(
            artifactToken, sha256: digest, byteLength: 42)
        // Exact duplicate completion is idempotent.
        try await journal.resolveArtifact(
            artifactToken, sha256: digest, byteLength: 42)
        let commit = try await journal.commit(endedAt: endedAt)
        XCTAssertEqual(commit.artifactCount, 1)
        XCTAssertEqual(commit.gaps.first?.reason, .captureLoss)
    }

    func testReservationOrderAndDeclaredLeadingTrailingGapReasonsReachCommit() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = makeFixture()
        let journal = CaptureJournal(root: root)
        _ = try await journal.begin(manifest: fixture.manifest, session: fixture.session)

        let leading = try await journal.reserve(streamId: fixture.streamId)
        let observed = try await journal.reserve(streamId: fixture.streamId)
        let trailing = try await journal.reserve(streamId: fixture.streamId)
        XCTAssertEqual(
            [leading.streamSequence, observed.streamSequence, trailing.streamSequence],
            [0, 1, 2])
        try await journal.resolveGap(
            leading, reason: .permissionDenied, detail: "screen recording unavailable")
        try await journal.resolveObservation(observed, record: record(fixture, token: observed))
        try await journal.resolveGap(trailing, reason: .sourceUnavailable, detail: "display detached")
        _ = try await journal.closeInput()
        _ = try await journal.beginDraining()

        let commit = try await journal.commit(endedAt: endedAt)
        XCTAssertEqual(commit.streamSummaries, [JazzArchiveStreamSummary(
            streamId: fixture.streamId,
            firstSequence: 0,
            lastSequence: 2,
            observationCount: 1)])
        XCTAssertEqual(commit.gaps, [
            JazzArchiveSequenceGap(
                streamId: fixture.streamId,
                firstSequence: 0,
                lastSequence: 0,
                reason: .permissionDenied,
                detail: "screen recording unavailable"),
            JazzArchiveSequenceGap(
                streamId: fixture.streamId,
                firstSequence: 2,
                lastSequence: 2,
                reason: .sourceUnavailable,
                detail: "display detached"),
        ])
    }

    func testDeclaredGapCannotCoverAnObservation() throws {
        let fixture = makeFixture()
        let observation = record(fixture, streamSequence: 0)
        XCTAssertThrowsError(try JazzArchiveCaptureCommit.make(
            captureId: fixture.captureId,
            revision: 1,
            endedAt: endedAt,
            records: [observation],
            declaredGaps: [JazzArchiveSequenceGap(
                streamId: fixture.streamId,
                firstSequence: 0,
                lastSequence: 0,
                reason: .intentionallyOmitted)]
        )) { error in
            XCTAssertEqual(
                error as? JazzArchiveError,
                .invalidField("captureCommit.declaredGaps"))
        }
    }

    func testObservationDuplicateIsIdempotentConflictIsRejectedAndOldTokenBecomesStale()
        async throws
    {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = makeFixture()
        let journal = CaptureJournal(root: root)
        _ = try await journal.begin(manifest: first.manifest, session: first.session)
        let token = try await journal.reserve(streamId: first.streamId)
        let observation = record(first, token: token)
        try await journal.resolveObservation(token, record: observation)
        try await journal.resolveObservation(token, record: observation)

        do {
            try await journal.resolveObservation(
                token,
                record: record(first, token: token, eventType: "key_press"))
            XCTFail("expected completion conflict")
        } catch {
            XCTAssertEqual(
                error as? CaptureJournalError,
                .completionConflict(token.reservationId))
        }
        let records = try await JazzArchiveDraftStore(root: root).records(
            archiveId: first.archiveId, captureId: first.captureId)
        XCTAssertEqual(records.count, 1)

        _ = try await journal.closeInput()
        _ = try await journal.beginDraining()
        _ = try await journal.commit(endedAt: endedAt)

        let second = makeFixture()
        _ = try await journal.begin(manifest: second.manifest, session: second.session)
        do {
            try await journal.resolveObservation(token, record: observation)
            XCTFail("expected stale reservation")
        } catch {
            XCTAssertEqual(
                error as? CaptureJournalError,
                .staleReservation(token.reservationId))
        }
    }

    func testRelaunchRecoversIntentBeforeArchiveAppend() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = makeFixture()
        let journal = CaptureJournal(root: root)
        _ = try await journal.begin(manifest: fixture.manifest, session: fixture.session)
        let token = try await journal.reserve(streamId: fixture.streamId)
        let observation = record(fixture, token: token)

        let draft = root.appendingPathComponent(
            "\(fixture.archiveId).jazz-archive.draft", isDirectory: true)
        let heldDraft = root.appendingPathComponent("held-draft", isDirectory: true)
        try FileManager.default.moveItem(at: draft, to: heldDraft)
        do {
            try await journal.resolveObservation(token, record: observation)
            XCTFail("expected archiveNotFound")
        } catch {
            XCTAssertEqual(error as? JazzArchiveError, .archiveNotFound(fixture.archiveId))
        }
        try FileManager.default.moveItem(at: heldDraft, to: draft)

        let relaunched = CaptureJournal(root: root)
        let recovered = try await relaunched.reopen(archiveId: fixture.archiveId)
        XCTAssertEqual(recovered.pendingReservationCount, 0)
        XCTAssertEqual(recovered.resolvedObservationCount, 1)
        let records = try await JazzArchiveDraftStore(root: root).records(
            archiveId: fixture.archiveId, captureId: fixture.captureId)
        XCTAssertEqual(records, [observation])
    }

    func testDeferredBatchFsyncFailureIsRetriedAndNeverLosesCanonicalEvidence()
        async throws
    {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = makeFixture()
        let durability = CanonicalDurabilityRecorder()
        let journal = CaptureJournal(root: root, durability: durability.value())
        _ = try await journal.begin(manifest: fixture.manifest, session: fixture.session)
        let token = try await journal.reserve(streamId: fixture.streamId)
        let observation = record(fixture, token: token)
        let batchId = "batch-\(token.reservationId.dropFirst("res-".count))"
        let batchURL =
            root
            .appendingPathComponent(
                "\(fixture.archiveId).jazz-archive.draft",
                isDirectory: true)
            .appendingPathComponent(fixture.manifest.sessions[0].path)
            .deletingLastPathComponent()
            .appendingPathComponent("records", isDirectory: true)
            .appendingPathComponent("\(batchId).ndjson")
        durability.failOnce(on: .file(CanonicalDurabilityRecorder.path(batchURL)))

        do {
            try await journal.resolveObservation(token, record: observation)
            XCTFail("the producer must not be acknowledged before the batch fsync")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveFilesystemDurabilityError,
                .synchronizationFailed)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: batchURL.path))

        let relaunched = CaptureJournal(
            root: root,
            durability: foundationTestFilesystemDurability())
        let recovered = try await relaunched.reopen(archiveId: fixture.archiveId)
        XCTAssertEqual(recovered.resolvedObservationCount, 1)
        XCTAssertEqual(recovered.pendingReservationCount, 0)
        let persisted = try await JazzArchiveDraftStore(root: root).allRecords(
            archiveId: fixture.archiveId,
            captureId: fixture.captureId)
        XCTAssertEqual(
            persisted,
            [try JazzArchiveRecord(erasing: observation)])
    }

    func testRelaunchDeduplicatesIntentAlreadyAppendedBeforeAcknowledgement() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = makeFixture()
        let journal = CaptureJournal(root: root)
        _ = try await journal.begin(manifest: fixture.manifest, session: fixture.session)
        let token = try await journal.reserve(streamId: fixture.streamId)
        let observation = record(fixture, token: token)
        try await journal.resolveObservation(token, record: observation)

        // Simulate a kill after the archive append but before the durable acknowledgement by
        // retiring only the final immutable WAL acknowledgement segment.
        let walURL = root
            .appendingPathComponent(".capture-journal", isDirectory: true)
            .appendingPathComponent(fixture.archiveId, isDirectory: true)
            .appendingPathComponent("wal", isDirectory: true)
        let segments = try FileManager.default.contentsOfDirectory(
            at: walURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertEqual(segments.count, 3)
        try FileManager.default.removeItem(at: try XCTUnwrap(segments.last))

        let relaunched = CaptureJournal(root: root)
        let recovered = try await relaunched.reopen(archiveId: fixture.archiveId)
        XCTAssertEqual(recovered.pendingReservationCount, 0)
        XCTAssertEqual(recovered.resolvedObservationCount, 1)
        let records = try await JazzArchiveDraftStore(root: root).records(
            archiveId: fixture.archiveId, captureId: fixture.captureId)
        XCTAssertEqual(records, [observation])
    }

    func testRelaunchFinishesPersistedCommitIntentIdempotently() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = makeFixture()
        let journal = CaptureJournal(root: root)
        _ = try await journal.begin(manifest: fixture.manifest, session: fixture.session)
        let token = try await journal.reserve(streamId: fixture.streamId)
        try await journal.resolveObservation(token, record: record(fixture, token: token))
        _ = try await journal.closeInput()
        _ = try await journal.beginDraining()
        let originalCommit = try await journal.commit(endedAt: endedAt)

        // Simulate a kill after store.end but before the journal's committed acknowledgement.
        let stateURL = root
            .appendingPathComponent(".capture-journal", isDirectory: true)
            .appendingPathComponent(fixture.archiveId, isDirectory: true)
            .appendingPathComponent("state.json")
        var state = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        state["lifecycle"] = "draining"
        let interruptedState = try JSONSerialization.data(
            withJSONObject: state, options: [.sortedKeys])
        try interruptedState.write(to: stateURL, options: .atomic)

        let relaunched = CaptureJournal(root: root)
        let recovered = try await relaunched.reopen(archiveId: fixture.archiveId)
        XCTAssertEqual(recovered.lifecycle, .committed)
        let recoveredCommit = try await JazzArchiveDraftStore(root: root).captureCommit(
            archiveId: fixture.archiveId, captureId: fixture.captureId)
        XCTAssertEqual(recoveredCommit.commitId, originalCommit.commitId)
    }
}
