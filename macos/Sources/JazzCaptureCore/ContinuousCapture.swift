import Foundation

/// Continuous-mode lifecycle rules; the native hosts own their timers and capture resources.
public enum ContinuousCapture {
    public static let pauseReminderInterval: TimeInterval = 30 * 60

    public static func shouldRemind(enabled: Bool, paused: Bool, recording: Bool) -> Bool {
        enabled && paused && !recording
    }

    public static func shouldContinue(
        enabled: Bool, committed: Bool, paused: Bool, terminating: Bool
    ) -> Bool {
        enabled && committed && !paused && !terminating
    }
}
