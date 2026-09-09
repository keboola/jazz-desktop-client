import Foundation
import XCTest

@testable import JazzCapture
@testable import JazzCaptureCore

@MainActor
final class NarrationAdmissionTests: XCTestCase {
    func testMetadataFailurePrecedesNativeRecorderAdmissionAndPreservesDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("synthetic.m4a")
        let bytes = Data("sole-source sentinel; not actual audio".utf8)
        try bytes.write(to: url)
        let recorder = NarrationRecorder()
        var attempted = false
        XCTAssertThrowsError(try recorder.start(
            at: url,
            persistStart: { timestamp in
                attempted = true
                XCTAssertNotNil(Timestamps.parse(timestamp))
                throw JazzArchiveFilesystemDurabilityError.synchronizationFailed
            },
            persistStop: { _, _ in XCTFail("unadmitted recorder cannot claim a stop") })) {
                XCTAssertEqual($0 as? JazzArchiveFilesystemDurabilityError, .synchronizationFailed)
            }
        XCTAssertTrue(attempted)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertNil(recorder.stop())
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        // The throwing admission hook runs before any AVAudioRecorder construction/mic access.
    }
}
