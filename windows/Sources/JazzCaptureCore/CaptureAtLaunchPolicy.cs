namespace JazzCaptureCore;

/// <summary>
/// What a single registry-backed rank (<see cref="CaptureAtLaunchPolicy.ManagedPolicy"/> or
/// <see cref="CaptureAtLaunchPolicy.InstallerPreference"/>) says, once parsed.
/// </summary>
/// <remarks>
/// <para>
/// <b>Amendment 3 (the decisions comment on #60): <c>0</c> means "no opinion", at both ranks.</b>
/// <see cref="Disabled"/> is kept as its own member, distinct from <see cref="Absent"/>, purely for
/// provenance -- a status detail or future diagnostic can still say "a value was deployed and it
/// said 0" rather than "nothing was deployed" -- but <see cref="EffectiveCaptureAtLaunch.Resolve"/>
/// treats the two identically: neither one decides anything at its rank, and resolution falls
/// through to the next rank exactly as it would for an absent value. Collapsing them at parse time
/// would make that provenance unrecoverable, so they stay distinct here even though nothing in
/// slice 1 currently reads the difference.
/// </para>
/// <para>
/// The practical consequence, stated once because it is easy to miss: an administrator cannot
/// enforce "off" through either channel. Deploying <c>0</c> (or removing a deployed value entirely)
/// only ever gives the decision back to the next rank down -- ultimately to the user's own tray
/// setting. Turning capture off, once a lower layer has turned it on, is not something a policy can
/// do; it is a deliberate product decision, not an oversight (see the decisions comment on #60,
/// amendment 3).
/// </para>
/// </remarks>
public enum CaptureAtLaunchPolicyValue
{
    /// <summary>No value is deployed at this rank. Falls through to the next rank.</summary>
    Absent,

    /// <summary>The rank enforces capture-at-launch on.</summary>
    Enabled,

    /// <summary>
    /// A value was deployed and it explicitly said "no opinion" (<c>0</c>). Resolves exactly like
    /// <see cref="Absent"/> -- see the type remarks -- but is kept distinct from it for provenance.
    /// </summary>
    Disabled,

    /// <summary>
    /// A value is present but is neither <c>0</c> nor <c>1</c>. The only value that ever forces
    /// capture off at this rank -- see <see cref="CaptureAtLaunchPolicy.Parse"/> and
    /// <see cref="EffectiveCaptureAtLaunch.Resolve"/>'s remarks.
    /// </summary>
    Malformed,
}

