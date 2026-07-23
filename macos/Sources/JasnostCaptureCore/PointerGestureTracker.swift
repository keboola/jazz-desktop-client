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
    public var gestureId: String
}

/// Turns mouse-down/drag/up callbacks into exactly one completed logical gesture. Delaying the
/// observation until mouse-up also lets accessibility enrichment see the resulting selection.
public struct PointerGestureTracker: Sendable {
    private struct Pending: Sendable {
        var start: PointerPoint
        var clickCount: Int
        var gestureId: String
        var didDrag = false
    }

    private var pending: Pending?

    public init() {}

    public mutating func mouseDown(
        at point: PointerPoint, clickCount: Int, gestureId: String
    ) {
        pending = Pending(
            start: point, clickCount: max(1, clickCount), gestureId: gestureId)
    }

    public mutating func mouseDragged() {
        pending?.didDrag = true
    }

    public mutating func mouseUp(at point: PointerPoint) -> CompletedPointerGesture? {
        guard let pending else { return nil }
        self.pending = nil
        return CompletedPointerGesture(
            kind: pending.didDrag ? .drag : .click,
            start: pending.start,
            end: pending.didDrag ? point : nil,
            clickCount: pending.clickCount,
            gestureId: pending.gestureId)
    }

    public mutating func reset() {
        pending = nil
    }
}
