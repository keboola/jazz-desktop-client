import XCTest

@testable import JazzCapture

@MainActor
final class BdmWorkshopStartupTests: XCTestCase {
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
