import XCTest

@testable import JasnostCaptureCore

final class RecordingIndicatorTests: XCTestCase {
    func testElapsedFormatting() {
        XCTAssertEqual(RecordingIndicator.elapsed(0), "0:00")
        XCTAssertEqual(RecordingIndicator.elapsed(7), "0:07")
        XCTAssertEqual(RecordingIndicator.elapsed(154), "2:34")
        XCTAssertEqual(RecordingIndicator.elapsed(3725), "1:02:05")
        XCTAssertEqual(RecordingIndicator.elapsed(-5), "0:00")  // clamps
    }

    func testMenuBarTitle() {
        XCTAssertEqual(RecordingIndicator.menuBarTitle(elapsed: 154, events: 47), "● 2:34 · 47")
    }

    func testStatusLinePluralisationAndMode() {
        XCTAssertEqual(
            RecordingIndicator.statusLine(elapsed: 154, events: 47, workshop: false),
            "Recording 2:34 · 47 events")
        XCTAssertEqual(
            RecordingIndicator.statusLine(elapsed: 60, events: 1, workshop: true),
            "BDM workshop 1:00 · 1 event")
    }
}
