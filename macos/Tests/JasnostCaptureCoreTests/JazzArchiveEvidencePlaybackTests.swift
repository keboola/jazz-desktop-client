import Foundation
import XCTest

@testable import JasnostCaptureCore

final class JazzArchiveEvidencePlaybackTests: XCTestCase {
    private let start = "2026-07-23T10:00:00.000Z"

    func testBuildsVerifiedOfflineTimelineWithArtifactAndExplicitGap() async throws {
        let fixture = try await makeCommittedArchive()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let snapshot = try await JazzArchiveEvidencePlaybackBuilder(root: fixture.root).build(
            archiveId: fixture.archiveId,
            captureId: fixture.captureId)

        XCTAssertEqual(snapshot.archiveId, fixture.archiveId)
        XCTAssertEqual(snapshot.captureId, fixture.captureId)
        XCTAssertEqual(snapshot.entries.map(\.item.kind), [.screenshot, .gap, .event])
        XCTAssertEqual(snapshot.entries[1].item.offsetMillis, 1_000)
        XCTAssertEqual(snapshot.entries[1].item.gapReason, "capture_loss")
        let screenshot = try XCTUnwrap(snapshot.entries.first?.artifact)
        XCTAssertEqual(screenshot.artifactId, fixture.artifactId)
        XCTAssertEqual(screenshot.mediaType, "image/png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: screenshot.url.path))
    }

    func testCorruptArtifactFailsWholePlaybackLoadClosed() async throws {
        let fixture = try await makeCommittedArchive()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("tampered".utf8).write(to: fixture.blobURL, options: .atomic)

        do {
            _ = try await JazzArchiveEvidencePlaybackBuilder(root: fixture.root).build(
                archiveId: fixture.archiveId,
                captureId: fixture.captureId)
            XCTFail("corrupt evidence must not produce a partial timeline")
        } catch let error as JazzArchiveError {
            guard case .digestMismatch = error else {
                return XCTFail("unexpected archive error: \(error)")
            }
        }
    }

    func testImportedFinalCoachUsesCanonicalLabelOnTheGlobalTimeline() async throws {
        let root = try copyFinalizedFixture(
            "03-capture-coach",
            archiveId: "ar-33333333-3333-7333-8333-333333333333")
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshot = try await JazzArchiveEvidencePlaybackBuilder(root: root).build(
            archiveId: "ar-33333333-3333-7333-8333-333333333333",
            captureId: "cap-33333333-3333-7333-8333-333333333333")

        XCTAssertEqual(snapshot.durationMillis, 120_000)
        XCTAssertEqual(snapshot.entries.filter { $0.item.kind == .label }.count, 1)
        XCTAssertTrue(snapshot.entries.contains { $0.item.kind == .coachInteraction })
        let label = try XCTUnwrap(snapshot.entries.first { $0.item.kind == .label })
        XCTAssertEqual(label.title, "Send the invoice")
        XCTAssertEqual(label.item.offsetMillis, 5_000)
        XCTAssertEqual(label.endOffsetMillis, 90_000)
    }

    func testImportedFinalMeetingSynchronizesVideoAudioAndTranscriptOffline() async throws {
        let root = try copyFinalizedFixture(
            "04-meeting-screen-share",
            archiveId: "ar-44444444-4444-7444-8444-444444444441")
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshot = try await JazzArchiveEvidencePlaybackBuilder(root: root).build(
            archiveId: "ar-44444444-4444-7444-8444-444444444441",
            captureId: "cap-44444444-4444-7444-8444-444444444441")

        XCTAssertEqual(snapshot.durationMillis, 13_000)
        XCTAssertTrue(snapshot.entries.contains { $0.item.kind == .screenshot })
        XCTAssertTrue(snapshot.entries.contains { $0.item.kind == .narration })
        XCTAssertTrue(snapshot.entries.contains { $0.item.kind == .transcript })
        XCTAssertTrue(snapshot.entries.allSatisfy {
            $0.artifact == nil || FileManager.default.fileExists(atPath: $0.artifact!.url.path)
        })

        var playhead = try JazzArchiveEvidencePlayhead(snapshot: snapshot)
        playhead.seek(toMillis: 4_000)
        let activeKinds = Set(snapshot.entries.filter {
            playhead.state.activeEntryIds.contains($0.id)
        }.map(\.item.kind))
        XCTAssertTrue(activeKinds.contains(.screenshot))
        XCTAssertTrue(activeKinds.contains(.narration))
        XCTAssertTrue(activeKinds.contains(.transcript))
    }

    private struct Fixture {
        let root: URL
        let archiveId: String
        let captureId: String
        let artifactId: String
        let blobURL: URL
    }

    private func makeCommittedArchive() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "jazz-playback-tests-\(UUID().uuidString)", isDirectory: true)
        let archiveId = Identifiers.newArchiveId()
        let originId = Identifiers.newOriginId()
        let sessionId = Identifiers.newSessionId()
        let captureId = Identifiers.newCaptureId()
        let streamId = Identifiers.newStreamId()
        let actorId = Identifiers.newActorId()
        let sourceId = Identifiers.newSourceId()
        let artifactId = Identifiers.newArtifactId()
        let producer = JazzArchiveProducer(name: "Playback test", version: "1")
        let manifest = JazzArchiveManifest(
            archiveId: archiveId,
            originId: originId,
            createdAt: start,
            producer: producer,
            actors: [JazzArchiveActor(
                actorId: actorId,
                kind: .human,
                identityStatus: .identified,
                displayName: "Recorder",
                provenance: JazzArchiveProvenance(factClass: .declared, sources: []))],
            sources: [JazzArchiveSource(
                sourceId: sourceId,
                kind: "macos.capture-controller",
                actorId: actorId,
                producer: producer,
                provenance: JazzArchiveProvenance(factClass: .observed, sources: []))],
            sessions: [JazzArchiveSessionRef(
                captureId: captureId,
                legacySessionId: sessionId)])
        let session = JazzArchiveSession(
            captureId: captureId,
            legacySessionId: sessionId,
            archiveId: archiveId,
            streamIds: [streamId],
            startedAt: start,
            recorderActorId: actorId,
            sourceIds: [sourceId],
            capturePolicy: JazzArchiveCapturePolicy(
                policyVersion: "test-consent",
                consentedAt: start,
                modalities: [.pointer, .screenshots],
                excludedApplications: [],
                businessDataCapture: false),
            quality: JazzArchiveQuality(status: .complete))
        let store = JazzArchiveDraftStore(root: root)
        _ = try await store.create(manifest: manifest, session: session)

