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
