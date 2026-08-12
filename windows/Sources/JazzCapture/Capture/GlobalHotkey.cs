using System.Globalization;
using System.Runtime.InteropServices;
using System.Threading;
using JazzCapture.Interop;

namespace JazzCapture.Capture;

/// <summary>
/// The system-wide Alt+Ctrl+L that opens or closes a bracketed label, matching the macOS client's
/// ⌥⌘L on "Label current task…" (ANNEX-HOST section 6).
/// </summary>
/// <remarks>
/// <para>
/// A label has to be declarable from inside whatever the user is actually doing. Reaching for the
/// notification area means leaving that application, which is both a context switch and an extra
/// <c>navigate</c> event in the middle of the work being recorded — so the shortcut is the primary
/// route and the menu item is the discoverable one.
/// </para>
/// <para>
/// <c>RegisterHotKey</c> delivers <c>WM_HOTKEY</c> to a window's queue, so this owns a message-only
/// window (<c>HWND_MESSAGE</c>) on a thread of its own with its own <c>GetMessage</c> pump. A
/// message-only window has no screen presence, no z-order and never paints, which is exactly what a
/// keyboard target should be; it also keeps the hotkey off the WPF dispatcher, so a modal dialog
/// running its own nested loop cannot stall it.
/// </para>
/// <para>
/// <b>Registration failure is reported, never swallowed.</b> Another application may already own
/// this combination, and a shortcut that silently does nothing is worse than one that was never
/// advertised — the user presses it, sees no label, and concludes the feature is broken.
/// <see cref="Failure"/> carries a sentence for the tray menu to show.
/// </para>
/// </remarks>
public sealed class GlobalHotkey : IDisposable
{
    /// <summary>How the shortcut is written in the UI.</summary>
    public const string DisplayName = "Alt+Ctrl+L";

    /// <summary>
    /// Identifier of this hotkey within our own window. Any value in 0..0xBFFF works; the
    /// registration is per window, so it cannot collide with another application's.
    /// </summary>
    private const int HotkeyId = 1;

    private readonly Action _onPressed;
    private readonly string _className;
    private readonly ManualResetEventSlim _ready = new(false);

    // The window procedure is passed to unmanaged code and called for the window's whole lifetime,
    // so the delegate has to be rooted here. A collected one would take the process down.
    private readonly NativeMethods.WndProc _windowProc;

    private Thread? _thread;
    private IntPtr _window;
    private volatile bool _running;

    /// <summary>Creates the hotkey. Nothing is registered until <see cref="Start"/>.</summary>
    /// <param name="onPressed">
    /// Invoked on the hotkey's own pump thread each time the combination is pressed. An
    /// implementation that touches UI must marshal.
    /// </param>
    public GlobalHotkey(Action onPressed)
    {
        _onPressed = onPressed ?? throw new ArgumentNullException(nameof(onPressed));

        // Unique per process: a second instance of the client must not fail to register its class
        // because the first one is still holding the name.
        _className = "JazzCaptureHotkey_" + Environment.ProcessId.ToString(CultureInfo.InvariantCulture);
        _windowProc = OnWindowMessage;
    }

    /// <summary>Whether the combination is currently ours.</summary>
    public bool IsRegistered { get; private set; }

    /// <summary>Why registration failed, or <see langword="null"/> when it did not.</summary>
    public string? Failure { get; private set; }

    /// <summary>
    /// Creates the window, registers the hotkey, and returns once the outcome is known.
    /// </summary>
    /// <returns>Whether the combination was registered.</returns>
    public bool Start()
    {
        if (_thread is not null)
        {
            return IsRegistered;
        }

        _running = true;
        _thread = new Thread(Run)
        {
            IsBackground = true,
            Name = "JazzHotkeyPump",
        };
        _thread.Start();

        // Waiting makes the outcome available to the caller synchronously, so the tray menu is
        // right the first time it is drawn rather than correcting itself a moment later.
        _ready.Wait();
        return IsRegistered;
    }

    /// <summary>Unregisters the hotkey and tears the window and its pump down.</summary>
    public void Stop()
    {
        if (!_running)
        {
            return;
        }

        _running = false;
        if (_window != IntPtr.Zero)
        {
            NativeMethods.PostMessageW(_window, NativeMethods.WM_APP_STOP, IntPtr.Zero, IntPtr.Zero);
        }

        _thread?.Join(TimeSpan.FromSeconds(2));
        _thread = null;
        IsRegistered = false;
    }

