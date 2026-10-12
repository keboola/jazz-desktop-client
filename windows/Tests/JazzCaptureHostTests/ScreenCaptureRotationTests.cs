using JazzCapture.Capture;
using JazzCaptureCore;
using JazzCaptureCore.Screen;

namespace JazzCaptureHostTests;

/// <summary>
/// Every session builds its own <see cref="ScreenCapture"/>, and an exemption change now rotates the
/// session. A physical capture that wedged in the old session is never cancelled, so the new
/// session's screenshot path must find the slot still taken rather than start a second capture
/// beside it.
/// </summary>
public sealed class ScreenCaptureRotationTests
{
    [Fact]
    public void AnOldSessionsBlockedCaptureStillHoldsTheSlotAfterARotation()
    {
        var owner = new AppIdentity(AppIdentity.ExecutablePathNamespace, "c:/tools/editor.exe", "Editor");
        using var occupied = new ManualResetEventSlim();
        using var release = new ManualResetEventSlim();

        // The old session's capture: wedged in the OS call, its caller long gone on its budget.
        _ = new ScreenCapture(new AppIdentityResolver(), () => DateTimeOffset.UtcNow);
        Task<SingleFlightResult<int>> wedged = Task.Run(() => PhysicalScreenshotSlot.Gate.Run(
            TimeSpan.FromMilliseconds(50),
            () =>
            {
                occupied.Set();
                release.Wait();
                return 0;
            }));

        try
        {
            Assert.True(occupied.Wait(TimeSpan.FromSeconds(10)));
            Assert.Equal(SingleFlightOutcome.TimedOut, wedged.Result.Outcome);

            // The rotation: a brand-new screenshot path for the new session.
            var newSession = new ScreenCapture(new AppIdentityResolver(), () => DateTimeOffset.UtcNow);
            ScreenshotAttempt attempt = newSession.CaptureWindow(
                owner, 0, new BoundingBox(0, 0, 1, 1), ApplicationDenylist.Empty);

            Assert.Null(attempt.Frame);
            Assert.Equal(ScreenshotFailure.PriorRequestStillInFlight, attempt.Failure);
        }
        finally
        {
            release.Set();
        }

        Assert.True(SpinWait.SpinUntil(() => !PhysicalScreenshotSlot.Gate.IsBusy, TimeSpan.FromSeconds(10)));
    }
}
