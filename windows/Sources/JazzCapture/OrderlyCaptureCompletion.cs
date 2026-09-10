using JazzCaptureCore;

namespace JazzCapture;

internal enum CaptureCompletionOutcome
{
    NoActiveCapture,
    Committed,
    PreservedForRecovery,
}

/// <summary>Testable local completion seam shared by every host shutdown entry point.</summary>
internal static class OrderlyCaptureCompletion
{
    internal static CaptureCompletionOutcome TryCommit(CaptureEngine? engine, Action stopAdmission, Func<bool> drain)
    {
        ArgumentNullException.ThrowIfNull(stopAdmission);
        ArgumentNullException.ThrowIfNull(drain);
        if (engine is null || engine.State != EngineState.Recording) return CaptureCompletionOutcome.NoActiveCapture;

        stopAdmission();
        return MaintenanceCaptureSession.TryCommit(engine, drain)
            ? CaptureCompletionOutcome.Committed
            : CaptureCompletionOutcome.PreservedForRecovery;
    }
}
