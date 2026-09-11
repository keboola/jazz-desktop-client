namespace JazzCapture;

/// <summary>Coalesces detached delivery nudges into one cancellable worker. Shutdown cancels and
/// joins that worker before its shared transports may be disposed.</summary>
/// <remarks>
/// Ported from the closed <c>codex/68-screenshot-files</c> branch (sound as written per the #72
/// review) with one change issue #73 requires: the backoff between failed drain passes no longer
/// hardcodes <c>1&lt;&lt;attempt</c> seconds with no jitter. It is now computed by
/// <see cref="ScreenshotUploadRetryPolicy.Delay"/> against <see cref="ScreenshotDeliverySettings"/>,
/// the same deterministic, jittered, configuration-driven schedule the background uploader uses for
/// one artifact's retries.
/// </remarks>
public sealed class ScreenshotDeliveryScheduler : IDisposable, IAsyncDisposable
{
    /// <summary>
    /// Stable identity fed to <see cref="ScreenshotUploadRetryPolicy.Delay"/> for this scheduler's
    /// own backoff. <see cref="ScreenshotUploadRetryPolicy"/> keys its jitter on an identity string
    /// so that, within one process lifetime, unrelated retry schedules do not synchronize on the
    /// same wall-clock millisecond. That identity is normally an artifact id because the policy's
    /// other caller (<see cref="ScreenshotStagingArea.RecordRetry"/>) is scheduling one artifact's
    /// next upload attempt. This scheduler's backoff is not about any one artifact -- it is about
    /// how soon the whole drain loop should try again after a pass failed outright (e.g. the
    /// transport itself threw) -- so there is no artifact id to key on, and a single fixed constant
    /// is used instead. Reusing the same constant every time is intentional: the only property this
    /// backoff needs is "do not busy-retry a loop that just failed," not "spread many independent
    /// schedules apart," which is already the per-artifact policy's job.
    /// </summary>
    public const string DrainLoopBackoffIdentity = "screenshot-delivery-scheduler/drain-loop";

    private readonly Func<CancellationToken, Task> drain;
    private readonly ScreenshotDeliverySettings settings;
    private readonly Func<TimeSpan, CancellationToken, Task> delay;
    private readonly CancellationTokenSource stop = new();
    private readonly object lifetime = new();
    private Task? worker;
    private Task? disposeTask;
    private bool disposed;
    private int running;
    private int nudged;
    private int attempt;

    public ScreenshotDeliveryScheduler(
        Func<CancellationToken, Task> drain,
        ScreenshotDeliverySettings settings,
        Func<TimeSpan, CancellationToken, Task>? delay = null)
    {
        this.drain = drain;
        this.settings = settings ?? throw new ArgumentNullException(nameof(settings));
        this.delay = delay ?? Task.Delay;
    }

    public void Nudge()
    {
        lock (lifetime)
        {
            if (disposed)
            {
                return;
            }

            Interlocked.Exchange(ref nudged, 1);
            if (Interlocked.CompareExchange(ref running, 1, 0) == 0)
            {
                worker = Task.Run(RunAsync);
            }
        }
    }
    private async Task RunAsync()
    {
        try
        {
            do
            {
                Interlocked.Exchange(ref nudged, 0);
                try
                {
                    await drain(stop.Token).ConfigureAwait(false);
                    attempt = 0;
                }
                catch (OperationCanceledException) when (stop.IsCancellationRequested)
                {
                    break;
                }
                catch
                {
                    attempt++;
                    TimeSpan wait = ScreenshotUploadRetryPolicy.Delay(attempt, DrainLoopBackoffIdentity, settings);
                    try
                    {
                        await delay(wait, stop.Token).ConfigureAwait(false);
                        Interlocked.Exchange(ref nudged, 1);
                    }
                    catch (OperationCanceledException) when (stop.IsCancellationRequested)
                    {
                        break;
                    }
                }
            }
            while (Volatile.Read(ref nudged) != 0 && !stop.IsCancellationRequested);
        }
        finally
        {
            Interlocked.Exchange(ref running, 0);
            if (Volatile.Read(ref nudged) != 0 && !stop.IsCancellationRequested)
            {
                Nudge();
            }
        }
    }
    public void Dispose()
        => DisposeAsync().AsTask().GetAwaiter().GetResult();

    public ValueTask DisposeAsync()
    {
        lock (lifetime)
        {
            if (disposeTask is not null)
            {
                return new ValueTask(disposeTask);
            }

            disposed = true;
            stop.Cancel();
            disposeTask = CompleteDisposeAsync(worker);
            return new ValueTask(disposeTask);
        }
    }

    private async Task CompleteDisposeAsync(Task? pending)
    {
        if (pending is not null)
        {
            try
            {
                await pending.ConfigureAwait(false);
            }
            catch
            {
                // RunAsync contains transport failures; shutdown still owns final disposal if an
                // unexpected worker exception escapes.
            }
        }
        stop.Dispose();
    }
}
