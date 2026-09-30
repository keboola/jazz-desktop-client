import XCTest

@testable import JazzCaptureCore

/// Replays of the formal/artifact-delivery TLA+ counterexamples against the real
/// `JazzArchiveDeliveryQueue` and `NarrationDedup`. Each test asserts the SAFE behaviour;
/// reproduced bugs are wrapped in `XCTExpectFailure`, so a fix turns the test red until the
/// wrapper is removed. See formal/artifact-delivery/README.md.
final class FormalArtifactDeliveryTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("formal-artifact-delivery-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func makeEntry(queuedAt: String = "2026-07-22T10:00:00.000Z")
        -> JazzArchiveDeliveryEntry
    {
        JazzArchiveDeliveryEntry(
            archiveId: Identifiers.newArchiveId(),
            captureId: Identifiers.newCaptureId(),
            artifactId: Identifiers.newArtifactId(),
            legacySessionId: Identifiers.newSessionId(),
            kind: "narration_audio",
            mediaType: "audio/mp4",
            fileName: "narration.m4a",
            tags: ["jazz", "jazz-artifact"],
            queuedAt: queuedAt)
    }

    /// Reproduces a crash between `writeOnce(receipt)` and `removeItem(pending)` in
    /// `markDelivered` (JazzArchiveDeliveryQueue.swift:161-169): the receipt is on disk and the
    /// pending entry still exists. This builds exactly that on-disk state.
    private func writeReceiptOnly(
        _ entry: JazzArchiveDeliveryEntry, remoteFileId: String
    ) throws {
        let delivered = root.appendingPathComponent("delivered", isDirectory: true)
        try FileManager.default.createDirectory(at: delivered, withIntermediateDirectories: true)
        let receipt = JazzArchiveDeliveryReceipt(
            entry: entry, remoteFileId: remoteFileId, deliveredAt: "2026-07-22T10:01:00.000Z")
        try JSONEncoder().encode(receipt).write(
            to: delivered.appendingPathComponent("\(entry.artifactId).json"))
    }

    /// Finding F1 (PendingClearedAfterReceipt / OnDeliveredOnce), fixed. After the crash, the
    /// next uploader pass re-finds the same remote file and calls markDelivered with the SAME
    /// id. markDelivered used to return the existing receipt without removing the pending
    /// entry, so drainOnce() re-listed/HEADed the item and fired onDelivered on every pass, and
    /// run() never waited for a nudge (hot loop). It now finishes the interrupted removal.
    func testF1RetryAfterCrashBetweenReceiptAndPendingRemovalClearsPending() async throws {
        let queue = JazzArchiveDeliveryQueue(root: root)
        let entry = makeEntry()
        _ = try await queue.enqueue(entry)
        try writeReceiptOnly(entry, remoteFileId: "1")

        let retried = try await queue.markDelivered(
            artifactId: entry.artifactId, remoteFileId: "1",
            deliveredAt: "2026-07-22T10:02:00.000Z")
        XCTAssertEqual(retried.remoteFileId, "1")
        let pendingAfterRetry = await queue.pending()
        XCTAssertEqual(pendingAfterRetry, [])

        // A second retry (no pending entry left) still returns the same receipt.
        let again = try await queue.markDelivered(
            artifactId: entry.artifactId, remoteFileId: "1",
            deliveredAt: "2026-07-22T10:03:00.000Z")
        XCTAssertEqual(again, retried)
    }

    /// Finding F2 (QueueProgress). Model trace: an orphan complete upload (id 1) exists — a
    /// crash after PUT, or a lost PUT response whose cleanup DELETE also failed; listFiles then
    /// returns [] (error or lag), a second upload (id 2) is receipted, and the process crashes
    /// before the pending entry is removed. Every later pass lists both complete copies,
    /// NarrationDedup reuses the OLDEST (id 1), and markDelivered(1) conflicts with the receipt
    /// (id 2): finish() returns false, drainOnce() returns false, and every item queued after
    /// this one is never attempted again.
    func testF2ReceiptedItemWithOlderDuplicateCanStillBeFinished() async throws {
        let queue = JazzArchiveDeliveryQueue(root: root)
        let entry = makeEntry()
        let later = makeEntry(queuedAt: "2026-07-22T10:05:00.000Z")
        _ = try await queue.enqueue(entry)
        _ = try await queue.enqueue(later)
        try writeReceiptOnly(entry, remoteFileId: "2")

        // What existingRemoteId() computes for a perfect listing (oldest first).
        let decision = NarrationDedup.decide([
            NarrationDedup.Candidate(fileId: 1, present: true),
            NarrationDedup.Candidate(fileId: 2, present: true),
        ])
        XCTAssertEqual(decision.reuseFileId, 1)
        let reuse = try XCTUnwrap(decision.reuseFileId)

        var finishError: Error?
        do {
            _ = try await queue.markDelivered(
                artifactId: entry.artifactId, remoteFileId: String(reuse))
        } catch {
            finishError = error
        }
        let pendingAfter = await queue.pending()

        XCTExpectFailure(
            "formal/artifact-delivery finding F2: dedup reuses the oldest complete copy, which "
                + "conflicts with the receipt, so the head item blocks the queue forever"
        ) {
            XCTAssertNil(finishError)
            XCTAssertEqual(pendingAfter.map(\.artifactId), [later.artifactId])
        }
    }

    /// DedupLemma (holds): for every candidate list up to length 3 over {true, false, nil}, the
    /// reused id is the first complete one, is never also deleted, and only HEAD-404 records
    /// are deleted.
    func testDedupLemmaExhaustive() {
        let values: [Bool?] = [true, false, nil]
        var lists: [[Bool?]] = [[]]
        var frontier: [[Bool?]] = [[]]
        for _ in 0..<3 {
            frontier = frontier.flatMap { prefix in values.map { prefix + [$0] } }
            lists += frontier
        }
        for presence in lists {
            let candidates = presence.enumerated().map {
                NarrationDedup.Candidate(fileId: $0.offset + 1, present: $0.element)
            }
            let decision = NarrationDedup.decide(candidates)
            let firstComplete = candidates.first { $0.present == true }?.fileId
            XCTAssertEqual(decision.reuseFileId, firstComplete, "\(presence)")
            if let reuse = decision.reuseFileId {
                XCTAssertFalse(decision.danglingToDelete.contains(reuse), "\(presence)")
            }
            XCTAssertEqual(
                decision.danglingToDelete,
                candidates.filter { $0.present == false }.map(\.fileId),
                "\(presence)")
        }
    }
}
