namespace JazzCaptureCore.Input;

/// <summary>
/// The 256-byte Windows key-state table a low-level keyboard hook has to maintain for itself, in the
/// exact layout <c>ToUnicodeEx</c> and <c>GetKeyboardState</c> use: bit <c>0x80</c> means the key is
/// physically down, bit <c>0x01</c> means a toggle key is currently lit.
/// </summary>
/// <remarks>
/// <para>
/// The table exists because <c>WH_KEYBOARD_LL</c> reports modifiers by <em>side</em> — a left shift
/// arrives as <c>VK_LSHIFT</c> (0xA0), never as <c>VK_SHIFT</c> (0x10) — while both
/// <c>ToUnicodeEx</c> and every "is Control held" question are asked against the generic index. A
/// table that only records the index it was handed therefore reports no modifiers at all: every
/// chord degrades to a bare key and every character translates unshifted. So each side-specific
/// modifier also maintains its generic index, which stays down while <em>either</em> side is down.
/// </para>
/// <para>
/// Toggle keys are a second trap. Caps, Num and Scroll Lock are not "on while held": their lit bit
/// flips once per physical press and survives the release. Bit <c>0x80</c> tracks the press, bit
/// <c>0x01</c> the toggle, and they are maintained independently. A session that starts with Caps
/// Lock already on only reads correctly if the host seeds <see cref="SeedToggle"/> from the OS at
/// hook install, because the hook stream by itself cannot know.
/// </para>
/// <para>
/// This type is deliberately in the portable core, with no P/Invoke: the logic above is where the
/// bugs live, and it is only testable off Windows if it is separated from the hook that feeds it.
/// It is not thread-safe; the owning hook procedure is the single writer.
/// </para>
/// </remarks>
public sealed class KeyStateTable
{
    /// <summary>Length of a Windows key-state array; one byte per virtual-key code.</summary>
    public const int Length = 256;

    /// <summary>Bit set while the key is physically held down.</summary>
    public const byte DownBit = 0x80;

    /// <summary>Bit set while a toggle key (Caps / Num / Scroll Lock) is lit.</summary>
    public const byte ToggleBit = 0x01;

    /// <summary><c>VK_SHIFT</c>: the generic index, never delivered by the low-level hook.</summary>
    public const int Shift = 0x10;

    /// <summary><c>VK_CONTROL</c>: the generic index, never delivered by the low-level hook.</summary>
    public const int Control = 0x11;

    /// <summary><c>VK_MENU</c> (Alt): the generic index, never delivered by the low-level hook.</summary>
    public const int Menu = 0x12;

    /// <summary><c>VK_CAPITAL</c>: Caps Lock.</summary>
    public const int CapsLock = 0x14;

    /// <summary><c>VK_LWIN</c>. Windows has no generic index for the Windows key.</summary>
    public const int LeftWindows = 0x5B;

    /// <summary><c>VK_RWIN</c>.</summary>
    public const int RightWindows = 0x5C;

    /// <summary><c>VK_NUMLOCK</c>.</summary>
    public const int NumLock = 0x90;

    /// <summary><c>VK_SCROLL</c>: Scroll Lock.</summary>
    public const int ScrollLock = 0x91;

    /// <summary><c>VK_LSHIFT</c>.</summary>
    public const int LeftShift = 0xA0;

    /// <summary><c>VK_RSHIFT</c>.</summary>
    public const int RightShift = 0xA1;

    /// <summary><c>VK_LCONTROL</c>.</summary>
    public const int LeftControl = 0xA2;

    /// <summary><c>VK_RCONTROL</c>.</summary>
    public const int RightControl = 0xA3;

    /// <summary><c>VK_LMENU</c>: left Alt.</summary>
    public const int LeftMenu = 0xA4;

    /// <summary><c>VK_RMENU</c>: right Alt / AltGr.</summary>
    public const int RightMenu = 0xA5;

    private readonly byte[] _state = new byte[Length];

    /// <summary>Whether the virtual key is a toggle key whose lit bit outlives the press.</summary>
    public static bool IsToggleKey(int virtualKey) =>
        virtualKey is CapsLock or NumLock or ScrollLock;

