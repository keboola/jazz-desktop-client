namespace JazzCaptureCore;

/// <summary>Continuous-mode decisions shared by startup, Pause/Resume and session rollover.</summary>
public static class ContinuousCapture
{
    public static readonly TimeSpan PauseReminderInterval = TimeSpan.FromMinutes(30);

    public static bool ShouldRemind(bool enabled, bool paused, bool recording) =>
        enabled && paused && !recording;

    // A failed commit is never permission to overwrite the engine that owns its journal.
    public static bool ShouldContinue(bool enabled, bool committed, bool paused, bool terminating) =>
        enabled && committed && !paused && !terminating;
}
