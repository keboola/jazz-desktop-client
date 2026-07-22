import XCTest

@testable import JasnostCaptureCore

/// Tests for the durable narration audio spool. Each test runs against its own temp dir.
final class NarrationSpoolTests: XCTestCase {
    private var root: URL!
    private var spool: NarrationSpool!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jasnost-narration-tests-\(UUID().uuidString)")
        spool = NarrationSpool(directory: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A throwaway m4a-ish blob in a fresh temp file (the recorder's temp output stand-in).
    private func tempAudio(bytes: Int = 16) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("narration-src-\(UUID().uuidString).m4a")
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        return url
    }

    private func meta(
        session: String = "s-1", label: String = "l-1", labelName: String = "Invoicing",
        sequence: Int = 5, startedAt: String = "2026-06-16T10:00:00.000Z",
        stagedAt: String = "2026-06-16T10:01:00.000Z"
    ) -> NarrationSpool.PendingNarration {
        NarrationSpool.PendingNarration(
            sessionId: session, labelId: label, label: labelName, sequence: sequence,
            startedAt: startedAt, stagedAt: stagedAt)
    }

    func testStageMovesTempFileIntoSpoolAndPersistsSidecar() throws {
        let src = try tempAudio()
        let staged = try spool.stage(audioURL: src, meta: meta())

        // The temp source is consumed (moved), the durable blob exists, and pending() round-trips
        // the sidecar metadata.
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.audioURL.path))
        let pending = spool.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].meta, meta())
        XCTAssertEqual(pending[0].audioURL, staged.audioURL)
    }

    func testPendingSortsBySessionThenSequence() throws {
        try spool.stage(audioURL: try tempAudio(), meta: meta(session: "s-2", label: "l-a", sequence: 1))
        try spool.stage(audioURL: try tempAudio(), meta: meta(session: "s-1", label: "l-b", sequence: 9))
        try spool.stage(audioURL: try tempAudio(), meta: meta(session: "s-1", label: "l-c", sequence: 2))

        XCTAssertEqual(
            spool.pending().map { "\($0.meta.sessionId)#\($0.meta.sequence)" },
            ["s-1#2", "s-1#9", "s-2#1"])
    }

    func testRemoveDeletesBlobSidecarAndEmptiedSessionDir() throws {
        try spool.stage(audioURL: try tempAudio(), meta: meta())
        let item = spool.pending()[0]
        spool.remove(item)
        XCTAssertTrue(spool.pending().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.audioURL.path))
        // The emptied session dir is pruned.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("s-1").path))
    }

    func testPendingSkipsCorruptSidecarAndBlobWithoutSidecar() throws {
        try spool.stage(audioURL: try tempAudio(), meta: meta(label: "l-good"))
        let dir = root.appendingPathComponent("s-1")

        // A corrupt sidecar: skipped, must not throw.
        try Data("{broken".utf8).write(to: dir.appendingPathComponent("l-bad.json"))
        try Data(repeating: 0, count: 8).write(to: dir.appendingPathComponent("l-bad.m4a"))
        // A sidecar whose blob is missing is also skipped (sidecar without an .m4a).
        let orphanMeta = meta(label: "l-orphan")
        try JSONEncoder().encode(orphanMeta)
            .write(to: dir.appendingPathComponent("l-orphan.json"))

        XCTAssertEqual(spool.pending().map(\.meta.labelId), ["l-good"])
    }

    func testRetentionEvictsByAgeOldestFirst() throws {
        try spool.stage(
            audioURL: try tempAudio(), meta: meta(label: "l-old", stagedAt: "2026-06-01T10:00:00.000Z"))
        try spool.stage(
            audioURL: try tempAudio(), meta: meta(label: "l-new", stagedAt: "2026-06-16T10:00:00.000Z"))

        // "Now" is 16 Jun; maxAge is 14 days, so the 1 Jun clip is past it, the 16 Jun one isn't.
        let now = Timestamps.parse("2026-06-16T10:05:00.000Z")!
        let evicted = spool.enforceRetention(now: now)
        XCTAssertEqual(evicted.map(\.labelId), ["l-old"])
        XCTAssertEqual(spool.pending().map(\.meta.labelId), ["l-new"])
    }

    func testRetentionEvictsBySizeOldestFirstUntilWithinBudget() throws {
        // Three 1 KB clips with a tiny ceiling: keep dropping the oldest until within budget.
        try spool.stage(
            audioURL: try tempAudio(bytes: 1024),
            meta: meta(label: "l-1", stagedAt: "2026-06-16T10:00:01.000Z"))
        try spool.stage(
            audioURL: try tempAudio(bytes: 1024),
            meta: meta(label: "l-2", stagedAt: "2026-06-16T10:00:02.000Z"))
        try spool.stage(
            audioURL: try tempAudio(bytes: 1024),
            meta: meta(label: "l-3", stagedAt: "2026-06-16T10:00:03.000Z"))

        // 2 KB ceiling leaves room for ~2 of the 1 KB clips → the oldest is dropped.
        let evicted = spool.enforceRetention(
            maxBytes: 2048, now: Timestamps.parse("2026-06-16T10:00:10.000Z")!)
        XCTAssertEqual(evicted.map(\.labelId), ["l-1"])  // one drop brings 3 KB → 2 KB
        XCTAssertEqual(spool.pending().map(\.meta.labelId).sorted(), ["l-2", "l-3"])
    }

    func testTotalBytesSumsBlobs() throws {
        try spool.stage(audioURL: try tempAudio(bytes: 100), meta: meta(label: "l-1"))
        try spool.stage(audioURL: try tempAudio(bytes: 200), meta: meta(label: "l-2"))
        XCTAssertEqual(spool.totalBytes(), 300)
    }

    func testSidecarRoundTripsProcessPickAndDecodesLegacySidecars() throws {
        // A Guided-capture sidecar round-trips the process pick…
        var guided = meta(label: "l-guided")
        guided.processId = "invoicing"
        guided.processName = "Invoicing"
        try spool.stage(audioURL: try tempAudio(), meta: guided)
        // …and a sidecar staged BEFORE the process fields existed (no keys at all) still decodes.
        let dir = root.appendingPathComponent("s-1")
        let legacy = """
            {"sessionId": "s-1", "labelId": "l-legacy", "label": "Old label", "sequence": 1,
             "startedAt": "2026-06-16T10:00:00.000Z", "stagedAt": "2026-06-16T10:01:00.000Z"}
            """
        try Data(legacy.utf8).write(to: dir.appendingPathComponent("l-legacy.json"))
        try Data(repeating: 0xAB, count: 8).write(to: dir.appendingPathComponent("l-legacy.m4a"))

        let byLabel = Dictionary(
            uniqueKeysWithValues: spool.pending().map { ($0.meta.labelId, $0.meta) })
        XCTAssertEqual(byLabel["l-guided"]?.processId, "invoicing")
        XCTAssertEqual(byLabel["l-guided"]?.processName, "Invoicing")
        XCTAssertEqual(byLabel["l-legacy"]?.label, "Old label")
        XCTAssertNil(byLabel["l-legacy"]?.processId)
    }
}
