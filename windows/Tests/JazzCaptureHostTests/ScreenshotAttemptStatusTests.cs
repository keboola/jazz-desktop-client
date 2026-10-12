using JazzCapture.Capture;
using JazzCaptureCore;

namespace JazzCaptureHostTests;

/// <summary>
/// Pins how each screenshot failure surfaces as the exported <c>screenshot.status</c>: one exact
/// vocabulary value per cause, so a row with an empty <c>screenshot_id</c> always says why.
/// </summary>
public sealed class ScreenshotAttemptStatusTests
{
    [Theory]
    [InlineData(ScreenshotFailure.PriorRequestStillInFlight, "busy")]
    [InlineData(ScreenshotFailure.DeadlineExceeded, "timeout")]
    [InlineData(ScreenshotFailure.NoWindowAtTarget, "no_window_at_target")]
    [InlineData(ScreenshotFailure.OwnerMismatch, "owner_mismatch")]
    [InlineData(ScreenshotFailure.SourceUnavailable, "source_unavailable")]
    public void EveryFailureMapsToItsOwnStatus(ScreenshotFailure failure, string expected)
    {
        Assert.Equal(expected, new ScreenshotAttempt(null, failure).Status);
        Assert.Contains(expected, ScreenshotStatus.All);
    }

    [Fact]
    public void EveryFailureValueIsMapped()
    {
        foreach (ScreenshotFailure failure in Enum.GetValues<ScreenshotFailure>())
        {
            Assert.NotEqual(ScreenshotStatus.Unknown, new ScreenshotAttempt(null, failure).Status);
        }
    }

    [Fact]
    public void AnAttemptWithNeitherFrameNorReasonIsUnknown() =>
        Assert.Equal(ScreenshotStatus.Unknown, new ScreenshotAttempt(null, null).Status);
}
