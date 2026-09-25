namespace JazzCaptureCore;

/// <summary>
/// Which configuration layer produced an effective capture-at-launch decision.
/// </summary>
/// <remarks>
/// #60 adds <see cref="InstallerPreference"/> and <see cref="ManagedPolicy"/>, both ranked above
/// <see cref="LaunchSwitch"/>. Nothing else in this enum, and nothing in
/// <see cref="EffectiveCaptureAtLaunch.Resolve(HostSettings, bool, CaptureAtLaunchPolicy)"/>'s
/// existing branches, changed to add them -- see that method's remarks for the precedence table
/// this type encodes.
/// </remarks>
public enum CaptureAtLaunchSource
{
    /// <summary>No layer decided a value: every rank was absent or expressed no opinion.</summary>
    None,

    /// <summary>The persisted <c>HostSettings.CaptureAtLaunchEnabled</c> user preference.</summary>
    UserSetting,

    /// <summary>The process-scoped <c>--capture-at-launch</c> launch switch (#76).</summary>
    LaunchSwitch,

    /// <summary>
    /// The per-user MSI's <c>HKCU\Software\Keboola\Jazz\Policy\CaptureAtLaunch</c> value (#60).
    /// Written by the per-user MSI (slice 2) or a user-context deployment script -- never by this
    /// client. Provenance and precedence over the user's own setting, not tamper-resistance: the
    /// client never writes it, but a user with <c>regedit</c> can.
    /// </summary>
    InstallerPreference,

    /// <summary>
    /// The <c>HKLM\Software\Policies\Keboola\Jazz\CaptureAtLaunch</c> value (#60). Never written by
    /// this client -- deployed by an administrator through Intune settings catalog / ADMX
    /// ingestion, GPO, or a device-context script. The only rank that is genuinely enforced: a
    /// standard user cannot write under <c>HKLM\Software\Policies</c> at all.
    /// </summary>
    ManagedPolicy,
}

