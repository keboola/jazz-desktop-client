namespace JazzCaptureCore;

/// <summary>Pure state transitions for a user's persisted capture-at-launch preference.</summary>
/// <remarks>
/// <para>
/// <b><c>automaticStartConfigured</c> is the effective value, not the persisted user setting.</b>
/// On a profile configured only by the #76 launch switch, <c>settings.CaptureAtLaunchEnabled</c>
/// is <see langword="false"/> -- the switch is process-scoped and never persisted -- so a
/// transition that consulted only that field would never record or clear a pause on such a
/// profile, and a user's Stop would be silently undone at the next login, forever. The caller
/// supplies <c>userSetting || launchSwitch</c> (in practice,
/// <c>EffectiveCaptureAtLaunch.Enabled</c>) so the pause is recordable and clearable regardless of
/// which layer turned automatic start on.
/// </para>
/// <para>
/// The single-argument overloads below exist only so every call and test written before #76
/// compiles and passes unchanged; they delegate using the persisted
/// <c>settings.CaptureAtLaunchEnabled</c> as <c>automaticStartConfigured</c>, which is exactly the
/// effective value on a profile with no launch switch.
/// </para>
/// <para>
/// <b>Pausing and resuming are not symmetric in what they may see.</b> Pausing
/// (<see cref="AfterSuccessfulUserStop"/>) must not manufacture a pause when nothing is
/// configured to start automatically, so it is gated on <c>automaticStartConfigured</c> as
/// evaluated by <em>this</em> process. Resuming (<see cref="AfterSuccessfulManualStart"/>)
/// deliberately is <b>not</b> gated the same way: a successful manual start is a person, right
/// now, explicitly choosing to start capture, and a launch switch that enabled a profile can live
/// on a shortcut this particular process was never started from -- so this process's own
/// effective value cannot always see it. Requiring it to would mean a machine started once
/// through a login script (no switch) and stopped once, then always started manually through a
/// plain Start Menu shortcut, could never clear its own pause, leaving every later switched
/// launch idle despite the person having started a capture themselves in between. A resume
/// therefore always clears an existing pause; the <c>automaticStartConfigured</c> parameter is
/// kept for signature symmetry with the pause side (and as a documented seam for #60), not
/// because this transition currently reads it.
/// </para>
/// </remarks>
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
        => AfterUserStopCompletion(
            settings,
            committed,
            settings?.CaptureAtLaunchEnabled ?? throw new ArgumentNullException(nameof(settings)));

    /// <summary>
    /// Applies the user-stop transition only after a durable commit, against the effective
    /// automatic-start configuration rather than the persisted user setting alone (see the type
    /// remarks).
    /// </summary>
    public static HostSettings AfterUserStopCompletion(
        HostSettings settings,
        bool committed,
        bool automaticStartConfigured)
        => committed ? AfterSuccessfulUserStop(settings, automaticStartConfigured) : settings;

    /// <summary>
    /// Pauses a currently enabled automatic-start preference after a successful user-requested
    /// stop. A failed stop and maintenance shutdown must not call this transition.
    /// </summary>
    public static HostSettings AfterSuccessfulUserStop(HostSettings settings)
        => AfterSuccessfulUserStop(
            settings,
            settings?.CaptureAtLaunchEnabled ?? throw new ArgumentNullException(nameof(settings)));

    /// <summary>
    /// Pauses automatic start after a successful user-requested stop, against the effective
    /// automatic-start configuration rather than the persisted user setting alone (see the type
    /// remarks).
    /// </summary>
    public static HostSettings AfterSuccessfulUserStop(HostSettings settings, bool automaticStartConfigured)
    {
        ArgumentNullException.ThrowIfNull(settings);
        return automaticStartConfigured
            ? settings with { CaptureAtLaunchPaused = true }
            : settings;
    }

    /// <summary>Clears a persisted pause after a successful manual capture start.</summary>
    public static HostSettings AfterSuccessfulManualStart(HostSettings settings)
        => AfterSuccessfulManualStart(
            settings,
            settings?.CaptureAtLaunchEnabled ?? throw new ArgumentNullException(nameof(settings)));

    /// <summary>
    /// Clears a persisted pause after a successful manual capture start. Unlike
    /// <see cref="AfterSuccessfulUserStop(HostSettings, bool)"/>, this is deliberately
    /// unconditional on <paramref name="automaticStartConfigured"/> -- see the type remarks for
    /// why a resume must not require this process to see whichever layer originally caused the
    /// pause.
    /// </summary>
    /// <param name="settings">The settings to transition.</param>
    /// <param name="automaticStartConfigured">
    /// Unused by this transition; accepted only for signature symmetry with
    /// <see cref="AfterSuccessfulUserStop(HostSettings, bool)"/> and as a documented seam for #60.
    /// </param>
    public static HostSettings AfterSuccessfulManualStart(HostSettings settings, bool automaticStartConfigured)
    {
        ArgumentNullException.ThrowIfNull(settings);
        _ = automaticStartConfigured;
        return settings.CaptureAtLaunchPaused
            ? settings with { CaptureAtLaunchPaused = false }
            : settings;
    }
}
