using JazzCapture;
using JazzCaptureCore;

namespace JazzCaptureHostTests;

/// <summary>
/// <see cref="SettingsWindow.ResolveEnforcedNoticeText"/> chooses between the two enforced-state
/// notices for an enforced capture-at-launch checkbox. Extracted as a pure, testable static after
/// an Opus review finding on PR #85: the original constructor logic chose the notice from
/// <c>CaptureAtLaunchPolicyRead.Detail</c>, which can be non-null for a rank
/// <see cref="EffectiveCaptureAtLaunch.Resolve(HostSettings, bool, CaptureAtLaunchPolicy)"/> never
/// even consulted (an enforced-on managed policy while the never-reached installer preference
/// happens to be malformed), letting the "could not be read" copy render while capture was, in
/// fact, actively enforced on. These tests pin the fix: the choice is <see cref="EffectiveCaptureAtLaunch.Enabled"/>
/// alone, with no dependency on <c>Detail</c> at all.
/// </summary>
public sealed class SettingsWindowEnforcedNoticeTests
{
    private const string EnforcedNotice = "This is set by your organisation's policy and cannot be changed here.";
    private const string PolicyUnreadableNotice =
        "A setting deployed to this machine could not be read, so this cannot be changed here.";

    [Fact]
    public void AnEnforcedOnManagedPolicyShowsTheOrganisationNotice()
    {
        var effective = new EffectiveCaptureAtLaunch(Enabled: true, Paused: false, CaptureAtLaunchSource.ManagedPolicy);

        Assert.Equal(EnforcedNotice, SettingsWindow.ResolveEnforcedNoticeText(effective));
    }

    [Fact]
    public void AnEnforcedOnInstallerPreferenceShowsTheOrganisationNotice()
    {
        var effective = new EffectiveCaptureAtLaunch(Enabled: true, Paused: false, CaptureAtLaunchSource.InstallerPreference);

        Assert.Equal(EnforcedNotice, SettingsWindow.ResolveEnforcedNoticeText(effective));
    }

    [Fact]
    public void AMalformedManagedPolicyShowsThePolicyUnreadableNotice()
    {
        var effective = new EffectiveCaptureAtLaunch(Enabled: false, Paused: false, CaptureAtLaunchSource.ManagedPolicy);

        Assert.Equal(PolicyUnreadableNotice, SettingsWindow.ResolveEnforcedNoticeText(effective));
    }

    [Fact]
    public void AMalformedInstallerPreferenceShowsThePolicyUnreadableNotice()
    {
        var effective = new EffectiveCaptureAtLaunch(Enabled: false, Paused: false, CaptureAtLaunchSource.InstallerPreference);

        Assert.Equal(PolicyUnreadableNotice, SettingsWindow.ResolveEnforcedNoticeText(effective));
    }

    /// <summary>Paused must not change which notice renders -- the choice is about which value
    /// will apply, not whether it is currently suppressed by a pause.</summary>
    [Fact]
    public void AnEnforcedOnPolicyThatIsCurrentlyPausedStillShowsTheOrganisationNotice()
    {
        var effective = new EffectiveCaptureAtLaunch(Enabled: true, Paused: true, CaptureAtLaunchSource.ManagedPolicy);

        Assert.Equal(EnforcedNotice, SettingsWindow.ResolveEnforcedNoticeText(effective));
    }

    [Fact]
    public void RejectsANullArgument()
    {
        Assert.Throws<ArgumentNullException>(() => SettingsWindow.ResolveEnforcedNoticeText(null!));
    }
}