/// <summary>
/// The single resolved capture-at-launch decision, combining every configuration layer #60 and #76
/// know about into exactly the two booleans <see cref="CaptureStartupDecision.ShouldStart"/> already
/// takes.
/// </summary>
/// <param name="Enabled">Whether the effective decision is to start automatically.</param>
/// <param name="Paused">The persisted <c>HostSettings.CaptureAtLaunchPaused</c> flag, passed through unmodified.</param>
/// <param name="Source">
/// The highest-ranked layer that <b>decided</b> the effective value -- turned it on, or forced it
/// off because its own value was <see cref="CaptureAtLaunchPolicyValue.Malformed"/> -- not only a
/// layer that turned it on. Neither policy rank can ever force a decided <c>false</c> any other way
/// (amendment 3 on #60's decisions comment: an <see cref="CaptureAtLaunchPolicyValue.Absent"/> or
/// <see cref="CaptureAtLaunchPolicyValue.Disabled"/> rank never decides at all). See the remarks
/// below for why an off-deciding outcome needs this broader meaning.
/// </param>
/// <remarks>
/// <para>
/// <b>Precedence, first match wins:</b>
/// </para>
/// <para>
/// <c>managed policy (#60) &gt; installer preference (#60) &gt; launch switch (#76) &gt; user setting (#69)</c>
/// </para>
/// <list type="table">
/// <listheader><term>Condition</term><description><c>Enabled</c> / <c>Source</c></description></listheader>
/// <item><term><c>policy.ManagedPolicy == Enabled</c></term><description><c>true</c> / <see cref="CaptureAtLaunchSource.ManagedPolicy"/></description></item>
/// <item><term><c>policy.ManagedPolicy == Malformed</c></term><description><c>false</c> / <see cref="CaptureAtLaunchSource.ManagedPolicy"/></description></item>
/// <item><term><c>policy.InstallerPreference == Enabled</c></term><description><c>true</c> / <see cref="CaptureAtLaunchSource.InstallerPreference"/></description></item>
/// <item><term><c>policy.InstallerPreference == Malformed</c></term><description><c>false</c> / <see cref="CaptureAtLaunchSource.InstallerPreference"/></description></item>
/// <item><term><c>launchSwitchPresent</c></term><description><c>true</c> / <see cref="CaptureAtLaunchSource.LaunchSwitch"/></description></item>
/// <item><term><c>settings.CaptureAtLaunchEnabled</c></term><description><c>true</c> / <see cref="CaptureAtLaunchSource.UserSetting"/></description></item>
/// <item><term>otherwise</term><description><c>false</c> / <see cref="CaptureAtLaunchSource.None"/></description></item>
/// </list>
/// <para>
/// <b>Amendment 3 on #60 (the widest-reaching of the four decisions on the plan's open questions):
/// <c>Absent</c> and <c>Disabled</c> (a deployed <c>0</c>) are both "no opinion" at either rank</b>
/// -- neither one appears in the table above, because neither ever decides anything; both simply
/// fall through to the next rank, exactly like an absent value. The practical consequence:
/// <b>an administrator cannot enforce "off" through either channel.</b> Deploying <c>0</c>, or
/// removing a previously deployed value, are the same thing -- both give the decision back to the
/// next rank down. Only <see cref="CaptureAtLaunchPolicyValue.Malformed"/> ever forces this method
/// to report <c>false</c> at the <see cref="CaptureAtLaunchSource.ManagedPolicy"/> or
/// <see cref="CaptureAtLaunchSource.InstallerPreference"/> rank, and that is a misconfiguration, not
/// a decision -- see <see cref="CaptureAtLaunchPolicy.Parse"/>'s remarks and the <c>PolicyUnreadable</c>
/// disclosure in <c>OnboardingWindowContent</c>.
/// </para>
/// <para>
/// <b><see cref="Source"/>'s contract changed under #60 (a deliberate divergence from the comment
/// this replaces): it now reports the highest-ranked layer that <em>decided</em> the value, not only
/// one that turned it on.</b> Before #60, no rank could ever produce <c>Enabled: false</c> for a
/// reason other than "nothing turned it on", so the distinction did not exist. Now a
/// <see cref="CaptureAtLaunchPolicyValue.Malformed"/> managed policy or installer preference forces
/// <c>Enabled: false</c> while still being the layer that decided it -- and the enforced-rendering
/// requirement (#60 scope 3, the <c>PolicyUnreadable</c> disclosure) is incoherent unless
/// <see cref="Source"/> can say so. Every row that predates #60 is unaffected: with
/// <see cref="CaptureAtLaunchPolicy.None"/>, both new ranks are <c>Absent</c>, neither ever decides
/// anything, and every existing case collapses to exactly what it always reported.
/// </para>
/// <para>
/// One cross-cutting rule, stated separately because it is not a configuration layer at all: an
/// explicit user pause suppresses automatic start from every layer above, until the user resumes
/// it. <see cref="Paused"/> is not ranked among the layers -- it passes straight from
/// <c>HostSettings.CaptureAtLaunchPaused</c>, and <see cref="CaptureStartupDecision.ShouldStart"/>
/// already ANDs <c>!paused</c>, so the pause automatically outranks every layer, managed policy
/// included, with no extra logic here. This is #53 scope 6 and #76's ratified cross-cutting rule,
/// preserved deliberately: an enforced "capture at launch" policy still leaves the user a
/// one-action Stop.
/// </para>
/// <para>
/// <see cref="Resolve(HostSettings, bool, CaptureAtLaunchPolicy)"/> is the <b>only</b> place #60
/// changes to add its two ranks. <see cref="CaptureStartupDecision.ShouldStart"/> (five
/// <see langword="bool"/> parameters) and <see cref="CaptureStartupGate.TryStart"/> (the same five
/// booleans plus its start callback) keep their exact signatures -- #60 does not touch #69's
/// decision API, exactly as #76 did not.
/// </para>
/// </remarks>
public sealed record EffectiveCaptureAtLaunch(bool Enabled, bool Paused, CaptureAtLaunchSource Source)
{
    /// <summary>
    /// Resolves the effective capture-at-launch decision for this process with no managed
    /// configuration in force. Delegates to the three-argument overload with
    /// <see cref="CaptureAtLaunchPolicy.None"/>, so every caller and test written before #60
    /// compiles and passes unchanged.
    /// </summary>
    /// <param name="settings">The persisted host settings, read once at startup or on demand from the live host.</param>
    /// <param name="launchSwitchPresent">Whether <see cref="LaunchOptions.CaptureAtLaunch"/> was set for this process.</param>
    public static EffectiveCaptureAtLaunch Resolve(HostSettings settings, bool launchSwitchPresent)
        => Resolve(settings, launchSwitchPresent, CaptureAtLaunchPolicy.None);

