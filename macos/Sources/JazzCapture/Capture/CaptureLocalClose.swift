import Foundation
import JazzCaptureCore

/// One controller close, including advisory/local admission tails BEFORE runtime.close. The
/// deadline reports retained recovery-required, not physical termination. The task and all captured
/// journal/claim owners remain alive until real return. A late return cannot revise the outcome.
@MainActor
final class CaptureLocalClose {
    enum Outcome: Equatable { case settled, recoveryRequired }
    private(set) var outcome: Outcome?
    private(set) var physicallyReturned = false
    private var operation: Task<Bool, Never>?

    var settled: Bool { outcome == .settled && physicallyReturned }

    /// The controller's actual pre-commit sequence. Each await can be non-cooperative; after a
    /// deadline none may admit the next phase. Previously admitted owners remain retained.
    static func drain(
        narration: NarrationRecorder,
        screen: ScreenCaptureSingleFlight,
        ax: CaptureAXAdmission? = nil,
        labelTail: CaptureCoachLiveLabelContextAdmissionTail?,
        audioTail: CaptureCoachLivePCMAdmissionTail?,
        coachLive: CaptureCoachLiveRuntime?,
        journalAdmission: @escaping @MainActor () -> Task<Void, Never>?,
        runtime: CaptureJournalRuntime?,
        coachActions: Task<Void, Never>?,
        orderedProjection: CaptureJournalOrderedProjection?,
        commit: @escaping @MainActor () async throws -> Void
    ) async throws {
        await narration.waitForQuiescence()
        try Task.checkCancellation()
        audioTail?.stopAccepting()
        await labelTail?.drain()
        try Task.checkCancellation()
        await audioTail?.drain()
        try Task.checkCancellation()
        await coachLive?.stop()
        try Task.checkCancellation()
        await journalAdmission()?.value
        try Task.checkCancellation()
        await runtime?.waitForAdmittedWork()
        try Task.checkCancellation()
        await journalAdmission()?.value
        try Task.checkCancellation()
        await coachActions?.value
        try Task.checkCancellation()
        _ = await orderedProjection?.retryPending()
        try Task.checkCancellation()
        await screen.waitForQuiescence()
        try Task.checkCancellation()
        await ax?.waitForQuiescence()
        try Task.checkCancellation()
        try await commit()
    }

    func run(
        budgetNanoseconds: UInt64,
        close: @escaping @MainActor () async throws -> Void,
        recoveryRequired: @escaping @MainActor () -> Void
    ) async -> Outcome {
        precondition(operation == nil)
        let task = Task { @MainActor in
            defer { self.physicallyReturned = true }
            do { try await close(); try Task.checkCancellation(); return true }
            catch { return false }
        }
        operation = task
        let result = await LocalAsyncDeadline.race(
            nanoseconds: budgetNanoseconds, cancelOperationOnResolution: false
        ) { await task.value }
        if case .value(true) = result {
            outcome = .settled
        } else {
            outcome = .recoveryRequired
            task.cancel()
            recoveryRequired()
        }
        return outcome!
    }
}

/// Label drain ownership is independent of permission to reopen the closing capture's sources.
/// Controller label admission and session close both await this same retained task.
@MainActor
final class CaptureLabelClose {
    private(set) var task: Task<Bool, Never>?
    private var owner = UUID()

    @discardableResult
    func begin(
        budgetNanoseconds: UInt64 = 5_000_000_000,
        drain: @escaping @MainActor () async throws -> Void,
        recoveryRequired: @escaping @MainActor () -> Void,
        reopen: @escaping @MainActor () -> Bool
    ) -> Task<Bool, Never> {
        let owner = UUID()
        self.owner = owner
        let close = CaptureLocalClose()
        let task = Task {
            let result = await close.run(budgetNanoseconds: budgetNanoseconds, close: drain,
                recoveryRequired: {
                    guard self.owner == owner else { return }
                    recoveryRequired()
                })
            guard self.owner == owner, result == .settled else { return false }
            // Pause may forbid reopening without making a successful drain a permanent blocker.
            // Failed/deadline outcomes stay retained; stale completions cannot clear a newer task.
            self.task = nil
            return reopen()
        }
        self.task = task
        return task
    }

    @discardableResult
    func admit(
        eligible: @escaping @MainActor () -> Bool,
        open: @escaping @MainActor () -> Void
    ) -> Task<Void, Never>? {
        if let task {
            return Task {
                guard await task.value, eligible() else { return }
                open()
            }
        }
        if eligible() { open() }
        return nil
    }
}
