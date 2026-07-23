import XCTest

@testable import JasnostCaptureCore

final class PointerGestureTrackerTests: XCTestCase {
    func testClickIsPublishedOnlyOnceAtMouseUp() throws {
        var tracker = PointerGestureTracker()
        tracker.mouseDown(
            at: PointerPoint(x: 10, y: 20), clickCount: 2,
            gestureId: "gesture-019b7c6e-e400-7000-8000-000000000001")

        let completed = try XCTUnwrap(tracker.mouseUp(at: PointerPoint(x: 10, y: 20)))
        XCTAssertEqual(completed.kind, .click)
        XCTAssertEqual(completed.clickCount, 2)
        XCTAssertNil(completed.end)
        XCTAssertNil(tracker.mouseUp(at: PointerPoint(x: 10, y: 20)))
    }

    func testDragDoesNotAlsoEmitInitialClick() throws {
        var tracker = PointerGestureTracker()
        tracker.mouseDown(
            at: PointerPoint(x: 10, y: 20), clickCount: 1,
            gestureId: "gesture-019b7c6e-e400-7000-8000-000000000002")
        tracker.mouseDragged()

        let completed = try XCTUnwrap(tracker.mouseUp(at: PointerPoint(x: 30, y: 40)))
        XCTAssertEqual(completed.kind, .drag)
        XCTAssertEqual(completed.start, PointerPoint(x: 10, y: 20))
        XCTAssertEqual(completed.end, PointerPoint(x: 30, y: 40))
        XCTAssertNil(tracker.mouseUp(at: PointerPoint(x: 30, y: 40)))
    }

    func testMouseUpWithoutDownAndResetProduceNoObservation() {
        var tracker = PointerGestureTracker()
        XCTAssertNil(tracker.mouseUp(at: PointerPoint(x: 1, y: 2)))
        tracker.mouseDown(
            at: PointerPoint(x: 1, y: 2), clickCount: 0,
            gestureId: "gesture-019b7c6e-e400-7000-8000-000000000003")
        tracker.reset()
        XCTAssertNil(tracker.mouseUp(at: PointerPoint(x: 1, y: 2)))
    }
}
