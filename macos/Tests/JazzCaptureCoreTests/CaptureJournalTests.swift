import XCTest

@testable import JazzCaptureCore

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

    func testNarrationSealBeforeIntentRecovery() async throws {
        try await checkNarrationClosedRecovery(admissionFailed: false)
    }

    func testNarrationAdmissionFailedClosedRecovery() async throws {
        try await checkNarrationClosedRecovery(admissionFailed: true)
    }

    private func checkNarrationClosedRecovery(admissionFailed: Bool) async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = narrationFixture()
        let journal = CaptureJournal(root: root)
        _ = try await journal.begin(manifest: fixture.manifest, session: fixture.session)
        let bytes = Data("sole narration bytes".utf8)
        let metadata = narrationMetadata(fixture)
        let writable = try JazzArchiveWritableFileClaim.prepare(
            root: root, archiveId: fixture.archiveId, captureId: fixture.captureId,
            artifactId: metadata.artifactId, fileExtension: "m4a")
        let digest = try writable.recordNarrationStart(metadata, durability: narrationDurability)
        try bytes.write(to: writable.recordingURL)
        if admissionFailed { await journal.revoke() }
        let recordedStart = "2026-07-22T10:00:03.000Z"
        try writable.recordNarrationStop(
            startedAt: recordedStart, endedAt: endedAt, admissionDigest: digest, durability: narrationDurability)
        let sealed = try writable.seal()
        await journal.revoke()
        let recovery = CaptureJournal(root: root)
        let reopened = try await recovery.reopen(archiveId: fixture.archiveId)
        XCTAssertEqual(reopened.resolvedArtifactCount, 1)
        XCTAssertEqual(reopened.resolvedObservationCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sealed.url.path))
        let store = JazzArchiveDraftStore(root: root)
        let artifacts = try await store.artifacts(archiveId: fixture.archiveId, captureId: fixture.captureId)
        XCTAssertEqual(artifacts, [metadata.artifact(claim: sealed, startedAt: recordedStart, endedAt: endedAt)])
        let blob = root.appendingPathComponent("\(fixture.archiveId).jazz-archive.draft")
            .appendingPathComponent(artifacts[0].content.path)
        XCTAssertEqual(try Data(contentsOf: blob), bytes)
        await recovery.revoke()
        let restarted = CaptureJournal(root: root)
        let again = try await restarted.reopen(archiveId: fixture.archiveId)
        XCTAssertEqual(again, reopened)
        let commit = try await restarted.recoverInterrupted(archiveId: fixture.archiveId)
        XCTAssertEqual(commit.artifactCount, 1)
        let records = try await store.records(archiveId: fixture.archiveId, captureId: fixture.captureId)
        XCTAssertEqual(Set(records.map(\.observationId)), [metadata.observationId, metadata.labelStartObservationId])
        XCTAssertEqual(records.map(\.payload.timestamp), [startedAt, recordedStart])
    }

    func testNarrationIncompleteCrashBoundariesNeverInventClosedAudio() async throws {
        for edge in ["prepared", "admission", "recording", "sealed-without-stop", "stop-before-receipt"] {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = narrationFixture()
            let journal = CaptureJournal(root: root)
            _ = try await journal.begin(manifest: fixture.manifest, session: fixture.session)
            let metadata = narrationMetadata(fixture)
            let writable = try JazzArchiveWritableFileClaim.prepare(
                root: root, archiveId: fixture.archiveId, captureId: fixture.captureId,
                artifactId: metadata.artifactId, fileExtension: "m4a")
            if edge != "prepared" {
                _ = try writable.recordNarrationStart(metadata, durability: narrationDurability)
            }
            let bytes = edge == "prepared" || edge == "admission" ? Data() : Data("unverified crash audio".utf8)
            try bytes.write(to: writable.recordingURL)
            let media = edge == "sealed-without-stop" ? try writable.seal().url : writable.recordingURL
            await journal.revoke()
            let recovery = CaptureJournal(root: root)
            do {
                _ = try await recovery.reopen(archiveId: fixture.archiveId)
                XCTFail("invented closure at \(edge)")
            } catch let error as CaptureJournalError {
                guard case .retainedClaims = error else { throw error }
                if edge != "prepared" { XCTAssertTrue(error.description.contains("no durable recorder stop")) }
            }
            XCTAssertEqual(try Data(contentsOf: media), bytes, edge)
            let artifacts = try await JazzArchiveDraftStore(root: root).artifacts(
                archiveId: fixture.archiveId, captureId: fixture.captureId)
            XCTAssertTrue(artifacts.isEmpty, edge)
        }
    }

    func testNarrationClosedCrashEdgesReplayExactlyOnce() async throws {
        for edge in ["before-seal", "after-rename", "seal-fsync", "reserved", "staged", "ingest-intent", "published", "recovery-checkpoint"] {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = narrationFixture()
            let durability = JazzArchiveFilesystemDurability(synchronizeRegularFile: { url, _ in
                if edge == "published", url.path.contains("/wal/"),
                    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
                    let mutation = json["mutation"] as? [String: Any],
                    let update = mutation["updateArtifact"] as? [String: Any],
                    let entry = update["entry"] as? [String: Any], entry["status"] as? String == "resolved" {
                    throw JazzArchiveFilesystemDurabilityError.synchronizationFailed
                }
            }, synchronizeDirectory: { _ in })
            let journal = CaptureJournal(root: root, durability: durability)
            _ = try await journal.begin(manifest: fixture.manifest, session: fixture.session)
            let metadata = narrationMetadata(fixture)
            let writable = try JazzArchiveWritableFileClaim.prepare(
                root: root, archiveId: fixture.archiveId, captureId: fixture.captureId,
                artifactId: metadata.artifactId, fileExtension: "m4a")
            let digest = try writable.recordNarrationStart(metadata, durability: narrationDurability)
            let bytes = Data("closed audio at \(edge)".utf8)
            try bytes.write(to: writable.recordingURL)
            try writable.recordNarrationStop(startedAt: startedAt, endedAt: endedAt, admissionDigest: digest, durability: narrationDurability)
            var claim: JazzArchiveClaimedFile?
            if edge == "after-rename" {
                try FileManager.default.moveItem(at: writable.recordingURL, to: writable.sealedURL)
            } else if edge == "seal-fsync" {
                XCTAssertThrowsError(try writable.seal(durability: JazzArchiveFilesystemDurability(
                    synchronizeRegularFile: { _, _ in throw JazzArchiveFilesystemDurabilityError.synchronizationFailed },
                    synchronizeDirectory: { _ in })))
            } else if edge != "before-seal" {
                claim = try writable.seal()
            }
            if ["reserved", "staged", "ingest-intent", "published"].contains(edge) {
                let label = try await journal.reserve(streamId: fixture.streamId)
                try await journal.resolveObservation(label, record: metadata.record(sequence: label.streamSequence, labelStart: true))
                let observation = try await journal.reserve(streamId: fixture.streamId)
                let artifact = try await journal.reserveArtifact(artifactId: metadata.artifactId)
                if edge != "reserved" {
                    try await journal.stageObservation(observation, record: metadata.record(sequence: observation.streamSequence))
                }
                if edge == "ingest-intent" || edge == "published" {
                    let obstruction = root.appendingPathComponent("\(fixture.archiveId).jazz-archive.draft/blobs")
                    if edge == "ingest-intent" { try Data("fault".utf8).write(to: obstruction) }
                    do {
                        _ = try await ingestNarration(journal, token: artifact, metadata: metadata, claim: XCTUnwrap(claim))
                        XCTFail("expected persistence fault: \(edge)")
                    } catch { }
                    if edge == "ingest-intent" { try FileManager.default.removeItem(at: obstruction) }
                }
            }
            await journal.revoke()
            if edge == "recovery-checkpoint" {
                let failing = CaptureJournal(root: root, durability: JazzArchiveFilesystemDurability(
                    synchronizeRegularFile: { url, _ in
                        if url.lastPathComponent == "state.json" { throw JazzArchiveFilesystemDurabilityError.synchronizationFailed }
                    }, synchronizeDirectory: { _ in }))
                do {
                    _ = try await failing.reopen(archiveId: fixture.archiveId)
                    XCTFail("expected checkpoint fsync fault")
                } catch { }
                XCTAssertEqual(try Data(contentsOf: writable.sealedURL), bytes)
            }
            let recovery = CaptureJournal(root: root)
            let first = try await recovery.reopen(archiveId: fixture.archiveId)
            XCTAssertEqual(first.resolvedArtifactCount, 1, edge)
            XCTAssertEqual(first.resolvedObservationCount, 2, edge)
            let store = JazzArchiveDraftStore(root: root)
            let artifacts = try await store.artifacts(archiveId: fixture.archiveId, captureId: fixture.captureId)
            XCTAssertEqual(artifacts.count, 1, edge)
            XCTAssertEqual(artifacts[0].captureInterval, JazzArchiveArtifactCaptureInterval(startedAt: startedAt, endedAt: endedAt), edge)
            let blob = root.appendingPathComponent("\(fixture.archiveId).jazz-archive.draft").appendingPathComponent(artifacts[0].content.path)
            XCTAssertEqual(try Data(contentsOf: blob), bytes, edge)
            XCTAssertFalse(FileManager.default.fileExists(atPath: writable.recordingURL.path), edge)
            XCTAssertFalse(FileManager.default.fileExists(atPath: writable.sealedURL.path), edge)
            await recovery.revoke()
            let restarted = CaptureJournal(root: root)
            let again = try await restarted.reopen(archiveId: fixture.archiveId)
            XCTAssertEqual(first, again, edge)
            _ = try await restarted.recoverInterrupted(archiveId: fixture.archiveId)
        }
    }

    func testNarrationReceiptsRejectTamperingAndForeignClaimsWithoutDeletingBytes() async throws {
        for attack in ["start-label", "start-time", "source-rebound", "foreign-claim", "closed-time", "negative-interval-rebound", "changed-file", "receipt-symlink", "unconsented-modality"] {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            var fixture = narrationFixture()
            if attack == "unconsented-modality" { fixture.session.capturePolicy.modalities.removeAll { $0 == .narration } }
            let journal = CaptureJournal(root: root)
            _ = try await journal.begin(manifest: fixture.manifest, session: fixture.session)
            let metadata = narrationMetadata(fixture)
            let writable = try JazzArchiveWritableFileClaim.prepare(
                root: root, archiveId: fixture.archiveId, captureId: fixture.captureId,
                artifactId: metadata.artifactId, fileExtension: "m4a")
            let digest = try writable.recordNarrationStart(metadata, durability: narrationDurability)
            let original = Data("original audio: \(attack)".utf8)
            try original.write(to: writable.recordingURL)
            try writable.recordNarrationStop(startedAt: startedAt, endedAt: endedAt, admissionDigest: digest, durability: narrationDurability)
            let claim = try writable.seal()
            await journal.revoke()
            let directory = try CaptureJournalNarrationReceipt.directory(root: root, archiveId: fixture.archiveId, captureId: fixture.captureId)
            let startURL = try CaptureJournalNarrationReceipt.url(directory: directory, artifactId: metadata.artifactId)
            let closedURL = try CaptureJournalNarrationReceipt.url(directory: directory, artifactId: metadata.artifactId, closed: true)
            var start = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: startURL)) as? [String: Any])
            var closed = try JSONDecoder().decode(CaptureJournalNarrationReceipt.Closed.self, from: Data(contentsOf: closedURL))
            var startMetadata = try XCTUnwrap(start["metadata"] as? [String: Any])
            if attack == "start-label" || attack == "start-time" {
                var event = try XCTUnwrap(startMetadata["event"] as? [String: Any])
                event[attack == "start-label" ? "label" : "timestamp"] = attack == "start-label" ? "forged label" : endedAt
                startMetadata["event"] = event
            } else if attack == "source-rebound" {
                var context = try XCTUnwrap(startMetadata["context"] as? [String: Any])
                context["sourceId"] = Identifiers.newSourceId()
                startMetadata["context"] = context
            }
            start["metadata"] = startMetadata
            var expectedBytes = original
            if attack == "foreign-claim" {
                let foreignRoot = root.appendingPathComponent("foreign")
                let foreign = try sealedClaim(root: foreignRoot, fixture: fixture, artifactId: metadata.artifactId, bytes: original)
                start["sealedURL"] = foreign.url.absoluteString
                closed.claim = foreign
            } else if attack == "closed-time" {
                closed.endedAt = "2026-07-22T10:02:00.000Z"
            } else if attack == "negative-interval-rebound" {
                closed.endedAt = "2026-07-22T09:59:59.000Z"
            } else if attack == "changed-file" {
                expectedBytes = Data("changed bytes must also survive".utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: claim.url.path)
                try expectedBytes.write(to: claim.url)
            }
            let startBytes = try JSONSerialization.data(withJSONObject: start, options: [.sortedKeys])
            try startBytes.write(to: startURL, options: .atomic)
            if ["source-rebound", "foreign-claim", "negative-interval-rebound"].contains(attack) {
                let receipt = try JSONDecoder().decode(CaptureJournalNarrationReceipt.self, from: startBytes)
                closed.admissionDigest = try receipt.digest
                closed.contentSHA256 = try closed.digest
            }
            try JSONEncoder().encode(closed).write(to: closedURL, options: .atomic)
            if attack == "receipt-symlink" {
                let target = root.appendingPathComponent("foreign-start.json")
                try FileManager.default.moveItem(at: startURL, to: target)
                try FileManager.default.createSymbolicLink(at: startURL, withDestinationURL: target)
            }
            let recovery = CaptureJournal(root: root)
            do {
                _ = try await recovery.reopen(archiveId: fixture.archiveId)
                XCTFail("accepted \(attack)")
            } catch { }
            XCTAssertEqual(try Data(contentsOf: claim.url), expectedBytes, attack)
            if attack == "foreign-claim" { XCTAssertEqual(try Data(contentsOf: closed.claim.url), original) }
            let artifacts = try await JazzArchiveDraftStore(root: root).artifacts(archiveId: fixture.archiveId, captureId: fixture.captureId)
            XCTAssertTrue(artifacts.isEmpty, attack)
        }
    }

    func testNarrationReceiptBindsWALAndCheckpointIntents() async throws {
        for checkpoint in [false, true] {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = narrationFixture()
            let journal = CaptureJournal(root: root)
            _ = try await journal.begin(manifest: fixture.manifest, session: fixture.session)
            let metadata = narrationMetadata(fixture)
            let writable = try JazzArchiveWritableFileClaim.prepare(
                root: root, archiveId: fixture.archiveId, captureId: fixture.captureId,
                artifactId: metadata.artifactId, fileExtension: "m4a")
            let digest = try writable.recordNarrationStart(metadata, durability: narrationDurability)
            let bytes = Data("immutable narration intent".utf8)
            try bytes.write(to: writable.recordingURL)
            try writable.recordNarrationStop(startedAt: startedAt, endedAt: endedAt, admissionDigest: digest, durability: narrationDurability)
            let claim = try writable.seal()
            let token = try await journal.reserveArtifact(artifactId: metadata.artifactId)
            let obstruction = root.appendingPathComponent("\(fixture.archiveId).jazz-archive.draft/blobs")
            try Data("fault".utf8).write(to: obstruction)
            do {
                _ = try await ingestNarration(journal, token: token, metadata: metadata, claim: claim)
                XCTFail("expected publication fault")
            } catch { }
            await journal.revoke()
            try FileManager.default.removeItem(at: obstruction)
            let stateDirectory = root.appendingPathComponent(".capture-journal/\(fixture.archiveId)")
            let target: URL
            if checkpoint {
                let failing = CaptureJournal(root: root, durability: JazzArchiveFilesystemDurability(
                    synchronizeRegularFile: { url, _ in
                        if url.lastPathComponent == "state.json" { throw JazzArchiveFilesystemDurabilityError.synchronizationFailed }
                    }, synchronizeDirectory: { _ in }))
                do { _ = try await failing.reopen(archiveId: fixture.archiveId); XCTFail("expected checkpoint fault") } catch { }
                target = stateDirectory.appendingPathComponent("state.json")
            } else {
                target = try XCTUnwrap(FileManager.default.contentsOfDirectory(
                    at: stateDirectory.appendingPathComponent("wal"), includingPropertiesForKeys: nil).sorted { $0.path < $1.path }.last)
            }
            var state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: target)) as? [String: Any])
            var mutation = state["mutation"] as? [String: Any] ?? [:]
            var update = mutation["updateArtifact"] as? [String: Any] ?? [:]
            var entry = try XCTUnwrap(checkpoint ? (state["artifacts"] as? [[String: Any]])?.first : update["entry"] as? [String: Any])
            var intent = try XCTUnwrap(entry["ingestIntent"] as? [String: Any])
            var artifact = try XCTUnwrap(intent["artifact"] as? [String: Any])
            var interval = try XCTUnwrap(artifact["captureInterval"] as? [String: Any])
            interval["endedAt"] = "2026-07-22T10:02:00.000Z"
            artifact["captureInterval"] = interval
            intent["artifact"] = artifact
            entry["ingestIntent"] = intent
            if checkpoint { state["artifacts"] = [entry] } else {
                update["entry"] = entry
                mutation["updateArtifact"] = update
                state["mutation"] = mutation
            }
            let tampered = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
            try tampered.write(to: target, options: .atomic)
            let recovery = CaptureJournal(root: root)
            do { _ = try await recovery.reopen(archiveId: fixture.archiveId); XCTFail("accepted substitution") } catch { }
            XCTAssertEqual(try Data(contentsOf: claim.url), bytes)
            XCTAssertEqual(try Data(contentsOf: target), tampered)
            let artifacts = try await JazzArchiveDraftStore(root: root).artifacts(archiveId: fixture.archiveId, captureId: fixture.captureId)
            XCTAssertTrue(artifacts.isEmpty)
        }
    }

    func testNarrationRuntimeUsesAdmissionIdentityAndRejectsMetadataSubstitution() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = narrationFixture()
        let journal = CaptureJournal(root: root)
        _ = try await journal.begin(manifest: fixture.manifest, session: fixture.session)
        let metadata = narrationMetadata(fixture)
        let runtime = CaptureJournalRuntime(journal: journal, context: metadata.context)
        _ = try await runtime.submit { _ in .observation(CaptureJournalActivityObservation(
            event: metadata.labelStartEvent, observationId: metadata.labelStartObservationId,
            extensions: metadata.labelStartExtensions)) }
        let writable = try JazzArchiveWritableFileClaim.prepare(root: root, archiveId: fixture.archiveId,
            captureId: fixture.captureId, artifactId: metadata.artifactId, fileExtension: "m4a")
        let digest = try writable.recordNarrationStart(metadata, durability: narrationDurability)
        let bytes = Data("normal runtime narration".utf8)
        try bytes.write(to: writable.recordingURL)
        let recordedStart = "2026-07-22T10:00:03.000Z"
        try writable.recordNarrationStop(startedAt: recordedStart, endedAt: endedAt, admissionDigest: digest, durability: narrationDurability)
        let claim = try writable.seal()
        let badToken = try await journal.reserve(streamId: fixture.streamId)
        var forgedRecord = metadata.record(sequence: badToken.streamSequence)
        forgedRecord.payload.label = "substituted label"
        do { try await journal.stageObservation(badToken, record: forgedRecord); XCTFail("accepted substituted observation") } catch { }
        try await journal.resolveGap(badToken, reason: .captureLoss)
        let interval = JazzArchiveArtifactCaptureInterval(startedAt: recordedStart, endedAt: endedAt)
        let narrationEvent = metadata.record(sequence: 0, startedAt: recordedStart).payload
        _ = try await runtime.submit { _ in .observation(CaptureJournalActivityObservation(
            event: narrationEvent, observationId: metadata.observationId,
            artifact: CaptureJournalArtifactInput(artifactId: metadata.artifactId, claimedFile: claim,
                kind: "narration_audio", mediaType: "audio/mp4", role: "narration_audio",
                sourceRole: "microphone_capture", actorRole: "narrator", captureInterval: interval,
                privacy: JazzArchivePrivacy(status: .captured, policyVersion: "consent-v1")))) }
        let commit = try await runtime.close(endedAt: endedAt)
        XCTAssertEqual(commit.artifactCount, 1)
        await journal.revoke()
        let recovery = CaptureJournal(root: root)
        let reopened = try await recovery.reopen(archiveId: fixture.archiveId)
        XCTAssertEqual(reopened.lifecycle, .committed)
        XCTAssertEqual(reopened.resolvedObservationCount, 2)
        let store = JazzArchiveDraftStore(root: root)
        let actual = try await store.artifactBytes(archiveId: fixture.archiveId, captureId: fixture.captureId, artifactId: metadata.artifactId)
        XCTAssertEqual(actual, bytes)
    }

    func testNarrationAdmissionAndCloseDurabilityFailuresRetainEvidence() async throws {
        for edge in ["admission-file", "admission-directory", "close-media", "close-directory", "close-file", "close-receipt-directory"] {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = narrationFixture()
            let journal = CaptureJournal(root: root)
            _ = try await journal.begin(manifest: fixture.manifest, session: fixture.session)
            let metadata = narrationMetadata(fixture)
            let writable = try JazzArchiveWritableFileClaim.prepare(root: root, archiveId: fixture.archiveId,
                captureId: fixture.captureId, artifactId: metadata.artifactId, fileExtension: "m4a")
            let directory = try CaptureJournalNarrationReceipt.directory(root: root, archiveId: fixture.archiveId, captureId: fixture.captureId)
            let startURL = try CaptureJournalNarrationReceipt.url(directory: directory, artifactId: metadata.artifactId)
            let closedURL = try CaptureJournalNarrationReceipt.url(directory: directory, artifactId: metadata.artifactId, closed: true)
            let recorder = CanonicalDurabilityRecorder()
            if edge.hasPrefix("admission") {
                recorder.failOnce(on: edge == "admission-file" ? .file(CanonicalDurabilityRecorder.path(startURL)) : .directory(CanonicalDurabilityRecorder.path(directory)))
                XCTAssertThrowsError(try writable.recordNarrationStart(metadata, durability: recorder.value()))
                XCTAssertEqual(try Data(contentsOf: writable.recordingURL), Data())
            } else {
                let digest = try writable.recordNarrationStart(metadata, durability: recorder.value())
                let bytes = Data("recorded before failed close".utf8)
                try bytes.write(to: writable.recordingURL)
                let event: CanonicalDurabilityRecorder.Event
                switch edge {
                case "close-media": event = .file(CanonicalDurabilityRecorder.path(writable.recordingURL))
                case "close-directory": event = .directory(CanonicalDurabilityRecorder.path(writable.recordingURL.deletingLastPathComponent()))
                case "close-file": event = .file(CanonicalDurabilityRecorder.path(closedURL))
                default: event = .directory(CanonicalDurabilityRecorder.path(directory))
                }
                recorder.failOnce(on: event)
                XCTAssertThrowsError(try writable.recordNarrationStop(startedAt: startedAt, endedAt: endedAt, admissionDigest: digest, durability: recorder.value()))
                XCTAssertEqual(try Data(contentsOf: writable.recordingURL), bytes)
            }
            await journal.revoke()
            let recovery = CaptureJournal(root: root)
            if edge == "close-file" || edge == "close-receipt-directory" {
                // Unknown fsync acknowledgement is recoverable if the complete, verified receipt
                // actually survived. These bytes were closed before the injected durability fault.
                let reopened = try await recovery.reopen(archiveId: fixture.archiveId)
                XCTAssertEqual(reopened.resolvedArtifactCount, 1)
            } else {
                do { _ = try await recovery.reopen(archiveId: fixture.archiveId); XCTFail("invented closure") } catch { }
                XCTAssertTrue(FileManager.default.fileExists(atPath: writable.recordingURL.path))
            }
        }
    }

    func testNarrationStopCannotRebindChangedAdmissionReceipt() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = narrationFixture()
        let metadata = narrationMetadata(fixture)
        let writable = try JazzArchiveWritableFileClaim.prepare(root: root, archiveId: fixture.archiveId,
            captureId: fixture.captureId, artifactId: metadata.artifactId, fileExtension: "m4a")
        let digest = try writable.recordNarrationStart(metadata, durability: narrationDurability)
        let bytes = Data("still owned recording".utf8)
        try bytes.write(to: writable.recordingURL)
        let directory = try CaptureJournalNarrationReceipt.directory(root: root, archiveId: fixture.archiveId, captureId: fixture.captureId)
        let startURL = try CaptureJournalNarrationReceipt.url(directory: directory, artifactId: metadata.artifactId)
        var receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: startURL)) as? [String: Any])
        receipt["schemaVersion"] = 2
        try JSONSerialization.data(withJSONObject: receipt).write(to: startURL, options: .atomic)
        XCTAssertThrowsError(try writable.recordNarrationStop(startedAt: startedAt, endedAt: endedAt, admissionDigest: digest, durability: narrationDurability))
        XCTAssertEqual(try Data(contentsOf: writable.recordingURL), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try CaptureJournalNarrationReceipt.url(directory: directory, artifactId: metadata.artifactId, closed: true).path))
    }

    private func ingestNarration(
        _ journal: CaptureJournal, token: CaptureJournalArtifactToken,
        metadata: CaptureJournalNarrationContext, claim: JazzArchiveClaimedFile
    ) async throws -> JazzArchiveArtifact {
        let artifact = metadata.artifact(claim: claim, startedAt: startedAt, endedAt: endedAt)
        return try await journal.ingestArtifact(
            token, payload: .claimedFile(claim), kind: artifact.kind, mediaType: artifact.content.mediaType,
            sourceRefs: artifact.sourceRefs, actorRefs: artifact.actorRefs, labelRefs: artifact.labelRefs,
            observationRefs: artifact.observationRefs, captureInterval: artifact.captureInterval,
            provenance: artifact.provenance, quality: artifact.quality, privacy: artifact.privacy)
    }

    private var narrationDurability: JazzArchiveFilesystemDurability {
        foundationTestFilesystemDurability()
    }

    private func narrationFixture() -> Fixture {
        var fixture = makeFixture()
        fixture.session.capturePolicy.modalities.append(.narration)
        return fixture
    }

    private func narrationMetadata(_ fixture: Fixture) -> CaptureJournalNarrationContext {
        let labelId = Identifiers.newLabelId()
        return CaptureJournalNarrationContext(
            archiveId: fixture.archiveId, artifactId: Identifiers.newArtifactId(),
            context: CaptureJournalActivityContext(
                originId: fixture.originId, captureId: fixture.captureId, streamId: fixture.streamId,
                sourceId: fixture.sourceId, actorId: fixture.actorId, policyVersion: "consent-v1"),
            event: ActivityEvent(
                sessionId: fixture.legacySessionId,
                eventId: Identifiers.eventId(sessionId: fixture.legacySessionId, sequence: 1),
                sequence: 1, timestamp: startedAt, eventType: EventType.narration.rawValue,
                url: "app://session", labelId: labelId, label: "Explain this task"),
            labelStartEvent: ActivityEvent(
                sessionId: fixture.legacySessionId,
                eventId: Identifiers.eventId(sessionId: fixture.legacySessionId, sequence: 0),
                sequence: 0, timestamp: startedAt, eventType: EventType.labelStart.rawValue,
                url: "app://session", labelId: labelId, label: "Explain this task"),
            labelStartObservationId: Identifiers.newObservationId(),
            labelStartExtensions: ["dev.jazz.label.declarationMode": .string("free_text")])
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
        // Integrity metadata alone is not durable evidence. Resolve only through actual ingest;
        // repeating the same persisted bytes/document remains idempotent.
        for _ in 0..<2 {
            _ = try await journal.ingestArtifact(
                artifactToken, bytes: Data("durable bytes".utf8), kind: "test_blob",
                mediaType: "application/octet-stream",
                sourceRefs: [JazzArchiveSourceRef(sourceId: fixture.sourceId, role: "capture")],
                provenance: JazzArchiveProvenance(
                    factClass: .observed, sources: [fixture.sourceId]),
                quality: JazzArchiveQuality(status: .complete),
                privacy: JazzArchivePrivacy(status: .captured, policyVersion: "consent-v1"))
        }
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

    func testRecoveryDoesNotTreatCorruptOrMissingArtifactBytesAsAbsentWork() async throws {
        for missingBlob in [true, false] {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = makeFixture()
            let journal = CaptureJournal(root: root)
            _ = try await journal.begin(manifest: fixture.manifest, session: fixture.session)
            let observation = try await journal.reserve(streamId: fixture.streamId)
            try await journal.resolveObservation(
                observation, record: record(fixture, token: observation))
            let token = try await journal.reserveArtifact()
            let bytes = Data("recover only verified bytes".utf8)
            let artifact = try await journal.ingestArtifact(
                token, bytes: bytes, kind: "test_blob", mediaType: "application/octet-stream",
                sourceRefs: [JazzArchiveSourceRef(sourceId: fixture.sourceId, role: "capture")],
                provenance: JazzArchiveProvenance(
                    factClass: .observed, sources: [fixture.sourceId]),
                quality: JazzArchiveQuality(status: .complete),
                privacy: JazzArchivePrivacy(status: .captured, policyVersion: "consent-v1"))
            try await journal.relinquishOwnership()
            let wal = root.appendingPathComponent(".capture-journal/\(fixture.archiveId)/wal")
            let last = try XCTUnwrap(
                FileManager.default.contentsOfDirectory(at: wal, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }.last)
            try FileManager.default.removeItem(at: last)  // Crash before resolution acknowledgement.
            let draft = root.appendingPathComponent("\(fixture.archiveId).jazz-archive.draft")
            let document = draft.appendingPathComponent(fixture.manifest.sessions[0].path)
                .deletingLastPathComponent().appendingPathComponent(
                    "artifacts/\(token.artifactId).json")
            let target =
                missingBlob ? draft.appendingPathComponent(artifact.content.path) : document
            let saved = try Data(contentsOf: target)
            if missingBlob {
                try FileManager.default.removeItem(at: target)
            } else {
                try Data("invalid metadata".utf8).write(to: target)
            }
            let recovery = CaptureJournal(root: root)
            do {
                _ = try await recovery.recoverInterrupted(
                    archiveId: fixture.archiveId, endedAt: endedAt);
                XCTFail("integrity failure was treated as absence")
            } catch { /* Failure must retain the unresolved journal and artifact document. */  }
            XCTAssertTrue(FileManager.default.fileExists(atPath: document.path))
            let ids = await recovery.recoverableArchiveIds()
            XCTAssertEqual(ids, [fixture.archiveId])
            try saved.write(to: target)
            let commit = try await recovery.recoverInterrupted(
                archiveId: fixture.archiveId, endedAt: endedAt)
            XCTAssertEqual(commit.artifactCount, 1)
            let recovered = try await JazzArchiveDraftStore(root: root).artifactBytes(
                archiveId: fixture.archiveId, captureId: fixture.captureId,
                artifactId: token.artifactId)
            XCTAssertEqual(recovered, bytes)
        }
    }

    private func sealedClaim(
        root: URL, fixture: Fixture, artifactId: String, bytes: Data,
        captureId: String? = nil
    ) throws -> JazzArchiveClaimedFile {
        let writable = try JazzArchiveWritableFileClaim.prepare(
            root: root, archiveId: fixture.archiveId,
            captureId: captureId ?? fixture.captureId, artifactId: artifactId,
            fileExtension: "bin")
        try bytes.write(to: writable.recordingURL)
        return try writable.seal()
    }

    private func claimedArtifact(
        _ fixture: Fixture, artifactId: String, bytes: Data
    ) -> JazzArchiveArtifact {
        let digest = JazzArchiveDigest.sha256Hex(bytes)
        return JazzArchiveArtifact(
            artifactId: artifactId, captureId: fixture.captureId, origin: .captured,
            kind: "test_blob",
            content: JazzArchiveArtifactContent(
                path: "blobs/sha256/\(digest.prefix(2))/\(digest)",
                mediaType: "application/octet-stream", byteLength: Int64(bytes.count), sha256: digest),
            sourceRefs: [JazzArchiveSourceRef(sourceId: fixture.sourceId, role: "capture")],
            provenance: JazzArchiveProvenance(factClass: .observed, sources: [fixture.sourceId]),
            quality: JazzArchiveQuality(status: .complete),
            privacy: JazzArchivePrivacy(status: .captured, policyVersion: "consent-v1"))
    }

    func testPublicDraftIngestRejectsDecodedUnownedClaims() async throws {
        for attack in ["foreign-file", "foreign-root", "foreign-capture", "foreign-artifact",
                       "unsealed-name", "symlink-ancestor", "symlink-traversal", "owned"] {
            let root = temporaryRoot()
            let foreign = temporaryRoot()
            defer {
                try? FileManager.default.removeItem(at: root)
                try? FileManager.default.removeItem(at: foreign)
            }
            let fixture = makeFixture()
            let store = JazzArchiveDraftStore(root: root)
            _ = try await store.create(manifest: fixture.manifest, session: fixture.session)
            let bytes = Data("synthetic foreign sole-source bytes".utf8)
            let artifactId = Identifiers.newArtifactId()
            let artifact = claimedArtifact(fixture, artifactId: artifactId, bytes: bytes)
            let claim = try sealedClaim(
                root: ["foreign-file", "foreign-root", "symlink-traversal"].contains(attack) ? foreign : root,
                fixture: fixture,
                artifactId: attack == "foreign-artifact" ? Identifiers.newArtifactId() : artifactId,
                bytes: bytes,
                captureId: attack == "foreign-capture" ? Identifiers.newCaptureId() : nil)
            var url = claim.url
            if attack == "foreign-file" || attack == "unsealed-name" {
                url = claim.url.deletingLastPathComponent().appendingPathComponent(
                    attack == "foreign-file" ? "ordinary.bin" : "\(artifactId).recording.bin")
                try FileManager.default.moveItem(at: claim.url, to: url)
            } else if attack == "symlink-ancestor" {
                let directory = claim.url.deletingLastPathComponent()
                try FileManager.default.moveItem(at: directory, to: foreign)
                try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: foreign)
            } else if attack == "symlink-traversal" {
                let directory = root.appendingPathComponent(
                    ".artifact-claims/\(fixture.archiveId)/\(fixture.captureId)")
                let child = claim.url.deletingLastPathComponent().appendingPathComponent("child")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(
                    at: directory.appendingPathComponent("link"), withDestinationURL: child)
                // Lexical standardization hides the symlink, but the OS follows it before `..`.
                url = directory.appendingPathComponent("link/../\(claim.url.lastPathComponent)")
            }
            // Exercise the public Decodable surface, not an internal capability constructor.
            var descriptor = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(claim)) as? [String: Any])
            descriptor["url"] = url.absoluteString
            let decoded = try JSONDecoder().decode(
                JazzArchiveClaimedFile.self, from: JSONSerialization.data(withJSONObject: descriptor))
            do {
                _ = try await store.ingestArtifact(
                    archiveId: fixture.archiveId, captureId: fixture.captureId,
                    artifact: artifact, claimedFile: decoded)
                if attack != "owned" { XCTFail("accepted \(attack)") }
            } catch {
                if attack == "owned" { throw error }
                XCTAssertTrue(error is JazzArchiveClaimError, "\(attack): \(error)")
            }
            XCTAssertEqual(try Data(contentsOf: url), bytes, attack)
            let published = try await store.artifacts(
                archiveId: fixture.archiveId, captureId: fixture.captureId)
            XCTAssertEqual(published, attack == "owned" ? [artifact] : [], attack)
        }
    }

    func testArtifactRetryCannotReplaceClaimIntentWithDifferentBytes() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = makeFixture()
        let durability = CanonicalDurabilityRecorder()
        let journal = CaptureJournal(root: root, durability: durability.value())
        _ = try await journal.begin(manifest: fixture.manifest, session: fixture.session)
        let token = try await journal.reserveArtifact()
        let bytes = Data("synthetic retained intent bytes".utf8)
        let claim = try sealedClaim(root: root, fixture: fixture, artifactId: token.artifactId, bytes: bytes)
        let artifact = claimedArtifact(fixture, artifactId: token.artifactId, bytes: bytes)
        durability.failOnce(on: .file(CanonicalDurabilityRecorder.path(
            root.appendingPathComponent("\(fixture.archiveId).jazz-archive.draft")
                .appendingPathComponent(artifact.content.path))))
        for payload in [CaptureJournalArtifactPayload.claimedFile(claim), .bytes(Data("substitute".utf8))] {
            do {
                _ = try await journal.ingestArtifact(
                    token, payload: payload, kind: artifact.kind, mediaType: artifact.content.mediaType,
                    sourceRefs: artifact.sourceRefs, provenance: artifact.provenance,
                    quality: artifact.quality, privacy: artifact.privacy)
                XCTFail("failed intent must not be replaced")
            } catch {
                if case .bytes = payload {
                    XCTAssertEqual(error as? CaptureJournalError, .completionConflict(token.reservationId))
                }
            }
        }
        XCTAssertEqual(try Data(contentsOf: claim.url), bytes)
        let published = try await JazzArchiveDraftStore(root: root).artifacts(
            archiveId: fixture.archiveId, captureId: fixture.captureId)
        XCTAssertTrue(published.isEmpty)
        try await journal.relinquishOwnership()
        let recovery = CaptureJournal(root: root)
        _ = try await recovery.reopen(archiveId: fixture.archiveId)
        let recovered = try await JazzArchiveDraftStore(root: root).artifactBytes(
            archiveId: fixture.archiveId, captureId: fixture.captureId, artifactId: token.artifactId)
        XCTAssertEqual(recovered, bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: claim.url.path))
    }

    func testRecoveryRejectsTamperedArtifactResolutionWAL() async throws {
        try await checkTamperedArtifactResolution(checkpoint: false)
    }

    func testRecoveryBindsCheckpointIntentToPublishedArtifactBeforeDeletingClaim() async throws {
        try await checkTamperedArtifactResolution(checkpoint: true)
    }

    private func checkTamperedArtifactResolution(checkpoint: Bool) async throws {
        let attacks = checkpoint
            ? ["claim", "sha256", "byteLength", "metadata", "artifactId", "captureId",
               "consistent-substitution", "unpublished", "missing-blob", "corrupt-blob", "matching"]
            : ["claim", "drop", "consistent-substitution"]
        for attack in attacks {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = makeFixture()
            let journal = CaptureJournal(root: root)
            _ = try await journal.begin(manifest: fixture.manifest, session: fixture.session)
            let token = try await journal.reserveArtifact()
            let bytes = Data("synthetic canonical artifact".utf8)
            let original = try sealedClaim(
                root: root, fixture: fixture, artifactId: token.artifactId, bytes: bytes)
            let artifact = try await journal.ingestArtifact(
                token, payload: .claimedFile(original), kind: "test_blob",
                mediaType: "application/octet-stream",
                sourceRefs: [JazzArchiveSourceRef(sourceId: fixture.sourceId, role: "capture")],
                provenance: JazzArchiveProvenance(factClass: .observed, sources: [fixture.sourceId]),
                quality: JazzArchiveQuality(status: .complete),
                privacy: JazzArchivePrivacy(status: .captured, policyVersion: "consent-v1"))
            try await journal.relinquishOwnership()
            let stateDirectory = root.appendingPathComponent(".capture-journal/\(fixture.archiveId)")
            if checkpoint {
                let recovery = CaptureJournal(root: root)
                _ = try await recovery.reopen(archiveId: fixture.archiveId)
                try await recovery.relinquishOwnership()
            }
            let target: URL
            if checkpoint {
                target = stateDirectory.appendingPathComponent("state.json")
            } else {
                target = try XCTUnwrap(FileManager.default.contentsOfDirectory(
                    at: stateDirectory.appendingPathComponent("wal"), includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }.last)
            }
            var document = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: target)) as? [String: Any])
            var mutation = document["mutation"] as? [String: Any] ?? [:]
            var update = mutation["updateArtifact"] as? [String: Any] ?? [:]
            var entry = try XCTUnwrap(checkpoint
                ? (document["artifacts"] as? [[String: Any]])?.first
                : update["entry"] as? [String: Any])
            var intent = try XCTUnwrap(entry["ingestIntent"] as? [String: Any])
            let substituted = attack == "claim" || attack == "consistent-substitution"
            let retainedBytes = substituted ? Data("different unarchived sole-source bytes".utf8) : bytes
            let retained = try sealedClaim(
                root: root, fixture: fixture, artifactId: token.artifactId, bytes: retainedBytes)
            intent["claim"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(retained))
            if attack == "consistent-substitution" {
                let replacement = claimedArtifact(fixture, artifactId: token.artifactId, bytes: retainedBytes)
                intent["artifact"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(replacement))
                entry["sha256"] = replacement.content.sha256
                entry["byteLength"] = replacement.content.byteLength
                entry["metadata"] = ["kind": replacement.kind, "mediaType": replacement.content.mediaType,
                                     "path": replacement.content.path]
            } else if attack == "sha256" {
                entry["sha256"] = String(repeating: "0", count: 64)
            } else if attack == "byteLength" {
                entry["byteLength"] = bytes.count + 1
            } else if attack == "metadata" {
                entry["metadata"] = ["kind": "different"]
            } else if attack == "artifactId" || attack == "captureId" {
                var metadata = try XCTUnwrap(intent["artifact"] as? [String: Any])
                metadata[attack] = attack == "artifactId" ? Identifiers.newArtifactId() : Identifiers.newCaptureId()
                intent["artifact"] = metadata
            }
            entry["ingestIntent"] = attack == "drop" ? nil : intent
            if attack == "drop" {
                // No retained file can incidentally mask acceptance of a dropped immutable intent.
                try FileManager.default.removeItem(at: retained.url)
            }
            if checkpoint {
                document["artifacts"] = [entry]
            } else {
                update["entry"] = entry
                mutation["updateArtifact"] = update
                document["mutation"] = mutation
            }
            try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: target)
            let draft = root.appendingPathComponent("\(fixture.archiveId).jazz-archive.draft")
            let blob = draft.appendingPathComponent(artifact.content.path)
            if attack == "unpublished" {
                let artifactURL = draft.appendingPathComponent(fixture.manifest.sessions[0].path)
                    .deletingLastPathComponent().appendingPathComponent("artifacts/\(token.artifactId).json")
                try FileManager.default.removeItem(at: artifactURL)
            } else if attack == "missing-blob" {
                try FileManager.default.removeItem(at: blob)
            } else if attack == "corrupt-blob" {
                try Data("corrupt".utf8).write(to: blob)
            }
            let tamperedState = try Data(contentsOf: target)
            let recovery = CaptureJournal(root: root)
            do {
                _ = try await recovery.reopen(archiveId: fixture.archiveId)
                if attack != "matching" { XCTFail("accepted \(checkpoint ? "checkpoint" : "WAL") \(attack)") }
            } catch {
                if attack == "matching" { throw error }
            }
            if attack == "matching" {
                XCTAssertFalse(FileManager.default.fileExists(atPath: retained.url.path))
            } else {
                if attack != "drop" {
                    XCTAssertEqual(try? Data(contentsOf: retained.url), retainedBytes, attack)
                }
                XCTAssertEqual(try? Data(contentsOf: target), tamperedState, "must fail before checkpoint: \(attack)")
                let snapshot = await recovery.snapshot()
                XCTAssertEqual(snapshot.lifecycle, .idle, attack)
            }
            if !["missing-blob", "corrupt-blob"].contains(attack) {
                XCTAssertEqual(try Data(contentsOf: blob), bytes, attack)
            }
        }
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