    /// <inheritdoc />
    public void Dispose()
    {
        Stop();
        _ready.Dispose();
    }

    private void Run()
    {
        try
        {
            Register();
        }
        catch (Exception ex)
        {
            Failure = ex.Message;
        }
        finally
        {
            _ready.Set();
        }

        if (_window == IntPtr.Zero)
        {
            return;
        }

        try
        {
            Pump();
        }
        finally
        {
            Unregister();
        }
    }

    private void Register()
    {
        IntPtr instance = NativeMethods.GetModuleHandleW(null);
        var windowClass = new NativeMethods.WNDCLASSW
        {
            WndProc = Marshal.GetFunctionPointerForDelegate(_windowProc),
            Instance = instance,
            ClassName = _className,
        };

        if (NativeMethods.RegisterClassW(ref windowClass) == 0)
        {
            Failure = Describe("could not create the shortcut listener", Marshal.GetLastWin32Error());
            return;
        }

        _window = NativeMethods.CreateWindowExW(
            0,
            _className,
            null,
            0,
            0,
            0,
            0,
            0,
            NativeMethods.HWND_MESSAGE,
            IntPtr.Zero,
            instance,
            IntPtr.Zero);

        if (_window == IntPtr.Zero)
        {
            Failure = Describe("could not create the shortcut listener", Marshal.GetLastWin32Error());
            NativeMethods.UnregisterClassW(_className, instance);
            return;
        }

        if (!NativeMethods.RegisterHotKey(
                _window,
                HotkeyId,
                NativeMethods.MOD_ALT | NativeMethods.MOD_CONTROL | NativeMethods.MOD_NOREPEAT,
                NativeMethods.VK_L))
        {
            Failure = Describe("is not available", Marshal.GetLastWin32Error());
            return;
        }

        IsRegistered = true;
        Failure = null;
    }

    /// <summary>
    /// A message the user can act on. The already-registered case is named explicitly because it is
    /// the common one and the only one with an obvious remedy.
    /// </summary>
    private static string Describe(string what, int error) =>
        error == NativeMethods.ERROR_HOTKEY_ALREADY_REGISTERED
            ? DisplayName + " is already taken by another application"
            : DisplayName + " " + what + " (error "
                + error.ToString(CultureInfo.InvariantCulture) + ")";

    private void Pump()
    {
        while (_running)
        {
            int result = NativeMethods.GetMessageW(out NativeMethods.MSG message, IntPtr.Zero, 0, 0);
            if (result <= 0)
            {
                // 0 is WM_QUIT, -1 is an error on a queue we can no longer trust. Either way this
                // pump is finished.
                break;
            }

            if (message.Message == NativeMethods.WM_APP_STOP)
            {
                break;
            }

            if (message.Message == NativeMethods.WM_HOTKEY && message.WParam.ToInt64() == HotkeyId)
            {
                Deliver();
                continue;
            }

            NativeMethods.TranslateMessage(ref message);
            NativeMethods.DispatchMessageW(ref message);
        }
    }

    /// <summary>
    /// Hands the press to the host. A handler that throws must not take the pump with it, or the
    /// shortcut would work exactly once.
    /// </summary>
    private void Deliver()
    {
        try
        {
            _onPressed();
        }
        catch (Exception ex)
        {
            Failure = DisplayName + " failed: " + ex.Message;
        }
    }

    private void Unregister()
    {
        if (_window != IntPtr.Zero)
        {
            if (IsRegistered)
            {
                NativeMethods.UnregisterHotKey(_window, HotkeyId);
            }

            NativeMethods.DestroyWindow(_window);
            _window = IntPtr.Zero;
        }

        NativeMethods.UnregisterClassW(_className, NativeMethods.GetModuleHandleW(null));
        IsRegistered = false;
    }

    /// <summary>
    /// The window procedure. A message-only window handles nothing itself — <c>WM_HOTKEY</c> is
    /// delivered to the thread queue and read by <see cref="Pump"/>, never dispatched here — so
    /// everything goes to the default handler.
    /// </summary>
    private IntPtr OnWindowMessage(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam) =>
        NativeMethods.DefWindowProcW(hwnd, msg, wParam, lParam);
}
