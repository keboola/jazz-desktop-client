import Foundation

/// Platform-neutral point used by the pointer state machine. OS adapters translate to/from their
/// native coordinate type; coordinates remain evidence and are never treated as portable locators.
public struct PointerPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct CompletedPointerGesture: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case click, drag }

    public var kind: Kind
    public var start: PointerPoint
    public var end: PointerPoint?
    public var clickCount: Int
    /// Identity of the final physical press whose snapshot backs this logical observation.
    public var sampleId: String
    /// Stable root identity shared by every physical sample in the logical gesture.
    public var gestureId: String
    /// Wall-clock completion time captured at the final mouse-up, before any coalescing delay.
    public var completedAt: Date
}

/// One physical pointer completion. It is provisional evidence only: enrich this sample
/// immediately, but do not append it until ``CompletedPointerGesture`` selects its `sampleId`.
public struct PointerGestureSample: Equatable, Sendable {
    public var kind: CompletedPointerGesture.Kind
    public var start: PointerPoint
    public var end: PointerPoint?
    public var clickCount: Int
    /// Unique identity of this physical press/release pair.
    public var sampleId: String
    /// Root identity of the logical sequence.
    public var gestureId: String
    public var completedAt: Date
}

/// Result of one physical mouse-up. `sample` starts enrichment now; `resolutions` determines which
/// already-started sample may become canonical. A drag carries both in the same update.
public struct PointerGestureUpdate: Equatable, Sendable {
    public var sample: PointerGestureSample
    public var resolutions: [CompletedPointerGesture]

    public init(
        sample: PointerGestureSample,
        resolutions: [CompletedPointerGesture] = []
    ) {
        self.sample = sample
        self.resolutions = resolutions
    }
}

/// Turns mouse-down/drag/up callbacks into exactly one completed logical gesture. Delaying the
/// observation until mouse-up also lets accessibility enrichment see the resulting selection.
///
/// A first click is held for the bounded system double-click interval. A following click whose
/// OS click state advances the same sequence replaces it, so a physical down/up count 1 followed
/// by down/up count 2 produces one logical click with `clickCount == 2`. The platform adapter owns
/// the timer and calls ``flushExpired(at:)``; ``finish()`` drains a completed click at Stop.
public struct PointerGestureTracker: Sendable {
    private struct Pending: Sendable {
        var start: PointerPoint
        var clickCount: Int
        /// Unique identity of this physical press. It changes for click 1 → 2 → 3.
        var sampleId: String
        /// Candidate root minted for this press, retained if a boundary rebases a continuation.
        var candidateGestureId: String
        /// Root identity of the logical sequence. It stays fixed across click 1 → 2 → 3.
        var rootGestureId: String
        var didDrag = false
        var continuesClickSequence: Bool
    }

    private struct DeferredClick: Sendable {
        var gesture: CompletedPointerGesture
        var deadline: TimeInterval
    }

    private let doubleClickInterval: TimeInterval
    private var pending: Pending?
    private var deferredClick: DeferredClick?

    public init(doubleClickInterval: TimeInterval = 0.5) {
        self.doubleClickInterval = max(0, doubleClickInterval)
    }

    /// Monotonic deadline the platform timer should target. While a continuation button press is
    /// active the deadline is suspended: the OS already recognised that press as the next click.
    public var nextClickDeadline: TimeInterval? {
        guard pending?.continuesClickSequence != true else { return nil }
        return deferredClick?.deadline
    }

