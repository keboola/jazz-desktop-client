namespace JazzCaptureCore;

/// <summary>
/// The one-time decision made after a host has completed its startup safety checks.
/// </summary>
/// <remarks>
/// This type deliberately has no knowledge of credentials, enrollment, login registration, or
/// delivery. Those are not consent to capture. A later managed-policy layer may supply the
/// effective preference, but it must use this same decision boundary.
/// </remarks>
public static class CaptureStartupDecision
{
    /// <summary>
    /// Returns whether startup may invoke the ordinary local-first capture path exactly once.
    /// </summary>
    public static bool ShouldStart(
        bool ownsSingleInstance,
        bool initializationSucceeded,
        bool recoveryCompleted,
        bool captureAtLaunchEnabled,
        bool captureAtLaunchPaused)
        => ownsSingleInstance
            && initializationSucceeded
            && recoveryCompleted
            && captureAtLaunchEnabled
            && !captureAtLaunchPaused;
}
