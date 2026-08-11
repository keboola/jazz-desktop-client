import Foundation

/// Pure formatting for the menu-bar recording indicator, split out so it is unit-testable without
/// AppKit. A capture tool should make it obvious it is recording (and for how long) — this drives
/// the live "● 2:34 · 47" the menu bar shows while a session is active.
public enum RecordingIndicator {
    /// An elapsed duration as "M:SS" (or "H:MM:SS" past an hour). Negative clamps to 0:00.
    public static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    /// The menu-bar title while capturing: a red dot, the elapsed time, and the event count.
    public static func menuBarTitle(elapsed seconds: TimeInterval, events: Int) -> String {
        "● \(elapsed(seconds)) · \(events)"
    }

    /// A one-line "what's being recorded" status for the menu (e.g. "Recording 2:34 · 47 events").
    public static func statusLine(elapsed seconds: TimeInterval, events: Int, workshop: Bool) -> String {
        let head = workshop ? "BDM workshop" : "Recording"
        return "\(head) \(elapsed(seconds)) · \(events) event\(events == 1 ? "" : "s")"
    }
}
