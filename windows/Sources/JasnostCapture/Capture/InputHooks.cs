using System.Text;
using System.Threading;
using JasnostCapture.Interop;

namespace JasnostCapture.Capture;

/// <summary>
/// Installs the two low-level input hooks (<c>WH_MOUSE_LL</c>, <c>WH_KEYBOARD_LL</c>) on a dedicated
/// thread that owns their message pump, exactly as ANNEX-HOST section 7 requires.
/// </summary>
/// <remarks>
/// <para>
/// The hook procedures do the minimum the OS budget allows: read the struct, stamp a monotonic
/// arrival sequence with <see cref="Interlocked"/>, hand the sample to the pipeline, and call
/// <c>CallNextHookEx</c>. A low-level hook whose callback runs longer than the system timeout is
/// silently detached, so nothing here waits, allocates on a hot path it can avoid, or touches UI
/// Automation — that work belongs to the pipeline worker.
/// </para>
/// <para>
/// The one deliberate exception is <c>ToUnicodeEx</c> in the keyboard callback. The character a key
/// produces depends on the modifier and dead-key state at the instant it was pressed, so it is
/// resolved synchronously against a key-state array this class maintains from the hook stream itself
/// (rather than <c>GetKeyboardState</c>, which does not reflect physical keys on a non-foreground
/// thread). The call is bounded and sub-millisecond, and uses the no-dead-key-state flag so passive
/// observation never disturbs the user's next accented keystroke.
/// </para>
/// <para>
/// Re-arming after an OS detach must happen on the hook thread, because that is the thread that owns
/// the hooks; the watchdog requests it by posting a message to the pump.
/// </para>
/// </remarks>
public sealed class InputHooks : IDisposable
{
    private const uint WM_APP_STOP = NativeMethods.WM_APP_STOP;
    private const uint WM_APP_REHOOK = NativeMethods.WM_APP_STOP + 1;

    private readonly Action<MouseSample> _onMouse;
    private readonly Action<KeySample> _onKey;

    // The delegates must outlive the hooks: if either is collected the native callback crashes.
    private readonly NativeMethods.LowLevelHookProc _mouseProc;
    private readonly NativeMethods.LowLevelHookProc _keyProc;

    // The key-state array the callback feeds to ToUnicodeEx, maintained from the hook stream.
    private readonly byte[] _keyState = new byte[256];

    private Thread? _thread;
    private uint _threadId;
    private IntPtr _mouseHook;
    private IntPtr _keyHook;
    private long _sequence;
    private long _lastCallbackTicks;
    private long _reArmCount;
    private volatile bool _running;

    /// <summary>Creates the hooks around two non-blocking sinks that only enqueue.</summary>
    /// <param name="onMouse">Receives each mouse sample; must not block.</param>
    /// <param name="onKey">Receives each keyboard sample; must not block.</param>
    public InputHooks(Action<MouseSample> onMouse, Action<KeySample> onKey)
    {
        _onMouse = onMouse ?? throw new ArgumentNullException(nameof(onMouse));
        _onKey = onKey ?? throw new ArgumentNullException(nameof(onKey));
        _mouseProc = MouseCallback;
        _keyProc = KeyCallback;
    }

    /// <summary>How many times the watchdog has re-armed a detached hook this session.</summary>
    public long ReArmCount => Interlocked.Read(ref _reArmCount);

    /// <summary><c>Environment.TickCount64</c> of the most recent callback, for the watchdog.</summary>
    public long LastCallbackTicks => Interlocked.Read(ref _lastCallbackTicks);

    /// <summary>Whether both hooks are believed installed.</summary>
    public bool IsInstalled => _mouseHook != IntPtr.Zero && _keyHook != IntPtr.Zero;

    /// <summary>Starts the hook thread and installs both hooks. Returns once the thread is pumping.</summary>
    public void Start()
    {
        if (_thread is not null)
        {
            return;
        }

        _running = true;
        var ready = new ManualResetEventSlim(false);
        _thread = new Thread(() => Pump(ready))
        {
            IsBackground = true,
            Name = "JasnostInputHooks",
        };
        _thread.Start();
        ready.Wait();
    }

    /// <summary>Asks the hook thread to detach and re-install both hooks.</summary>
    public void RequestReArm()
    {
        if (_threadId != 0)
        {
            NativeMethods.PostThreadMessageW(_threadId, WM_APP_REHOOK, IntPtr.Zero, IntPtr.Zero);
        }
    }

    /// <summary>Stops the pump and unhooks. Safe to call more than once.</summary>
    public void Stop()
    {
        if (!_running)
        {
            return;
        }

        _running = false;
        if (_threadId != 0)
        {
            NativeMethods.PostThreadMessageW(_threadId, WM_APP_STOP, IntPtr.Zero, IntPtr.Zero);
        }

        _thread?.Join(TimeSpan.FromSeconds(2));
        _thread = null;
    }

    /// <inheritdoc />
    public void Dispose() => Stop();

