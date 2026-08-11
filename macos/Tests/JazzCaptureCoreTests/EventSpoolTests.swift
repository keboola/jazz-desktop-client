import XCTest

@testable import JazzCaptureCore

/// Tests for the durable spool + journal. Each test runs against its own temp root.
final class EventSpoolTests: XCTestCase {
    private var root: URL!
    private var spool: EventSpool!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jazz-spool-tests-\(UUID().uuidString)")
        spool = EventSpool(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func meta(
        _ sessionId: String, startedAt: String = "2026-06-13T10:00:00.000Z",
        kind: String? = nil
    ) -> EventSpool.SessionMeta {
        EventSpool.SessionMeta(
            sessionId: sessionId,
            traceId: "aaaa1111bbbb2222cccc3333dddd4444",
            spanId: "abcd1234abcd1234",
            startedAt: startedAt,
            kind: kind,
            user: "petr@example.com"
        )
    }

    private func event(
        _ sessionId: String, seq: Int?, type: String = "click", value: String? = nil
    ) -> ActivityEvent {
        ActivityEvent(
            sessionId: sessionId,
            eventId: "\(sessionId)-\(seq ?? 0)",
            sequence: seq,
            timestamp: "2026-06-13T10:00:00.000Z",
            eventType: type,
            url: "app://x",
            value: value
        )
    }

    func testSpoolJournalRoundtrip() throws {
        try spool.createSession(meta("s-1", kind: "bdm-workshop"))
        try spool.appendBatch(sessionId: "s-1", events: [event("s-1", seq: 0), event("s-1", seq: 1)])
        try spool.appendBatch(sessionId: "s-1", events: [event("s-1", seq: 2)])

        var pending = spool.pendingBatches()
        XCTAssertEqual(pending.count, 2)
        XCTAssertEqual(pending.map(\.sessionId), ["s-1", "s-1"])

        // Ship the first batch; it moves to the journal, the second stays pending.
        try spool.markSent(pending[0])
        pending = spool.pendingBatches()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].url.lastPathComponent, "batch-00000002.ndjson")

