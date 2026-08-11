namespace JazzCapture.Capture;

/// <summary>
/// One raw mouse observation, as the low-level hook read it. The hook thread does nothing with these
/// beyond stamping the arrival sequence and handing them off; all interpretation happens on the
/// pipeline worker.
/// </summary>
/// <param name="Message">The <c>WM_*</c> mouse message.</param>
/// <param name="X">Screen x of the pointer.</param>
/// <param name="Y">Screen y of the pointer.</param>
/// <param name="WheelDelta">Signed wheel notches for <c>WM_MOUSEWHEEL</c>; otherwise zero.</param>
/// <param name="TimeMs">The message time in milliseconds (<c>GetTickCount</c> domain).</param>
/// <param name="Sequence">Monotonic arrival order, assigned in the callback before any async work.</param>
public readonly record struct MouseSample(
    uint Message,
    int X,
    int Y,
    short WheelDelta,
    uint TimeMs,
    long Sequence);

/// <summary>
/// One raw keyboard observation. The produced <see cref="Characters"/> and the modifier flags are
/// resolved in the callback from a hook-maintained key-state array, because the character a key emits
/// depends on the exact modifier state at that instant.
/// </summary>
/// <param name="Message">The <c>WM_*</c> keyboard message.</param>
/// <param name="VirtualKey">The virtual-key code.</param>
/// <param name="ScanCode">The hardware scan code.</param>
/// <param name="Characters">The characters <c>ToUnicodeEx</c> produced, or <see langword="null"/>.</param>
/// <param name="Ctrl">Whether Control was held.</param>
/// <param name="Alt">Whether Alt was held.</param>
/// <param name="Shift">Whether Shift was held.</param>
/// <param name="Win">Whether a Windows key was held.</param>
/// <param name="TimeMs">The message time in milliseconds.</param>
/// <param name="Sequence">Monotonic arrival order.</param>
public readonly record struct KeySample(
    uint Message,
    ushort VirtualKey,
    uint ScanCode,
    string? Characters,
    bool Ctrl,
    bool Alt,
    bool Shift,
    bool Win,
    uint TimeMs,
    long Sequence);

/// <summary>A foreground application switch, resolved from the WinEvent hook.</summary>
/// <param name="WindowHandle">The activated top-level window.</param>
/// <param name="TimeMs">The event time in milliseconds.</param>
public readonly record struct ForegroundSample(IntPtr WindowHandle, uint TimeMs);
