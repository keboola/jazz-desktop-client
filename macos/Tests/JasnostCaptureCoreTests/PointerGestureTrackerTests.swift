import XCTest

@testable import JasnostCaptureCore

final class PointerGestureTrackerTests: XCTestCase {
    private let firstGestureId = "gesture-019b7c6e-e400-7000-8000-000000000001"
    private let secondGestureId = "gesture-019b7c6e-e400-7000-8000-000000000002"
    private let thirdGestureId = "gesture-019b7c6e-e400-7000-8000-000000000003"
    private let firstSampleId = "sample-019b7c6e-e400-7000-8000-000000000001"
    private let secondSampleId = "sample-019b7c6e-e400-7000-8000-000000000002"
    private let thirdSampleId = "sample-019b7c6e-e400-7000-8000-000000000003"

    func testPhysicalDoubleClickSequenceProducesOneLogicalDoubleClick() throws {
        var tracker = PointerGestureTracker(doubleClickInterval: 0.5)

        XCTAssertEqual(
            tracker.mouseDown(
                at: PointerPoint(x: 10, y: 20), clickCount: 1,
                sampleId: firstSampleId,
                gestureId: firstGestureId, timestamp: 1.0),
            [])
        let firstUpdate = try XCTUnwrap(
            tracker.mouseUp(at: PointerPoint(x: 10, y: 20), timestamp: 1.01))
        XCTAssertEqual(firstUpdate.sample.sampleId, firstSampleId)
        XCTAssertEqual(firstUpdate.sample.gestureId, firstGestureId)
        XCTAssertEqual(firstUpdate.resolutions, [])
        XCTAssertEqual(
            try XCTUnwrap(tracker.nextClickDeadline),
            1.51,
            accuracy: 0.000_001)

        XCTAssertEqual(
            tracker.mouseDown(
                at: PointerPoint(x: 10, y: 20), clickCount: 2,
                sampleId: secondSampleId,
                gestureId: secondGestureId, timestamp: 1.2),
            [])
        XCTAssertNil(tracker.nextClickDeadline)
        let secondUpdate = try XCTUnwrap(
            tracker.mouseUp(at: PointerPoint(x: 10, y: 20), timestamp: 1.21))
        XCTAssertEqual(secondUpdate.sample.sampleId, secondSampleId)
        XCTAssertEqual(secondUpdate.sample.gestureId, firstGestureId)
        XCTAssertEqual(secondUpdate.resolutions, [])

        XCTAssertEqual(tracker.flushExpired(at: 1.70), [])
        let completed = try XCTUnwrap(tracker.flushExpired(at: 1.71).only)
        XCTAssertEqual(completed.kind, .click)
        XCTAssertEqual(completed.clickCount, 2)
        XCTAssertEqual(completed.start, PointerPoint(x: 10, y: 20))
        XCTAssertNil(completed.end)
        XCTAssertEqual(completed.sampleId, secondSampleId)
        XCTAssertEqual(completed.gestureId, firstGestureId)
        XCTAssertEqual(tracker.flushExpired(at: 2.0), [])
    }

    func testTripleClickSequenceProducesOneHighestCountAtFinalLocationAndTime() throws {
        var tracker = PointerGestureTracker(doubleClickInterval: 0.5)
        tracker.mouseDown(
            at: PointerPoint(x: 10, y: 20), clickCount: 1,
            sampleId: firstSampleId,
            gestureId: firstGestureId, timestamp: 2)
        tracker.mouseUp(at: PointerPoint(x: 10, y: 20), timestamp: 2.01)
        tracker.mouseDown(
            at: PointerPoint(x: 11, y: 21), clickCount: 2,
            sampleId: secondSampleId,
            gestureId: secondGestureId, timestamp: 2.1)
        tracker.mouseUp(at: PointerPoint(x: 11, y: 21), timestamp: 2.11)
        tracker.mouseDown(
            at: PointerPoint(x: 12, y: 22), clickCount: 3,
            sampleId: thirdSampleId,
            gestureId: thirdGestureId, timestamp: 2.2)
        let finalTime = Date(timeIntervalSince1970: 1234)
        tracker.mouseUp(
            at: PointerPoint(x: 12, y: 22),
            timestamp: 2.21,
            completedAt: finalTime)

        let completed = try XCTUnwrap(tracker.flushExpired(at: 2.71).only)
        XCTAssertEqual(completed.kind, .click)
        XCTAssertEqual(completed.clickCount, 3)
        XCTAssertEqual(completed.start, PointerPoint(x: 12, y: 22))
        XCTAssertEqual(completed.sampleId, thirdSampleId)
        XCTAssertEqual(completed.gestureId, firstGestureId)
        XCTAssertEqual(completed.completedAt, finalTime)
        XCTAssertEqual(tracker.finish(), [])
    }