/// <summary>
/// The two managed-configuration ranks #60 adds above the #76 launch switch, already parsed into
/// the four-value domain <see cref="CaptureAtLaunchPolicyValue"/> describes. Combining both ranks
/// into a single record (rather than two loose <see cref="CaptureAtLaunchPolicyValue"/> parameters
/// threaded everywhere) keeps <see cref="EffectiveCaptureAtLaunch.Resolve"/>'s signature to three
/// parameters and gives the reader (<c>CaptureAtLaunchPolicyStore</c>, host-side) exactly one type
/// to hand back.
/// </summary>
/// <param name="ManagedPolicy">
/// The value read from <c>HKLM\Software\Policies\Keboola\Jazz\CaptureAtLaunch</c> -- genuinely
/// enforced, in the sense that a standard user cannot write under
/// <c>HKLM\Software\Policies</c> at all. Never written by this client.
/// </param>
/// <param name="InstallerPreference">
/// The value read from <c>HKCU\Software\Keboola\Jazz\Policy\CaptureAtLaunch</c> -- provenance and
/// precedence over the user's own tray setting, not tamper-resistance: the per-user MSI that will
/// write it in slice 2 runs as the user, so anything it writes, the user can rewrite with
/// <c>regedit</c>. This client never writes this value either; it only reads it.
/// </param>
/// <remarks>
/// This record carries exactly two members, both of the four-value enum above, and nothing else --
/// so there is no member shape a secret (a token, an endpoint) could ever travel through, matching
/// #62 constraint 2 structurally rather than by inspection, the same argument
/// <see cref="LaunchOptions"/> already makes for the launch switch.
/// </remarks>
public sealed record CaptureAtLaunchPolicy(
    CaptureAtLaunchPolicyValue ManagedPolicy,
    CaptureAtLaunchPolicyValue InstallerPreference)
{
    /// <summary>Neither rank carries a value. Every existing caller of <c>EffectiveCaptureAtLaunch.Resolve</c>
    /// that predates #60 is, in effect, always passing this.</summary>
    public static readonly CaptureAtLaunchPolicy None =
        new(CaptureAtLaunchPolicyValue.Absent, CaptureAtLaunchPolicyValue.Absent);

    /// <summary>
    /// Parses one raw registry value into the four-value domain above.
    /// </summary>
    /// <remarks>
    /// <para>
    /// One spelling each, matching <see cref="LaunchOptions"/>'s own single-spelling discipline: no
    /// <c>"true"</c>, no <c>"yes"</c>, no case folding of words. <c>null</c> (the value or its key is
    /// absent) maps to <see cref="CaptureAtLaunchPolicyValue.Absent"/>; <c>"1"</c> after
    /// <see cref="string.Trim()"/> maps to <see cref="CaptureAtLaunchPolicyValue.Enabled"/>;
    /// <c>"0"</c> after trimming maps to <see cref="CaptureAtLaunchPolicyValue.Disabled"/>.
    /// <b>Anything else, including an empty or whitespace-only string, maps to
    /// <see cref="CaptureAtLaunchPolicyValue.Malformed"/>.</b>
    /// </para>
    /// <para>
    /// <b><see cref="CaptureAtLaunchPolicyValue.Malformed"/> is treated by
    /// <see cref="EffectiveCaptureAtLaunch.Resolve"/> as enforced off, never ignored</b> -- #60 scope
    /// 1 forbids an unrecognised value ever falling through to the more permissive option, and once
    /// amendment 3 makes <c>0</c> mean "no opinion", falling through past a value nobody could parse
    /// <em>is</em> the permissive direction whenever a lower layer (the launch switch, or the user's
    /// own tray setting) is on. This is now the <b>only</b> path that forces capture off: neither
    /// rank can enforce off by design (see <see cref="CaptureAtLaunchPolicyValue"/>'s remarks), so a
    /// <see cref="CaptureAtLaunchPolicyValue.Malformed"/> reading is a misconfiguration, not anyone's
    /// decision -- the status window's <c>PolicyUnreadable</c> copy says exactly that (see
    /// <c>OnboardingWindowContent</c>).
    /// </para>
    /// <para>
    /// <b>Deliberately diverges from <see cref="HostSettingsStore"/>'s <c>OptionalFlag</c></b>, which
    /// throws a <see cref="FormatException"/> when a present key holds something other than a
    /// boolean. Throwing here would turn a mistyped policy on a machine nobody is sitting at into a
    /// total capture outage; folding the failure into a value that safely resolves to "not enabled"
    /// is the same fail-safe posture <see cref="LaunchOptions.Parse"/> already takes for an
    /// unrecognised command-line argument, and it is the only direction that is safe by default.
    /// </para>
    /// <para>
    /// This type -- and this method -- decide capture-<em>at-launch</em> only. A manual "Start
    /// capture" from the tray is never gated on a policy value; nothing in this file, or in
    /// <see cref="EffectiveCaptureAtLaunch"/>, is consulted anywhere but the one startup decision.
    /// </para>
    /// </remarks>
    public static CaptureAtLaunchPolicyValue Parse(string? raw)
    {
        if (raw is null)
        {
            return CaptureAtLaunchPolicyValue.Absent;
        }

        return raw.Trim() switch
        {
            "1" => CaptureAtLaunchPolicyValue.Enabled,
            "0" => CaptureAtLaunchPolicyValue.Disabled,
            _ => CaptureAtLaunchPolicyValue.Malformed,
        };
    }
}