    private void Pump(ManualResetEventSlim ready)
    {
        _threadId = NativeMethods.GetCurrentThreadId();
        Install();
        ready.Set();

        while (_running && NativeMethods.GetMessageW(out NativeMethods.MSG msg, IntPtr.Zero, 0, 0) > 0)
        {
            if (msg.Message == WM_APP_STOP)
            {
                break;
            }

            if (msg.Message == WM_APP_REHOOK)
            {
                ReArm();
                continue;
            }

            NativeMethods.TranslateMessage(ref msg);
            NativeMethods.DispatchMessageW(ref msg);
        }

        Uninstall();
    }

    private void Install()
    {
        IntPtr module = NativeMethods.GetModuleHandleW(null);
        _mouseHook = NativeMethods.SetWindowsHookExW(NativeMethods.WH_MOUSE_LL, _mouseProc, module, 0);
        _keyHook = NativeMethods.SetWindowsHookExW(NativeMethods.WH_KEYBOARD_LL, _keyProc, module, 0);
        Interlocked.Exchange(ref _lastCallbackTicks, Environment.TickCount64);
    }

    private void Uninstall()
    {
        if (_mouseHook != IntPtr.Zero)
        {
            NativeMethods.UnhookWindowsHookEx(_mouseHook);
            _mouseHook = IntPtr.Zero;
        }

        if (_keyHook != IntPtr.Zero)
        {
            NativeMethods.UnhookWindowsHookEx(_keyHook);
            _keyHook = IntPtr.Zero;
        }
    }

    private void ReArm()
    {
        Uninstall();
        Install();
        Interlocked.Increment(ref _reArmCount);
    }

    private IntPtr MouseCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode == NativeMethods.HC_ACTION)
        {
            try
            {
                var data = System.Runtime.InteropServices.Marshal
                    .PtrToStructure<NativeMethods.MSLLHOOKSTRUCT>(lParam);
                uint message = (uint)wParam;
                short wheel = (short)((data.MouseData >> 16) & 0xFFFF);
                long sequence = Interlocked.Increment(ref _sequence);
                Interlocked.Exchange(ref _lastCallbackTicks, Environment.TickCount64);
                _onMouse(new MouseSample(message, data.Point.X, data.Point.Y, wheel, data.Time, sequence));
            }
            catch
            {
                // A hook procedure must never throw into the OS; a dropped sample is the safe failure.
            }
        }

        return NativeMethods.CallNextHookEx(IntPtr.Zero, nCode, wParam, lParam);
    }

    private IntPtr KeyCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode == NativeMethods.HC_ACTION)
        {
            try
            {
                var data = System.Runtime.InteropServices.Marshal
                    .PtrToStructure<NativeMethods.KBDLLHOOKSTRUCT>(lParam);
                uint message = (uint)wParam;
                long sequence = Interlocked.Increment(ref _sequence);
                Interlocked.Exchange(ref _lastCallbackTicks, Environment.TickCount64);

                bool isDown = message is NativeMethods.WM_KEYDOWN or NativeMethods.WM_SYSKEYDOWN;
                UpdateKeyState(data.VkCode, isDown);

                if (isDown)
                {
                    bool ctrl = IsDown(NativeMethods.VK_CONTROL);
                    bool alt = IsDown(NativeMethods.VK_MENU);
                    bool shift = IsDown(NativeMethods.VK_SHIFT);
                    bool win = IsDown(NativeMethods.VK_LWIN) || IsDown(NativeMethods.VK_RWIN);
                    string? characters = TranslateCharacters(data.VkCode, data.ScanCode);

                    _onKey(new KeySample(
                        message,
                        (ushort)data.VkCode,
                        data.ScanCode,
                        characters,
                        ctrl,
                        alt,
                        shift,
                        win,
                        data.Time,
                        sequence));
                }
            }
            catch
            {
                // Drop the sample rather than propagate into the OS callback.
            }
        }

        return NativeMethods.CallNextHookEx(IntPtr.Zero, nCode, wParam, lParam);
    }

    private void UpdateKeyState(uint vk, bool isDown)
    {
        if (vk > 255)
        {
            return;
        }

        // Mirror the physical toggle keys so ToUnicodeEx sees the same casing the user does.
        _keyState[vk] = isDown ? (byte)0x80 : (byte)0x00;
        if (isDown && vk is 0x14 or 0x90 or 0x91) // Caps/Num/Scroll lock
        {
            _keyState[vk] |= 0x01;
        }
    }

    private bool IsDown(int vk) => vk is >= 0 and <= 255 && (_keyState[vk] & 0x80) != 0;

    private string? TranslateCharacters(uint vk, uint scan)
    {
        IntPtr layout = NativeMethods.GetKeyboardLayout(0);
        var buffer = new StringBuilder(8);
        int result = NativeMethods.ToUnicodeEx(
            vk,
            scan,
            _keyState,
            buffer,
            buffer.Capacity,
            NativeMethods.TOUNICODE_NO_DEADKEY_STATE,
            layout);

        return result > 0 ? buffer.ToString(0, result) : null;
    }
}
