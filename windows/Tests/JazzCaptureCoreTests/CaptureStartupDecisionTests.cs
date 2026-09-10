using JazzCaptureCore;

namespace JazzCaptureCoreTests;

public sealed class CaptureStartupDecisionTests
{
    [Theory]
    [InlineData(true, true, true, true, false, true)]
    [InlineData(false, true, true, true, false, false)]
    [InlineData(true, false, true, true, false, false)]
    [InlineData(true, true, false, true, false, false)]
    [InlineData(true, true, true, false, false, false)]
    [InlineData(true, true, true, true, true, false)]
    public void StartsOnlyAfterEveryStartupSafetyCondition(
        bool ownsSingleInstance,
        bool initializationSucceeded,
        bool recoveryCompleted,
        bool captureAtLaunchEnabled,
        bool captureAtLaunchPaused,
        bool expected)
    {
        Assert.Equal(expected, CaptureStartupDecision.ShouldStart(
            ownsSingleInstance,
            initializationSucceeded,
            recoveryCompleted,
            captureAtLaunchEnabled,
            captureAtLaunchPaused));
    }

    [Fact]
    public void CredentialsAndLoginRegistrationAreNotDecisionInputs()
    {
        // The API's deliberately small signature is the policy: neither a device credential nor a
        // Run entry can manufacture consent to capture.
        Assert.False(CaptureStartupDecision.ShouldStart(
            ownsSingleInstance: true,
            initializationSucceeded: true,
            recoveryCompleted: true,
            captureAtLaunchEnabled: false,
            captureAtLaunchPaused: false));
    }

    [Fact]
    public void GateInvokesEnabledStartAtMostOnce()
    {
        var gate = new CaptureStartupGate();
        int starts = 0;

        Assert.True(gate.TryStart(true, true, true, true, false, () => { starts++; return true; }));
        Assert.False(gate.TryStart(true, true, true, true, false, () => { starts++; return true; }));
        Assert.Equal(1, starts);
    }

    [Fact]
    public void GateClosesAfterAnIneligibleEvaluation()
    {
        var gate = new CaptureStartupGate();
        int starts = 0;

        Assert.False(gate.TryStart(true, true, true, false, false, () => { starts++; return true; }));
        Assert.False(gate.TryStart(true, true, true, true, false, () => { starts++; return true; }));
        Assert.Equal(0, starts);
    }

    [Fact]
    public void GateClosesAfterAFailedStart()
    {
        var gate = new CaptureStartupGate();
        int starts = 0;

        Assert.False(gate.TryStart(true, true, true, true, false, () => { starts++; return false; }));
        Assert.False(gate.TryStart(true, true, true, true, false, () => { starts++; return true; }));
        Assert.Equal(1, starts);
    }

    [Fact]
    public void SuccessfulUserStopPausesAndSuccessfulManualStartResumes()
    {
        HostSettings enabled = new(Array.Empty<string>(), false, false, true, CaptureAtLaunchEnabled: true);

        HostSettings paused = CaptureAtLaunchPreference.AfterSuccessfulUserStop(enabled);
        Assert.True(paused.CaptureAtLaunchPaused);
        Assert.False(CaptureStartupDecision.ShouldStart(true, true, true, true, paused.CaptureAtLaunchPaused));

        HostSettings resumed = CaptureAtLaunchPreference.AfterSuccessfulManualStart(paused);
        Assert.False(resumed.CaptureAtLaunchPaused);
        Assert.True(CaptureStartupDecision.ShouldStart(true, true, true, true, resumed.CaptureAtLaunchPaused));
    }

    [Fact]
    public void DisabledPreferenceAndUncommittedStopDoNotManufacturePause()
    {
        HostSettings disabled = new(Array.Empty<string>(), false, false, true);
        HostSettings afterStop = CaptureAtLaunchPreference.AfterSuccessfulUserStop(disabled);

        Assert.False(afterStop.CaptureAtLaunchPaused);
        Assert.Equal(disabled, afterStop);

        HostSettings enabled = disabled with { CaptureAtLaunchEnabled = true };
        Assert.False(CaptureAtLaunchPreference.AfterUserStopCompletion(
            enabled, committed: false).CaptureAtLaunchPaused);
        Assert.False(CaptureAtLaunchPreference.AfterUserStopCompletion(
            enabled, committed: false).CaptureAtLaunchPaused);
    }
}
