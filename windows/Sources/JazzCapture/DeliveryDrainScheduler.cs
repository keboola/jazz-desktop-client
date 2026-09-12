namespace JazzCapture;

/// <summary>Coalesces detached delivery nudges into one cancellable worker. Shutdown cancels and
/// joins that worker before its shared transports may be disposed.</summary>
/// <remarks>
/// <para>
/// <b>Generalised from <c>ScreenshotDeliveryScheduler</c> (issue #48, §2.6).</b> That type -- itself
/// ported from the closed <c>codex/68-screenshot-files</c> branch and sound as written per the #72
/// review -- was entirely generic except that its <c>catch</c> branch called
/// <c>ScreenshotUploadRetryPolicy.Delay(attempt, DrainLoopBackoffIdentity, settings)</c> directly.
/// This type replaces that one call with a caller-supplied <see cref="backoff"/> delegate, so the
/// same scheduler now drives both the screenshot drain loop (backed by
/// <c>ScreenshotUploadRetryPolicy.Delay</c> and <c>ScreenshotUploadRetryPolicy.DrainLoopBackoffIdentity</c>)
/// and the event drain loop (backed by <see cref="EventStreamRetryPolicy.Delay"/> and
/// <see cref="EventStreamRetryPolicy.DrainLoopBackoffIdentity"/>) without knowing either policy
/// exists. This is a behaviour-preserving rename plus one generalisation, not a rewrite:
/// <c>ScreenshotDeliverySchedulerTests</c> stays green with only its construction and type-name
/// lines changed -- no assertion in that suite was altered.
/// </para>
/// <para>
/// <b>Two distinct delays, kept separate.</b> This class waits on two entirely different signals,
/// both funnelled through the same injectable <see cref="delay"/> so tests never sleep for real:
/// </para>
/// <list type="bullet">
/// <item><description>
/// <b>Drain-loop backoff</b> (the <c>catch</c> branch below): the whole pass threw -- e.g. the
/// transport itself is down -- so the loop backs off before trying the whole thing again, using
/// <see cref="backoff"/>. This is about the health of the loop, not any one item.
/// </description></item>
/// <item><description>
/// <b>Sleep-until-due</b> (the success branch below, driven by <c>drain</c>'s own return value): the
/// pass completed cleanly, but the caller's drain delegate reports that some item's own backoff will
/// not be due for a known span. Sleeping here for exactly that span and then treating the wake-up as
/// a self-nudge closes the gap where a retryable failure would otherwise never re-arm the drain loop
/// at all, without inventing a second timer or a second cancellation path.
/// </description></item>
/// </list>
/// <para>
/// <b>Known, accepted limitation.</b> A <see cref="Nudge"/> that arrives while this class is
/// sleeping-until-due does not shorten that sleep -- the newly staged/spooled item's own due time is
/// not compared against the sleep already in flight. This is accepted rather than fixed because: (1)
/// the drain-loop backoff branch already behaves identically; (2) for both current callers, the
/// activity event (or the screenshot's Files id) was already emitted immediately, well before this
/// sleep even begins -- only the background delivery attempt is delayed; and (3) shortening it would
/// need a per-iteration linked <see cref="CancellationTokenSource"/> that <see cref="Dispose"/> would
/// also have to track and not leak, which is machinery this worst case does not justify.
/// </para>
/// </remarks>
public sealed class DeliveryDrainScheduler : IDisposable, IAsyncDisposable
{
    private readonly Func<CancellationToken, Task<TimeSpan?>> drain;
    private readonly Func<int, TimeSpan> backoff;
    private readonly Func<TimeSpan, CancellationToken, Task> delay;
    private readonly CancellationTokenSource stop = new();
    private readonly object lifetime = new();
    private Task? worker;
    private Task? disposeTask;
    private bool disposed;
    private int running;
    private int nudged;
    private int attempt;

    public DeliveryDrainScheduler(
        Func<CancellationToken, Task<TimeSpan?>> drain,
        Func<int, TimeSpan> backoff,
        Func<TimeSpan, CancellationToken, Task>? delay = null)
    {
        this.drain = drain;
        this.backoff = backoff ?? throw new ArgumentNullException(nameof(backoff));
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
                        // Sleep-until-due: the pass succeeded, but the caller reports an item is not
                        // due again until `span` from now (see this class's remarks for why this is
                        // kept distinct from the drain-loop backoff below). Waking up from this
                        // sleep is treated as a self-nudge, exactly like the drain-loop backoff
                        // already does, so the loop condition below picks the next pass back up
                        // without any external caller having to call Nudge().
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
                    TimeSpan wait = backoff(attempt);
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
