import Foundation
import JazzCaptureCore
import XCTest

@testable import JazzCapture

final class CaptureJournalLeaseTests: XCTestCase {
    func testNativeJournalLeaseExcludesSecondOwnerUntilRelease() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "journal-lease-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = JazzArchiveFilesystemPlatform.captureJournalLeaseProvider
        let first = try provider.acquire(root: root, fileManager: .default)
        XCTAssertThrowsError(try provider.acquire(root: root, fileManager: .default)) {
            XCTAssertEqual($0 as? JazzArchiveFilesystemLeaseError, .inProgress)
        }
        first.release()
        let second = try provider.acquire(root: root, fileManager: .default)
        second.release()
    }
}