    @discardableResult
    public mutating func mouseDown(
        at point: PointerPoint, clickCount: Int, sampleId: String, gestureId: String,
        timestamp: TimeInterval
    ) -> [CompletedPointerGesture] {
        let hadExpiredSequence =
            deferredClick.map { timestamp >= $0.deadline } ?? false
        var completed = flushExpired(at: timestamp)
        let reportedClickCount = max(1, clickCount)
        let continuesClickSequence =
            deferredClick.map {
                !hadExpiredSequence
                    && reportedClickCount == $0.gesture.clickCount + 1
                    && timestamp < $0.deadline
            } ?? false

        // A multi-click count is only evidence when this capture observed the preceding click.
        // Starting mid-series (or losing the prefix) must not invent a double/triple gesture.
        var logicalClickCount = deferredClick == nil ? 1 : reportedClickCount
        if deferredClick != nil, !continuesClickSequence {
            completed.append(contentsOf: flushPendingClick())
            // A repeated/non-advancing OS click state starts a new logical sequence. Treat it as a
            // single even if a malformed adapter supplied a stale multi-click state.
            logicalClickCount = 1
        } else if hadExpiredSequence {
            logicalClickCount = 1
        }

        let rootGestureId =
            continuesClickSequence
            ? deferredClick?.gesture.gestureId ?? gestureId
            : gestureId
        pending = Pending(
            start: point,
            clickCount: logicalClickCount,
            sampleId: sampleId,
            candidateGestureId: gestureId,
            rootGestureId: rootGestureId,
            continuesClickSequence: continuesClickSequence)
        return completed
    }

    public mutating func mouseDragged() {
        pending?.didDrag = true
    }

    @discardableResult
    public mutating func mouseUp(
        at point: PointerPoint, timestamp: TimeInterval, completedAt: Date = Date()
    ) -> PointerGestureUpdate? {
        guard let pending else { return nil }
        self.pending = nil
        let sample = PointerGestureSample(
            kind: pending.didDrag ? .drag : .click,
            start: pending.start,
            end: pending.didDrag ? point : nil,
            clickCount: pending.clickCount,
            sampleId: pending.sampleId,
            gestureId: pending.rootGestureId,
            completedAt: completedAt)

        if pending.didDrag {
            // A drag is complete at mouse-up and must never wait behind click coalescing. If the
            // drag was the next press in a multi-click sequence, the whole physical interaction is
            // represented by the drag rather than a stale initial click plus a drag.
            if pending.continuesClickSequence {
                deferredClick = nil
            }
            return PointerGestureUpdate(
                sample: sample,
                resolutions: [
                    CompletedPointerGesture(
                        kind: .drag,
                        start: pending.start,
                        end: point,
                        clickCount: pending.clickCount,
                        sampleId: pending.sampleId,
                        gestureId: pending.rootGestureId,
                        completedAt: completedAt)
                ])
        }

        let gesture: CompletedPointerGesture
        if pending.continuesClickSequence, deferredClick != nil {
            gesture = CompletedPointerGesture(
                kind: .click,
                // The root ID belongs to the full multi-click sequence, while hit-testing belongs
                // at the final press that produced the resulting selection.
                start: pending.start,
                end: nil,
                clickCount: pending.clickCount,
                sampleId: pending.sampleId,
                gestureId: pending.rootGestureId,
                completedAt: completedAt)
        } else {
            gesture = CompletedPointerGesture(
                kind: .click,
                start: pending.start,
                end: nil,
                clickCount: pending.clickCount,
                sampleId: pending.sampleId,
                gestureId: pending.rootGestureId,
                completedAt: completedAt)
        }
        deferredClick = DeferredClick(
            gesture: gesture,
            deadline: timestamp + doubleClickInterval)
        return PointerGestureUpdate(sample: sample)
    }

    /// Emits a completed click once its bounded continuation window has elapsed.
    public mutating func flushExpired(at timestamp: TimeInterval) -> [CompletedPointerGesture] {
        guard pending?.continuesClickSequence != true,
            let deferredClick,
            timestamp >= deferredClick.deadline
        else {
            return []
        }
        self.deferredClick = nil
        return [deferredClick.gesture]
    }

    /// Ends the current click sequence before an independent input event. Any active continuation
    /// is rebased to a single press so it cannot later refer to the click that was just emitted.
    public mutating func flushPendingClick() -> [CompletedPointerGesture] {
        guard let deferredClick else { return [] }
        self.deferredClick = nil
        if var active = pending, active.continuesClickSequence {
            active.continuesClickSequence = false
            active.clickCount = 1
            active.rootGestureId = active.candidateGestureId
            pending = active
        }
        return [deferredClick.gesture]
    }

    /// Drains completed evidence at capture Stop, then discards any still-incomplete button press.
    public mutating func finish() -> [CompletedPointerGesture] {
        let completed = flushPendingClick()
        pending = nil
        return completed
    }

    public mutating func reset() {
        pending = nil
        deferredClick = nil
    }
}
