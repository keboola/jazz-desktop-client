import Foundation
import XCTest

@testable import JazzCaptureCore

@MainActor
final class CaptureStartIntentTests: XCTestCase {
    private let durability = JazzArchiveFilesystemDurability(
        synchronizeRegularFile: { _, _ in }, synchronizeDirectory: { _ in })

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func intent(_ root: URL, continuous: Bool = true) -> CaptureStartIntent {
        CaptureStartIntent(root: root, continuous: continuous, durability: durability)
    }

    /// These are the actual recovery/prepare/enable/abort boundaries called by CaptureController,
    /// without TCC, Keychain, a live service, or a real microphone/screenshot.
    private func run(_ intent: CaptureStartIntent, _ token: UUID) async -> Bool {
        await intent.runStart(
            token, recovery: { true }, prepare: { true }, enable: { true }, abort: {})
    }

    func testPauseBeforeScheduledTaskNeverPreparesOrEnables() async throws {
        let owner = intent(try root())
        owner.completeRecovery(succeeded: true)
        let token = try XCTUnwrap(owner.requestStart(explicit: true))
        owner.pause()
        let started = await owner.runStart(
            token,
            recovery: { XCTFail("revoked before first await"); return true },
            prepare: { XCTFail("no archive preparation"); return true },
            enable: { XCTFail("no input"); return true },
            abort: { XCTFail("nothing was prepared") })
        XCTAssertFalse(started)
        XCTAssertFalse(owner.isStarting)
        XCTAssertTrue(owner.userPaused)
    }

    func testPauseDuringRecoveryNeverPreparesSources() async throws {
        let owner = intent(try root())
        let recovery = Deferred<Bool>(entered: expectation(description: "recovery entered"))
        let token = try XCTUnwrap(owner.requestStart(explicit: false))
        let task = Task {
            await owner.runStart(
                token,
                recovery: { await recovery.wait() },
                prepare: { XCTFail("paused during recovery"); return true },
                enable: { XCTFail("no input"); return true }, abort: {})
        }
        await fulfillment(of: [recovery.entered], timeout: 2)
        XCTAssertNil(owner.requestStart(explicit: true))
        owner.pause()
        owner.completeRecovery(succeeded: true)
        recovery.resolve(true)
        let started = await task.value
        XCTAssertFalse(started)
        XCTAssertNil(owner.requestStart(explicit: false)) // reconnect is not Resume
    }

    func testRepeatedStartSerializedAndPauseDuringPreparationCannotEnableThenResumeWorks() async throws {
        let owner = intent(try root())
        owner.completeRecovery(succeeded: true)
        let preparation = Deferred<Bool>(entered: expectation(description: "prepare entered"))
        let cleanup = Deferred<Void>(entered: expectation(description: "abort entered"))
        let token = try XCTUnwrap(owner.requestStart(explicit: true))
        XCTAssertNil(owner.requestStart(explicit: true)) // before the first Task runs
        var enabled = 0
        let task = Task {
            await owner.runStart(
                token, recovery: { true }, prepare: { await preparation.wait() },
                enable: { enabled += 1; return true }, abort: { await cleanup.wait() })
        }
        await fulfillment(of: [preparation.entered], timeout: 2)
        XCTAssertNil(owner.requestStart(explicit: true))
        owner.pause()
        preparation.resolve(true) // non-cooperative startup returns success AFTER Pause
        await fulfillment(of: [cleanup.entered], timeout: 2)
        XCTAssertNil(owner.requestStart(explicit: true)) // close still owns the slot
        XCTAssertEqual(enabled, 0)
        cleanup.resolve(())
        let started = await task.value
        XCTAssertFalse(started)
        XCTAssertFalse(owner.isStarting)
        let resumed = try XCTUnwrap(owner.requestStart(explicit: true))
        let success = await run(owner, resumed)
        XCTAssertTrue(success)
        XCTAssertFalse(owner.userPaused)
    }

    func testRecoveryFailureAndUncompletedRecoveryBlockEvenExplicitStart() async throws {
        for returnedSuccess in [false, true] {
            let owner = intent(try root())
            owner.completeRecovery(succeeded: false)
            let token = try XCTUnwrap(owner.requestStart(explicit: true))
            let started = await owner.runStart(
                token, recovery: { returnedSuccess },
                prepare: { XCTFail("recovery not complete"); return true },
                enable: { XCTFail("no input"); return true }, abort: {})
            XCTAssertFalse(started)
            XCTAssertTrue(owner.idleStatus.contains("recovery"))
        }
    }

