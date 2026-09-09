import Foundation

/// Local engineering targets, not archive authorization or negotiated receiver capabilities.
public struct CaptureChunkBoundary: Equatable, Sendable {
    public enum Reason: String, Sendable {
        case duration = "duration target"
        case bytes = "byte target"
        case unknown = "unknown time/byte accounting"
    }
    public enum Failure: Error { case invalidConfiguration }
    public static let defaultDuration: TimeInterval = 30 * 60
    public static let defaultTargetBytes: Int64 = 250 * 1024 * 1024
    public static let closeHeadroomBytes: Int64 = 16 * 1024 * 1024
    public let duration: TimeInterval
    public let targetBytes: Int64

    public init(duration: TimeInterval = Self.defaultDuration,
        targetBytes: Int64 = Self.defaultTargetBytes) throws
    {
        // Stay below the known portable importer's 512 MiB entry / 2 GiB package ceilings.
        // Deployed receiver/proxy ceilings are not advertised; this is NOT server-limit proof.
        guard duration.isFinite, (60...Self.defaultDuration).contains(duration),
            (32 * 1024 * 1024...Self.defaultTargetBytes).contains(targetBytes)
        else { throw Failure.invalidConfiguration }
        self.duration = duration
        self.targetBytes = targetBytes
    }

    public static func permitsContinuation(reason: Reason, hasOpenSpan: Bool) -> Bool {
        reason != .unknown && !hasOpenSpan
    }

    public func reason(started: TimeInterval, now: TimeInterval,
        measuredBytes: Int64?, pendingBytes: Int64?) -> Reason?
    {
        guard started.isFinite, now.isFinite, started >= 0, now >= started,
            let measuredBytes, let pendingBytes, measuredBytes >= 0, pendingBytes >= 0
        else { return .unknown }
        let (bytes, overflow) = measuredBytes.addingReportingOverflow(pendingBytes)
        let (budget, headroomOverflow) = bytes.addingReportingOverflow(Self.closeHeadroomBytes)
        guard !overflow, !headroomOverflow else { return .unknown }
        if budget >= targetBytes { return .bytes }
        return now - started >= duration ? .duration : nil
    }
}

/// O(1) cumulative write/media budget shared across journal actor and executable. It deliberately
/// counts copies and repeated WAL/checkpoint bytes, not a directory size or final ZIP prediction.
/// A lost/overflowed measurement is sticky unknown; accounting never throws away admitted evidence.
public final class CaptureChunkBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64? = 0

    public init() {}
    public var measured: Int64? { lock.withLock { bytes } }

    public func add(_ count: Int64, copies: Int64 = 1) {
        lock.withLock {
            guard let previous = bytes, count >= 0, copies > 0 else { bytes = nil; return }
            let (amount, multiplied) = count.multipliedReportingOverflow(by: copies)
            let (total, added) = previous.addingReportingOverflow(amount)
            bytes = multiplied || added ? nil : total
        }
    }
}
