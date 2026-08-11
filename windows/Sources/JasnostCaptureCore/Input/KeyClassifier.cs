namespace JasnostCaptureCore.Input;

/// <summary>What a single key press means once classified (ANNEX-HOST section 2).</summary>
public enum KeyActionKind
{
    /// <summary>A printable character (or space) appended to the typing buffer.</summary>
    Text,

    /// <summary>A backspace that removes the last buffered character.</summary>
    Backspace,

    /// <summary>Alt+Backspace: removes the preceding word from the buffer.</summary>
    WordBackspace,

    /// <summary>A named navigation or control key, e.g. <c>Enter</c> or <c>Escape</c>.</summary>
    Special,

    /// <summary>A modifier chord, e.g. <c>Ctrl+S</c>.</summary>
    Shortcut,

    /// <summary>A key this build does not model (a lone modifier, an unprintable dead key).</summary>
    Ignored,
}

/// <summary>
/// The classified meaning of one key press. A value type would be enough, but a record gives the
/// tests exact value equality including the carried string.
/// </summary>
/// <param name="Kind">Which action the key press represents.</param>
/// <param name="Value">
/// The typed characters (<see cref="KeyActionKind.Text"/>), the key name
/// (<see cref="KeyActionKind.Special"/>), or the chord (<see cref="KeyActionKind.Shortcut"/>);
/// otherwise <see langword="null"/>.
/// </param>
public sealed record KeyAction(KeyActionKind Kind, string? Value = null)
{
    /// <summary>The shared, valueless backspace action.</summary>
    public static readonly KeyAction Backspace = new(KeyActionKind.Backspace);

    /// <summary>The shared, valueless word-backspace action.</summary>
    public static readonly KeyAction WordBackspace = new(KeyActionKind.WordBackspace);

    /// <summary>The shared, valueless ignored action.</summary>
    public static readonly KeyAction Ignored = new(KeyActionKind.Ignored);

    /// <summary>Builds a <see cref="KeyActionKind.Text"/> action.</summary>
    public static KeyAction Text(string characters) => new(KeyActionKind.Text, characters);

    /// <summary>Builds a <see cref="KeyActionKind.Special"/> action.</summary>
    public static KeyAction Special(string name) => new(KeyActionKind.Special, name);

    /// <summary>Builds a <see cref="KeyActionKind.Shortcut"/> action.</summary>
    public static KeyAction Shortcut(string combo) => new(KeyActionKind.Shortcut, combo);
}

/// <summary>
/// Windows virtual-key constants and the VK-to-name table shared by classification.
/// </summary>
public static class VirtualKeys
{
    /// <summary><c>VK_BACK</c>.</summary>
    public const ushort Back = 0x08;

    /// <summary><c>VK_TAB</c>.</summary>
    public const ushort Tab = 0x09;

    /// <summary><c>VK_RETURN</c>.</summary>
    public const ushort Return = 0x0D;

    /// <summary><c>VK_ESCAPE</c>.</summary>
    public const ushort Escape = 0x1B;

    /// <summary><c>VK_SPACE</c>.</summary>
    public const ushort Space = 0x20;

    private const ushort PriorKey = 0x21;
    private const ushort NextKey = 0x22;
    private const ushort EndKey = 0x23;
    private const ushort HomeKey = 0x24;
    private const ushort LeftKey = 0x25;
    private const ushort UpKey = 0x26;
    private const ushort RightKey = 0x27;
    private const ushort DownKey = 0x28;
    private const ushort DeleteKey = 0x2E;

    /// <summary>
    /// Named navigation and control keys that classify as <see cref="KeyActionKind.Special"/> rather
    /// than typed text. Space and Backspace are deliberately absent: Space is printable and Backspace
    /// edits the buffer.
    /// </summary>
    private static readonly IReadOnlyDictionary<ushort, string> SpecialNames = new Dictionary<ushort, string>
    {
        [Return] = "Enter",
        [Tab] = "Tab",
        [Escape] = "Escape",
        [Back] = "Backspace",
        [DeleteKey] = "ForwardDelete",
        [LeftKey] = "ArrowLeft",
        [RightKey] = "ArrowRight",
        [UpKey] = "ArrowUp",
        [DownKey] = "ArrowDown",
        [HomeKey] = "Home",
        [EndKey] = "End",
        [PriorKey] = "PageUp",
        [NextKey] = "PageDown",
    };

    /// <summary>The keys that <see cref="KeyClassifier"/> reports as named special keys.</summary>
    /// <remarks>Backspace resolves to a name for chords but is not a standalone special key.</remarks>
    private static readonly HashSet<ushort> StandaloneSpecials = new()
    {
        Return, Tab, Escape, DeleteKey, LeftKey, RightKey, UpKey, DownKey,
        HomeKey, EndKey, PriorKey, NextKey,
    };