    /// <summary>
    /// Resolves the effective capture-at-launch decision for this process, including the two #60
    /// managed-configuration ranks. See the type remarks for the full precedence table.
    /// </summary>
    /// <param name="settings">The persisted host settings, read once at startup or on demand from the live host.</param>
    /// <param name="launchSwitchPresent">Whether <see cref="LaunchOptions.CaptureAtLaunch"/> was set for this process.</param>
    /// <param name="policy">
    /// The managed policy and installer preference read from the registry at process start. Pass
    /// <see cref="CaptureAtLaunchPolicy.None"/> where neither exists -- there is deliberately no
    /// default value for this parameter (see the remarks on why a defaulted parameter would be
    /// unsafe here): every production call site must pass a policy explicitly.
    /// </param>
    /// <remarks>
    /// This parameter has no default value, unlike the optional constructor parameters
    /// <c>TrayHost</c> adds for the same policy. A defaulted parameter here would let a production
    /// call site silently drop the policy -- precisely the kind of drift #76 fought at
    /// <c>OnboardingWindowContent</c>'s two-argument <c>Resolve</c> overload (that type keeps an
    /// <see langword="internal"/> convenience overload for tests only, for the same reason). There
    /// are exactly three production call sites for this method
    /// (<c>App.xaml.cs</c>'s startup resolution and <c>ShowStatus</c> fallback, and
    /// <c>TrayHost.CurrentCaptureAtLaunch</c>), and all three pass a policy explicitly.
    /// </remarks>
    public static EffectiveCaptureAtLaunch Resolve(
        HostSettings settings, bool launchSwitchPresent, CaptureAtLaunchPolicy policy)
    {
        ArgumentNullException.ThrowIfNull(settings);
        ArgumentNullException.ThrowIfNull(policy);

        if (policy.ManagedPolicy == CaptureAtLaunchPolicyValue.Enabled)
        {
            return new EffectiveCaptureAtLaunch(true, settings.CaptureAtLaunchPaused, CaptureAtLaunchSource.ManagedPolicy);
        }

        if (policy.ManagedPolicy == CaptureAtLaunchPolicyValue.Malformed)
        {
            return new EffectiveCaptureAtLaunch(false, settings.CaptureAtLaunchPaused, CaptureAtLaunchSource.ManagedPolicy);
        }

        // Absent and Disabled (a deployed 0) are both "no opinion" here -- amendment 3 -- so neither
        // one ends the search; both simply fall through to the installer preference below exactly
        // as an absent value would.
        if (policy.InstallerPreference == CaptureAtLaunchPolicyValue.Enabled)
        {
            return new EffectiveCaptureAtLaunch(true, settings.CaptureAtLaunchPaused, CaptureAtLaunchSource.InstallerPreference);
        }

        if (policy.InstallerPreference == CaptureAtLaunchPolicyValue.Malformed)
        {
            return new EffectiveCaptureAtLaunch(false, settings.CaptureAtLaunchPaused, CaptureAtLaunchSource.InstallerPreference);
        }

        CaptureAtLaunchSource source = launchSwitchPresent
            ? CaptureAtLaunchSource.LaunchSwitch
            : settings.CaptureAtLaunchEnabled || settings.ContinuousCapture
                ? CaptureAtLaunchSource.UserSetting
                : CaptureAtLaunchSource.None;

        return new EffectiveCaptureAtLaunch(
            Enabled: launchSwitchPresent || settings.CaptureAtLaunchEnabled || settings.ContinuousCapture,
            Paused: settings.CaptureAtLaunchPaused,
            Source: source);
    }
}
