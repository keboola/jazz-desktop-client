import Foundation
import XCTest

@testable import JazzCapture

@MainActor
final class AXCaptureBoundaryTests: XCTestCase {
    func testRevokedQueuedAXCannotAdmitForeignReadOrMainThreadFallback() async {
        let queue = DispatchQueue(label: "test.synthetic-ax-queue")
        let block = DispatchSemaphore(value: 0)
        defer { block.signal() }
        let entered = expectation(description: "queue deliberately occupied")
        queue.async { entered.fulfill(); block.wait() }
        await fulfillment(of: [entered], timeout: 1)
        let admission = CaptureAXAdmission(accepting: true)
        let task = Task { await AXCapture.enrichedTarget(
            admission: admission, kind: .click, location: .zero, excluding: 0, queue: queue,
            native: AXCapture.NativeOperations(foreign: { _ in
                XCTFail("queued read crossed Stop")
                return AXCapture.ForeignResult(hasWindow: false, info: nil)
            }, fallback: { _ in XCTFail("queued fallback crossed Stop"); return nil })) }
        admission.revoke()
        XCTAssertTrue(admission.isClosedAndQuiescent)
        let nextGeneration = CaptureAXAdmission(accepting: true)
        XCTAssertTrue(nextGeneration.permitsReads)
        XCTAssertFalse(admission.permitsReads)
        block.signal()
        let result = await task.value
        XCTAssertNil(result)
        nextGeneration.revoke()
    }

    func testInFlightAXRetainsPhysicalOwnershipRejectsNextAttributeAndDiscardsLateResult() async throws {
        for foreignHasWindow in [true, false] {
            let queue = DispatchQueue(label: "test.synthetic-ax-native")
            let nativeReturn = DispatchSemaphore(value: 0)
            defer { nativeReturn.signal() }
            let entered = expectation(description: "foreign AX attribute in flight")
            let admission = CaptureAXAdmission(accepting: true)
            let task = Task { await AXCapture.enrichedTarget(
                admission: admission, kind: .click, location: .zero, excluding: 0, queue: queue,
                native: AXCapture.NativeOperations(foreign: { admission in
                    // Accessibility.copyAttr/hit-test/PID/window-list use this same read admission.
                    let first = admission.read {
                        entered.fulfill()
                        nativeReturn.wait() // admitted foreign IPC ignores cancellation
                        var info = AXTargetInfo()
                        info.label = "synthetic late context"
                        return info
                    }
                    let next: AXTargetInfo? = admission.read {
                        XCTFail("next native attribute/traversal read after revoke")
                        return AXTargetInfo()
                    }
                    XCTAssertNil(next)
                    return AXCapture.ForeignResult(hasWindow: foreignHasWindow, info: first)
                }, fallback: { _ in XCTFail("main-thread fallback after revoke"); return nil })) }
            await fulfillment(of: [entered], timeout: 1)
            admission.revoke()
            XCTAssertFalse(admission.isClosedAndQuiescent)
            let close = CaptureLocalClose()
            let screen = ScreenCaptureSingleFlight()
            let narration = NarrationRecorder(canAdmit: { false })
            let outcome = await close.run(budgetNanoseconds: 15_000_000, close: {
                try await CaptureLocalClose.drain(
                    narration: narration, screen: screen, ax: admission, labelTail: nil, audioTail: nil,
                    coachLive: nil, journalAdmission: { nil }, runtime: nil, coachActions: nil,
                    orderedProjection: nil, commit: { XCTFail("old AX still physically active") })
            }, recoveryRequired: {})
            XCTAssertEqual(outcome, .recoveryRequired)
            XCTAssertFalse(close.physicallyReturned)
            XCTAssertFalse(admission.isClosedAndQuiescent)
            nativeReturn.signal()
            let result = await task.value
            XCTAssertNil(result)
            await admission.waitForQuiescence()
            XCTAssertTrue(admission.isClosedAndQuiescent)
            for _ in 0..<200 where !close.physicallyReturned {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            XCTAssertTrue(close.physicallyReturned)
            XCTAssertFalse(close.settled)
        }
    }

    func testMainThreadFallbackResultAndFollowingReadAreRevoked() async {
        let admission = CaptureAXAdmission(accepting: true)
        let result = await AXCapture.enrichedTarget(
            admission: admission, kind: .paste, location: .zero, excluding: 0,
            native: AXCapture.NativeOperations(foreign: { _ in
                AXCapture.ForeignResult(hasWindow: false, info: nil)
            }, fallback: { admission in
                let first = admission.read {
                    admission.revoke() // simulate revocation while a synchronous native read returns
                    return AXTargetInfo()
                }
                let next: AXTargetInfo? = admission.read { XCTFail("revoked fallback read"); return AXTargetInfo() }
                XCTAssertNil(first)
                XCTAssertNil(next)
                return first
            }))
        XCTAssertNil(result)
        XCTAssertTrue(admission.isClosedAndQuiescent)
        // These production entry points return before creating AX handles or reading OS state.
        XCTAssertNil(Accessibility.focusedInfo(admission: admission))
        XCTAssertNil(Accessibility.focusedInfo(inApp: 0, admission: admission))
        XCTAssertNil(Accessibility.target(inApp: 0, atScreenPoint: .zero, admission: admission))
        XCTAssertNil(Accessibility.target(atScreenPoint: .zero, admission: admission))
        XCTAssertNil(Accessibility.foreignWindowPID(at: .zero, excluding: 0, admission: admission))
    }
}