    func testSingleClickIsPublishedAtBoundedDeadline() throws {
        var tracker = PointerGestureTracker(doubleClickInterval: 0.25)
        tracker.mouseDown(
            at: PointerPoint(x: 4, y: 5), clickCount: 1,
            sampleId: firstSampleId,
            gestureId: firstGestureId, timestamp: 10)
        let update = try XCTUnwrap(
            tracker.mouseUp(at: PointerPoint(x: 4, y: 5), timestamp: 10.01))
        XCTAssertEqual(update.sample.sampleId, firstSampleId)
        XCTAssertEqual(update.resolutions, [])

        XCTAssertEqual(tracker.flushExpired(at: 10.259), [])
        let completed = try XCTUnwrap(tracker.flushExpired(at: 10.26).only)
        XCTAssertEqual(completed.kind, .click)
        XCTAssertEqual(completed.clickCount, 1)
        XCTAssertEqual(completed.sampleId, firstSampleId)
        XCTAssertEqual(completed.gestureId, firstGestureId)
    }

    func testMultiClickCountWithoutObservedPrefixIsClampedToSingle() throws {
        var tracker = PointerGestureTracker(doubleClickInterval: 0.25)
        tracker.mouseDown(
            at: PointerPoint(x: 4, y: 5), clickCount: 2,
            sampleId: secondSampleId,
            gestureId: secondGestureId, timestamp: 15)
        tracker.mouseUp(at: PointerPoint(x: 4, y: 5), timestamp: 15.01)

        let completed = try XCTUnwrap(tracker.finish().only)
        XCTAssertEqual(completed.kind, .click)
        XCTAssertEqual(completed.clickCount, 1)
        XCTAssertEqual(completed.sampleId, secondSampleId)
        XCTAssertEqual(completed.gestureId, secondGestureId)
    }

    func testSeparatedClicksProduceTwoSinglesInPhysicalOrder() throws {
        var tracker = PointerGestureTracker(doubleClickInterval: 0.2)
        tracker.mouseDown(
            at: PointerPoint(x: 1, y: 2), clickCount: 1,
            sampleId: firstSampleId,
            gestureId: firstGestureId, timestamp: 20)
        tracker.mouseUp(at: PointerPoint(x: 1, y: 2), timestamp: 20.01)

        let first = try XCTUnwrap(
            tracker.mouseDown(
                at: PointerPoint(x: 30, y: 40), clickCount: 1,
                sampleId: secondSampleId,
                gestureId: secondGestureId, timestamp: 20.3
            ).only)
        XCTAssertEqual(first.clickCount, 1)
        XCTAssertEqual(first.gestureId, firstGestureId)

        let update = try XCTUnwrap(
            tracker.mouseUp(at: PointerPoint(x: 30, y: 40), timestamp: 20.31))
        XCTAssertEqual(update.resolutions, [])
        let second = try XCTUnwrap(tracker.finish().only)
        XCTAssertEqual(second.clickCount, 1)
        XCTAssertEqual(second.sampleId, secondSampleId)
        XCTAssertEqual(second.gestureId, secondGestureId)
    }

    func testDragIsImmediateAndDoesNotAlsoEmitInitialClick() throws {
        var tracker = PointerGestureTracker(doubleClickInterval: 0.5)
        tracker.mouseDown(
            at: PointerPoint(x: 10, y: 20), clickCount: 1,
            sampleId: firstSampleId,
            gestureId: firstGestureId, timestamp: 30)
        tracker.mouseDragged()

        let completed = try XCTUnwrap(
            tracker.mouseUp(
                at: PointerPoint(x: 30, y: 40), timestamp: 30.2
            )?.resolutions.only)
        XCTAssertEqual(completed.kind, .drag)
        XCTAssertEqual(completed.start, PointerPoint(x: 10, y: 20))
        XCTAssertEqual(completed.end, PointerPoint(x: 30, y: 40))
        XCTAssertEqual(completed.sampleId, firstSampleId)
        XCTAssertEqual(completed.gestureId, firstGestureId)
        XCTAssertNil(tracker.nextClickDeadline)
        XCTAssertEqual(tracker.finish(), [])
    }

