import Foundation
import XCTest

@testable import JazzCaptureCore

private final class CaptureHotPathWorkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var journalUnits: [CaptureJournalWorkUnit] = []
    private var draftUnits: [JazzArchiveDraftStoreWorkUnit] = []
    private var uploadUnits: [JazzArchiveUploadQueueWorkUnit] = []

    func record(_ unit: CaptureJournalWorkUnit) {
        lock.lock()
        journalUnits.append(unit)
        lock.unlock()
    }

    func record(_ unit: JazzArchiveDraftStoreWorkUnit) {
        lock.lock()
        draftUnits.append(unit)
        lock.unlock()
    }

    func record(_ unit: JazzArchiveUploadQueueWorkUnit) {
        lock.lock()
        uploadUnits.append(unit)
        lock.unlock()
    }

    func count(_ unit: CaptureJournalWorkUnit) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return journalUnits.filter { $0 == unit }.count
    }

    func journalBytes() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return journalUnits.reduce(into: 0) { total, unit in
            switch unit {
            case .checkpointBytes(let count), .walSegmentBytes(let count):
                total += count
            case .fullLedgerReservationValidation, .incrementalInstall,
                .walReplayMutation:
                break
            }
        }
    }

    func count(_ unit: JazzArchiveDraftStoreWorkUnit) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return draftUnits.filter { $0 == unit }.count
    }

    func draftBytes() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return draftUnits.reduce(into: 0) { total, unit in
            switch unit {
            case .deferredPayloadBytes(let count), .checkpointBytes(let count):
                total += count
            case .inventoryEntryFingerprint, .historicalRecordDecode,
                .targetedFileFingerprint:
                break
            }
        }
    }

    func count(_ unit: JazzArchiveUploadQueueWorkUnit) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return uploadUnits.filter { $0 == unit }.count
    }

    func reset() {
        lock.lock()
        journalUnits.removeAll(keepingCapacity: true)
        draftUnits.removeAll(keepingCapacity: true)
        uploadUnits.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}

final class CaptureHotPathWorkTests: XCTestCase {
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

    func testPhysicalJournalAndDraftBytesGrowNearLinearlyWithObservationCount()
        async throws
    {
        let small = try await captureByteProfile(observations: 16)
        let large = try await captureByteProfile(observations: 64)

        XCTAssertLessThan(
            large.journalBytes,
            small.journalBytes * 5,
            "four times the observations must not rewrite a growing journal checkpoint")
        XCTAssertLessThan(
            large.draftBytes,
            small.draftBytes * 5,
            "four times the observations must not rewrite inventory/manifest per append")
        XCTAssertLessThanOrEqual(
            abs(large.stateBytes - small.stateBytes),
            32,
            "the checkpoint remains a small capture header while WAL segments grow")
        XCTAssertEqual(large.inventoryBytes, small.inventoryBytes)
        XCTAssertEqual(large.manifestBytes, small.manifestBytes)
        XCTAssertEqual(large.walSegments, 64 * 3)
    }

    func testPhysicalJournalAndDraftBytesGrowNearLinearlyWithArtifactCount()
        async throws
    {
        let small = try await artifactByteProfile(artifacts: 4)
        let large = try await artifactByteProfile(artifacts: 16)

        XCTAssertLessThan(large.journalBytes, small.journalBytes * 5)
        XCTAssertLessThan(large.draftBytes, small.draftBytes * 5)
        XCTAssertEqual(large.inventoryBytes, small.inventoryBytes)
        XCTAssertEqual(large.manifestBytes, small.manifestBytes)
        XCTAssertEqual(large.walSegments, 16 * 2)
    }

