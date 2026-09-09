import XCTest
import JazzCaptureCore

@testable import JazzCapture

@MainActor
final class BdmWorkshopStartupTests: XCTestCase {
    func testCaptureBoundaryStopsAdaptiveOwnerWithoutRecursingAndFencesLateFallbackAfterRestart() async {
        var visibility: [Bool] = []
        var fallbacks: [@MainActor () -> Void] = []
        var cancelledTimers = 0
        let workshop = BdmWorkshopController(panelVisibility: { visibility.append($0) }, scheduleFallback: {
            fallbacks.append($0)
            return { cancelledTimers += 1 }
        })
        var asked: [String] = []
        var closes = 0
        var segments = 0
        var refreshes = 0
        workshop.adaptive = true
        workshop.onStartCapture = { true }
        workshop.onAskQuestion = { asked.append($0.text) }
        workshop.onStopCapture = { closes += 1 }
        workshop.onEndSegment = { segments += 1 }
        workshop.onStoppedByCapture = { [weak workshop] in
            guard let workshop else { return XCTFail("workshop released during its boundary callback") }
            XCTAssertFalse(workshop.isRunning)
            XCTAssertFalse(workshop.adaptive)
            XCTAssertEqual(visibility.last, false)
            refreshes += 1
        }
        // The exact method-reference callback assigned to controller.onWorkshopBoundaryStop by
        // AppDelegate. CaptureController invokes it BEFORE its sole environment-owned close.
        let boundaryStop = workshop.captureStoppedAtBoundary
        workshop.start()
        for _ in 0..<100 where workshop.isStarting { await Task.yield() }
        XCTAssertTrue(workshop.isRunning)
        XCTAssertEqual(visibility, [true])
        XCTAssertEqual(asked.count, 1)
        workshop.next()
        XCTAssertEqual(fallbacks.count, 1)
        boundaryStop()
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(cancelledTimers, 1)
        XCTAssertEqual(closes, 0, "capture-owned boundary must not call public Stop")
        XCTAssertEqual(segments, 1, "capture owner closes the final segment, not this callback")
        let captureClose = CaptureLocalClose()
        let result = await captureClose.run(budgetNanoseconds: 1_000_000_000,
            close: { closes += 1 }, recoveryRequired: { XCTFail("synthetic close failed") })
        XCTAssertEqual(result, .settled)
        workshop.next()
        workshop.finish()
        for reply in [BdmRelayOutcome.question(.init(id: "late", text: "Unrecorded question")), .fallback, .done] {
            workshop.receiveAdaptiveQuestion(reply)
        }
        fallbacks[0]() // even an already-enqueued native timer cannot advance the stopped panel
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(closes, 1)
        XCTAssertFalse(workshop.isRunning)

        // A later EXPLICIT workshop start works; an old cancelled timer must not resolve its wait.
        workshop.adaptive = true
        workshop.start()
        for _ in 0..<100 where workshop.isStarting { await Task.yield() }
        XCTAssertTrue(workshop.isRunning)
        XCTAssertEqual(asked.count, 2)
        workshop.next()
        XCTAssertEqual(fallbacks.count, 2)
        fallbacks[0]()
        XCTAssertEqual(asked.count, 2, "stale fallback crossed into a fresh workshop")
        fallbacks[1]()
        XCTAssertEqual(asked.count, 3, "current fallback still advances normally")
        workshop.finish()
        XCTAssertEqual(closes, 2, "explicit finish retains its one capture Stop")
        XCTAssertEqual(segments, 2)
        XCTAssertEqual(visibility, [true, false, true, false])
    }

