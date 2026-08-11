using JasnostCapture.Interop;

namespace JasnostCapture.Capture;

/// <summary>
/// Watches for foreground application switches with a WinEvent hook and reports each one, which the
/// pipeline turns into a <c>navigate</c> event (ANNEX-HOST sections 1 and 7).
/// </summary>
/// <remarks>
/// The hook is installed <c>WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS</c>: out-of-context so no
/// DLL is injected into other processes, and skip-own-process so our own windows never raise a switch
/// — the first of the three own-window exclusion layers for navigation. It must be installed on a
/// thread with a running message pump; the tray host installs it on the WPF UI thread, whose
/// dispatcher provides one.
/// </remarks>
public sealed class ForegroundTracker : IDisposable
{
    private readonly Action<IntPtr> _onForeground;

    // Held for the hook's lifetime so the native callback target is never collected.
    private readonly NativeMethods.WinEventProc _proc;

    private IntPtr _hook;

    /// <summary>Creates the tracker around a sink that receives each newly activated window.</summary>
    /// <param name="onForeground">Receives the activated top-level window handle.</param>
    public ForegroundTracker(Action<IntPtr> onForeground)
    {
        _onForeground = onForeground ?? throw new ArgumentNullException(nameof(onForeground));
        _proc = OnWinEvent;
    }

    /// <summary>Whether the WinEvent hook is currently installed.</summary>
    public bool IsInstalled => _hook != IntPtr.Zero;

    /// <summary>Installs the hook. Call on a thread that pumps messages (the WPF UI thread).</summary>
    public void Start()
    {
        if (_hook != IntPtr.Zero)
        {
            return;
        }

        _hook = NativeMethods.SetWinEventHook(
            NativeMethods.EVENT_SYSTEM_FOREGROUND,
            NativeMethods.EVENT_SYSTEM_FOREGROUND,
            IntPtr.Zero,
            _proc,
            0,
            0,
            NativeMethods.WINEVENT_OUTOFCONTEXT | NativeMethods.WINEVENT_SKIPOWNPROCESS);
    }

    /// <summary>Removes the hook. Safe to call more than once.</summary>
    public void Stop()
    {
        if (_hook != IntPtr.Zero)
        {
            NativeMethods.UnhookWinEvent(_hook);
            _hook = IntPtr.Zero;
        }
    }

    /// <inheritdoc />
    public void Dispose() => Stop();

    private void OnWinEvent(
        IntPtr hWinEventHook,
        uint eventType,
        IntPtr hwnd,
        int idObject,
        int idChild,
        uint dwEventThread,
        uint dwmsEventTime)
    {
        if (eventType == NativeMethods.EVENT_SYSTEM_FOREGROUND && hwnd != IntPtr.Zero)
        {
            try
            {
                _onForeground(hwnd);
            }
            catch
            {
                // A WinEvent callback must not throw into the OS.
            }
        }
    }
}