    func testWALRelaunchPreservesReservationsAndLegacyCheckpointStillOpens()
        async throws
    {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = makeFixture()
        let initial = makeJournal(root: root, work: CaptureHotPathWorkRecorder())
        _ = try await initial.begin(manifest: fixture.manifest, session: fixture.session)
        for _ in 0..<12 {
            let token = try await initial.reserve(streamId: fixture.streamId)
            try await initial.resolveObservation(
                token, record: record(fixture, token: token))
        }

        let firstRelaunch = makeJournal(root: root, work: CaptureHotPathWorkRecorder())
        let recovered = try await firstRelaunch.reopen(archiveId: fixture.archiveId)
        XCTAssertEqual(recovered.resolvedObservationCount, 12)
        XCTAssertEqual(recovered.nextSequenceByStream[fixture.streamId], 12)

        // `reopen` checkpointed and retired the WAL. Removing the optional cursor emulates the
        // pre-WAL state.json layout shipped by older desktop clients.
        let stateURL =
            root
            .appendingPathComponent(".capture-journal", isDirectory: true)
            .appendingPathComponent(fixture.archiveId, isDirectory: true)
            .appendingPathComponent("state.json")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: stateURL))
                as? [String: Any])
        object.removeValue(forKey: "walSequence")
        try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys]
        ).write(to: stateURL, options: .atomic)

        let legacyRelaunch = makeJournal(root: root, work: CaptureHotPathWorkRecorder())
        let legacy = try await legacyRelaunch.reopen(archiveId: fixture.archiveId)
        XCTAssertEqual(legacy.resolvedObservationCount, 12)
        let next = try await legacyRelaunch.reserve(streamId: fixture.streamId)
        XCTAssertEqual(next.streamSequence, 12)
    }

    func testWALReplayWorkGrowsLinearlyWithLedgerSize() async throws {
        let small = try await recoveryWorkProfile(observations: 16)
        let large = try await recoveryWorkProfile(observations: 64)

        XCTAssertEqual(small.replayMutations, 16 * 3)
        XCTAssertEqual(large.replayMutations, 64 * 3)
        XCTAssertEqual(small.ledgerValidations, 16)
        XCTAssertEqual(large.ledgerValidations, 64)
        XCTAssertLessThan(
            large.replayMutations + large.ledgerValidations,
            (small.replayMutations + small.ledgerValidations) * 5)
    }

    func testLongCaptureUsesTargetedWorkUntilStrictRecoveryAndFinalCommit() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = makeFixture()
        let initialWork = CaptureHotPathWorkRecorder()
        let initial = makeJournal(root: root, work: initialWork)

        _ = try await initial.begin(
            manifest: fixture.manifest,
            session: fixture.session)
        initialWork.reset()

        let observationCount = 32
        for sequence in 0..<observationCount {
            let token = try await initial.reserve(streamId: fixture.streamId)
            XCTAssertEqual(token.streamSequence, sequence)
            try await initial.resolveObservation(
                token,
                record: record(fixture, token: token))
        }

        let artifactCount = 4
        for index in 0..<artifactCount {
            let token = try await initial.reserveArtifact()
            _ = try await initial.ingestArtifact(
                token,
                bytes: Data("artifact-\(index)".utf8),
                kind: "test_blob",
                mediaType: "application/octet-stream",
                sourceRefs: [
                    JazzArchiveSourceRef(sourceId: fixture.sourceId, role: "capture")
                ],
                provenance: JazzArchiveProvenance(
                    factClass: .observed,
                    sources: [fixture.sourceId]),
                quality: JazzArchiveQuality(status: .complete),
                privacy: JazzArchivePrivacy(
                    status: .captured,
                    policyVersion: "consent-v1"))
        }

        // Artifact inventory changes must preserve the record identity index. This append would
        // otherwise trigger another complete record decode after every artifact.
        let finalToken = try await initial.reserve(streamId: fixture.streamId)
        try await initial.resolveObservation(
            finalToken,
            record: record(fixture, token: finalToken))

        XCTAssertEqual(
            initialWork.count(.fullLedgerReservationValidation),
            0)
        XCTAssertEqual(initialWork.count(.inventoryEntryFingerprint), 0)
        XCTAssertEqual(initialWork.count(.historicalRecordDecode), 0)
        XCTAssertEqual(
            initialWork.count(.targetedFileFingerprint),
            0)

        // A fresh process pays exactly one strict recovery pass and reconstructs both indexes.
        let recoveryWork = CaptureHotPathWorkRecorder()
        let relaunched = makeJournal(root: root, work: recoveryWork)
        let recovered = try await relaunched.reopen(archiveId: fixture.archiveId)
        XCTAssertEqual(recovered.lifecycle, .recording)
        XCTAssertEqual(
            recoveryWork.count(.fullLedgerReservationValidation),
            observationCount + 1)
        XCTAssertEqual(
            recoveryWork.count(.historicalRecordDecode),
            observationCount + 1)
        XCTAssertEqual(
            recoveryWork.count(.inventoryEntryFingerprint),
            1,
            "only the checkpointed session is inventoried before end")

        recoveryWork.reset()
        let afterRecovery = try await relaunched.reserve(streamId: fixture.streamId)
        try await relaunched.resolveObservation(
            afterRecovery,
            record: record(fixture, token: afterRecovery))
        XCTAssertEqual(
            recoveryWork.count(.fullLedgerReservationValidation),
            0)
        XCTAssertEqual(recoveryWork.count(.inventoryEntryFingerprint), 0)
        XCTAssertEqual(recoveryWork.count(.historicalRecordDecode), 0)
        XCTAssertEqual(recoveryWork.count(.targetedFileFingerprint), 0)

        _ = try await relaunched.closeInput()
        _ = try await relaunched.beginDraining()
        _ = try await relaunched.commit(
            endedAt: "2026-07-22T10:01:00.000Z")
        XCTAssertEqual(
            recoveryWork.count(.fullLedgerReservationValidation),
            observationCount + 2)
        XCTAssertEqual(
            recoveryWork.count(.historicalRecordDecode),
            observationCount + 2)
        XCTAssertGreaterThan(
            recoveryWork.count(.inventoryEntryFingerprint),
            observationCount + artifactCount)

        let committedInventory = try await JazzArchiveDraftStore(root: root)
            .inventory(archiveId: fixture.archiveId)
        XCTAssertEqual(
            committedInventory.entries.filter {
                $0.path.contains("/records/") && $0.path.hasSuffix(".ndjson")
            }.count,
            observationCount + 2)
        let package = try await JazzArchiveFinalizer(root: root).finalize(
            archiveId: fixture.archiveId,
            snapshotAt: "2026-07-22T10:02:00.000Z")
        XCTAssertFalse(package.inventory.entries.contains {
            $0.path.contains("/records/")
        })
        let compactRecords = try XCTUnwrap(
            package.inventory.entries.first {
                $0.path.hasSuffix("/records.ndjson")
            })
        let compactData = try Data(
            contentsOf: package.url.appendingPathComponent(compactRecords.path))
        XCTAssertEqual(
            String(decoding: compactData, as: UTF8.self)
                .split(separator: "\n").count,
            observationCount + 2)
    }

    func testQueueListingDoesNotHashPackagesButUploadReadStillFailsClosed() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let work = CaptureHotPathWorkRecorder()
        let queue = JazzArchiveUploadQueue(
            root: root,
            durability: foundationTestFilesystemDurability(),
            leaseProvider: TestArchiveFilesystemLeaseProvider.shared,
            workObserver: { work.record($0) })
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)

        var items: [JazzArchiveUploadItem] = []
        for index in 0..<3 {
            let source = root.appendingPathComponent("source-\(index).jazz-archive")
            try Data("immutable-package-\(index)".utf8).write(to: source)
            items.append(
                try await queue.enqueue(
                    file: source,
                    archiveId: Identifiers.newArchiveId(),
                    originId: Identifiers.newOriginId(),
                    captureIds: [Identifiers.newCaptureId()],
                    revision: 1,
                    contentDigest: String(repeating: "\(index)", count: 64),
                    scope: nil))
        }
        work.reset()

        let firstListing = try await queue.all()
        let secondListing = try await queue.all()
        XCTAssertEqual(firstListing.count, 3)
        XCTAssertEqual(secondListing.count, 3)
        XCTAssertEqual(work.count(.packageFingerprint), 0)

        let changed = items[1]
        let changedURL =
            root
            .appendingPathComponent("packages", isDirectory: true)
            .appendingPathComponent(changed.packageFileName)
        try Data("changed-package".utf8).write(to: changedURL, options: .atomic)

        // One damaged package no longer prevents the UI/worker from listing unrelated work.
        let listingWithChangedPackage = try await queue.all()
        XCTAssertEqual(listingWithChangedPackage.count, 3)
        XCTAssertEqual(work.count(.packageFingerprint), 0)

        _ = try await queue.packageURL(archiveId: items[0].archiveId)
        XCTAssertEqual(work.count(.packageFingerprint), 1)
        do {
            _ = try await queue.packageURL(archiveId: changed.archiveId)
            XCTFail("changed package must fail before object upload")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveUploadError,
                .packageChanged(changed.archiveId))
        }
        XCTAssertEqual(work.count(.packageFingerprint), 2)
    }

    func testRecoveryAndFinalCommitRetainStrictWholeArchiveVerification() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = makeFixture()
        let initial = makeJournal(root: root, work: CaptureHotPathWorkRecorder())
        _ = try await initial.begin(
            manifest: fixture.manifest,
            session: fixture.session)
        let token = try await initial.reserve(streamId: fixture.streamId)
        try await initial.resolveObservation(
            token,
            record: record(fixture, token: token))

        let recordsRoot =
            root
            .appendingPathComponent(
                "\(fixture.archiveId).jazz-archive.draft",
                isDirectory: true
            )
            .appendingPathComponent(fixture.manifest.sessions[0].path)
            .deletingLastPathComponent()
            .appendingPathComponent("records", isDirectory: true)
        let batch = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: recordsRoot,
                includingPropertiesForKeys: nil
            )
            .first(where: { $0.pathExtension == "ndjson" }))
        try Data("tampered\n".utf8).write(to: batch, options: .atomic)

        let relaunched = makeJournal(root: root, work: CaptureHotPathWorkRecorder())
        do {
            _ = try await relaunched.reopen(archiveId: fixture.archiveId)
            XCTFail("strict recovery must reject changed canonical evidence")
        } catch {
            guard case .corruptRecord = error as? JazzArchiveError else {
                return XCTFail("unexpected recovery error: \(error)")
            }
        }

        _ = try await initial.closeInput()
        _ = try await initial.beginDraining()
        do {
            _ = try await initial.commit(
                endedAt: "2026-07-22T10:01:00.000Z")
            XCTFail("strict final commit must reject changed canonical evidence")
        } catch {
            guard case .corruptRecord = error as? JazzArchiveError else {
                return XCTFail("unexpected commit error: \(error)")
            }
        }
    }

    private struct ByteProfile {
        var journalBytes: Int
        var draftBytes: Int
        var stateBytes: Int
        var inventoryBytes: Int
        var manifestBytes: Int
        var walSegments: Int
    }

    private struct RecoveryWorkProfile {
        var replayMutations: Int
        var ledgerValidations: Int
    }

    private func recoveryWorkProfile(
        observations: Int
    ) async throws -> RecoveryWorkProfile {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = makeFixture()
        let initial = makeJournal(root: root, work: CaptureHotPathWorkRecorder())
        _ = try await initial.begin(manifest: fixture.manifest, session: fixture.session)
        for _ in 0..<observations {
            let token = try await initial.reserve(streamId: fixture.streamId)
            try await initial.resolveObservation(
                token, record: record(fixture, token: token))
        }

        let work = CaptureHotPathWorkRecorder()
        let relaunched = makeJournal(root: root, work: work)
        let snapshot = try await relaunched.reopen(archiveId: fixture.archiveId)
        XCTAssertEqual(snapshot.resolvedObservationCount, observations)
        return RecoveryWorkProfile(
            replayMutations: work.count(.walReplayMutation),
            ledgerValidations: work.count(.fullLedgerReservationValidation))
    }

    private func captureByteProfile(observations: Int) async throws -> ByteProfile {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = makeFixture()
        let work = CaptureHotPathWorkRecorder()
        let journal = makeJournal(root: root, work: work)
        _ = try await journal.begin(manifest: fixture.manifest, session: fixture.session)
        work.reset()

        for _ in 0..<observations {
            let token = try await journal.reserve(streamId: fixture.streamId)
            try await journal.resolveObservation(
                token, record: record(fixture, token: token))
        }
        return try byteProfile(root: root, fixture: fixture, work: work)
    }

    private func artifactByteProfile(artifacts: Int) async throws -> ByteProfile {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = makeFixture()
        let work = CaptureHotPathWorkRecorder()
        let journal = makeJournal(root: root, work: work)
        _ = try await journal.begin(manifest: fixture.manifest, session: fixture.session)
        work.reset()

        for index in 0..<artifacts {
            let token = try await journal.reserveArtifact()
            _ = try await journal.ingestArtifact(
                token,
                bytes: Data("fixed-size-artifact-\(String(format: "%04d", index))".utf8),
                kind: "test_blob",
                mediaType: "application/octet-stream",
                sourceRefs: [
                    JazzArchiveSourceRef(sourceId: fixture.sourceId, role: "capture")
                ],
                provenance: JazzArchiveProvenance(
                    factClass: .observed,
                    sources: [fixture.sourceId]),
                quality: JazzArchiveQuality(status: .complete),
                privacy: JazzArchivePrivacy(
                    status: .captured,
                    policyVersion: "consent-v1"))
        }
        return try byteProfile(root: root, fixture: fixture, work: work)
    }

    private func byteProfile(
        root: URL,
        fixture: Fixture,
        work: CaptureHotPathWorkRecorder
    ) throws -> ByteProfile {
        let stateDirectory =
            root
            .appendingPathComponent(".capture-journal", isDirectory: true)
            .appendingPathComponent(fixture.archiveId, isDirectory: true)
        let archiveDirectory = root.appendingPathComponent(
            "\(fixture.archiveId).jazz-archive.draft", isDirectory: true)
        let walDirectory = stateDirectory.appendingPathComponent("wal", isDirectory: true)
        let walSegments =
            (try? FileManager.default.contentsOfDirectory(
                at: walDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]))?
            .filter { $0.pathExtension == "json" }
            .count
            ?? 0
        return ByteProfile(
            journalBytes: work.journalBytes(),
            draftBytes: work.draftBytes(),
            stateBytes: try Data(
                contentsOf: stateDirectory.appendingPathComponent("state.json")).count,
            inventoryBytes: try Data(
                contentsOf: archiveDirectory.appendingPathComponent("inventory.json")).count,
            manifestBytes: try Data(
                contentsOf: archiveDirectory.appendingPathComponent("manifest.json")).count,
            walSegments: walSegments)
    }

    private func makeJournal(
        root: URL,
        work: CaptureHotPathWorkRecorder
    ) -> CaptureJournal {
        CaptureJournal(
            root: root,
            durability: foundationTestFilesystemDurability(),
            journalWorkObserver: { work.record($0) },
            archiveWorkObserver: { work.record($0) })
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
            version: "hot-path-test",
            platform: "macOS")
        let actor = JazzArchiveActor(
            actorId: actorId,
            kind: .human,
            identityStatus: .identified,
            displayName: "Recorder",
            provenance: JazzArchiveProvenance(
                factClass: .declared,
                sources: []))
        let source = JazzArchiveSource(
            sourceId: sourceId,
            kind: "macos.hot-path-test",
            actorId: actorId,
            producer: producer,
            capabilities: ["pointer.click"],
            provenance: JazzArchiveProvenance(
                factClass: .observed,
                sources: []))
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
            sessions: [
                JazzArchiveSessionRef(
                    captureId: captureId,
                    legacySessionId: legacySessionId)
            ])
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
        ArchiveRecord(
            event: ActivityEvent(
                sessionId: fixture.legacySessionId,
                eventId: Identifiers.eventId(
                    sessionId: fixture.legacySessionId,
                    sequence: token.streamSequence),
                sequence: token.streamSequence,
                timestamp: startedAt,
                eventType: "click",
                url: "app://com.example.finance"),
            observationId: Identifiers.newObservationId(),
            originId: fixture.originId,
            captureId: fixture.captureId,
            streamId: fixture.streamId,
            streamSequence: token.streamSequence,
            sourceRefs: [
                JazzArchiveSourceRef(sourceId: fixture.sourceId, role: "trigger")
            ],
            actorRefs: [
                JazzArchiveActorRef(
                    actorId: fixture.actorId,
                    role: "operator",
                    basis: .observed,
                    method: "event_tap")
            ],
            provenance: JazzArchiveProvenance(
                factClass: .observed,
                sources: [fixture.sourceId]),
            quality: JazzArchiveQuality(status: .complete),
            privacy: JazzArchivePrivacy(
                status: .captured,
                policyVersion: "consent-v1"))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "capture-hot-path-\(UUID().uuidString)",
            isDirectory: true)
    }
}