    func testDragContinuationConsumesDeferredClick() throws {
        var tracker = PointerGestureTracker(doubleClickInterval: 0.5)
        tracker.mouseDown(
            at: PointerPoint(x: 10, y: 20), clickCount: 1,
            sampleId: firstSampleId,
            gestureId: firstGestureId, timestamp: 40)
        tracker.mouseUp(at: PointerPoint(x: 10, y: 20), timestamp: 40.01)
        tracker.mouseDown(
            at: PointerPoint(x: 10, y: 20), clickCount: 2,
            sampleId: secondSampleId,
            gestureId: secondGestureId, timestamp: 40.2)
        tracker.mouseDragged()

        let completed = try XCTUnwrap(
            tracker.mouseUp(
                at: PointerPoint(x: 50, y: 60), timestamp: 40.3
            )?.resolutions.only)
        XCTAssertEqual(completed.kind, .drag)
        XCTAssertEqual(completed.clickCount, 2)
        XCTAssertEqual(completed.sampleId, secondSampleId)
        XCTAssertEqual(completed.gestureId, firstGestureId)
        XCTAssertEqual(tracker.finish(), [])
    }

    func testFinishDrainsCompletedClickButNotIncompleteContinuation() throws {
        var tracker = PointerGestureTracker(doubleClickInterval: 0.5)
        tracker.mouseDown(
            at: PointerPoint(x: 1, y: 2), clickCount: 1,
            sampleId: firstSampleId,
            gestureId: firstGestureId, timestamp: 50)
        tracker.mouseUp(at: PointerPoint(x: 1, y: 2), timestamp: 50.01)
        tracker.mouseDown(
            at: PointerPoint(x: 1, y: 2), clickCount: 2,
            sampleId: secondSampleId,
            gestureId: secondGestureId, timestamp: 50.2)

        let completed = try XCTUnwrap(tracker.finish().only)
        XCTAssertEqual(completed.kind, .click)
        XCTAssertEqual(completed.clickCount, 1)
        XCTAssertEqual(completed.sampleId, firstSampleId)
        XCTAssertEqual(completed.gestureId, firstGestureId)
        XCTAssertEqual(tracker.finish(), [])
        XCTAssertNil(
            tracker.mouseUp(at: PointerPoint(x: 1, y: 2), timestamp: 50.3))
    }

    func testFinishDrainsCompletedDoubleClickBeforeItsTimer() throws {
        var tracker = PointerGestureTracker(doubleClickInterval: 0.5)
        tracker.mouseDown(
            at: PointerPoint(x: 1, y: 2), clickCount: 1,
            sampleId: firstSampleId,
            gestureId: firstGestureId, timestamp: 55)
        tracker.mouseUp(at: PointerPoint(x: 1, y: 2), timestamp: 55.01)
        tracker.mouseDown(
            at: PointerPoint(x: 1, y: 2), clickCount: 2,
            sampleId: secondSampleId,
            gestureId: secondGestureId, timestamp: 55.2)
        tracker.mouseUp(at: PointerPoint(x: 1, y: 2), timestamp: 55.21)

        let completed = try XCTUnwrap(tracker.finish().only)
        XCTAssertEqual(completed.kind, .click)
        XCTAssertEqual(completed.clickCount, 2)
        XCTAssertEqual(completed.sampleId, secondSampleId)
        XCTAssertEqual(completed.gestureId, firstGestureId)
        XCTAssertEqual(tracker.finish(), [])
    }

    func testIndependentInputFlushesClickAndRebasesActiveContinuation() throws {
        var tracker = PointerGestureTracker(doubleClickInterval: 0.5)
        tracker.mouseDown(
            at: PointerPoint(x: 1, y: 2), clickCount: 1,
            sampleId: firstSampleId,
            gestureId: firstGestureId, timestamp: 60)
        tracker.mouseUp(at: PointerPoint(x: 1, y: 2), timestamp: 60.01)
        tracker.mouseDown(
            at: PointerPoint(x: 1, y: 2), clickCount: 2,
            sampleId: secondSampleId,
            gestureId: secondGestureId, timestamp: 60.2)

        let first = try XCTUnwrap(tracker.flushPendingClick().only)
        XCTAssertEqual(first.clickCount, 1)
        XCTAssertEqual(first.gestureId, firstGestureId)

        tracker.mouseUp(at: PointerPoint(x: 1, y: 2), timestamp: 60.21)
        let second = try XCTUnwrap(tracker.finish().only)
        XCTAssertEqual(second.clickCount, 1)
        XCTAssertEqual(second.sampleId, secondSampleId)
        XCTAssertEqual(second.gestureId, secondGestureId)
    }

    func testMouseUpWithoutDownAndResetProduceNoObservation() {
        var tracker = PointerGestureTracker()
        XCTAssertNil(
            tracker.mouseUp(at: PointerPoint(x: 1, y: 2), timestamp: 70))
        tracker.mouseDown(
            at: PointerPoint(x: 1, y: 2), clickCount: 0,
            sampleId: firstSampleId,
            gestureId: firstGestureId, timestamp: 70.1)
        tracker.reset()
        XCTAssertNil(
            tracker.mouseUp(at: PointerPoint(x: 1, y: 2), timestamp: 70.2))
        XCTAssertEqual(tracker.finish(), [])
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
