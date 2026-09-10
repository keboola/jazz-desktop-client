using System.Windows.Forms;
using JazzCapture.Interop;

namespace JazzCapture;

/// <summary>
/// Hidden top-level window used by Windows Installer Restart Manager. It contains no activation
/// protocol: it only accepts the standard close/session messages and refuses them unless the host
/// has durably drained an active capture.
/// </summary>
internal sealed class MaintenanceShutdownWindow : NativeWindow, IDisposable
{
    private readonly MaintenanceShutdownController _controller;
    internal bool RestartRegistered { get; }
    internal bool HasNativeHandle => Handle != IntPtr.Zero;

    internal MaintenanceShutdownWindow(
        Func<bool> prepare,
        Action shutdown,
        Func<int>? registerApplicationRestart = null)
    {
        _controller = new MaintenanceShutdownController(prepare, shutdown);
        CreateHandle(new CreateParams { Caption = "Jazz Capture maintenance" });
        try
        {
            int result = registerApplicationRestart?.Invoke() ??
                NativeMethods.RegisterApplicationRestart(
                    null,
                    NativeMethods.MAINTENANCE_RESTART_FLAGS);
            // Failure means Windows may not restart us automatically after maintenance. Keep the
            // close sink alive so an upgrade can still drain safely; startup must not crash and
            // the owned native handle remains deterministically disposable.
            RestartRegistered = RestartRegistration.IsSuccess(result);
        }
        catch (Exception exception) when (
            exception is DllNotFoundException or EntryPointNotFoundException)
        {
            // The application targets Windows, but a missing API must still degrade to a safe close
            // sink instead of leaking the handle created above or crashing the tray host.
            RestartRegistered = false;
        }
    }

    protected override void WndProc(ref Message message)
    {
        if (message.Msg == NativeMethods.WM_QUERYENDSESSION)
        {
            message.Result = _controller.QueryClose() ? new IntPtr(1) : IntPtr.Zero;
            return;
        }

        if (message.Msg == NativeMethods.WM_CLOSE)
        {
            _controller.RequestClose();
            return;
        }

        if (message.Msg == NativeMethods.WM_ENDSESSION)
        {
            _controller.EndSession(message.WParam != IntPtr.Zero);
            return;
        }

        base.WndProc(ref message);
    }

    public void Dispose()
    {
        if (Handle != IntPtr.Zero) { DestroyHandle(); }
        GC.SuppressFinalize(this);
    }
}