    func testPausedIntentSurvivesRelaunchAndRepeatedReconnectExplicitResumeWorks() async throws {
        let directory = try root()
        let first = intent(directory)
        first.pause()
        let reopened = intent(directory)
        reopened.completeRecovery(succeeded: true)
        XCTAssertTrue(reopened.continuous) // Pause is not the continuous-mode preference
        XCTAssertTrue(reopened.userPaused)
        XCTAssertFalse(reopened.requiresResume) // distinguish user Pause from safety guard
        XCTAssertEqual(reopened.idleStatus, "Paused by you")
        for _ in 0..<3 { XCTAssertNil(reopened.requestStart(explicit: false)) }
        let token = try XCTUnwrap(reopened.requestStart(explicit: true))
        let resumed = await run(reopened, token)
        XCTAssertTrue(resumed)
    }

    func testManualStartIsEphemeralAndManualModeNeverAutoStarts() async throws {
        let directory = try root()
        let first = intent(directory, continuous: false)
        first.completeRecovery(succeeded: true)
        XCTAssertNil(first.requestStart(explicit: false))
        let token = try XCTUnwrap(first.requestStart(explicit: true))
        let started = await run(first, token)
        XCTAssertTrue(started)
        let reopened = intent(directory, continuous: false)
        reopened.completeRecovery(succeeded: true)
        for _ in 0..<3 { XCTAssertNil(reopened.requestStart(explicit: false)) }
        let explicit = try XCTUnwrap(reopened.requestStart(explicit: true))
        let resumed = await run(reopened, explicit)
        XCTAssertTrue(resumed)
    }

    func testModeChangeStopsPendingStartAndReenablingModeNeverClearsPause() async throws {
        let owner = intent(try root())
        owner.completeRecovery(succeeded: true)
        let token = try XCTUnwrap(owner.requestStart(explicit: false))
        owner.setContinuous(false)
        XCTAssertTrue(owner.userPaused)
        XCTAssertFalse(owner.permitsStart(token))
        owner.setContinuous(true)
        let started = await run(owner, token)
        XCTAssertFalse(started)
        XCTAssertNil(owner.requestStart(explicit: false))
    }

    func testGuardMustSynchronizeBeforeAnyStartAdmission() throws {
        let owner = CaptureStartIntent(
            root: try root(), continuous: true,
            durability: JazzArchiveFilesystemDurability(
                synchronizeRegularFile: { _, _ in throw CocoaError(.fileWriteUnknown) },
                synchronizeDirectory: { _ in }))
        XCTAssertNil(owner.requestStart(explicit: true))
        XCTAssertFalse(owner.isStarting)
        XCTAssertNotNil(owner.storageError)
        XCTAssertNil(owner.requestStart(explicit: false))
        XCTAssertTrue(owner.idleStatus.contains("blocked"))
    }

    func testPauseWriteFailureRetainsPrearmedGuardAcrossRelaunch() async throws {
        let directory = try root()
        let retained = try root().appendingPathComponent("retained-intent")
        let owner = intent(directory)
        owner.completeRecovery(succeeded: true)
        let token = try XCTUnwrap(owner.requestStart(explicit: true))
        let started = await run(owner, token)
        XCTAssertTrue(started)
        // Make every write to the original parent fail, preserving the EXACT old durable bytes.
        // Reopening retained simulates relaunch seeing only the last successful write.
        try FileManager.default.moveItem(at: directory, to: retained)
        try Data("not a directory".utf8).write(to: directory)
        owner.pause()
        XCTAssertTrue(owner.userPaused)
        XCTAssertNotNil(owner.storageError)
        XCTAssertNil(owner.requestStart(explicit: true))
        let reopened = intent(retained)
        reopened.completeRecovery(succeeded: true)
        XCTAssertFalse(reopened.userPaused) // failed Pause did not reach the old durable bytes
        XCTAssertTrue(reopened.requiresResume)
        XCTAssertTrue(reopened.idleStatus.contains("safety check"))
        XCTAssertNil(reopened.requestStart(explicit: false))
    }

