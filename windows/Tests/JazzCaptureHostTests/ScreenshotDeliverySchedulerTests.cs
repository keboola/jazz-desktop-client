using JazzCapture;

namespace JazzCaptureHostTests;

public sealed class ScreenshotDeliverySchedulerTests
{
    [Fact]
    public async Task TerminalDrainCompletionDoesNotScheduleBackoff()
    {
        int calls = 0;
        int delays = 0;
        var completed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var scheduler = new ScreenshotDeliveryScheduler(
            _ =>
            {
                calls++;
                completed.TrySetResult(); // Represents a worker terminal-quarantine completion.
                return Task.CompletedTask;
            },
            (_, _) =>
            {
                delays++;
                return Task.CompletedTask;
            });

        scheduler.Nudge();
        await completed.Task.WaitAsync(TimeSpan.FromSeconds(2));

        Assert.Equal(1, calls);
        Assert.Equal(0, delays);
    }

    [Fact]
    public async Task RetryBackoffRunsAgainWithoutExternalNudge()
    {
        int calls = 0;
        int delays = 0;
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var scheduler = new ScreenshotDeliveryScheduler(
            _ =>
            {
                if (Interlocked.Increment(ref calls) == 1)
                {
                    throw new IOException();
                }

                done.TrySetResult();
                return Task.CompletedTask;
            },
            (_, _) =>
            {
                delays++;
                return Task.CompletedTask;
            });

        scheduler.Nudge();
        await done.Task.WaitAsync(TimeSpan.FromSeconds(2));

        Assert.Equal(2, calls);
        Assert.Equal(1, delays);
    }

    [Fact]
    public async Task NudgesCoalesceAndNeverRunConcurrentDrains()
    {
        int active = 0;
        int maximum = 0;
        int calls = 0;
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var secondCompleted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var scheduler = new ScreenshotDeliveryScheduler(async _ =>
        {
            int now = Interlocked.Increment(ref active);
            maximum = Math.Max(maximum, now);
            if (Interlocked.Increment(ref calls) == 1)
            {
                entered.TrySetResult();
                await release.Task;
            }
            else
            {
                secondCompleted.TrySetResult();
            }
            Interlocked.Decrement(ref active);
        });

        scheduler.Nudge();
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(2));
        scheduler.Nudge();
        scheduler.Nudge();
        release.SetResult();
        await secondCompleted.Task.WaitAsync(TimeSpan.FromSeconds(2));

        Assert.Equal(1, maximum);
        Assert.Equal(2, calls);
    }

    [Fact]
    public async Task DisposeCancelsBackoffWithoutAnotherDrain()
    {
        int calls = 0;
        var delayEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var cancellationObserved = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var scheduler = new ScreenshotDeliveryScheduler(
            _ =>
            {
                Interlocked.Increment(ref calls);
                throw new IOException();
            },
            async (span, cancellationToken) =>
            {
                Assert.Equal(TimeSpan.FromSeconds(2), span);
                delayEntered.TrySetResult();
                try
                {
                    await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                {
                    cancellationObserved.TrySetResult();
                    throw;
                }
            });

        scheduler.Nudge();
        await delayEntered.Task.WaitAsync(TimeSpan.FromSeconds(2));
        scheduler.Dispose();
        await cancellationObserved.Task.WaitAsync(TimeSpan.FromSeconds(2));
        scheduler.Nudge();
        await Task.Delay(20);

        Assert.Equal(1, calls);
    }

    [Fact]
    public async Task DisposeWaitsForCanceledDrainBeforeReturning()
    {
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var cancellationObserved = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var scheduler = new ScreenshotDeliveryScheduler(async cancellationToken =>
        {
            entered.TrySetResult();
            try
            {
                await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                cancellationObserved.TrySetResult();
                await release.Task;
                throw;
            }
        });
        scheduler.Nudge();
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(2));

        Task disposing = Task.Run(scheduler.Dispose);
        await cancellationObserved.Task.WaitAsync(TimeSpan.FromSeconds(2));
        Assert.False(disposing.IsCompleted);

        release.SetResult();
        await disposing.WaitAsync(TimeSpan.FromSeconds(2));
    }
}
