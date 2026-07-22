import Foundation

/// What a single key press means, once classified. The chosen keystroke model is
/// "semantic text + shortcuts": plain characters accumulate into per-field typed text, modifier
/// chords become shortcuts, and a handful of control keys become named special keys. Nothing here
/// is a raw per-key log destined for storage — the executable accumulates ``text`` and emits one
/// redacted `input` event per field; ``shortcut`` / ``special`` become `keydown` events.
public enum KeyAction: Sendable, Equatable {
    case text(String)  // a printable character (or space) — appended to the typing buffer
    case backspace  // edits the typing buffer rather than emitting anything
    case special(String)  // "Enter", "Tab", "Escape", "ArrowLeft", …
    case shortcut(String)  // "Cmd+S", "Cmd+Shift+Z", "Ctrl+Opt+Delete"
    case ignored  // a key we don't model (e.g. a lone modifier, an unprintable dead key)
}

/// US-layout virtual keycode <-> human key-name table, shared by capture (keycode -> name) and
/// replay (name -> keycode), so a captured shortcut/special key round-trips through storage.
public enum KeyMap {
    /// Named key -> US virtual keycode. Letters are uppercase; digits are their character.
    public static let nameToCode: [String: Int64] = {
        var map: [String: Int64] = [:]
        let letters: [(String, Int64)] = [
            ("A", 0), ("B", 11), ("C", 8), ("D", 2), ("E", 14), ("F", 3), ("G", 5), ("H", 4),
            ("I", 34), ("J", 38), ("K", 40), ("L", 37), ("M", 46), ("N", 45), ("O", 31), ("P", 35),
            ("Q", 12), ("R", 15), ("S", 1), ("T", 17), ("U", 32), ("V", 9), ("W", 13), ("X", 7),
            ("Y", 16), ("Z", 6),
        ]
        let digits: [(String, Int64)] = [
            ("0", 29), ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("5", 23), ("6", 22), ("7", 26),
            ("8", 28), ("9", 25),
        ]
        // First write wins, so the main Return (36) is "Enter", not the keypad Enter (76).
        for (name, code) in letters + digits + specials where map[name] == nil { map[name] = code }
        return map
    }()

    /// US virtual keycode -> named key (inverse of ``nameToCode``).
    public static let codeToName: [Int64: String] = {
        var map: [Int64: String] = [:]
        for (name, code) in nameToCode where map[code] == nil { map[code] = name }
        return map
    }()

    /// Control / navigation keys that become named ``KeyAction.special`` events (NOT typed text).
    /// Excludes Space (a printable " ") and Delete/backspace (handled as ``KeyAction.backspace``).
    static let specials: [(String, Int64)] = [
        ("Enter", 36), ("Enter", 76), ("Tab", 48), ("Escape", 53),
        ("ArrowLeft", 123), ("ArrowRight", 124), ("ArrowDown", 125), ("ArrowUp", 126),
        ("Home", 115), ("End", 119), ("PageUp", 116), ("PageDown", 121), ("ForwardDelete", 117),
    ]

    static let specialNames: [Int64: String] = {
        var map: [Int64: String] = [:]
        for (name, code) in specials where map[code] == nil { map[code] = name }
        return map
    }()

    static let backspaceKeycode: Int64 = 51
}

/// Pure classification of a keyDown into a ``KeyAction``. Driven by the executable's event tap; kept
/// here so the (fiddly) modifier/keycode logic is unit-tested without CoreGraphics.
public enum KeyClassifier {
    public static func classify(
        keycode: Int64, characters: String?,
        command: Bool, control: Bool, option: Bool, shift: Bool
    ) -> KeyAction {
        // A Cmd/Ctrl chord is a shortcut (Shift/Option alone are part of normal typing).
        if command || control {
            return .shortcut(
                combo(
                    keycode: keycode, characters: characters,
                    command: command, control: control, option: option, shift: shift
                )
            )
        }
        if keycode == KeyMap.backspaceKeycode { return .backspace }
        if let name = KeyMap.specialNames[keycode] { return .special(name) }
        if let characters, !characters.isEmpty, isPrintable(characters) { return .text(characters) }
        return .ignored
    }

    /// "Cmd+Shift+S" — modifiers in a stable order, then the key name (codeToName, else the char).
    static func combo(
        keycode: Int64, characters: String?,
        command: Bool, control: Bool, option: Bool, shift: Bool
    ) -> String {
        var parts: [String] = []
        if command { parts.append("Cmd") }
        if control { parts.append("Ctrl") }
        if option { parts.append("Opt") }
        if shift { parts.append("Shift") }
        let key =
            KeyMap.codeToName[keycode]
            ?? characters?.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "?"
        parts.append(key.isEmpty ? "?" : key)
        return parts.joined(separator: "+")
    }

    /// Printable = every scalar is at/above space and not DEL (filters control/dead keys).
    static func isPrintable(_ s: String) -> Bool {
        !s.unicodeScalars.isEmpty && s.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
    }
}

/// Accumulates printable keystrokes into a per-field string, edited by backspace and flushed at a
/// focus boundary (click, app switch, special key, shortcut, stop). The executable owns one of these
/// while a field has focus; the value is redacted at flush time before it is stored.
public struct TypingAccumulator: Sendable {
    public private(set) var buffer = ""

    public init() {}
    public var isEmpty: Bool { buffer.isEmpty }

    public mutating func append(_ s: String) { buffer += s }
    public mutating func backspace() { if !buffer.isEmpty { buffer.removeLast() } }

    /// Return the raw buffer and clear it. The caller redacts before storing.
    public mutating func flush() -> String {
        defer { buffer = "" }
        return buffer
    }
}
