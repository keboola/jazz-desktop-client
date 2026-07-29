import Foundation

enum ScreenCaptureSingleFlightResult<Value: Sendable>: Sendable {
    case value(Value)
    case timedOut
    case cancelled
    case busy
}

/// Owns the one physical ScreenCaptureKit admission slot for a process.
///
/// A logical caller may time out or be cancelled, but the physical OS operation is deliberately
/// not cancelled: several ScreenCaptureKit paths return from cancellation before their IPC
/// callback has actually settled. The slot is released only by the operation's real return. Until
/// then all later requests fail immediately as `busy`, so a wedged OS continuation costs one task
/// and one IPC request rather than an unbounded task/request backlog.
actor ScreenCaptureSingleFlight {
    struct Snapshot: Equatable, Sendable {
        let physicalOperationActive: Bool
        let admittedOperationCount: Int
    }

    private var nextTicket: UInt64 = 0
    private var activeTicket: UInt64?
    private var admittedOperationCount = 0

    func run<Value: Sendable>(
        budgetNanoseconds: UInt64,
        operation: @escaping @Sendable () async -> Value
    ) async -> ScreenCaptureSingleFlightResult<Value> {
        guard activeTicket == nil else { return .busy }
        nextTicket &+= 1
        let ticket = nextTicket
        activeTicket = ticket
        admittedOperationCount += 1

        let result = await LocalAsyncDeadline.race(
            nanoseconds: budgetNanoseconds,
            cancelOperationOnResolution: false
        ) {
            let value = await operation()
            await self.release(ticket: ticket)
            return value
        }
        switch result {
        case .value(let value):
            return .value(value)
        case .timedOut:
            return .timedOut
        case .cancelled:
            return .cancelled
        }
    }

    func snapshot() -> Snapshot {
        Snapshot(
            physicalOperationActive: activeTicket != nil,
            admittedOperationCount: admittedOperationCount)
    }

    private func release(ticket: UInt64) {
        // Ticket identity prevents a stale completion from opening a slot owned by a newer
        // operation if this actor's implementation later gains explicit recovery controls.
        guard activeTicket == ticket else { return }
        activeTicket = nil
    }
}
