using JazzCaptureCore;

namespace JazzCapture;

/// <summary>
/// Narrow maintenance-only commit seam. It can drain and stop a recording engine; it has no API
/// for confirmation, finalization, export, queueing, or opening review UI.
/// </summary>
internal static class MaintenanceCaptureSession
{
    internal static bool TryCommit(CaptureEngine? engine, Func<bool> drain)
    {
        ArgumentNullException.ThrowIfNull(drain);
        if (engine is null || engine.State != EngineState.Recording) { return true; }
        if (!drain()) { return false; }
        engine.Stop();
        return engine.State == EngineState.Committed;
    }
}
