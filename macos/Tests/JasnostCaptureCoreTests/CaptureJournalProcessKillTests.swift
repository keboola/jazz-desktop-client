import Darwin
import Foundation
import XCTest

@testable import JasnostCaptureCore

/// Exercises recovery through an actual SIGKILL boundary. The child test process persists one
/// lifecycle state and terminates without running Swift cleanup; the parent opens the same root
/// with a fresh actor and verifies the durable state and canonical observation.
final class CaptureJournalProcessKillTests: XCTestCase {
    private struct Fixture {
        let archiveId: String
        let originId: String
        let legacySessionId: String
        let captureId: String
        let streamId: String
        let actorId: String
        let sourceId: String
        let manifest: JazzArchiveManifest
        let session: JazzArchiveSession
    }

    private let startedAt = "2026-07-22T10:00:00.000Z"
    private let endedAt = "2026-07-22T10:01:00.000Z"
    private let childStateEnvironment = "JAZZ_CAPTURE_PROCESS_KILL_STATE"
    private let childRootEnvironment = "JAZZ_CAPTURE_PROCESS_KILL_ROOT"
    private let childReadyName = "child-ready"
    private let artifactBytes = Data("durable process-kill artifact".utf8)

    func testActualProcessKillRecoversEveryLifecycleState() async throws {
        let environment = ProcessInfo.processInfo.environment
        if let rawState = environment[childStateEnvironment],
            let rootPath = environment[childRootEnvironment]
        {
            try await runChild(
                state: try XCTUnwrap(CaptureJournalLifecycle(rawValue: rawState)),
                root: URL(fileURLWithPath: rootPath, isDirectory: true))
            return
        }

        for state in CaptureJournalLifecycle.allCases {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "capture-journal-process-kill-\(state.rawValue)-\(UUID().uuidString)",
                isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            child.arguments = [
                "xctest",
                "-XCTest",
                "JasnostCaptureCoreTests.CaptureJournalProcessKillTests/"
                    + "testActualProcessKillRecoversEveryLifecycleState",
                Bundle(for: Self.self).bundleURL.path,
            ]
            var childEnvironment = environment
            childEnvironment[childStateEnvironment] = state.rawValue
            childEnvironment[childRootEnvironment] = root.path
            child.environment = childEnvironment
            let output = Pipe()
            child.standardOutput = output
            child.standardError = output

            try child.run()
            let readyURL = root.appendingPathComponent(childReadyName)
            for _ in 0..<3_000
            where child.isRunning && !FileManager.default.fileExists(atPath: readyURL.path) {
                Darwin.usleep(10_000)
            }
            guard FileManager.default.fileExists(atPath: readyURL.path) else {
                if child.isRunning {
                    _ = Darwin.kill(child.processIdentifier, SIGKILL)
                }
                child.waitUntilExit()
                let diagnostic = String(
                    decoding: output.fileHandleForReading.readDataToEndOfFile(),
                    as: UTF8.self)
                return XCTFail(
                    "\(state.rawValue) child exited before the persisted kill boundary: "
                        + diagnostic)
            }
            XCTAssertEqual(Darwin.kill(child.processIdentifier, SIGKILL), 0)
            child.waitUntilExit()
            let diagnostic = String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self)
            XCTAssertEqual(
                child.terminationReason,
                .uncaughtSignal,
                "\(state.rawValue): \(diagnostic)")
            XCTAssertEqual(
                child.terminationStatus,
                SIGKILL,
                "\(state.rawValue): \(diagnostic)")

            let archiveId = try String(
                decoding: Data(contentsOf: root.appendingPathComponent("child-archive-id")),
                as: UTF8.self)
            let journal = CaptureJournal(root: root)
            if state == .idle {
                let snapshot = await journal.snapshot()
                let recoverable = await journal.recoverableArchiveIds()
                XCTAssertEqual(snapshot.lifecycle, .idle)
                XCTAssertNil(snapshot.archiveId)
                XCTAssertEqual(recoverable, [])
                continue
            }

            let recovered = try await journal.reopen(archiveId: archiveId)
            let expectedLifecycle: CaptureJournalLifecycle =
                state == .starting ? .recording : state
            XCTAssertEqual(recovered.lifecycle, expectedLifecycle, state.rawValue)
            let store = JazzArchiveDraftStore(root: root)
            let session = try await store.session(
                archiveId: archiveId,
                captureId: try XCTUnwrap(recovered.captureId))
            if state == .starting {
                XCTAssertEqual(recovered.resolvedObservationCount, 0)
                XCTAssertEqual(recovered.resolvedArtifactCount, 0)
                XCTAssertEqual(session.status, .open)
            } else {
                XCTAssertEqual(recovered.resolvedObservationCount, 1)
                XCTAssertEqual(recovered.resolvedArtifactCount, 1)
                let records = try await store.records(
                    archiveId: archiveId,
                    captureId: session.captureId)
                XCTAssertEqual(records.count, 1)
                let artifacts = try await store.artifacts(
                    archiveId: archiveId,
                    captureId: session.captureId)
                XCTAssertEqual(artifacts.count, 1)
                let persistedArtifactBytes = try await store.artifactBytes(
                    archiveId: archiveId,
                    captureId: session.captureId,
                    artifactId: try XCTUnwrap(artifacts.first?.artifactId))
                XCTAssertEqual(
                    persistedArtifactBytes,
                    artifactBytes)
            }
            if state == .committed {
                XCTAssertEqual(session.status, .closed)
                let commit = try await store.captureCommit(
                    archiveId: archiveId,
                    captureId: session.captureId)
                XCTAssertEqual(commit.artifactCount, 1)
            }
        }
    }

    private func runChild(
        state: CaptureJournalLifecycle,
        root: URL
    ) async throws {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        let fixture = makeFixture()
        try Data(fixture.archiveId.utf8).write(
            to: root.appendingPathComponent("child-archive-id"),
            options: .atomic)
        let journal = CaptureJournal(root: root)

        if state != .idle {
            if state == .starting {
                _ = try await journal.prepare(
                    manifest: fixture.manifest,
                    session: fixture.session)
            } else {
                _ = try await journal.begin(
                    manifest: fixture.manifest,
                    session: fixture.session)
                let artifactToken = try await journal.reserveArtifact()
                let artifact = try await journal.ingestArtifact(
                    artifactToken,
                    bytes: artifactBytes,
                    kind: "test_blob",
                    mediaType: "application/octet-stream",
                    sourceRefs: [JazzArchiveSourceRef(
                        sourceId: fixture.sourceId,
                        role: "capture")],
                    actorRefs: [JazzArchiveActorRef(
                        actorId: fixture.actorId,
                        role: "performer",
                        basis: .declared,
                        method: "session_recorder")],
                    provenance: JazzArchiveProvenance(
                        factClass: .observed,
                        sources: [fixture.sourceId]),
                    quality: JazzArchiveQuality(status: .complete),
                    privacy: JazzArchivePrivacy(
                        status: .captured,
                        policyVersion: "consent-v1"))
                let token = try await journal.reserve(streamId: fixture.streamId)
                var observation = record(fixture, token: token)
                observation.artifactRefs = [JazzArchiveArtifactRef(
                    artifactId: artifact.artifactId,
                    role: "attachment")]
                try await journal.resolveObservation(token, record: observation)
                if state == .closingInput || state == .draining || state == .committed {
                    _ = try await journal.closeInput()
                }
                if state == .draining || state == .committed {
                    _ = try await journal.beginDraining()
                }
                if state == .committed {
                    _ = try await journal.commit(endedAt: endedAt)
                }
            }
        }

        try Data("ready".utf8).write(
            to: root.appendingPathComponent(childReadyName),
            options: .atomic)
        while true {
            _ = Darwin.pause()
        }
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
            name: "Jazz Capture",
            version: "process-kill-test",
            platform: "macOS")
        let actor = JazzArchiveActor(
            actorId: actorId,
            kind: .human,
            identityStatus: .identified,
            displayName: "Recorder",
            provenance: JazzArchiveProvenance(factClass: .declared, sources: []))
        let source = JazzArchiveSource(
            sourceId: sourceId,
            kind: "macos.capture-journal-process-kill-test",
            actorId: actorId,
            producer: producer,
            capabilities: ["pointer.click"],
            provenance: JazzArchiveProvenance(factClass: .observed, sources: []))
        let manifest = JazzArchiveManifest(
            archiveId: archiveId,
            originId: originId,
            originScope: JazzArchiveExternalIdentity(
                namespace: "test.tenant",
                value: "offline"),
            createdAt: startedAt,
            producer: producer,
            contracts: [.activityEvent],
            actors: [actor],
            sources: [source],
            sessions: [JazzArchiveSessionRef(
                captureId: captureId,
                legacySessionId: legacySessionId)])
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
        token: CaptureJournalReservationToken
    ) -> ArchiveRecord<ActivityEvent> {
        let event = ActivityEvent(
            sessionId: fixture.legacySessionId,
            eventId: Identifiers.eventId(
                sessionId: fixture.legacySessionId,
                sequence: token.streamSequence),
            sequence: token.streamSequence,
            timestamp: startedAt,
            eventType: "click",
            url: "app://com.example.finance")
        return ArchiveRecord(
            event: event,
            observationId: Identifiers.newObservationId(),
            originId: fixture.originId,
            captureId: fixture.captureId,
            streamId: fixture.streamId,
            streamSequence: token.streamSequence,
            sourceRefs: [JazzArchiveSourceRef(
                sourceId: fixture.sourceId,
                role: "trigger")],
            actorRefs: [JazzArchiveActorRef(
                actorId: fixture.actorId,
                role: "performer",
                basis: .declared,
                method: "session_recorder")],
            provenance: JazzArchiveProvenance(
                factClass: .observed,
                sources: [fixture.sourceId]),
            quality: JazzArchiveQuality(status: .complete),
            privacy: JazzArchivePrivacy(
                status: .captured,
                policyVersion: "consent-v1"))
    }
}
