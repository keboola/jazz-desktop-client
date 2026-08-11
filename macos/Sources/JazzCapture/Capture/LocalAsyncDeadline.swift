import Foundation

/// Result of a local deadline race whose operation may ignore cooperative cancellation.
enum LocalAsyncDeadlineResult<Value: Sendable>: Sendable {
    case value(Value)
    case timedOut
    case cancelled
}

private actor LocalAsyncDeadlineGate<Value: Sendable> {
    private var result: LocalAsyncDeadlineResult<Value>?
    private var continuation:
        CheckedContinuation<LocalAsyncDeadlineResult<Value>, Never>?

    func wait() async -> LocalAsyncDeadlineResult<Value> {
        if let result { return result }
        return await withCheckedContinuation { continuation = $0 }
    }

    func resolve(_ result: LocalAsyncDeadlineResult<Value>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(returning: result)
        continuation = nil
    }
}

/// Races untrusted local OS work against a monotonic deadline without structurally awaiting the
/// loser. This matters for APIs such as ScreenCaptureKit: cancellation is best-effort and an IPC
/// continuation may physically finish after the caller has already moved on.
///
/// The operation MUST keep all canonical side effects outside this primitive. A late result can
/// only attempt to resolve the already-locked gate and therefore cannot re-enter finalization.
enum LocalAsyncDeadline {
    static func race<Value: Sendable>(
        nanoseconds: UInt64,
        cancelOperationOnResolution: Bool = true,
        operation: @escaping @Sendable () async -> Value
    ) async -> LocalAsyncDeadlineResult<Value> {
        let gate = LocalAsyncDeadlineGate<Value>()
        let operationTask = Task {
            let value = await operation()
            await gate.resolve(.value(value))
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            await gate.resolve(.timedOut)
        }

        return await withTaskCancellationHandler {
            let result = await gate.wait()
            if cancelOperationOnResolution {
                operationTask.cancel()
            }
            timeoutTask.cancel()
            return result
        } onCancel: {
            if cancelOperationOnResolution {
                operationTask.cancel()
            }
            timeoutTask.cancel()
            Task {
                await gate.resolve(.cancelled)
            }
        }
    }
}
