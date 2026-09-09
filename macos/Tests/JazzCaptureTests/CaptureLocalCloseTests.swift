import Foundation
import XCTest

@testable import JazzCapture
@testable import JazzCaptureCore

@MainActor
final class CaptureLocalCloseTests: XCTestCase {
    private actor Gate {
        private var open = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            if open { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { open = true; continuation?.resume(); continuation = nil }
    }

    func testWholeControllerPreCommitSequenceIsBoundedAndLateTailCannotCommitOrRestore() async throws {
        // These are the concrete admission tails and the exact drain function invoked by the
        // controller, not a parallel fake close algorithm. All handlers are local deferred fakes.
        for blockedStage in ["nativePCM", "label", "audio", "journal", "coach"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let owner = try JazzArchiveFilesystemPlatform.captureJournalLeaseProvider.acquire(
                root: root, fileManager: .default)
            defer { owner.release() }
            let sentinel = root.appendingPathComponent("sole-source")
            let bytes = Data("synthetic canonical source; never delete on deadline".utf8)
            try bytes.write(to: sentinel)
            let intent = CaptureStartIntent(root: root, continuous: true,
                durability: JazzArchiveFilesystemPlatform.durability)
            intent.completeRecovery(succeeded: true)
            let token = try XCTUnwrap(intent.requestStart(explicit: true))
            let started = await intent.runStart(token, recovery: { true }, prepare: { true },
                enable: { true }, abort: {})
            XCTAssertTrue(started)
            let shutdownGeneration = intent.beginShutdown()
            let gate = Gate()
            defer { Task { await gate.release() } }
            let entered = expectation(description: "\(blockedStage) tail entered")
            let label = CaptureCoachLiveLabelContextAdmissionTail { _, _, _ in
                if blockedStage == "label" { entered.fulfill(); await gate.wait() }
            }
            let audio = CaptureCoachLivePCMAdmissionTail { _, _, _ in
                if blockedStage == "audio" { entered.fulfill(); await gate.wait() }
            }
            label.submit(labelId: nil, processId: nil, presentationContext: nil)
            label.stopAccepting()
            audio.submit(labelId: "synthetic-label", processId: "synthetic-process", chunk:
                try CaptureCoachLivePCMChunk(sequence: 0, startMillis: 0, endMillis: 1,
                    recordedAt: Timestamps.iso8601(), bytes: Data(repeating: 0, count: 32)))
            let journalTail = Task {
                if blockedStage == "journal" { entered.fulfill(); await gate.wait() }
            }
            let coachTail = Task {
                if blockedStage == "coach" { entered.fulfill(); await gate.wait() }
            }
            let screen = ScreenCaptureSingleFlight() // closed and physically quiet, never snapshot-open
            let pcmGate = DispatchSemaphore(value: 0)
            defer { pcmGate.signal() }
            let narration = NarrationRecorder(canAdmit: { true }, makeSources: { _, _ in
                NarrationRecorder.NativeSources(isRecording: { true }, stopRecording: {}, stopPCM: {},
                    drainPCM: { entered.fulfill(); pcmGate.wait() })
            }, probe: { _ in })
            if blockedStage == "nativePCM" {
                _ = try narration.start(at: sentinel, persistStart: { _ in }, persistStop: { _, _ in })
                _ = narration.stop()
                XCTAssertFalse(narration.isRecording)
            }
            let close = CaptureLocalClose()
            var commits = 0
            let clock = ContinuousClock()
            let start = clock.now
            let result = await close.run(budgetNanoseconds: 25_000_000, close: {
                try await CaptureLocalClose.drain(
                    narration: narration, screen: screen, labelTail: label, audioTail: audio,
                    coachLive: nil, journalAdmission: { journalTail }, runtime: nil,
                    coachActions: coachTail, orderedProjection: nil,
                    commit: { commits += 1 })
                // The actual controller also only restores from the resolved close owner.
                withExtendedLifetime(owner) {}
            }, recoveryRequired: { intent.completeRecovery(succeeded: false) })
            await fulfillment(of: [entered], timeout: 1)
            XCTAssertEqual(result, .recoveryRequired)
            XCTAssertLessThan(start.duration(to: clock.now), .seconds(2))
            XCTAssertFalse(close.physicallyReturned)
            XCTAssertFalse(close.settled)
            XCTAssertEqual(commits, 0)
            XCTAssertThrowsError(try JazzArchiveFilesystemPlatform.captureJournalLeaseProvider.acquire(
                root: root, fileManager: .default)) {
                XCTAssertEqual($0 as? JazzArchiveFilesystemLeaseError, .inProgress)
            }
            intent.finishShutdown(shutdownGeneration, settled: close.settled,
                physicallyQuiescent: screen.isClosedAndQuiescent && narration.isQuiescent)
            XCTAssertTrue(CaptureStartIntent(root: root, continuous: true,
                durability: JazzArchiveFilesystemPlatform.durability).requiresResume)
            intent.pause() // late completion must not replace the current user intent
            await gate.release()
            pcmGate.signal()
            for _ in 0..<200 where !close.physicallyReturned {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            XCTAssertTrue(close.physicallyReturned)
            XCTAssertEqual(close.outcome, .recoveryRequired)
            XCTAssertFalse(close.settled)
            XCTAssertEqual(commits, 0, "late \(blockedStage) completion crossed the cancellation checkpoint")
            XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
            intent.finishShutdown(shutdownGeneration, settled: close.settled, physicallyQuiescent: true)
            XCTAssertTrue(CaptureStartIntent(root: root, continuous: true,
                durability: JazzArchiveFilesystemPlatform.durability).userPaused)
        }
    }

    func testCleanClosedAndQuiescentSequenceCanRestoreOnlyCurrentContinuousIntent() async throws {
        for pause in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let intent = CaptureStartIntent(root: root, continuous: true,
                durability: JazzArchiveFilesystemPlatform.durability)
            intent.completeRecovery(succeeded: true)
            let token = try XCTUnwrap(intent.requestStart(explicit: true))
            let started = await intent.runStart(token, recovery: { true }, prepare: { true },
                enable: { true }, abort: {})
            XCTAssertTrue(started)
            let generation = intent.beginShutdown()
            let screen = ScreenCaptureSingleFlight()
            let narration = NarrationRecorder(canAdmit: { false })
            let close = CaptureLocalClose()
            var committed = false
            let outcome = await close.run(budgetNanoseconds: 1_000_000_000, close: {
                try await CaptureLocalClose.drain(
                    narration: narration, screen: screen, labelTail: nil, audioTail: nil,
                    coachLive: nil, journalAdmission: { nil }, runtime: nil, coachActions: nil,
                    orderedProjection: nil, commit: { committed = true })
            }, recoveryRequired: { XCTFail("no blocked sources/tails") })
            XCTAssertEqual(outcome, .settled)
            XCTAssertTrue(committed)
            XCTAssertTrue(close.settled)
            if pause { intent.pause() }
            intent.finishShutdown(generation, settled: close.settled,
                physicallyQuiescent: screen.isClosedAndQuiescent && narration.isQuiescent)
            let reopened = CaptureStartIntent(root: root, continuous: true,
                durability: JazzArchiveFilesystemPlatform.durability)
            XCTAssertEqual(reopened.userPaused, pause)
            XCTAssertFalse(reopened.requiresResume)
            XCTAssertEqual(reopened.requestStart(explicit: false) == nil, pause)
            // This physical eligibility does not bypass the separately unqualified OS lock gate.
            XCTAssertFalse(CaptureSourceEnvironment(consoleSession: { true }).permitsCapture)
        }
    }
}
