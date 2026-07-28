import Foundation

/// One on-screen window from the window-server snapshot: who owns it and where it sits.
/// Deliberately minimal so the z-order pick is testable without CGWindowList / AppKit.
public struct WindowDescriptor: Equatable, Sendable {
    public let ownerPID: pid_t
    /// Global, top-left-origin frame (the Quartz coordinate space CGEvent locations use too).
    public let bounds: CaptureRectangle
    /// Quartz window level. Only level 0 represents a normal application window; positive levels
    /// are menu extras, HUDs, launchers, window-manager overlays, and other non-content surfaces.
    public let layer: Int
    /// Window-server opacity. Fully transparent helpers are not physical pointer targets.
    public let alpha: Double

    public init(
        ownerPID: pid_t,
        bounds: CaptureRectangle,
        layer: Int = 0,
        alpha: Double = 1
    ) {
        self.ownerPID = ownerPID
        self.bounds = bounds
        self.layer = layer
        self.alpha = alpha
    }
}

/// Pure z-order math for "whose window is under this point", split out so it is unit-testable
/// without the window server.
public enum WindowHitTest {
    /// Owner PID of the topmost window under `point` that is **not** ours.
    ///
    /// `windows` must be front-to-back z-order (what `CGWindowListCopyWindowInfo` returns). We skip
    /// every window owned by `excludingPID` — our own UI, above all the full-screen click-through
    /// highlight overlay — because hit-testing an in-process element resolves through AppKit's
    /// `NSAccessibility`, which is main-thread-only and crashes when driven off the AX background
    /// queue (a data race → `objc_msgSend` on a freed object). By picking the foreign window under
    /// the point we keep the subsequent AX hit-test on the safe cross-process (IPC) path, and a
    /// click that passed *through* our overlay still attributes to the app beneath it.
    ///
    /// Returns `nil` when only our own windows (or the bare desktop) lie under the point.
    public static func topmostForeignOwner(
        windows: [WindowDescriptor],
        at point: CapturePoint,
        excluding excludingPID: pid_t
    ) -> pid_t? {
        for window in windows
        where window.ownerPID != excludingPID
            && window.layer == 0
            && window.alpha > 0
            && window.bounds.contains(point)
        {
            return window.ownerPID
        }
        return nil
    }

    /// A cross-process AX hit is useful only when the returned element actually covers the
    /// physical pointer. Some overlay applications return their menu bar or root element even for
    /// coordinates outside that element; accepting it poisons both click attribution and the
    /// screenshot owner check. Missing frames remain admissible because many legitimate AX
    /// elements do not expose `kAXFrame`.
    public static func targetFrameIsPlausible(
        _ frame: CaptureRectangle?,
        at point: CapturePoint
    ) -> Bool {
        frame?.contains(point) ?? true
    }
}
