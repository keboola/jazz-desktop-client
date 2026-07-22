import CoreGraphics
import Foundation

/// A listen-only CGEventTap. Captures meaningful interaction milestones — clicks, right
/// clicks, scrolls, clipboard shortcuts (⌘C/⌘X/⌘V), and key presses. Raw keys are forwarded as a
/// neutral payload; the CaptureController classifies them into semantic typed text + shortcuts and
/// NEVER buffers input from secure/sensitive fields (the "semantic text + shortcuts" model).
/// Requires Accessibility permission.
final class EventTap {
    enum RawKind { case click, rightClick, scroll, copy, cut, paste, key }

    /// Raw payload of a key press, classified downstream by ``KeyClassifier``.
    struct KeyInfo {
        var keycode: Int64
        var characters: String?  // the unicode the key produced (nil for non-printable)
        var flags: CGEventFlags
    }

    struct RawEvent {
        var kind: RawKind
        var location: CGPoint
        var key: KeyInfo?

        init(kind: RawKind, location: CGPoint, key: KeyInfo? = nil) {
            self.kind = kind
            self.location = location
            self.key = key
        }
    }

    /// US keycodes for clipboard shortcuts.
    private enum KeyCode { static let c: Int64 = 8; static let x: Int64 = 7; static let v: Int64 = 9 }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    var onEvent: ((RawEvent) -> Void)?
    /// Times the OS disabled this tap (slow callback or user input) and we re-enabled it.
    /// A rising counter means the callback is too slow — surfaced via ``onReArm``.
    private(set) var reArmCount = 0
    var onReArm: ((Int) -> Void)?

    @discardableResult
    func start() -> Bool {
        reArmCount = 0  // per-session counter (a fresh tap starts healthy)
        let mask: CGEventMask =
            (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.rightMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.scrollWheel.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon {
                let tap = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()
                tap.handle(type: type, event: event)
            }
            // Listen-only: always pass the event through unchanged.
            return Unmanaged.passUnretained(event)
        }

        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else { return false }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        let location = event.location
        switch type {
        case .leftMouseDown:
            onEvent?(RawEvent(kind: .click, location: location))
        case .rightMouseDown:
            onEvent?(RawEvent(kind: .rightClick, location: location))
        case .scrollWheel:
            onEvent?(RawEvent(kind: .scroll, location: location))
        case .keyDown:
            handleKeyDown(event, location: location)
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The OS disables a tap it considers unresponsive (or on secure-input events).
            // Without this re-enable, capture silently stops — the historical "it just
            // stopped recording" failure. Re-arm, log, and surface the count.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            reArmCount += 1
            NSLog("jasnost: event tap disabled by the OS (%@), re-armed (count %d)",
                type == .tapDisabledByTimeout ? "timeout" : "user input", reArmCount)
            onReArm?(reArmCount)
        default:
            return
        }
    }

    private func handleKeyDown(_ event: CGEvent, location: CGPoint) {
        let flags = event.flags
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        // Clipboard shortcuts stay first-class semantic events (copy/cut/paste).
        if flags.contains(.maskCommand) {
            switch keycode {
            case KeyCode.c: onEvent?(RawEvent(kind: .copy, location: location)); return
            case KeyCode.x: onEvent?(RawEvent(kind: .cut, location: location)); return
            case KeyCode.v: onEvent?(RawEvent(kind: .paste, location: location)); return
            default: break  // other ⌘ chord -> a .key event, classified as a shortcut downstream
            }
        }
        let key = KeyInfo(keycode: keycode, characters: Self.unicode(from: event), flags: flags)
        onEvent?(RawEvent(kind: .key, location: location, key: key))
    }

    /// The unicode string a key event produced (nil when empty — e.g. a pure modifier/dead key).
    /// For secure text fields the system enables Secure Event Input, so the tap receives no
    /// characters here — a defence-in-depth backstop on top of the field-sensitivity check.
    static func unicode(from event: CGEvent) -> String? {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &buffer)
        guard length > 0 else { return nil }
        return String(utf16CodeUnits: buffer, count: length)
    }
}
