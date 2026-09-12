namespace JazzCaptureCore;

/// <summary>Pure state transitions for a user's persisted capture-at-launch preference.</summary>
/// <remarks>
/// <para>
/// <b><c>automaticStartConfigured</c> is the effective value, not the persisted user setting.</b>
/// On a profile configured only by the #76 launch switch, <c>settings.CaptureAtLaunchEnabled</c>
/// is <see langword="false"/> -- the switch is process-scoped and never persisted -- so a
/// transition that consulted only that field would never record a pause on such a profile, and a
/// user's Stop would be silently undone at the next login, forever. The caller supplies
/// <c>userSetting || launchSwitch</c> (in practice, <c>EffectiveCaptureAtLaunch.Enabled</c>) so the
/// pause is recordable when the process handling the Stop can see what turned automatic start on
/// -- see the known gap below for the case where it cannot.
/// </para>
/// <para>
/// The single-argument overloads below exist only so every call and test written before #76
/// compiles and passes unchanged; they delegate using the persisted
/// <c>settings.CaptureAtLaunchEnabled</c> as <c>automaticStartConfigured</c>, which is exactly the
/// effective value on a profile with no launch switch.
/// </para>
/// <para>
/// <b>Pausing and resuming are not symmetric in what they may see, and that asymmetry is
/// intentional on the resume side and a known, accepted gap on the pause side.</b> Resuming
/// (<see cref="AfterSuccessfulManualStart"/>) is unconditional: a successful manual start is a
/// person, right now, explicitly choosing to start capture, and a launch switch that enabled a
/// profile can live on a shortcut this particular process was never started from -- requiring this
/// process to see it would mean a machine started once through a login script (no switch) and
/// stopped once, then always started manually through a plain Start Menu shortcut, could never
/// clear its own pause. So a resume always clears an existing pause, regardless of
/// <c>automaticStartConfigured</c>; that parameter is kept only for signature symmetry with the
/// pause side (and as a documented seam for #60), not because the transition reads it.
/// </para>
/// <para>
/// Pausing (<see cref="AfterSuccessfulUserStop"/>) cannot be made unconditional the same way: it
/// must not manufacture a pause when nothing is configured to start automatically --
/// <c>DisabledPreferenceAndUncommittedStopDoNotManufacturePause</c> pins exactly that, and the
/// approved plan for #76 requires it stay unmodified. The gap this leaves: a process with no
/// visible switch and no user setting cannot tell whether some <em>other</em> shortcut, scheduled
/// task, or login script on the same profile carries the switch -- which, per <c>windows/README.md</c>'s
/// login-race note, is the ordinary shape of a switch-configured MSI install, since the installed
/// Run value and Start Menu shortcut both launch with no switch at all. A manual Stop performed
/// from such a process therefore does not record a pause on behalf of a switch it cannot see,
/// even though a differently-launched process on the same profile would auto-start again later.
/// Closing this gap would require persisting something about the switch's existence beyond this
/// one process, which is exactly what R1 forbids; it is left open, deliberately, rather than
/// worked around by weakening the guarantee <c>DisabledPreferenceAndUncommittedStopDoNotManufacturePause</c>
/// pins.
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