        let sessions = spool.sessions()
        XCTAssertEqual(sessions.count, 1)
        let s = sessions[0]
        XCTAssertEqual(s.id, "s-1")
        XCTAssertEqual(s.startedAt, "2026-06-13T10:00:00.000Z")
        XCTAssertEqual(s.kind, "bdm-workshop")
        XCTAssertEqual(s.user, "petr@example.com")
        XCTAssertEqual(s.eventCount, 3)
        XCTAssertEqual(s.sentCount, 2)
        XCTAssertEqual(s.pendingCount, 1)
        XCTAssertNil(s.endedAt)
    }

    func testBatchFilenamesKeepNumericFIFOOrder() throws {
        try spool.createSession(meta("s-1"))
        // Without zero-padding "batch-10" would sort before "batch-2" and break FIFO.
        try spool.appendBatch(sessionId: "s-1", events: [event("s-1", seq: 2)])
        try spool.appendBatch(sessionId: "s-1", events: [event("s-1", seq: 10)])
        let names = spool.pendingBatches().map(\.url.lastPathComponent)
        XCTAssertEqual(names, ["batch-00000002.ndjson", "batch-00000010.ndjson"])
    }

    func testSequencelessBatchesGetUniqueNames() throws {
        try spool.createSession(meta("s-1"))
        // Both pad as sequence 0 — the collision suffix must keep them distinct.
        try spool.appendBatch(sessionId: "s-1", events: [event("s-1", seq: nil)])
        try spool.appendBatch(sessionId: "s-1", events: [event("s-1", seq: nil)])
        XCTAssertEqual(spool.pendingBatches().count, 2)
        XCTAssertEqual(spool.sessions()[0].pendingCount, 2)
    }

    func testEmptyBatchWritesNothing() throws {
        try spool.createSession(meta("s-1"))
        XCTAssertNil(try spool.appendBatch(sessionId: "s-1", events: []))
        XCTAssertTrue(spool.pendingBatches().isEmpty)
    }

    func testCreateSessionNeverOverwritesAnExistingIdentity() throws {
        let original = meta("s-1", startedAt: "2026-06-13T10:00:00.000Z")
        try spool.createSession(original)

        let conflicting = meta("s-1", startedAt: "2026-06-14T11:00:00.000Z")
        XCTAssertThrowsError(try spool.createSession(conflicting)) { error in
            XCTAssertEqual(error as? EventSpool.SpoolError, .sessionAlreadyExists("s-1"))
        }
        XCTAssertEqual(spool.sessionMeta(sessionId: "s-1"), original)
    }

    func testCanonicalObservationProjectionIsIdempotentAndConflictSafe() throws {
        try spool.createSession(meta("s-1"))
        let observationId = Identifiers.newObservationId()
        let original = event("s-1", seq: 3)
        let first = try XCTUnwrap(try spool.appendProjection(
            sessionId: "s-1", observationId: observationId, event: original))
        let repeated = try XCTUnwrap(try spool.appendProjection(
            sessionId: "s-1", observationId: observationId, event: original))
        XCTAssertEqual(first.url, repeated.url)
        XCTAssertEqual(spool.pendingBatches().count, 1)

        var conflicting = original
        conflicting.eventType = "scroll"
        XCTAssertThrowsError(try spool.appendProjection(
            sessionId: "s-1", observationId: observationId, event: conflicting)) { error in
            XCTAssertEqual(
                error as? EventSpool.SpoolError,
                .projectionConflict(observationId))
        }

        try spool.markSent(first)
        XCTAssertNil(try spool.appendProjection(
            sessionId: "s-1", observationId: observationId, event: original))
        XCTAssertEqual(spool.sessionEvents(sessionId: "s-1"), [original])
    }

    func testEndSessionUpdatesMetaAndUnknownSessionThrows() throws {
        try spool.createSession(meta("s-1"))
        try spool.endSession(sessionId: "s-1", endedAt: "2026-06-13T10:05:00.000Z")
        XCTAssertEqual(spool.sessions()[0].endedAt, "2026-06-13T10:05:00.000Z")
        XCTAssertEqual(spool.sessionMeta(sessionId: "s-1")?.endedAt, "2026-06-13T10:05:00.000Z")

        XCTAssertThrowsError(try spool.endSession(sessionId: "s-x", endedAt: "now")) { error in
            XCTAssertEqual(error as? EventSpool.SpoolError, .sessionNotFound("s-x"))
        }
    }

    func testJournalIsSelfContainedAfterSpoolCleanup() throws {
        try spool.createSession(meta("s-1"))
        try spool.appendBatch(sessionId: "s-1", events: [event("s-1", seq: 0)])
        try spool.markSent(spool.pendingBatches()[0])

        // Simulate a later spool cleanup: only the journal remains.
        try FileManager.default.removeItem(at: root.appendingPathComponent("s-1"))
        let sessions = spool.sessions()
        XCTAssertEqual(sessions.count, 1)
        // The meta mirror written by markSent keeps the listing intact.
        XCTAssertEqual(sessions[0].startedAt, "2026-06-13T10:00:00.000Z")
        XCTAssertEqual(sessions[0].sentCount, 1)
        XCTAssertEqual(sessions[0].pendingCount, 0)
    }

    func testLabelsCollectAnnotationValuesInOrder() throws {
        try spool.createSession(meta("s-1"))
        try spool.appendBatch(
            sessionId: "s-1",
            events: [
                event("s-1", seq: 0, type: "session_start"),
                event("s-1", seq: 1, type: "annotation", value: "Invoicing"),
            ])
        try spool.markSent(spool.pendingBatches()[0])  // first labels come from the journal
        try spool.appendBatch(
            sessionId: "s-1",
            events: [
                event("s-1", seq: 2, type: "annotation", value: "Reconciliation"),
                event("s-1", seq: 3, type: "annotation", value: ""),  // empty label dropped
                event("s-1", seq: 4, type: "click", value: "not-a-label"),
            ])
        XCTAssertEqual(spool.sessions()[0].labels, ["Invoicing", "Reconciliation"])
    }

    func testListingToleratesCorruption() throws {
        try spool.createSession(meta("s-1"))
        try spool.appendBatch(sessionId: "s-1", events: [event("s-1", seq: 0)])

        let dir = root.appendingPathComponent("s-1")
        // A batch with one good line between garbage and a JSON non-event.
        let mixed = """
            this is not json
            {"unrelated": true}
            {"sessionId":"s-1","eventId":"s-1-1","timestamp":"2026-06-13T10:00:01Z",\
            "eventType":"annotation","url":"app://session","value":"Good line"}
            """
        try Data(mixed.utf8).write(to: dir.appendingPathComponent("batch-00000001.ndjson"))
        // Corrupt meta: the session must still list (with unknown start) — never throw.
        try Data("{broken".utf8).write(to: dir.appendingPathComponent("meta.json"))
        // Stray non-session file at the root must be ignored.
        try Data("noise".utf8).write(to: root.appendingPathComponent("stray.txt"))

        let sessions = spool.sessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].id, "s-1")
        XCTAssertNil(sessions[0].startedAt)  // meta was corrupt
        XCTAssertEqual(sessions[0].eventCount, 2)  // good event + good line; garbage skipped
        XCTAssertEqual(sessions[0].labels, ["Good line"])
    }

    func testSessionsSortNewestFirst() throws {
        try spool.createSession(meta("s-old", startedAt: "2026-06-12T08:00:00.000Z"))
        try spool.createSession(meta("s-new", startedAt: "2026-06-13T09:00:00.000Z"))
        XCTAssertEqual(spool.sessions().map(\.id), ["s-new", "s-old"])
    }

    func testArchiveDraftRootIsNotListedAsAnEventSession() throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("archives/ar-example.jazz-archive.draft"),
            withIntermediateDirectories: true)
        XCTAssertTrue(spool.sessions().isEmpty)
    }

    func testReadEventsRoundtripAndCorruptionTolerance() throws {
        try spool.createSession(meta("s-1"))
        let written = [event("s-1", seq: 0), event("s-1", seq: 1, type: "annotation", value: "X")]
        try spool.appendBatch(sessionId: "s-1", events: written)
        let batch = spool.pendingBatches()[0]
        XCTAssertEqual(spool.readEvents(batch), written)

        // A corrupt line in the middle must not block the surrounding good lines.
        let dir = root.appendingPathComponent("s-1")
        let mixed = """
            {"sessionId":"s-1","eventId":"s-1-2","sequence":2,\
            "timestamp":"2026-06-13T10:00:02.000Z","eventType":"click","url":"app://x"}
            garbage line
            {"sessionId":"s-1","eventId":"s-1-3","sequence":3,\
            "timestamp":"2026-06-13T10:00:03.000Z","eventType":"click","url":"app://x"}
            """
        let mixedURL = dir.appendingPathComponent("batch-00000002.ndjson")
        try Data(mixed.utf8).write(to: mixedURL)
        let events = spool.readEvents(EventSpool.PendingBatch(sessionId: "s-1", url: mixedURL))
        XCTAssertEqual(events.map(\.sequence), [2, 3])

        // An unreadable file yields [] rather than throwing.
        let missing = EventSpool.PendingBatch(
            sessionId: "s-1", url: dir.appendingPathComponent("batch-99999999.ndjson"))
        XCTAssertEqual(spool.readEvents(missing), [])
    }

    func testInstanceNamePersistsAndDecodesMissingAsEmpty() throws {
        // instanceName survives a meta write/read so the sender can rebuild host.name after a
        // crash, even once only the journal remains.
        let m = EventSpool.SessionMeta(
            sessionId: "s-1",
            traceId: "aaaa1111bbbb2222cccc3333dddd4444",
            spanId: "abcd1234abcd1234",
            startedAt: "2026-06-13T10:00:00.000Z",
            user: "petr@example.com",
            instanceName: "Padak's MacBook Pro"
        )
        try spool.createSession(m)
        XCTAssertEqual(spool.sessionMeta(sessionId: "s-1")?.instanceName, "Padak's MacBook Pro")

        // meta.json written before this field existed (no host.name key) must decode with
        // instanceName == "" rather than failing the whole record (crash-recovery tolerance).
        let legacy = """
            {"sessionId":"s-old","traceId":"aaaa1111bbbb2222cccc3333dddd4444",\
            "spanId":"abcd1234abcd1234","startedAt":"2026-06-13T10:00:00.000Z",\
            "user":"petr@example.com","schemaVersion":1}
            """
        let dir = root.appendingPathComponent("s-old")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(legacy.utf8).write(to: dir.appendingPathComponent("meta.json"))
        let recovered = spool.sessionMeta(sessionId: "s-old")
        XCTAssertEqual(recovered?.user, "petr@example.com")
        XCTAssertEqual(recovered?.instanceName, "")
    }

    func testSpanLifecycleGatesOnEndAndDrain() throws {
        try spool.createSession(meta("s-1"))
        try spool.appendBatch(sessionId: "s-1", events: [event("s-1", seq: 0)])

        // Not ended yet -> no span.
        XCTAssertTrue(spool.sessionsAwaitingSpan().isEmpty)

        // Ended but a batch is still pending -> the span must wait (logs ship first).
        try spool.endSession(sessionId: "s-1", endedAt: "2026-06-13T10:05:00.000Z")
        XCTAssertTrue(spool.sessionsAwaitingSpan().isEmpty)

        // All batches journaled -> the span is ready, carrying the persisted ids + endedAt.
        try spool.markSent(spool.pendingBatches()[0])
        let awaiting = spool.sessionsAwaitingSpan()
        XCTAssertEqual(awaiting.map(\.sessionId), ["s-1"])
        XCTAssertEqual(awaiting[0].endedAt, "2026-06-13T10:05:00.000Z")
        XCTAssertEqual(awaiting[0].traceId, "aaaa1111bbbb2222cccc3333dddd4444")

        // markSpanSent is durable: never awaiting again, even with only the journal left.
        XCTAssertFalse(spool.isSpanSent(sessionId: "s-1"))
        try spool.markSpanSent(sessionId: "s-1")
        XCTAssertTrue(spool.isSpanSent(sessionId: "s-1"))
        XCTAssertTrue(spool.sessionsAwaitingSpan().isEmpty)
        try FileManager.default.removeItem(at: root.appendingPathComponent("s-1"))
        XCTAssertTrue(spool.isSpanSent(sessionId: "s-1"))
        XCTAssertTrue(spool.sessionsAwaitingSpan().isEmpty)
    }

    func testSpansAwaitInCaptureOrder() throws {
        try spool.createSession(meta("s-b", startedAt: "2026-06-13T11:00:00.000Z"))
        try spool.createSession(meta("s-a", startedAt: "2026-06-13T10:00:00.000Z"))
        try spool.endSession(sessionId: "s-b", endedAt: "2026-06-13T11:05:00.000Z")
        try spool.endSession(sessionId: "s-a", endedAt: "2026-06-13T10:05:00.000Z")
        XCTAssertEqual(spool.sessionsAwaitingSpan().map(\.sessionId), ["s-a", "s-b"])
    }

    func testReservedSubsystemDirsAreNotSessions() throws {
        // Subsystem-owned roots may never show up as phantom sessions in listings or pending scans.
        for name in ["shots", "narration", "guided-execution"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try spool.createSession(meta("s-1"))
        XCTAssertEqual(spool.sessions().map(\.id), ["s-1"])
        XCTAssertTrue(spool.pendingBatches().isEmpty)
        XCTAssertTrue(spool.sessionsAwaitingSpan().isEmpty)
    }

    func testSessionEventsMergeJournalThenSpoolInOrder() throws {
        try spool.createSession(meta("s-1"))
        try spool.appendBatch(sessionId: "s-1", events: [event("s-1", seq: 0), event("s-1", seq: 1)])
        try spool.appendBatch(sessionId: "s-1", events: [event("s-1", seq: 2)])
        // Ship the first batch — its events must still come FIRST in the merged read.
        try spool.markSent(spool.pendingBatches()[0])
        try spool.appendBatch(sessionId: "s-1", events: [event("s-1", seq: 3)])

        let events = spool.sessionEvents(sessionId: "s-1")
        XCTAssertEqual(events.map(\.sequence), [0, 1, 2, 3])
    }

    func testSessionEventsToleratesCorruptLines() throws {
        try spool.createSession(meta("s-1"))
        let batch = try XCTUnwrap(
            spool.appendBatch(sessionId: "s-1", events: [event("s-1", seq: 0)]))
        var text = String(decoding: try Data(contentsOf: batch.url), as: UTF8.self)
        text += "{not json}\n"
        try Data(text.utf8).write(to: batch.url)
        XCTAssertEqual(spool.sessionEvents(sessionId: "s-1").count, 1)
        XCTAssertTrue(spool.sessionEvents(sessionId: "s-unknown").isEmpty)
    }

    func testSummaryDurationAndStartDisplay() throws {
        try spool.createSession(meta("s-1"))
        try spool.endSession(sessionId: "s-1", endedAt: "2026-06-13T10:05:23.000Z")
        let summary = try XCTUnwrap(spool.sessions().first)
        XCTAssertEqual(summary.durationDisplay, "5m 23s")
        XCTAssertFalse(summary.startedDisplay.isEmpty)

        // Open session (no endedAt) renders no duration rather than garbage.
        try spool.createSession(meta("s-2", startedAt: "2026-06-13T11:00:00.000Z"))
        let open = try XCTUnwrap(spool.sessions().first { $0.id == "s-2" })
        XCTAssertEqual(open.durationDisplay, "")
    }

    func testFormatDurationBuckets() {
        XCTAssertEqual(EventSpool.SessionSummary.formatDuration(23), "23s")
        XCTAssertEqual(EventSpool.SessionSummary.formatDuration(323), "5m 23s")
        XCTAssertEqual(EventSpool.SessionSummary.formatDuration(3900), "1h 05m")
        XCTAssertEqual(EventSpool.SessionSummary.formatDuration(-5), "0s")
    }
}
