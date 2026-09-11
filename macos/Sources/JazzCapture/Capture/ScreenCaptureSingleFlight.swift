import Foundation

enum ScreenCaptureSingleFlightResult<Value: Sendable>: Sendable {
    case value(Value)
    case timedOut
    case cancelled
    case busy
}

/// MainActor ordering makes revocation synchronous with input/label admission. A logical deadline
/// never releases the physical slot. Only the actual operation return can settle a closed gate.
@MainActor
final class ScreenCaptureSingleFlight {
    struct Admission: Equatable, Sendable { fileprivate let generation: UUID }
    struct Snapshot: Equatable, Sendable {
        let physicalOperationActive: Bool
        let admittedOperationCount: Int
    }

    private var generation = UUID()
    private var accepting = false
    private var activeTicket: UUID?
    private var admittedOperationCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var eligible: () -> Bool = { false }

    var isClosedAndQuiescent: Bool { !accepting && activeTicket == nil }
    var admission: Admission? { accepting ? Admission(generation: generation) : nil }

    /// A new generation cannot overlap old native work, even after a caller timed out.
    func open(eligible: @escaping () -> Bool) -> Bool {
        guard isClosedAndQuiescent, eligible() else { return false }
        generation = UUID()
        self.eligible = eligible
        accepting = true
        return true
    }

    func close() {
        accepting = false
        generation = UUID()
        eligible = { false }
    }

    func permits(_ admission: Admission?) -> Bool {
        guard accepting, admission?.generation == generation else { return false }
        return eligible() && accepting && admission?.generation == generation
    }

    func waitForQuiescence() async {
        precondition(!accepting)
        if activeTicket == nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func run<Value: Sendable>(
        admission: Admission?,
        budgetNanoseconds: UInt64,
        operation: @escaping @MainActor @Sendable () async -> Value
    ) async -> ScreenCaptureSingleFlightResult<Value> {
        guard permits(admission) else { return .cancelled }
        guard activeTicket == nil else { return .busy }
        let ticket = UUID()
        activeTicket = ticket
        admittedOperationCount += 1
        let result = await LocalAsyncDeadline.race(
            nanoseconds: budgetNanoseconds,
            cancelOperationOnResolution: false
        ) { @MainActor () -> Value? in
            defer { self.release(ticket: ticket) }
            guard self.permits(admission) else { return nil }
            return await operation()
        }
        switch result {
        case .value(let value):
            guard let value, permits(admission) else { return .cancelled }
            return .value(value)
        case .timedOut: return .timedOut
        case .cancelled: return .cancelled
        }
    }

    func snapshot() -> Snapshot {
        Snapshot(physicalOperationActive: activeTicket != nil,
                 admittedOperationCount: admittedOperationCount)
    }

    private func release(ticket: UUID) {
        guard activeTicket == ticket else { return }
        activeTicket = nil
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
