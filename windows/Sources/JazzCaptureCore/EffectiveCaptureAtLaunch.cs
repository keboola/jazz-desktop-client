namespace JazzCaptureCore;

/// <summary>
/// Which configuration layer produced an effective capture-at-launch decision.
/// </summary>
/// <remarks>
/// #60 adds <c>InstallerPreference</c> and <c>ManagedPolicy</c>, both ranked above
/// <see cref="LaunchSwitch"/>. Nothing else in this enum, and nothing in
/// <see cref="EffectiveCaptureAtLaunch.Resolve"/>'s existing branches, is expected to change when
/// it does -- see that method's remarks for the precedence table this type encodes.
/// </remarks>
public enum CaptureAtLaunchSource
{
    /// <summary>Neither a launch switch nor a user setting turned capture-at-launch on.</summary>
    None,

    /// <summary>The persisted <c>HostSettings.CaptureAtLaunchEnabled</c> user preference.</summary>
    UserSetting,

    /// <summary>The process-scoped <c>--capture-at-launch</c> launch switch (#76).</summary>
    LaunchSwitch,
}

/// <summary>
/// The single resolved capture-at-launch decision, combining every configuration layer #76 knows
/// about into exactly the two booleans <see cref="CaptureStartupDecision.ShouldStart"/> already
/// takes.
/// </summary>
/// <param name="Enabled">Whether any layer at or above <see cref="CaptureAtLaunchSource.UserSetting"/> asked for automatic start.</param>
/// <param name="Paused">The persisted <c>HostSettings.CaptureAtLaunchPaused</c> flag, passed through unmodified.</param>
/// <param name="Source">The highest-ranked layer that turned <see cref="Enabled"/> on, or <see cref="CaptureAtLaunchSource.None"/>.</param>
/// <remarks>
/// <para>
/// <b>Precedence, and the seam #60 extends:</b>
/// </para>
/// <para>
/// <c>managed policy (#60) &gt; installer preference (#60) &gt; launch switch (#76) &gt; user setting (#69)</c>
/// </para>
/// <para>
/// with one cross-cutting rule, stated separately because it is not a configuration layer at all:
/// an explicit user pause suppresses automatic start from every layer above, until the user
/// resumes it. <see cref="Paused"/> is not ranked among the layers -- it passes straight from
/// <c>HostSettings.CaptureAtLaunchPaused</c>, and <see cref="CaptureStartupDecision.ShouldStart"/>
/// already ANDs <c>!paused</c>, so the pause automatically outranks every layer with no extra
/// logic here.
/// </para>
/// <para>
/// <see cref="Resolve"/> is the <b>only</b> place #60 changes to add its two layers: it gains two
/// more inputs and this enum gains two more members ranked above
/// <see cref="CaptureAtLaunchSource.LaunchSwitch"/>. <see cref="CaptureStartupDecision.ShouldStart"/>
/// and <see cref="CaptureStartupGate.TryStart"/> keep their exact five-argument signatures --
/// #76 does not touch #69's decision API, and #60 must not need to either.
/// </para>
/// <para>
/// <see cref="Source"/> exists for #60's "a value the policy enforces must render as enforced"
/// requirement. #76 does not render it anywhere; it is reported here, and covered by test, purely
/// so the extension point exists before it is needed.
/// </para>
/// </remarks>
public sealed record EffectiveCaptureAtLaunch(bool Enabled, bool Paused, CaptureAtLaunchSource Source)
{
    /// <summary>
    /// Resolves the effective capture-at-launch decision for this process.
    /// </summary>
    /// <param name="settings">The persisted host settings, read once at startup or on demand from the live host.</param>
    /// <param name="launchSwitchPresent">Whether <see cref="LaunchOptions.CaptureAtLaunch"/> was set for this process.</param>
    public static EffectiveCaptureAtLaunch Resolve(HostSettings settings, bool launchSwitchPresent)
    {
        ArgumentNullException.ThrowIfNull(settings);

        CaptureAtLaunchSource source = launchSwitchPresent
            ? CaptureAtLaunchSource.LaunchSwitch
            : settings.CaptureAtLaunchEnabled
                ? CaptureAtLaunchSource.UserSetting
                : CaptureAtLaunchSource.None;

        return new EffectiveCaptureAtLaunch(
            Enabled: launchSwitchPresent || settings.CaptureAtLaunchEnabled,
            Paused: settings.CaptureAtLaunchPaused,
            Source: source);
    }
}
