import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics

/// The three TCC permissions the agent needs. Granting happens up front in Settings so the
/// capture flow never interrupts the user with one prompt at a time.
enum Permission: String, CaseIterable, Identifiable {
    case accessibility
    case screenRecording
    case microphone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        case .microphone: return "Microphone"
        }
    }

    var why: String {
        switch self {
        case .accessibility: return "Required — read the element you click and capture input."
        case .screenRecording: return "For screenshots of the focused window."
        case .microphone: return "For voice narration."
        }
    }

    /// The System Settings privacy pane anchor for this permission.
    fileprivate var settingsAnchor: String {
        switch self {
        case .accessibility: return "Privacy_Accessibility"
        case .screenRecording: return "Privacy_ScreenCapture"
        case .microphone: return "Privacy_Microphone"
        }
    }
}

enum PermissionStatus {
    case granted
    case notDetermined
    case denied
}

@MainActor
enum Permissions {
    static func status(_ permission: Permission) -> PermissionStatus {
        switch permission {
        case .accessibility:
            // AX has no "not determined" state — it's trusted or not.
            return AXIsProcessTrusted() ? .granted : .denied
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .denied
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        }
    }

    /// Trigger the system permission prompt (where one exists). For already-denied
    /// permissions there is no prompt — the user must toggle it in System Settings, so the
    /// UI also offers `openSystemSettings`.
    static func request(_ permission: Permission) {
        switch permission {
        case .accessibility:
            _ = Accessibility.isTrusted(prompt: true)
        case .screenRecording:
            CGRequestScreenCaptureAccess()
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
    }

    static func requestAllMissing() {
        for permission in Permission.allCases where status(permission) != .granted {
            request(permission)
        }
    }

    static func openSystemSettings(_ permission: Permission) {
        let urlString =
            "x-apple.systempreferences:com.apple.preference.security?\(permission.settingsAnchor)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    /// macOS applies Accessibility / Screen Recording grants only to a freshly launched
    /// process — the running one keeps its stale TCC answer. Relaunch the bundle: spawn a
    /// detached shell that waits for this PID to exit, then re-opens the .app, and terminate.
    static func relaunch() {
        let bundlePath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
            "-c",
            "while /bin/kill -0 \(pid) >/dev/null 2>&1; do /bin/sleep 0.2; done; "
                + "/usr/bin/open \"\(bundlePath)\"",
        ]
        try? task.run()
        NSApp.terminate(nil)
    }
}
