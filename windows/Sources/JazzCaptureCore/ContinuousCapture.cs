namespace JazzCaptureCore;

/// <summary>Continuous-mode decisions shared by startup, Pause/Resume and session rollover.</summary>
public static class ContinuousCapture
{
    public static bool ShouldRemind(bool continuous, bool paused, bool recording) =>
        continuous && paused && !recording;

    // A failed commit is never permission to overwrite the engine that owns its journal.
    public static bool ShouldContinue(bool continuous, bool committed, bool paused, bool terminating) =>
        continuous && committed && !paused && !terminating;
}
