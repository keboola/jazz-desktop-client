using System.Threading;
using JasnostCapture.Interop;
using Timer = System.Threading.Timer;

namespace JasnostCapture.Capture;

/// <summary>
/// Detects the silent detach that Windows applies to a low-level hook whose callback ran too long,
/// and re-arms it (ANNEX-HOST sections 5 and 7). Without this, capture would stop without any signal;
/// with it, the re-arm is recorded as a temporarily-disabled then restored capability pair.
/// </summary>
/// <remarks>
/// Liveness is judged against <c>GetLastInputInfo</c>, which reports the last system-wide input
/// independently of our hook. When the OS says input happened recently but our own callback clock has
/// not advanced past the heartbeat, the hook is presumed dead and re-armed. This is the one reliable
/// way to notice a detach, and it is best-effort until validated on real hardware in Task 10.
/// </remarks>
public sealed class HookWatchdog : IDisposable
{
    private readonly InputHooks _hooks;
    private readonly TimeSpan _heartbeat;
    private readonly Action _onReArm;
    private readonly Timer _timer;

    private uint _previousInputTick;

    /// <summary>Creates the watchdog.</summary>
    /// <param name="hooks">The hooks to watch and re-arm.</param>
    /// <param name="heartbeat">Poll interval and staleness threshold.</param>
    /// <param name="onReArm">Invoked after a re-arm so the caller can emit the capability pair.</param>
    public HookWatchdog(InputHooks hooks, TimeSpan heartbeat, Action onReArm)
    {
        _hooks = hooks ?? throw new ArgumentNullException(nameof(hooks));
        _heartbeat = heartbeat;
        _onReArm = onReArm ?? throw new ArgumentNullException(nameof(onReArm));
        _timer = new Timer(_ => Check());
    }

    /// <summary>Starts polling at the heartbeat interval.</summary>
    public void Start() => _timer.Change(_heartbeat, _heartbeat);

    /// <summary>Stops polling.</summary>
    public void Stop() => _timer.Change(Timeout.Infinite, Timeout.Infinite);

    /// <inheritdoc />
    public void Dispose() => _timer.Dispose();

    private void Check()
    {
        var info = new NativeMethods.LASTINPUTINFO { CbSize = (uint)System.Runtime.InteropServices.Marshal.SizeOf<NativeMethods.LASTINPUTINFO>() };
        if (!NativeMethods.GetLastInputInfo(ref info))
        {
            return;
        }

        uint inputTick = info.DwTime;
        bool newInput = inputTick != _previousInputTick;
        _previousInputTick = inputTick;

        if (!newInput)
        {
            return; // No input since the last check: an idle hook is not a dead hook.
        }

        long heartbeatMs = (long)_heartbeat.TotalMilliseconds;
        long sinceCallback = Environment.TickCount64 - _hooks.LastCallbackTicks;
        if (sinceCallback > heartbeatMs * 2)
        {
            // Input occurred but our callback never ran: the hook was detached. Re-arm and report.
            _hooks.RequestReArm();
            _onReArm();
        }
    }
}
