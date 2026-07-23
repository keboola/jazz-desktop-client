import XCTest

@testable import JasnostCaptureCore

final class JazzArchiveDeliveryQueueTests: XCTestCase {
    func testQueueIsIdempotentAndKeepsDurableReceipt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-delivery-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = JazzArchiveDeliveryQueue(root: root)
        let entry = JazzArchiveDeliveryEntry(
            archiveId: Identifiers.newArchiveId(),
            captureId: Identifiers.newCaptureId(),
            artifactId: Identifiers.newArtifactId(),
            legacySessionId: Identifiers.newSessionId(),
            kind: "screenshot",
            mediaType: "image/jpeg",
            fileName: "screen.jpg",
            tags: ["jasnost", "jazz-artifact"],
            queuedAt: "2026-07-22T10:00:00.000Z")
        let firstEnqueue = try await queue.enqueue(entry)
        let duplicateEnqueue = try await queue.enqueue(entry)
        XCTAssertTrue(firstEnqueue)
        XCTAssertFalse(duplicateEnqueue)
        let pending = await queue.pending()
        XCTAssertEqual(pending, [entry])

        let receipt = try await queue.markDelivered(
            artifactId: entry.artifactId,
            remoteFileId: "123",
            deliveredAt: "2026-07-22T10:01:00.000Z")
        XCTAssertEqual(receipt.entry, entry)
        let pendingAfterDelivery = await queue.pending()
        let durableReceipt = await queue.receipt(artifactId: entry.artifactId)
        let enqueueAfterDelivery = try await queue.enqueue(entry)
        XCTAssertEqual(pendingAfterDelivery, [])
        XCTAssertEqual(durableReceipt, receipt)
        XCTAssertFalse(enqueueAfterDelivery)
    }

    func testQueueRejectsConflictingRetry() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-delivery-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = JazzArchiveDeliveryQueue(root: root)
        let artifactId = Identifiers.newArtifactId()
        let first = JazzArchiveDeliveryEntry(
            archiveId: Identifiers.newArchiveId(),
            captureId: Identifiers.newCaptureId(),
            artifactId: artifactId,
            legacySessionId: Identifiers.newSessionId(),
            kind: "screenshot",
            mediaType: "image/jpeg",
            fileName: "screen.jpg",
            tags: ["jasnost"],
            queuedAt: "2026-07-22T10:00:00.000Z")
        _ = try await queue.enqueue(first)
        var conflicting = first
        conflicting.fileName = "other.jpg"
        do {
            _ = try await queue.enqueue(conflicting)
            XCTFail("expected conflict")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveDeliveryQueueError,
                .conflict(artifactId))
        }
    }
}
