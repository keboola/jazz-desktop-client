using JazzCapture;

namespace JazzCaptureHostTests;

/// <summary>
/// Two review findings on PR #80 (issue #76) landed on <see cref="SettingsWindow.ResolvePauseOnSave"/>,
/// the extracted pure decision behind <c>OnSave</c>'s pause handling -- kept testable (via
/// <c>InternalsVisibleTo</c>) even though the window itself is WPF-host code this repository does
/// not otherwise unit test.
/// </summary>
/// <remarks>
/// <para>
/// <b>Copilot's finding (H1b / M6-adjacent):</b> unchecking the box on a profile where the launch
/// switch is present and the user's own preference was also on cleared a pause the switch alone
/// still needed, silently resuming automatic capture after an explicit Stop -- exactly the
/// override issue #76 scope 5 forbids.
/// </para>
/// <para>
/// <b>The Opus reviewer's follow-up finding (H1a):</b> the fix for H1b did not re-examine the
/// checked branch. On a profile the switch alone had already made reachable --
/// <c>(CaptureAtLaunchEnabled: false, CaptureAtLaunchPaused: true)</c> -- the status window's own
/// copy tells the user to tick "Start local capture automatically when Jazz opens" to start it on
/// its own. Ticking that exact box and saving preserved the pause verbatim, landing the user in a
/// permanently paused state with no UI path back out. Ticking the box is now treated as an
/// unconditional resume, symmetric with <c>CaptureAtLaunchPreference.AfterSuccessfulManualStart</c>
/// treating a manual "Start capture" the same way.
/// </para>
/// </remarks>
public sealed class SettingsWindowPauseTests
{
    [Fact]
    public void TickingTheBoxOnForTheFirstTimeAlwaysResumes()
    {
        // The H1a regression: (enabled: false, paused: true) is the exact state a switch-only
        // Stop leaves behind, and the status window tells this user to tick this very box. It
        // must not leave them paused forever.
        Assert.False(SettingsWindow.ResolvePauseOnSave(checkedNow: true, priorEnabled: false, priorPaused: true, captureAtLaunchFromLaunchSwitch: false));
        Assert.False(SettingsWindow.ResolvePauseOnSave(checkedNow: true, priorEnabled: false, priorPaused: true, captureAtLaunchFromLaunchSwitch: true));
        // Already unpaused: still false, trivially.
        Assert.False(SettingsWindow.ResolvePauseOnSave(checkedNow: true, priorEnabled: false, priorPaused: false, captureAtLaunchFromLaunchSwitch: false));
    }

    [Fact]
    public void LeavingTheBoxCheckedPreservesWhateverPauseIsOnRecord()
    {
        // No transition in the user's own preference (it was already on and stays on) -- only an
        // explicit Stop/Start transition, or the off->on tick above, may change the pause here.
        Assert.True(SettingsWindow.ResolvePauseOnSave(checkedNow: true, priorEnabled: true, priorPaused: true, captureAtLaunchFromLaunchSwitch: false));
        Assert.False(SettingsWindow.ResolvePauseOnSave(checkedNow: true, priorEnabled: true, priorPaused: false, captureAtLaunchFromLaunchSwitch: false));
    }

    [Fact]
    public void UncheckingWithNoLaunchSwitchAndAPriorPreferenceClearsAStalePause()
    {
        // The pre-#76 behaviour, still correct when the switch is absent: nothing is left asking
        // for automatic start, so a leftover pause is stale and clearing it is harmless.
        Assert.False(SettingsWindow.ResolvePauseOnSave(checkedNow: false, priorEnabled: true, priorPaused: true, captureAtLaunchFromLaunchSwitch: false));
    }

    [Fact]
    public void UncheckingWithTheLaunchSwitchPresentNeverClearsThePause()
    {
        // Copilot's H1b: the switch still resolves Enabled to true on the next launch regardless
        // of this checkbox, so clearing the pause here would silently undo a Stop the user chose.
        // True whether or not the user's own preference was also on.
        Assert.True(SettingsWindow.ResolvePauseOnSave(checkedNow: false, priorEnabled: true, priorPaused: true, captureAtLaunchFromLaunchSwitch: true));
        Assert.True(SettingsWindow.ResolvePauseOnSave(checkedNow: false, priorEnabled: false, priorPaused: true, captureAtLaunchFromLaunchSwitch: true));
    }

    [Fact]
    public void UncheckingWithNoPriorPreferenceAndNoPauseStaysUnpaused()
    {
        // The ordinary unmanaged case: nothing to preserve, nothing to clear.
        Assert.False(SettingsWindow.ResolvePauseOnSave(checkedNow: false, priorEnabled: false, priorPaused: false, captureAtLaunchFromLaunchSwitch: false));
    }

    [Fact]
    public void UncheckingWithNoPriorPreferenceLeavesAnExistingPauseAlone()
    {
        // The box was already unchecked (no real transition) and a pause exists only because the
        // switch put it there on a previous launch; whether or not the switch is present in *this*
        // dialog session, there is no off->on or on->off transition of the user's own preference
        // to react to, so the pause is left exactly as it was.
        Assert.True(SettingsWindow.ResolvePauseOnSave(checkedNow: false, priorEnabled: false, priorPaused: true, captureAtLaunchFromLaunchSwitch: false));
    }
}