        // Small valid 1×1 PNG. Playback never transforms the bytes; AppKit reads this URL later.
        let bytes = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let digest = JazzArchiveDigest.sha256Hex(bytes)
        let artifact = JazzArchiveArtifact(
            artifactId: artifactId,
            captureId: captureId,
            kind: "screenshot",
            content: JazzArchiveArtifactContent(
                path: "blobs/sha256/\(digest.prefix(2))/\(digest)",
                mediaType: "image/png",
                byteLength: Int64(bytes.count),
                sha256: digest),
            sourceRefs: [JazzArchiveSourceRef(sourceId: sourceId, role: "screen_capture")],
            actorRefs: [JazzArchiveActorRef(
                actorId: actorId,
                role: "performer",
                basis: .observed,
                method: "test")],
            captureInterval: JazzArchiveArtifactCaptureInterval(startedAt: start),
            provenance: JazzArchiveProvenance(factClass: .observed, sources: [sourceId]),
            quality: JazzArchiveQuality(status: .complete),
            privacy: JazzArchivePrivacy(status: .captured, policyVersion: "test-consent"))
        _ = try await store.ingestArtifact(
            archiveId: archiveId,
            captureId: captureId,
            artifact: artifact,
            bytes: bytes)

        let records = [
            activityRecord(
                sessionId: sessionId,
                originId: originId,
                captureId: captureId,
                streamId: streamId,
                sourceId: sourceId,
                actorId: actorId,
                sequence: 0,
                timestamp: start,
                type: .click,
                artifactId: artifactId),
            activityRecord(
                sessionId: sessionId,
                originId: originId,
                captureId: captureId,
                streamId: streamId,
                sourceId: sourceId,
                actorId: actorId,
                sequence: 2,
                timestamp: "2026-07-23T10:00:02.000Z",
                type: .navigate,
                artifactId: nil),
        ]
        _ = try await store.append(
            archiveId: archiveId,
            captureId: captureId,
            records: records)
        _ = try await store.end(
            archiveId: archiveId,
            captureId: captureId,
            endedAt: "2026-07-23T10:00:03.000Z",
            artifactDigests: [artifactId: digest],
            gapReason: .captureLoss)

        return Fixture(
            root: root,
            archiveId: archiveId,
            captureId: captureId,
            artifactId: artifactId,
            blobURL: root
                .appendingPathComponent("\(archiveId).jazz-archive.draft")
                .appendingPathComponent(artifact.content.path))
    }

    private func activityRecord(
        sessionId: String,
        originId: String,
        captureId: String,
        streamId: String,
        sourceId: String,
        actorId: String,
        sequence: Int,
        timestamp: String,
        type: EventType,
        artifactId: String?
    ) -> ArchiveRecord<ActivityEvent> {
        ArchiveRecord(
            event: ActivityEvent(
                sessionId: sessionId,
                eventId: Identifiers.eventId(sessionId: sessionId, sequence: sequence),
                sequence: sequence,
                timestamp: timestamp,
                eventType: type.rawValue,
                url: "app://com.example.finance",
                application: ActivityApplicationIdentity(
                    namespace: "macos.bundle-id",
                    value: "com.example.finance",
                    name: "Finance")),
            originId: originId,
            captureId: captureId,
            streamId: streamId,
            streamSequence: sequence,
            sourceRefs: [JazzArchiveSourceRef(sourceId: sourceId, role: "trigger")],
            actorRefs: [JazzArchiveActorRef(
                actorId: actorId,
                role: "performer",
                basis: .observed,
                method: "test")],
            artifactRefs: artifactId.map {
                [JazzArchiveArtifactRef(artifactId: $0, role: "screenshot")]
            } ?? [],
            provenance: JazzArchiveProvenance(factClass: .observed, sources: [sourceId]),
            quality: JazzArchiveQuality(status: .complete),
            privacy: JazzArchivePrivacy(status: .captured, policyVersion: "test-consent"))
    }

    private func copyFinalizedFixture(
        _ name: String,
        archiveId: String
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "jazz-final-playback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "contract/archive/fixtures/\(name)",
                isDirectory: true)
        let destination = root.appendingPathComponent(
            "\(archiveId).jazz-archive.finalized",
            isDirectory: true)
        try FileManager.default.copyItem(at: source, to: destination)
        return root
    }
}
