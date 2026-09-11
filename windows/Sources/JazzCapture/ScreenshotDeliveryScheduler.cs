namespace JazzCapture;

/// <summary>Coalesces detached delivery nudges into one cancellable worker. Shutdown cancels and
/// joins that worker before its shared transports may be disposed.</summary>
/// <remarks>
/// <para>
/// Ported from the closed <c>codex/68-screenshot-files</c> branch (sound as written per the #72
/// review) with one change issue #73 requires: the backoff between failed drain passes no longer
/// hardcodes <c>1&lt;&lt;attempt</c> seconds with no jitter. It is now computed by
/// <see cref="ScreenshotUploadRetryPolicy.Delay"/> against <see cref="ScreenshotDeliverySettings"/>,
/// the same deterministic, jittered, configuration-driven schedule the background uploader uses for
/// one artifact's retries.
/// </para>
/// <para>
/// <b>Two distinct delays, kept separate.</b> This class waits on two entirely different signals,
/// both funnelled through the same injectable <see cref="delay"/> so tests never sleep for real:
/// </para>
/// <list type="bullet">
/// <item><description>
/// <b>Drain-loop backoff</b> (the <c>catch</c> branch below, keyed by
/// <see cref="DrainLoopBackoffIdentity"/>): the whole pass threw -- e.g. the transport itself is
/// down -- so the loop backs off before trying the whole thing again. This is about the health of
/// the loop, not any one screenshot.
/// </description></item>
/// <item><description>
/// <b>Sleep-until-due</b> (the success branch below, driven by <c>drain</c>'s own return value): the
/// pass completed cleanly, but <see cref="ScreenshotDeliveryWorker.DrainOnceAsync"/> reports that a
/// staged entry's own <see cref="ScreenshotUploadRetryPolicy"/> backoff (set by
/// <see cref="ScreenshotStagingArea.RecordRetry"/>) will not be due for some known span. This is what
/// closes the defect where a retryable upload failure previously never re-armed the drain loop at
/// all -- nothing else in the process was guaranteed to call <see cref="Nudge"/> again once whatever
/// staged the failing entry had finished. Sleeping here for exactly that span and then treating the
/// wake-up as a self-nudge (identical to the drain-loop backoff's own "then nudge" shape) closes it
/// without inventing a second timer or a second cancellation path.
/// </description></item>
/// </list>
/// <para>
/// <b>Known, accepted limitation.</b> A <see cref="Nudge"/> that arrives while this class is
/// sleeping-until-due does not shorten that sleep -- the newly staged screenshot's own due time is
/// not compared against the sleep already in flight. In the worst case a freshly staged screenshot
/// waits up to <see cref="ScreenshotDeliverySettings.UploadBackoffCeiling"/> (8 seconds by default)
/// behind a stale backoff from some other entry. This is accepted rather than fixed because: (1) the
/// drain-loop backoff branch already behaves identically and has since the closed branch this was
/// ported from; (2) the activity event carrying the screenshot's Files id has already been emitted
/// by the time anything is staged -- only the byte upload itself is delayed; and (3) shortening it
/// would need a per-iteration linked <see cref="CancellationTokenSource"/> that
/// <see cref="Dispose"/> would also have to track and not leak, which is machinery this 8-second
/// worst case does not justify.
/// </para>
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

    private readonly Func<CancellationToken, Task<TimeSpan?>> drain;
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
        Func<CancellationToken, Task<TimeSpan?>> drain,
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
                    TimeSpan? due = await drain(stop.Token).ConfigureAwait(false);
                    attempt = 0;

                    if (due is { } span)
                    {
                        // Sleep-until-due: the pass succeeded, but the staging area reports an
                        // entry is not due again until `span` from now (see this class's remarks
                        // for why this is kept distinct from the drain-loop backoff below). Waking
                        // up from this sleep is treated as a self-nudge, exactly like the
                        // drain-loop backoff already does, so the loop condition below picks the
                        // next pass back up without any external caller having to call Nudge().
                        try
                        {
                            await delay(span, stop.Token).ConfigureAwait(false);
                            Interlocked.Exchange(ref nudged, 1);
                        }
                        catch (OperationCanceledException) when (stop.IsCancellationRequested)
                        {
                            break;
                        }
                    }
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