    func testCancelledPreSourceShutdownCanRestoreButStaleCleanupAfterPauseCannot() async throws {
        for pauseBeforeRestore in [false, true] {
            let directory = try root()
            let owner = intent(directory)
            owner.completeRecovery(succeeded: true)
            let token = try XCTUnwrap(owner.requestStart(explicit: false))
            let shutdown = owner.beginShutdown()
            let started = await run(owner, token)
            XCTAssertFalse(started)
            if pauseBeforeRestore { owner.pause() }
            owner.finishShutdown(shutdown, settled: true, physicallyQuiescent: true)
            let reopened = intent(directory)
            reopened.completeRecovery(succeeded: true)
            XCTAssertEqual(reopened.userPaused, pauseBeforeRestore)
            XCTAssertFalse(reopened.requiresResume)
            if pauseBeforeRestore {
                XCTAssertNil(reopened.requestStart(explicit: false))
            } else {
                XCTAssertNotNil(reopened.requestStart(explicit: false))
            }
        }
    }

    func testPendingOrUnsettledShutdownNeverRestoresGuard() async throws {
        let directory = try root()
        let owner = intent(directory)
        owner.completeRecovery(succeeded: true)
        let token = try XCTUnwrap(owner.requestStart(explicit: false))
        let shutdown = owner.beginShutdown()
        owner.finishShutdown(shutdown, settled: true, physicallyQuiescent: true) // startup has not returned
        XCTAssertTrue(intent(directory).requiresResume)
        let started = await run(owner, token)
        XCTAssertFalse(started)
        owner.finishShutdown(shutdown, settled: false, physicallyQuiescent: true) // timeout/uncertain close
        XCTAssertTrue(intent(directory).requiresResume)
    }

    func testLogicalSettlementWithoutPhysicalQuiescenceCannotRestoreCleanQuit() async throws {
        let directory = try root()
        let owner = intent(directory)
        owner.completeRecovery(succeeded: true)
        let token = try XCTUnwrap(owner.requestStart(explicit: false))
        let started = await run(owner, token)
        XCTAssertTrue(started)
        let shutdown = owner.beginShutdown()
        owner.finishShutdown(shutdown, settled: true, physicallyQuiescent: false)
        XCTAssertTrue(intent(directory).requiresResume)
        owner.pause()
        owner.finishShutdown(shutdown, settled: true, physicallyQuiescent: true)
        XCTAssertTrue(intent(directory).userPaused)
    }

    func testCleanShutdownAfterSourceAdmissionRestoresContinuousEligibility() async throws {
        let directory = try root()
        let owner = intent(directory)
        owner.completeRecovery(succeeded: true)
        let token = try XCTUnwrap(owner.requestStart(explicit: false))
        let started = await run(owner, token)
        XCTAssertTrue(started)
        let shutdown = owner.beginShutdown()
        owner.finishShutdown(shutdown, settled: true, physicallyQuiescent: true)
        let reopened = intent(directory)
        reopened.completeRecovery(succeeded: true)
        XCTAssertFalse(reopened.requiresResume)
        XCTAssertFalse(reopened.userPaused)
        XCTAssertNotNil(reopened.requestStart(explicit: false))
    }

    func testPreparationFailureOrRevokedRecoveryAbortsWithoutInput() async throws {
        for prepared in [false, true] {
            let owner = intent(try root())
            owner.completeRecovery(succeeded: true)
            let token = try XCTUnwrap(owner.requestStart(explicit: true))
            var aborted = false
            let started = await owner.runStart(
                token, recovery: { true },
                prepare: {
                    owner.completeRecovery(succeeded: false)
                    return prepared
                },
                enable: { XCTFail("failed preparation cannot enable input"); return true },
                abort: { aborted = true })
            XCTAssertFalse(started)
            XCTAssertTrue(aborted)
            XCTAssertFalse(owner.isStarting)
        }
    }

    func testCorruptIntentFailsClosedInsteadOfDefaultingToUnpaused() throws {
        let directory = try root()
        try Data("bad json".utf8).write(to: directory.appendingPathComponent("capture-intent.json"))
        let owner = intent(directory)
        XCTAssertNotNil(owner.storageError)
        XCTAssertNil(owner.requestStart(explicit: false))
        XCTAssertNil(owner.requestStart(explicit: true))
    }
}

@MainActor
private final class Deferred<Value> {
    let entered: XCTestExpectation
    private var continuation: CheckedContinuation<Value, Never>?

    init(entered: XCTestExpectation) { self.entered = entered }

    func wait() async -> Value {
        await withCheckedContinuation {
            continuation = $0
            entered.fulfill()
        }
    }

    func resolve(_ value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