    func testCaptureBoundaryCancelsScheduledAndDeferredWorkshopStartupWithoutFreeingItsSlotEarly() async {
        for deferred in [false, true] {
            var visibility: [Bool] = []
            let workshop = BdmWorkshopController(panelVisibility: { visibility.append($0) }, scheduleFallback: { _ in
                XCTFail("no fallback during startup"); return {}
            })
            var continuation: CheckedContinuation<Bool, Never>?
            let entered = expectation(description: "capture preparation")
            var starts = 0
            var asked = 0
            var stops = 0
            var refreshes = 0
            workshop.onStartCapture = {
                starts += 1
                return await withCheckedContinuation { continuation = $0; entered.fulfill() }
            }
            workshop.onAskQuestion = { _ in asked += 1 }
            workshop.onStopCapture = { stops += 1 }
            workshop.onStoppedByCapture = { refreshes += 1 }
            let boundaryStop = workshop.captureStoppedAtBoundary
            workshop.adaptive = true
            workshop.start()
            if deferred { await fulfillment(of: [entered], timeout: 2) }
            boundaryStop()
            XCTAssertFalse(workshop.isRunning)
            XCTAssertFalse(workshop.adaptive)
            XCTAssertEqual(refreshes, 1)
            XCTAssertEqual(visibility, [false])
            XCTAssertTrue(workshop.isStarting, "retained capture startup must actually return before reuse")
            workshop.finish() // must not bounce Stop back into the already-closing capture owner
            workshop.start()
            XCTAssertEqual(stops, 0)
            if deferred { continuation?.resume(returning: true) }
            else { entered.isInverted = true; await fulfillment(of: [entered], timeout: 0.01) }
            for _ in 0..<100 where workshop.isStarting { await Task.yield() }
            XCTAssertFalse(workshop.isStarting)
            XCTAssertFalse(workshop.isRunning)
            XCTAssertEqual(starts, deferred ? 1 : 0)
            XCTAssertEqual(asked, 0, "late startup success must not reopen a microphone label")
            XCTAssertEqual(visibility, [false])
            workshop.onStartCapture = { true }
            workshop.start()
            for _ in 0..<100 where workshop.isStarting { await Task.yield() }
            XCTAssertTrue(workshop.isRunning)
            XCTAssertEqual(asked, 1)
            workshop.finish()
            XCTAssertEqual(stops, 1)
        }
    }

    func testCaptureBoundaryDuringStartedCallbackCannotShowPanelOrOpenFirstQuestion() async {
        var visibility: [Bool] = []
        let workshop = BdmWorkshopController(panelVisibility: { visibility.append($0) })
        workshop.onStartCapture = { true }
        workshop.onStarted = workshop.captureStoppedAtBoundary
        workshop.onAskQuestion = { _ in XCTFail("hard boundary must precede first question") }
        workshop.onStopCapture = { XCTFail("capture already owns this close") }
        workshop.start()
        for _ in 0..<100 where workshop.isStarting { await Task.yield() }
        XCTAssertFalse(workshop.isRunning)
        XCTAssertFalse(workshop.isStarting)
        XCTAssertEqual(visibility, [false])
    }

    func testFinishBeforeTaskRunsDoesNotStartCaptureOrOpenPanel() async {
        let workshop = BdmWorkshopController()
        var stops = 0
        workshop.onStartCapture = { XCTFail("cancelled before admission"); return true }
        workshop.onStarted = { XCTFail("no panel/canvas after Stop") }
        workshop.onAskQuestion = { _ in XCTFail("no microphone label after Stop") }
        workshop.onStopCapture = { stops += 1 }
        workshop.start()
        XCTAssertTrue(workshop.isStarting)
        workshop.finish()
        for _ in 0..<100 where workshop.isStarting { await Task.yield() }
        XCTAssertFalse(workshop.isStarting)
        XCTAssertFalse(workshop.isRunning)
        XCTAssertEqual(stops, 1)
    }

    func testRepeatedWorkshopStartSerializedAndLateSuccessAfterFinishCannotOpenLabel() async {
        let workshop = BdmWorkshopController()
        let entered = expectation(description: "capture start entered")
        var continuation: CheckedContinuation<Bool, Never>?
        var starts = 0
        var stops = 0
        workshop.onStartCapture = {
            starts += 1
            return await withCheckedContinuation {
                continuation = $0
                entered.fulfill()
            }
        }
        workshop.onStarted = { XCTFail("late success cannot show panel/canvas") }
        workshop.onAskQuestion = { _ in XCTFail("late success cannot open mic label") }
        workshop.onStopCapture = { stops += 1 }
        workshop.start()
        workshop.start()
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(starts, 1)
        workshop.finish()
        workshop.start() // prior start still owns the slot until it actually returns
        XCTAssertEqual(stops, 1)
        continuation?.resume(returning: true)
        for _ in 0..<100 where workshop.isStarting { await Task.yield() }
        XCTAssertFalse(workshop.isStarting)
        XCTAssertFalse(workshop.isRunning)
        XCTAssertEqual(starts, 1)
    }
}
