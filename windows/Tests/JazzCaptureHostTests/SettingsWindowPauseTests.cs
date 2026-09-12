using JazzCapture;

namespace JazzCaptureHostTests;

/// <summary>
/// Three review findings on PR #80 (issue #76) landed on <see cref="SettingsWindow.ResolvePauseOnSave"/>,
/// the extracted pure decision behind <c>OnSave</c>'s pause handling -- kept testable (via
/// <c>InternalsVisibleTo</c>) even though the window itself is WPF-host code this repository does
/// not otherwise unit test.
/// </summary>
/// <remarks>
/// <para>
/// <b>Copilot's finding:</b> unchecking the box on a profile where the launch switch is present
/// and the user's own preference was also on cleared a pause the switch alone still needed,
/// silently resuming automatic capture after an explicit Stop -- exactly the override issue #76
/// scope 5 forbids.
/// </para>
/// <para>
/// <b>An Opus reviewer's first follow-up finding:</b> the fix for that did not re-examine the
/// checked branch. On a profile the switch alone had already made reachable --
/// <c>(CaptureAtLaunchEnabled: false, CaptureAtLaunchPaused: true)</c> -- the status window's own
/// copy tells the user to tick "Start local capture automatically when Jazz opens" to start it on
/// its own. Ticking that exact box and saving preserved the pause verbatim, landing the user in a
/// permanently paused state with no UI path back out.
/// </para>
/// <para>
/// <b>A second Opus follow-up finding:</b> the fix for the Copilot finding gated the untick-clears
/// decision on whether *this process* carried the launch switch -- but the switch is deliberately
/// process-scoped, so a process with no switch proves nothing about whether some other shortcut on
/// the same profile carries one. On an MSI-installed machine the plain Start Menu shortcut and the
/// HKCU Run value both carry no switch, so "this process has no switch" is the *common* case, not
/// an edge case -- unticking the box there and saving would still have silently cleared a pause a
/// switch elsewhere on the same profile still needed. The fix removes the untick-clears path
/// entirely: only an explicit fresh *on* choice (ticking this box, or a manual "Start capture") may
/// ever clear a pause; unticking never does, in either direction, and this is safe because
/// <c>(enabled: false, paused: true)</c> is inert until one of those two resumes happens.
/// </para>
/// </remarks>
public sealed class SettingsWindowPauseTests
{
    [Fact]
    public void TickingTheBoxOnForTheFirstTimeAlwaysResumes()
    {
        // The regression: (enabled: false, paused: true) is the exact state a Stop leaves behind
        // on a switch-configured profile, and the status window tells this user to tick this very
        // box. It must not leave them paused forever.
        Assert.False(SettingsWindow.ResolvePauseOnSave(checkedNow: true, priorEnabled: false, priorPaused: true));
        // Already unpaused: still false, trivially.
        Assert.False(SettingsWindow.ResolvePauseOnSave(checkedNow: true, priorEnabled: false, priorPaused: false));
    }

    [Fact]
    public void LeavingTheBoxCheckedPreservesWhateverPauseIsOnRecord()
    {
        // No transition in the user's own preference (it was already on and stays on) -- only the
        // off->on tick above, or a manual Start/Stop transition elsewhere, may change the pause.
        Assert.True(SettingsWindow.ResolvePauseOnSave(checkedNow: true, priorEnabled: true, priorPaused: true));
        Assert.False(SettingsWindow.ResolvePauseOnSave(checkedNow: true, priorEnabled: true, priorPaused: false));
    }

    [Fact]
    public void UncheckingNeverClearsAPauseRegardlessOfPriorPreference()
    {
        // The second Opus finding: unticking must never clear a pause, because this process
        // cannot know whether some other shortcut on the same profile still carries the launch
        // switch. Preserved in every combination of prior enabled/disabled.
        Assert.True(SettingsWindow.ResolvePauseOnSave(checkedNow: false, priorEnabled: true, priorPaused: true));
        Assert.True(SettingsWindow.ResolvePauseOnSave(checkedNow: false, priorEnabled: false, priorPaused: true));
        Assert.False(SettingsWindow.ResolvePauseOnSave(checkedNow: false, priorEnabled: true, priorPaused: false));
        Assert.False(SettingsWindow.ResolvePauseOnSave(checkedNow: false, priorEnabled: false, priorPaused: false));
    }
}
