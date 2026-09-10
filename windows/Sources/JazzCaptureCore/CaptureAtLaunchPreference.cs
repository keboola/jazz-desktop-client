namespace JazzCaptureCore;

/// <summary>Pure state transitions for a user's persisted capture-at-launch preference.</summary>
public static class CaptureAtLaunchPreference
{
    /// <summary>
    /// Applies the user-stop transition only after a durable commit. Failed drains preserve the
    /// journal for recovery and must not turn into a persistent pause; maintenance completion does
    /// not invoke this user-action transition at all.
    /// </summary>
    public static HostSettings AfterUserStopCompletion(
        HostSettings settings,
        bool committed)
        => committed
            ? AfterSuccessfulUserStop(settings)
            : settings;

    /// <summary>
    /// Pauses a currently enabled automatic-start preference after a successful user-requested
    /// stop. A failed stop and maintenance shutdown must not call this transition.
    /// </summary>
    public static HostSettings AfterSuccessfulUserStop(HostSettings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
        return settings.CaptureAtLaunchEnabled
            ? settings with { CaptureAtLaunchPaused = true }
            : settings;
    }

    /// <summary>Clears a persisted pause after a successful manual capture start.</summary>
    public static HostSettings AfterSuccessfulManualStart(HostSettings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
        return settings.CaptureAtLaunchEnabled && settings.CaptureAtLaunchPaused
            ? settings with { CaptureAtLaunchPaused = false }
            : settings;
    }
}
