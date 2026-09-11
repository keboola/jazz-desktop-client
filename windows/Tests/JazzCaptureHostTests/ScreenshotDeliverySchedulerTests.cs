using JazzCapture;

namespace JazzCaptureHostTests;

/// <summary>
/// Ported from the closed <c>codex/68-screenshot-files</c> branch, whose scheduler and tests the
/// #72 review found sound as written. The only change issue #73 requires: the backoff between
/// failed drain passes is no longer a hardcoded, un-jittered <c>1&lt;&lt;attempt</c> seconds -- it
/// is computed by <see cref="ScreenshotUploadRetryPolicy.Delay"/> against
/// <see cref="ScreenshotDeliverySettings"/>, so these tests compute their expected delay the same
/// way rather than asserting a literal that the jitter would make wrong.
/// </summary>
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
                return Task.FromResult<TimeSpan?>(null); // Nothing staged -- nothing due.
            },
            Settings(),
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
                return Task.FromResult<TimeSpan?>(null);
            },
            Settings(),
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
        using var scheduler = new ScreenshotDeliveryScheduler(
            async _ =>
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
                return null;
            },
            Settings());

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
        ScreenshotDeliverySettings settings = Settings();
        TimeSpan expectedFirstBackoff = ScreenshotUploadRetryPolicy.Delay(
            1, ScreenshotDeliveryScheduler.DrainLoopBackoffIdentity, settings);

        int calls = 0;
        var delayEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var cancellationObserved = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var scheduler = new ScreenshotDeliveryScheduler(
            _ =>
            {
                Interlocked.Increment(ref calls);
                throw new IOException();
            },
            settings,
            async (span, cancellationToken) =>
            {
                Assert.Equal(expectedFirstBackoff, span);
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
        var scheduler = new ScreenshotDeliveryScheduler(
            async cancellationToken =>
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

                return null; // Unreachable at runtime; only here so the async lambda compiles as
                             // Func<CancellationToken, Task<TimeSpan?>>.
            },
            Settings());
        scheduler.Nudge();
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(2));

        Task disposing = Task.Run(scheduler.Dispose);
        await cancellationObserved.Task.WaitAsync(TimeSpan.FromSeconds(2));
        Assert.False(disposing.IsCompleted);

        release.SetResult();
        await disposing.WaitAsync(TimeSpan.FromSeconds(2));
    }

    /// <summary>
    /// Regression test for the defect this scheduler's whole sleep-until-due path exists to close
    /// (#74 review): before this fix, a drain pass that returned normally (as a retryable failure
    /// reported via <see cref="ScreenshotStagingArea.RecordRetry"/> always did) reset
    /// <c>attempt</c> to zero and left the loop with nothing to wait on -- <c>nudged</c> was never
    /// set again, so the <c>do/while</c> at the bottom of <c>RunAsync</c> simply exited. Nothing
    /// woke the scheduler again until some unrelated screenshot happened to stage and call
    /// <see cref="ScreenshotDeliveryScheduler.Nudge"/>. This models that exact shape -- the drain
    /// delegate returns normally with a non-null due time instead of throwing -- and asserts the
    /// scheduler sleeps for that span and runs a second pass with no external <c>Nudge()</c> at all,
    /// mirroring <see cref="RetryBackoffRunsAgainWithoutExternalNudge"/> but through the success
    /// path rather than a throw.
    /// </summary>
    [Fact]
    public async Task ARetryableFailuresDueTimeRearmsTheSchedulerWithoutExternalNudge()
    {
        TimeSpan due = TimeSpan.FromMilliseconds(250);
        int calls = 0;
        int delays = 0;
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var scheduler = new ScreenshotDeliveryScheduler(
            _ =>
            {
                if (Interlocked.Increment(ref calls) == 1)
                {
                    return Task.FromResult<TimeSpan?>(due);
                }

                done.TrySetResult();
                return Task.FromResult<TimeSpan?>(null);
            },
            Settings(),
            (span, _) =>
            {
                delays++;
                Assert.Equal(due, span);
                return Task.CompletedTask;
            });

        scheduler.Nudge();
        await done.Task.WaitAsync(TimeSpan.FromSeconds(2));

        Assert.Equal(2, calls);
        Assert.Equal(1, delays);
    }

    /// <summary>
    /// The sleep-until-due path must be cancellable by <see cref="ScreenshotDeliveryScheduler.Dispose"/>
    /// exactly like the drain-loop backoff path already is (see
    /// <see cref="DisposeCancelsBackoffWithoutAnotherDrain"/>): shutdown must not wait out an 8-second
    /// worst-case sleep, and a post-dispose nudge must start nothing.
    /// </summary>
    [Fact]
    public async Task DisposeCancelsASleepUntilDueWithoutAnotherDrain()
    {
        TimeSpan due = TimeSpan.FromSeconds(5);
        int calls = 0;
        var delayEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var cancellationObserved = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var scheduler = new ScreenshotDeliveryScheduler(
            _ =>
            {
                Interlocked.Increment(ref calls);
                return Task.FromResult<TimeSpan?>(due);
            },
            Settings(),
            async (span, cancellationToken) =>
            {
                Assert.Equal(due, span);
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

    private static ScreenshotDeliverySettings Settings() => new();
}
