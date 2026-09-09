namespace JazzCapture;

/// <summary>Idempotent, retryable state machine behind Restart Manager close messages.</summary>
internal sealed class MaintenanceShutdownController
{
    private readonly Func<bool> _prepare;
    private readonly Action _shutdown;
    private bool _prepared;
    private bool _shutdownRequested;

    internal MaintenanceShutdownController(Func<bool> prepare, Action shutdown)
    {
        _prepare = prepare;
        _shutdown = shutdown;
    }

    internal bool QueryClose()
    {
        if (!_prepared) { _prepared = _prepare(); }
        return _prepared;
    }

    internal bool RequestClose()
    {
        if (!QueryClose()) { return false; }
        if (!_shutdownRequested)
        {
            _shutdownRequested = true;
            _shutdown();
        }
        return true;
    }

    internal bool EndSession(bool sessionIsEnding) => sessionIsEnding && RequestClose();
}

internal static class RestartRegistration
{
    internal static bool IsSuccess(int hresult) => hresult == 0;
}
