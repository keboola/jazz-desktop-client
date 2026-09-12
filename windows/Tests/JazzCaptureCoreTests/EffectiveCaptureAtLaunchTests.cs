using System.Reflection;
using JazzCaptureCore;

namespace JazzCaptureCoreTests;

/// <summary>
/// <see cref="EffectiveCaptureAtLaunch"/> is the single seam that combines the #76 launch switch
/// with the #69 persisted user setting into exactly the two booleans
/// <see cref="CaptureStartupDecision.ShouldStart"/> already takes. These tests pin the precedence
/// table, that an explicit pause still outranks the switch, that the switch is recordable and
/// clearable on a switch-only profile (#76 scope 5), and that #69's decision API is untouched by
/// this issue.
/// </summary>
public sealed class EffectiveCaptureAtLaunchTests
{
    private static HostSettings Settings(bool enabled, bool paused) =>
        new(Array.Empty<string>(), false, false, true, CaptureAtLaunchEnabled: enabled, CaptureAtLaunchPaused: paused);

    [Fact]
    public void TheLaunchSwitchAloneProducesAStartDecision()
    {
        EffectiveCaptureAtLaunch effective = EffectiveCaptureAtLaunch.Resolve(
            Settings(enabled: false, paused: false), launchSwitchPresent: true);

        Assert.True(effective.Enabled);
        Assert.False(effective.Paused);
        Assert.Equal(CaptureAtLaunchSource.LaunchSwitch, effective.Source);
        Assert.True(CaptureStartupDecision.ShouldStart(
            true, true, true, effective.Enabled, effective.Paused));
    }

    [Fact]
    public void NeitherLayerSetLeavesTheClientIdle()
    {
        EffectiveCaptureAtLaunch effective = EffectiveCaptureAtLaunch.Resolve(
            Settings(enabled: false, paused: false), launchSwitchPresent: false);

        Assert.False(effective.Enabled);
        Assert.Equal(CaptureAtLaunchSource.None, effective.Source);
        Assert.False(CaptureStartupDecision.ShouldStart(
            true, true, true, effective.Enabled, effective.Paused));
    }

    [Theory]
    [InlineData(false, false, false)]
    [InlineData(false, false, true)]
    [InlineData(false, true, false)]
    [InlineData(false, true, true)]
    [InlineData(true, false, false)]
    [InlineData(true, false, true)]
    [InlineData(true, true, false)]
    [InlineData(true, true, true)]
    public void EveryLayerCombinationResolvesThroughTheUnchangedStartupDecision(
        bool userEnabled, bool userPaused, bool launchSwitch)
    {
        EffectiveCaptureAtLaunch effective = EffectiveCaptureAtLaunch.Resolve(
            Settings(userEnabled, userPaused), launchSwitch);

        bool expected = (userEnabled || launchSwitch) && !userPaused;
        Assert.Equal(expected, CaptureStartupDecision.ShouldStart(
            true, true, true, effective.Enabled, effective.Paused));
    }

    [Fact]
    public void TheDecisionApiIsUnchangedByThisIssue()
    {
        // #69's own closing promise, restated as a structural guard: #76 must not widen
        // ShouldStart's signature to smuggle a new input through it.
        MethodInfo shouldStart = typeof(CaptureStartupDecision).GetMethod(nameof(CaptureStartupDecision.ShouldStart))!;
        ParameterInfo[] parameters = shouldStart.GetParameters();

        Assert.Equal(5, parameters.Length);
        Assert.All(parameters, parameter => Assert.Equal(typeof(bool), parameter.ParameterType));
    }

