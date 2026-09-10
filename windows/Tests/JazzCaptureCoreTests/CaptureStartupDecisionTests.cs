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
}