    /// <summary>
    /// Records one key transition from the hook stream. A side-specific modifier also refreshes its
    /// generic index; a toggle key flips its lit bit on the press edge only, so auto-repeat while the
    /// key is held does not flicker it.
    /// </summary>
    /// <param name="virtualKey">The virtual-key code the hook reported. Out-of-range codes are ignored.</param>
    /// <param name="isDown">Whether this transition is a key-down.</param>
    public void Update(int virtualKey, bool isDown)
    {
        if (virtualKey is < 0 or >= Length)
        {
            return;
        }

        bool wasDown = (_state[virtualKey] & DownBit) != 0;

        if (isDown)
        {
            if (!wasDown && IsToggleKey(virtualKey))
            {
                _state[virtualKey] ^= ToggleBit;
            }

            _state[virtualKey] |= DownBit;
        }
        else
        {
            // Only the physical bit is cleared: a toggle key that is released stays lit.
            _state[virtualKey] &= unchecked((byte)~DownBit);
        }

        RefreshGeneric(virtualKey);
    }

    /// <summary>
    /// Seeds a toggle key's lit bit from the OS, for the state the session inherited. Has no effect
    /// on a key that is not a toggle key.
    /// </summary>
    public void SeedToggle(int virtualKey, bool isOn)
    {
        if (!IsToggleKey(virtualKey))
        {
            return;
        }

        if (isOn)
        {
            _state[virtualKey] |= ToggleBit;
        }
        else
        {
            _state[virtualKey] &= unchecked((byte)~ToggleBit);
        }
    }

    /// <summary>Whether the key is currently held down. Generic modifier indices are answered too.</summary>
    public bool IsDown(int virtualKey) =>
        virtualKey is >= 0 and < Length && (_state[virtualKey] & DownBit) != 0;

    /// <summary>Whether a toggle key is currently lit.</summary>
    public bool IsToggled(int virtualKey) =>
        virtualKey is >= 0 and < Length && (_state[virtualKey] & ToggleBit) != 0;

    /// <summary>Whether either Windows key is held; Windows has no generic index for it.</summary>
    public bool IsWindowsDown() => IsDown(LeftWindows) || IsDown(RightWindows);

    /// <summary>
    /// Copies the table into the caller's buffer, which must be at least <see cref="Length"/> bytes.
    /// The hook keeps one buffer alive and reuses it, so translating a keystroke allocates nothing.
    /// </summary>
    public void CopyTo(byte[] destination)
    {
        ArgumentNullException.ThrowIfNull(destination);
        if (destination.Length < Length)
        {
            throw new ArgumentException(
                "Key state buffer must hold at least " + Length + " bytes.",
                nameof(destination));
        }

        Array.Copy(_state, destination, Length);
    }

    /// <summary>Returns a fresh copy of the table, in <c>GetKeyboardState</c> layout.</summary>
    public byte[] Snapshot()
    {
        var copy = new byte[Length];
        Array.Copy(_state, copy, Length);
        return copy;
    }

    /// <summary>
    /// Recomputes the generic modifier index a side-specific key contributes to. The generic key is
    /// down while either side is down, so releasing one of two held shifts must not clear it.
    /// </summary>
    private void RefreshGeneric(int virtualKey)
    {
        switch (virtualKey)
        {
            case LeftShift:
            case RightShift:
                SetGeneric(Shift, LeftShift, RightShift);
                break;
            case LeftControl:
            case RightControl:
                SetGeneric(Control, LeftControl, RightControl);
                break;
            case LeftMenu:
            case RightMenu:
                SetGeneric(Menu, LeftMenu, RightMenu);
                break;
            default:
                break;
        }
    }

    private void SetGeneric(int generic, int left, int right)
    {
        bool down = (_state[left] & DownBit) != 0 || (_state[right] & DownBit) != 0;
        if (down)
        {
            _state[generic] |= DownBit;
        }
        else
        {
            _state[generic] &= unchecked((byte)~DownBit);
        }
    }
}
