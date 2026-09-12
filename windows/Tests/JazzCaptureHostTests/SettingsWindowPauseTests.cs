using JazzCapture;

namespace JazzCaptureHostTests;

/// <summary>
/// A Copilot review of #76 found a gap the plan's literal §3.6 code did not cover: on a profile
/// where the launch switch is present <em>and</em> the user's own preference was also on, saving
/// the Settings window with the checkbox unticked cleared a pause the switch alone still needed
/// -- silently resuming automatic capture on the next switched launch despite an explicit Stop,
/// exactly the override issue #76 scope 5 forbids. <see cref="SettingsWindow.ResolvePauseOnSave"/>
/// is the extracted pure decision behind <c>OnSave</c>'s pause handling, kept testable (via
/// <c>InternalsVisibleTo</c>) even though the window itself is WPF-host code this repository does
/// not otherwise unit test.
/// </summary>
public sealed class SettingsWindowPauseTests
{
    [Fact]
    public void ACheckedBoxAlwaysPreservesWhateverPauseIsOnRecord()
    {
        // Ticking (or leaving ticked) ignores everything else -- a checked box never itself
        // clears or sets a pause; only an explicit Stop/Start transition does that.
        Assert.False(SettingsWindow.ResolvePauseOnSave(checkedNow: true, priorEnabled: false, priorPaused: false, captureAtLaunchFromLaunchSwitch: false));
        Assert.True(SettingsWindow.ResolvePauseOnSave(checkedNow: true, priorEnabled: true, priorPaused: true, captureAtLaunchFromLaunchSwitch: false));
        Assert.True(SettingsWindow.ResolvePauseOnSave(checkedNow: true, priorEnabled: false, priorPaused: true, captureAtLaunchFromLaunchSwitch: true));
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
        // The bug this test guards: the switch still resolves Enabled to true on the next launch
        // regardless of this checkbox, so clearing the pause here would silently undo a Stop the
        // user chose. This is true whether or not the user's own preference was also on.
        Assert.True(SettingsWindow.ResolvePauseOnSave(checkedNow: false, priorEnabled: true, priorPaused: true, captureAtLaunchFromLaunchSwitch: true));
        Assert.True(SettingsWindow.ResolvePauseOnSave(checkedNow: false, priorEnabled: false, priorPaused: true, captureAtLaunchFromLaunchSwitch: true));
    }

    [Fact]
    public void UncheckingWithNoPriorPreferenceAndNoPauseStaysUnpaused()
    {
        // The ordinary unmanaged case: nothing to preserve, nothing to clear.
        Assert.False(SettingsWindow.ResolvePauseOnSave(checkedNow: false, priorEnabled: false, priorPaused: false, captureAtLaunchFromLaunchSwitch: false));
    }
}
