import Foundation
import XCTest

@testable import JazzCapture
@testable import JazzCaptureCore

/// Production controller orchestration seams; no native input, microphone, TCC or delivery.
@MainActor
final class CaptureLabelCloseTests: XCTestCase {
    private actor Gate {
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if released { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() {
            released = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }

    func testPauseDuringLabelDrainSettlesSessionThenResumeAdmitsFreshLabel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let intent = CaptureStartIntent(root: root, continuous: true,
            durability: JazzArchiveFilesystemPlatform.durability)
        intent.completeRecovery(succeeded: true)
        var sourcesOpen = false
        var labels: [String] = []
        let generation = try XCTUnwrap(intent.requestStart(explicit: true))
        let started = await intent.runStart(generation, recovery: { true }, prepare: { true },
            enable: { sourcesOpen = true; return true }, abort: { XCTFail("unexpected abort") })
        XCTAssertTrue(started)
        let owner = CaptureLabelClose()
        let gate = Gate()
        let entered = expectation(description: "label drain pending")
        let closing = owner.begin(drain: { entered.fulfill(); await gate.wait() },
            recoveryRequired: { intent.completeRecovery(succeeded: false) }, reopen: {
                guard sourcesOpen, intent.generation == generation else { return false }
                XCTFail("Pause must not reopen old sources")
                return true
            })
        let oldRequest = owner.admit(eligible: { sourcesOpen && intent.generation == generation },
            open: { labels.append("stale") })
        await fulfillment(of: [entered], timeout: 1)
        sourcesOpen = false // Controller closes physical admissions synchronously before Pause.
        intent.pause()
        let session = CaptureLocalClose()
        var committed = false
        let shutdown = Task {
            await session.run(budgetNanoseconds: 1_000_000_000, close: {
                _ = await closing.value // Same retained label task captured by beginLocalClose.
                try Task.checkCancellation()
                guard intent.recoveryReady else { throw CaptureJournalRuntimeError.closed }
                committed = true
            }, recoveryRequired: { intent.completeRecovery(succeeded: false) })
        }
        await gate.release()
        let reopened = await closing.value
        XCTAssertFalse(reopened)
        await oldRequest?.value
        let outcome = await shutdown.value
        XCTAssertEqual(outcome, .settled)
        XCTAssertTrue(session.settled)
        XCTAssertTrue(committed)
        XCTAssertTrue(intent.userPaused)
        XCTAssertTrue(intent.recoveryReady)
        XCTAssertNil(owner.task, "settled-but-not-reopened label must retire its task")
        let resumedGeneration = try XCTUnwrap(intent.requestStart(explicit: true))
        let resumed = await intent.runStart(resumedGeneration, recovery: { session.settled },
            prepare: { true }, enable: { sourcesOpen = true; return true }, abort: { XCTFail("Resume aborted") })
        XCTAssertTrue(resumed)
        await owner.admit(eligible: { sourcesOpen && intent.generation == resumedGeneration },
            open: { labels.append("fresh") })?.value
        XCTAssertEqual(labels, ["fresh"])
    }

    func testStaleCompletionCannotClearNewerOwnerOrReopenOldSources() async {
        let owner = CaptureLabelClose()
        let oldGate = Gate()
        let newGate = Gate()
        let old = owner.begin(drain: { await oldGate.wait() },
            recoveryRequired: { XCTFail("old close settled") },
            reopen: { XCTFail("stale owner must never reopen"); return true })
        let newer = owner.begin(drain: { await newGate.wait() },
            recoveryRequired: { XCTFail("new close settled") }, reopen: { true })
        await oldGate.release()
        let oldResult = await old.value
        XCTAssertFalse(oldResult)
        XCTAssertNotNil(owner.task, "old completion cannot clear the pending newer owner")
        var admitted = false
        let request = owner.admit(eligible: { true }, open: { admitted = true })
        XCTAssertFalse(admitted)
        await newGate.release()
        let newResult = await newer.value
        XCTAssertTrue(newResult)
        await request?.value
        XCTAssertTrue(admitted)
        XCTAssertNil(owner.task)
    }

    func testFailedOrTimedOutCloseRemainsBlockedEvenAfterLatePhysicalReturn() async {
        for timeout in [false, true] {
            let owner = CaptureLabelClose()
            let gate = Gate()
            let returned = expectation(description: "physical drain returned")
            var recoveryReady = true
            let closing = owner.begin(budgetNanoseconds: 10_000_000, drain: {
                defer { returned.fulfill() }
                if timeout { await gate.wait() }
                else { throw CaptureJournalRuntimeError.closed }
            }, recoveryRequired: { recoveryReady = false },
                reopen: { XCTFail("failed close cannot reopen"); return true })
            let result = await closing.value
            XCTAssertFalse(result)
            XCTAssertFalse(recoveryReady)
            XCTAssertNotNil(owner.task)
            await owner.admit(eligible: { true }, open: { XCTFail("failed close admits label") })?.value
            await gate.release()
            await fulfillment(of: [returned], timeout: 1)
            XCTAssertNotNil(owner.task, "late return cannot erase the recovery blocker")
            await owner.admit(eligible: { true }, open: { XCTFail("late return admits label") })?.value
        }
    }
}
