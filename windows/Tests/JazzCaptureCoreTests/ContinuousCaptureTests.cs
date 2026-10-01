using JazzCaptureCore;

namespace JazzCaptureCoreTests;

public sealed class ContinuousCaptureTests
{
    [Fact]
    public void OnlyAnExplicitOptInEnablesStartupAndAnExistingPauseStillWins()
    {
        var settings = new HostSettings(Array.Empty<string>(), false, false, true);
        Assert.False(EffectiveCaptureAtLaunch.Resolve(settings, false).Enabled);
        settings = settings with { ContinuousCapture = true };
        var enabled = EffectiveCaptureAtLaunch.Resolve(settings, false);
        Assert.True(enabled.Enabled);
        Assert.False(enabled.Paused);
        var paused = EffectiveCaptureAtLaunch.Resolve(settings with { CaptureAtLaunchPaused = true }, false);
        Assert.True(paused.Paused);
        var malformed = EffectiveCaptureAtLaunch.Resolve(settings, false,
            new CaptureAtLaunchPolicy(CaptureAtLaunchPolicyValue.Malformed, CaptureAtLaunchPolicyValue.Absent));
        Assert.False(malformed.Enabled);
    }

    [Fact]
    public void RolloverRequiresACommitAndNeverResumesAPauseOrShutdown()
    {
        for (int bits = 0; bits < 16; bits++)
        {
            bool enabled = (bits & 1) != 0, committed = (bits & 2) != 0;
            bool paused = (bits & 4) != 0, terminating = (bits & 8) != 0;
            Assert.Equal(bits == 3, ContinuousCapture.ShouldContinue(enabled, committed, paused, terminating));
        }
        Assert.Equal(TimeSpan.FromMinutes(30), ContinuousCapture.PauseReminderInterval);
        for (int bits = 0; bits < 8; bits++)
            Assert.Equal(bits == 3, ContinuousCapture.ShouldRemind(
                (bits & 1) != 0, (bits & 2) != 0, (bits & 4) != 0));
    }
}
