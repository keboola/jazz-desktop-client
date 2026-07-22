import AppKit
import ApplicationServices
import JasnostCaptureCore

/// Replays a captured session's steps by re-finding each element via Accessibility (role + name) and
/// PRESSING it — independent of window position — with a synthetic-click fallback at the recorded
/// coordinates. Activates the right app per step, highlights what it presses, paces itself, and stops
/// on demand.
///
/// Auto-replay posts REAL input, so it is deliberately explicit (you start it), paced (a delay between
/// steps), visible (the highlight shows each target), and interruptible (Stop). It replays clicks,
/// app switches, typed text (the REDACTED value that was stored), and shortcuts/special keys. It
/// never replays input captured from secure/sensitive fields — that was never recorded.
@MainActor
final class ReplayController: ObservableObject {
    @Published private(set) var isReplaying = false
    @Published private(set) var status = ""
    @Published private(set) var progress = ""  // "3 / 12"

    private let highlight = HighlightOverlay()
    private var cancelled = false

    func replay(_ steps: [ReplayStep], stepDelay: TimeInterval = 0.7) {
        guard !isReplaying else { return }
        let actionable = steps  // every kind (navigate/click/type/shortcut/key) is actionable
        guard !actionable.isEmpty else {
            status = "Nothing to replay."
            return
        }
        guard Permissions.status(.accessibility) == .granted else {
            status = "Grant Accessibility to replay."
            return
        }
        isReplaying = true
        cancelled = false
        Task { [weak self] in
            guard let self else { return }
            var skipped = 0
            for (index, step) in actionable.enumerated() {
                if cancelled { break }
                progress = "\(index + 1) / \(actionable.count)"
                status = step.label
                if await perform(step) == false { skipped += 1 }
                if cancelled { break }
                try? await Task.sleep(nanoseconds: UInt64(stepDelay * 1_000_000_000))
            }
            highlight.hide()
            if cancelled {
                status = "Replay stopped."
            } else if skipped > 0 {
                status = "Replay finished — \(skipped) step(s) skipped (app not available)."
            } else {
                status = "Replay finished."
            }
            progress = ""
            isReplaying = false
        }
    }

    func stop() { cancelled = true }

    /// Perform one step. Returns false if it was SKIPPED because its app couldn't be brought to the
    /// front — never a failure that posts input elsewhere.
    @discardableResult
    private func perform(_ step: ReplayStep) async -> Bool {
        guard let bundleID = step.bundleID else { return true }
        // SAFETY: never post synthetic input unless the captured app is actually frontmost. If it was
        // quit it is relaunched; if it still can't be fronted (e.g. a transient Spotlight overlay) the
        // step is skipped so clicks/typing/shortcuts never land blindly in whatever is focused now.
        guard await ensureFrontmost(bundleID) else {
            status = "Skipped “\(step.label)” — \(appLabel(bundleID)) isn't available."
            return false
        }
        switch step.kind {
        case .navigate:
            break  // bringing the app forward (above) is the whole step
        case .click:
            await performClick(step, bundleID: bundleID)
        case .type:
            await performType(step, bundleID: bundleID)
        case .shortcut:
            if let combo = step.name { Self.sendShortcut(combo) }
        case .key:
            if let name = step.name { Self.sendSpecialKey(name) }
        }
        return true
    }

    private func performClick(_ step: ReplayStep, bundleID: String) async {
        if let element = Accessibility.find(
            bundleID: bundleID, role: step.role, name: step.name,
            identifier: step.identifier, index: step.index)
        {
            if let frame = Accessibility.currentFrame(of: element) { highlight.flash(axFrame: frame) }
            try? await Task.sleep(nanoseconds: 150_000_000)
            Accessibility.press(element)
        } else if let box = step.boundingBox {
            // AX re-find failed (UI changed?) — fall back to a synthetic click at the recorded spot.
            highlight.flash(axFrame: box)
            try? await Task.sleep(nanoseconds: 150_000_000)
            Self.syntheticClick(at: CGPoint(x: box.midX, y: box.midY))
        } else {
            status = "Couldn't find “\(step.label)” — skipped."
        }
    }

    private func performType(_ step: ReplayStep, bundleID: String) async {
        guard let text = step.text, !text.isEmpty else { return }
        // Focus the recorded field first when we can re-find it, so the text lands where it was typed.
        if let element = Accessibility.find(
            bundleID: bundleID, role: step.role, name: step.name,
            identifier: step.identifier, index: step.index)
        {
            if let frame = Accessibility.currentFrame(of: element) { highlight.flash(axFrame: frame) }
            Accessibility.focus(element)
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        Self.typeText(text)
    }

    /// Bring ``bundleID`` to the front and CONFIRM it is frontmost before any input is posted. If the
    /// app isn't running it is launched; we then poll briefly for it to actually come forward. Returns
    /// false if it can't be made frontmost (quit + can't relaunch, or it never takes focus) — the
    /// caller must then abort rather than act blindly.
    private func ensureFrontmost(_ bundleID: String, timeout: TimeInterval = 3.0) async -> Bool {
        if isFrontmost(bundleID) { return true }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app.activate(options: [.activateAllWindows])
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
        } else {
            return false  // not installed / unknown bundle id
        }
        let deadline = Int(timeout / 0.15)
        for _ in 0..<deadline {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if isFrontmost(bundleID) { return true }
        }
        return isFrontmost(bundleID)
    }

    private func isFrontmost(_ bundleID: String) -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }

    /// Human label for an app (its localized name when running, else the bundle id).
    private func appLabel(_ bundleID: String) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
            ?? bundleID
    }

    /// Fallback: synthesize a left click at a screen point (top-left origin, matching capture).
    private nonisolated static func syntheticClick(at point: CGPoint) {
        let down = CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseDown,
            mouseCursorPosition: point, mouseButton: .left
        )
        let up = CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseUp,
            mouseCursorPosition: point, mouseButton: .left
        )
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Type a string by posting unicode key events (layout-independent — no keycode lookup needed).
    private nonisolated static func typeText(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for character in text {
            var utf16 = Array(String(character).utf16)
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown)
                else { continue }
                event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                event.post(tap: .cghidEventTap)
            }
        }
    }

    /// Re-send a captured shortcut ("Cmd+Shift+S"): map the trailing key name to a US keycode and
    /// press it with the recorded modifier flags. Unmappable keys are skipped (logged in status).
    private nonisolated static func sendShortcut(_ combo: String) {
        var parts = combo.split(separator: "+").map(String.init)
        guard let keyName = parts.popLast(), let keycode = KeyMap.nameToCode[keyName] else { return }
        var flags: CGEventFlags = []
        for modifier in parts {
            switch modifier {
            case "Cmd": flags.insert(.maskCommand)
            case "Ctrl": flags.insert(.maskControl)
            case "Opt": flags.insert(.maskAlternate)
            case "Shift": flags.insert(.maskShift)
            default: break
            }
        }
        postKey(CGKeyCode(keycode), flags: flags)
    }

    /// Re-send a captured special key ("Enter", "Tab", "ArrowLeft").
    private nonisolated static func sendSpecialKey(_ name: String) {
        guard let keycode = KeyMap.nameToCode[name] else { return }
        postKey(CGKeyCode(keycode), flags: [])
    }

    private nonisolated static func postKey(_ keycode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: keyDown)
            else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }
}
