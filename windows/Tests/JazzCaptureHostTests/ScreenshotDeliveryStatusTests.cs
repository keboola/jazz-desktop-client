using JazzCapture;
using JazzCaptureCore;

namespace JazzCaptureHostTests;

public sealed class ScreenshotDeliveryStatusTests
{
    [Theory]
    [InlineData(true, false)]
    [InlineData(false, true)]
    public void CaptureStartupTransitionDefersJournalReconciliation(bool starting, bool running)
    {
        Assert.True(TrayHost.IsCaptureTransitionActive(starting, running));
        Assert.False(TrayHost.IsCaptureTransitionActive(false, false));
    }

    [Fact]
    public void ScreenshotArtifactsWaitForFilesBindingWhileCanonicalEventsStayUnchanged()
    {
        var ordinary = new ActivityEvent { ScreenshotId = null };

        Assert.True(TrayHost.ShouldSendCapturedEventDirectly(ordinary));
        Assert.False(TrayHost.ShouldSendCapturedEventDirectly(new ActivityEvent { ScreenshotId = "legacy-id" }));
    }

    [Theory]
    [InlineData(ScreenshotDeliveryStatus.NotProvisioned, 0, "not provisioned")]
    [InlineData(ScreenshotDeliveryStatus.Uploading, 2, "uploading 2")]
    [InlineData(ScreenshotDeliveryStatus.Retrying, 3, "retrying 3")]
    [InlineData(ScreenshotDeliveryStatus.Streaming, 0, "up to date")]
    [InlineData(ScreenshotDeliveryStatus.Quarantined, 1, "quarantined")]
    public void RendersOnlySafeStateAndCount(
        ScreenshotDeliveryStatus state,
        int count,
        string expected)
    {
        string text = new ScreenshotDeliveryPresentation(state, count).Describe();

        Assert.Equal(expected, text);
        Assert.DoesNotContain("secret", text, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("https", text, StringComparison.OrdinalIgnoreCase);
    }
}
