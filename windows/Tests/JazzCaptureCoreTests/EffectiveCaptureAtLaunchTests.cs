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

        // A later manual start resumes it. AfterSuccessfulManualStart clears an existing pause
        // unconditionally (see its own remarks), so the second argument here is not actually
        // read; passed anyway for realism, matching what TrayHost.ToggleCapture supplies.
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

    /// <summary>
    /// A third-round Opus review finding on PR #80 (M-A): making
    /// <see cref="CaptureAtLaunchPreference.AfterSuccessfulManualStart"/> unconditional (the fix
    /// for M1 above) introduced a new way to lose a validly-recorded pause. A process with no
    /// switch and no user setting cannot see that <c>(enabled: false, paused: true)</c> was
    /// recorded by a switch on a *different* shortcut; if a manual Start there clears it (as it
    /// now unconditionally does) and a manual Stop right after cannot re-record it (because
    /// <see cref="CaptureAtLaunchPreference.AfterSuccessfulUserStop"/> is still correctly gated on
    /// <c>automaticStartConfigured</c>, which this process also cannot see), the pause is silently
    /// erased by an ordinary Start/Stop pair that has nothing to do with the switch.
    /// </summary>
    /// <remarks>
    /// This pins the exact sequence of Core calls <c>TrayHost.ToggleCapture</c>/<c>StopCapture</c>
    /// make -- it proves that sequence produces the right result, not that <c>TrayHost</c> itself
    /// calls it that way (that host-side wiring is untested WPF code, like everywhere else in this
    /// project; see <c>OnboardingWindowContentTests</c>' own class remarks for why). <c>TrayHost</c>
    /// remembers, for the process's own session only, that a Start just resumed a pause it did not
    /// itself configure, and ORs that into <c>automaticStartConfigured</c> for the next Stop -- so
    /// the pause this process resumed, it can also re-pause.
    /// </remarks>
    [Fact]
    public void AProcessThatResumesAPauseItCannotExplainCanRePauseItOnALaterStop()
    {
        HostSettings settings = new(Array.Empty<string>(), false, false, true, CaptureAtLaunchEnabled: false, CaptureAtLaunchPaused: true);
        const bool automaticStartConfigured = false; // this process has neither the switch nor the user setting

        // TrayHost.ToggleCapture's own check, before calling AfterSuccessfulManualStart: this
        // Start is the one resuming a pause it cannot itself explain only when its own effective
        // value is false yet a pause is already on record.
        bool resumedAPauseThisSession = !automaticStartConfigured && settings.CaptureAtLaunchPaused;
        Assert.True(resumedAPauseThisSession);

        HostSettings afterManualStart = CaptureAtLaunchPreference.AfterSuccessfulManualStart(
            settings, automaticStartConfigured);
        Assert.False(afterManualStart.CaptureAtLaunchPaused);

        // Without ORing in resumedAPauseThisSession, this Stop would see automaticStartConfigured
        // == false and silently fail to re-record the pause -- exactly the regression M-A found.
        HostSettings afterManualStop = CaptureAtLaunchPreference.AfterUserStopCompletion(
            afterManualStart, committed: true, automaticStartConfigured || resumedAPauseThisSession);
        Assert.True(afterManualStop.CaptureAtLaunchPaused);
    }

    /// <summary>
    /// A Copilot review finding on the M-A fix itself: the "resumed a pause I cannot explain"
    /// marker must not be set when this process's own effective value was already true at Start
    /// time -- the ordinary gated pause/resume already handles that case correctly, and setting
    /// the marker anyway would let a *later*, unrelated Stop manufacture a pause after the user
    /// has since turned their own preference off through Settings (see
    /// <c>TrayHost._resumedAPauseThisSession</c>'s remarks for the full scenario). This spells out
    /// the truth table for the exact boolean expression <c>TrayHost.ToggleCapture</c> assigns the
    /// marker from (<c>!automaticStartConfigured &amp;&amp; priorPaused</c>) as a readable
    /// specification, rather than exercising <c>TrayHost</c> itself, which this repository does
    /// not unit-test (WPF-host code; see <c>OnboardingWindowContentTests</c>' class remarks).
    /// </summary>
    [Theory]
    [InlineData(false, false, false)]
    [InlineData(false, true, true)]
    [InlineData(true, false, false)]
    [InlineData(true, true, false)]
    public void TheResumedPauseMarkerIsSetOnlyWhenThisProcessCouldNotItselfExplainThePause(
        bool automaticStartConfigured, bool priorPaused, bool expectedMarker)
    {
        bool resumedAPauseThisSession = !automaticStartConfigured && priorPaused;

        Assert.Equal(expectedMarker, resumedAPauseThisSession);
    }

    /// <summary>
    /// A second Copilot review finding on the M-A fix: the marker must not survive past the one
    /// Stop it was meant for. Simulates two independent Start/Stop pairs in the same process: the
    /// first is the genuine "cannot explain" case and correctly re-pauses; the second starts from
    /// an already-unpaused, already-configured profile (nothing to explain) and must not inherit
    /// the first pair's marker.
    /// </summary>
    [Fact]
    public void TheResumedPauseMarkerDoesNotSurviveIntoALaterUnrelatedStop()
    {
        HostSettings settings = new(Array.Empty<string>(), false, false, true, CaptureAtLaunchEnabled: false, CaptureAtLaunchPaused: true);

        // First pair: the genuine case, exactly as in the test above.
        bool firstMarker = !false && settings.CaptureAtLaunchPaused;
        HostSettings afterFirstStart = CaptureAtLaunchPreference.AfterSuccessfulManualStart(settings, automaticStartConfigured: false);
        HostSettings afterFirstStop = CaptureAtLaunchPreference.AfterUserStopCompletion(
            afterFirstStart, committed: true, automaticStartConfigured: false || firstMarker);
        Assert.True(afterFirstStop.CaptureAtLaunchPaused);
        // TrayHost.StopCapture consumes (reads, then resets to false) the marker on every Stop
        // attempt, committed or not -- simulated here by simply not carrying firstMarker forward.

        // Meanwhile, suppose the user ticked their own preference on through Settings (an off->on
        // tick always clears any pause -- SettingsWindow.ResolvePauseOnSave) and later turned it
        // back off (an untick never clears one). Net: enabled false again, paused false, and no
        // Start has happened since to legitimately re-arm the marker.
        HostSettings unrelatedProfile = afterFirstStop with { CaptureAtLaunchEnabled = false, CaptureAtLaunchPaused = false };

        // Second, unrelated Start: this process's own effective value is still false, but there is
        // no pause on record to resume, so the marker must compute false, not inherit `true` from
        // the first pair.
        bool secondMarker = !false && unrelatedProfile.CaptureAtLaunchPaused;
        Assert.False(secondMarker);

        HostSettings afterSecondStart = CaptureAtLaunchPreference.AfterSuccessfulManualStart(unrelatedProfile, automaticStartConfigured: false);
        HostSettings afterSecondStop = CaptureAtLaunchPreference.AfterUserStopCompletion(
            afterSecondStart, committed: true, automaticStartConfigured: false || secondMarker);

        // Nothing is configured and nothing was resumed: this Stop must not manufacture a pause.
        Assert.False(afterSecondStop.CaptureAtLaunchPaused);
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