    [Fact]
    public void AnExplicitPauseOutranksTheLaunchSwitchUntilItIsResumed()
    {
        HostSettings settings = Settings(enabled: false, paused: false);
        EffectiveCaptureAtLaunch started = EffectiveCaptureAtLaunch.Resolve(settings, launchSwitchPresent: true);
        Assert.True(CaptureStartupDecision.ShouldStart(true, true, true, started.Enabled, started.Paused));

        // A stop on a switch-only profile must be recordable: the persisted user setting is still
        // false, so the transition is fed the *effective* Enabled, not settings.CaptureAtLaunchEnabled.
        HostSettings pausedSettings = CaptureAtLaunchPreference.AfterSuccessfulUserStop(
            settings, automaticStartConfigured: started.Enabled);
        Assert.True(pausedSettings.CaptureAtLaunchPaused);

        EffectiveCaptureAtLaunch paused = EffectiveCaptureAtLaunch.Resolve(pausedSettings, launchSwitchPresent: true);
        Assert.False(CaptureStartupDecision.ShouldStart(true, true, true, paused.Enabled, paused.Paused));

        // A later manual start resumes it, again fed the effective Enabled.
        HostSettings resumedSettings = CaptureAtLaunchPreference.AfterSuccessfulManualStart(
            pausedSettings, automaticStartConfigured: paused.Enabled);
        Assert.False(resumedSettings.CaptureAtLaunchPaused);

        EffectiveCaptureAtLaunch resumed = EffectiveCaptureAtLaunch.Resolve(resumedSettings, launchSwitchPresent: true);
        Assert.True(CaptureStartupDecision.ShouldStart(true, true, true, resumed.Enabled, resumed.Paused));
    }

    /// <summary>
    /// Opus review finding on PR #80 (M1): a switch-configured machine can be started manually
    /// from a *different* process than the one that normally carries the switch -- a plain Start
    /// Menu shortcut, or the argument-less HKCU Run entry, with no <c>--capture-at-launch</c> at
    /// all. That process's own effective value is <c>false</c> (its persisted user setting is
    /// off and it has no switch), yet a person is right there choosing Start capture. A resume
    /// gated on this process's own <c>automaticStartConfigured</c> would never clear the pause,
    /// leaving every later switched launch idle despite the explicit Start -- acceptance box 5's
    /// "resuming restores it" would be false on exactly the profile shape the switch creates.
    /// </summary>
    [Fact]
    public void AManualStartResumesEvenWhenThisProcessCannotSeeWhatConfiguredAutomaticStart()
    {
        HostSettings paused = new(Array.Empty<string>(), false, false, true, CaptureAtLaunchEnabled: false, CaptureAtLaunchPaused: true);

        // This process has neither the user setting nor the switch -- automaticStartConfigured is
        // false -- yet the resume must still clear the pause.
        HostSettings resumed = CaptureAtLaunchPreference.AfterSuccessfulManualStart(paused, automaticStartConfigured: false);

        Assert.False(resumed.CaptureAtLaunchPaused);
    }

    [Theory]
    [InlineData(true, true, CaptureAtLaunchSource.LaunchSwitch)]
    [InlineData(true, false, CaptureAtLaunchSource.UserSetting)]
    [InlineData(false, true, CaptureAtLaunchSource.LaunchSwitch)]
    [InlineData(false, false, CaptureAtLaunchSource.None)]
    public void TheSwitchOutranksTheUserSettingAndReportsItself(
        bool userEnabled, bool launchSwitch, CaptureAtLaunchSource expectedSource)
    {
        EffectiveCaptureAtLaunch effective = EffectiveCaptureAtLaunch.Resolve(
            Settings(userEnabled, paused: false), launchSwitch);

        Assert.Equal(expectedSource, effective.Source);
    }

    [Fact]
    public void CaptureAtLaunchSourceHasExactlyThreeMembersUntilHashSixtyAddsToIt()
    {
        // #60 adds InstallerPreference and ManagedPolicy above LaunchSwitch. Pinning the count
        // here makes that addition a deliberate, visible diff rather than a silent widening.
        Assert.Equal(3, Enum.GetValues<CaptureAtLaunchSource>().Length);
    }

    [Fact]
    public void ResolveRejectsANullSettingsArgument()
    {
        Assert.Throws<ArgumentNullException>(() => EffectiveCaptureAtLaunch.Resolve(null!, launchSwitchPresent: false));
    }
}