    /// <summary>The special-key name for a standalone press, or <see langword="null"/>.</summary>
    public static string? StandaloneSpecialName(ushort virtualKey) =>
        StandaloneSpecials.Contains(virtualKey) && SpecialNames.TryGetValue(virtualKey, out string? name)
            ? name
            : null;

    /// <summary>
    /// The stable key name used inside a chord: a special-key name, an <c>A</c>–<c>Z</c> letter, a
    /// <c>0</c>–<c>9</c> digit, else <see langword="null"/> so the caller can fall back to the char.
    /// </summary>
    public static string? ChordKeyName(ushort virtualKey)
    {
        if (SpecialNames.TryGetValue(virtualKey, out string? special))
        {
            return special;
        }

        // VK codes for A-Z and 0-9 are the ASCII code points of the uppercase letter / digit.
        if (virtualKey is >= 0x41 and <= 0x5A)
        {
            return ((char)virtualKey).ToString();
        }

        if (virtualKey is >= 0x30 and <= 0x39)
        {
            return ((char)virtualKey).ToString();
        }

        return null;
    }
}

/// <summary>
/// Pure classification of a Windows key press into a <see cref="KeyAction"/> (ANNEX-HOST section 2).
/// </summary>
/// <remarks>
/// The host resolves the modifier flags and the produced characters (via <c>ToUnicodeEx</c>) on its
/// hook thread and calls this. Keeping the fiddly order here — backspace before chords, chords before
/// named keys, named keys before printable text — means it is unit-tested off Windows, where the rest
/// of the host cannot run. Ctrl+C / Ctrl+X / Ctrl+V are intercepted by the host <em>before</em> this
/// classifier, so they never reach it as shortcuts.
/// </remarks>
public static class KeyClassifier
{
    /// <summary>
    /// Classifies one key press.
    /// </summary>
    /// <param name="virtualKey">The Windows virtual-key code.</param>
    /// <param name="characters">
    /// The characters <c>ToUnicodeEx</c> produced, or <see langword="null"/> when the key produced
    /// none (a pure navigation or modifier key).
    /// </param>
    /// <param name="ctrl">Whether Control is held.</param>
    /// <param name="alt">Whether Alt (Menu) is held.</param>
    /// <param name="shift">Whether Shift is held.</param>
    /// <param name="win">Whether a Windows key is held (the Windows counterpart of macOS Command).</param>
    public static KeyAction Classify(
        ushort virtualKey,
        string? characters,
        bool ctrl,
        bool alt,
        bool shift,
        bool win)
    {
        // 1. Backspace is a buffer edit, checked before chord detection so Alt+Backspace deletes a
        //    word rather than emitting a shortcut. Ctrl/Win reclaim it as a chord.
        if (virtualKey == VirtualKeys.Back && !ctrl && !win)
        {
            return alt ? KeyAction.WordBackspace : KeyAction.Backspace;
        }

        // 2. A Ctrl or Win chord is a shortcut. Alt alone is not a trigger: it participates in AltGr
        //    typing on non-US layouts, so a bare Alt+key stays available to the printable branch.
        if (ctrl || win)
        {
            return KeyAction.Shortcut(Combo(virtualKey, characters, ctrl, alt, shift, win));
        }

        // 3. A named navigation / control key.
        if (VirtualKeys.StandaloneSpecialName(virtualKey) is { } special)
        {
            return KeyAction.Special(special);
        }

        // 4. Printable text: every scalar at or above space and not DEL.
        if (characters is { Length: > 0 } && IsPrintable(characters))
        {
            return KeyAction.Text(characters);
        }

        // 5. Anything else is not modelled.
        return KeyAction.Ignored;
    }

    /// <summary>
    /// Renders a chord in the fixed order <c>Win+Ctrl+Alt+Shift+&lt;Key&gt;</c>. The key name is the
    /// VK-mapped name when known, else the uppercased produced character, else <c>?</c>.
    /// </summary>
    private static string Combo(
        ushort virtualKey,
        string? characters,
        bool ctrl,
        bool alt,
        bool shift,
        bool win)
    {
        var parts = new List<string>(5);
        if (win)
        {
            parts.Add("Win");
        }

        if (ctrl)
        {
            parts.Add("Ctrl");
        }

        if (alt)
        {
            parts.Add("Alt");
        }

        if (shift)
        {
            parts.Add("Shift");
        }

        string key = VirtualKeys.ChordKeyName(virtualKey)
            ?? characters?.ToUpperInvariant().Trim() switch
            {
                { Length: > 0 } text => text,
                _ => "?",
            };

        parts.Add(key);
        return string.Join("+", parts);
    }

    /// <summary>Every scalar is at or above U+0020 and is not U+007F (DEL).</summary>
    private static bool IsPrintable(string value)
    {
        foreach (System.Text.Rune rune in value.EnumerateRunes())
        {
            if (rune.Value < 0x20 || rune.Value == 0x7F)
            {
                return false;
            }
        }

        return true;
    }
}
