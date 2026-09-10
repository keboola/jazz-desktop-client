using JazzCapture;

namespace JazzCaptureHostTests;

public sealed class ScreenshotDeliverySchedulerTests
{
    [Fact]
    public async Task NudgesCoalesceAndNeverRunConcurrentDrains()
    {
        int active = 0, maximum = 0, calls = 0; var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var scheduler = new ScreenshotDeliveryScheduler(async _ => { int now = Interlocked.Increment(ref active); maximum = Math.Max(maximum, now); Interlocked.Increment(ref calls); entered.TrySetResult(); await release.Task; Interlocked.Decrement(ref active); });
        scheduler.Nudge(); await entered.Task; scheduler.Nudge(); scheduler.Nudge(); release.SetResult();
        await Task.Delay(30); Assert.Equal(1, maximum); Assert.Equal(2, calls);
    }
    [Fact]
    public async Task FailureUsesInjectedBackoffAndCancellationStopsIt()
    {
        var delayed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); int calls = 0;
        using var scheduler = new ScreenshotDeliveryScheduler(_ => { calls++; throw new IOException(); }, (span, _) => { Assert.Equal(TimeSpan.FromSeconds(2), span); delayed.TrySetResult(); return Task.CompletedTask; });
        scheduler.Nudge(); await delayed.Task; await Task.Delay(20); Assert.True(calls >= 1);
    }
}
