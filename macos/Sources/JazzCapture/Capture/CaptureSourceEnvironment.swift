import AppKit
import CoreGraphics

/// Public session keys establish console/login membership, NOT an authoritative unlocked state.
/// Negative workspace signals and the distributed lock *hint* fence capture. Positive hints never
/// prove absence of a lock. Until real-Mac qualification, every launch/suspension needs a current
/// interactive acknowledgment; this is deliberately not unattended lock/startup qualification.
@MainActor
final class CaptureSourceEnvironment {
    enum Signal { case sleep, wake, screensSleep, screensWake, resigned, active, lockHint, unlockHint }
    private var asleep = false
    private var screensAsleep = false
    private var sessionResigned = false
    private(set) var requiresAcknowledgment = true
    private let consoleSession: () -> Bool
    var onRevocation: (() -> Void)?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(consoleSession: (() -> Bool)? = nil) {
        self.consoleSession = consoleSession ?? Self.currentConsoleSession
    }

    var permitsCapture: Bool {
        !requiresAcknowledgment && !asleep && !screensAsleep && !sessionResigned && consoleSession()
    }

    @discardableResult
    func acknowledgeCurrentUser() -> Bool {
        guard !asleep, !screensAsleep, !sessionResigned, consoleSession() else { return false }
        requiresAcknowledgment = false
        return true
    }

    func revoke() {
        requiresAcknowledgment = true
        onRevocation?()
    }

    func receive(_ signal: Signal) {
        switch signal {
        case .sleep: asleep = true
        case .wake: asleep = false
        case .screensSleep: screensAsleep = true
        case .screensWake: screensAsleep = false
        case .resigned: sessionResigned = true
        case .active: sessionResigned = false
        case .lockHint: break
        case .unlockHint: return
        }
        switch signal {
        case .sleep, .screensSleep, .resigned, .lockHint: revoke()
        default: break // Wake/active are not proof of non-lock suspension or permission to resume.
        }
    }

    func observe() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        for (name, signal) in [
            (NSWorkspace.willSleepNotification, Signal.sleep),
            (NSWorkspace.didWakeNotification, .wake),
            (NSWorkspace.screensDidSleepNotification, .screensSleep),
            (NSWorkspace.screensDidWakeNotification, .screensWake),
            (NSWorkspace.sessionDidResignActiveNotification, .resigned),
            (NSWorkspace.sessionDidBecomeActiveNotification, .active),
        ] {
            observe(workspace, name, signal)
        }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked"), .lockHint)
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked"), .unlockHint)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ signal: Signal) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.receive(signal) }
        }
        observers.append((center, observer))
    }

    deinit { for (center, observer) in observers { center.removeObserver(observer) } }

    static func currentConsoleSession() -> Bool {
        isCurrentConsoleSession(CGSessionCopyCurrentDictionary() as? [String: Any], userID: getuid())
    }

    static func isCurrentConsoleSession(_ session: [String: Any]?, userID currentUserID: UInt32) -> Bool {
        guard let session,
            let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool,
            let loginDone = session[kCGSessionLoginDoneKey as String] as? Bool,
            let userID = session[kCGSessionUserIDKey as String] as? NSNumber
        else { return false }
        return onConsole && loginDone && userID == NSNumber(value: currentUserID)
    }
}
