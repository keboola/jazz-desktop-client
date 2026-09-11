namespace JazzCapture;

/// <summary>Coalesces detached delivery nudges into one cancellable worker. Shutdown cancels and
/// joins that worker before its shared transports may be disposed.</summary>
public sealed class ScreenshotDeliveryScheduler : IDisposable, IAsyncDisposable
{
    private readonly Func<CancellationToken, Task> drain;
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
        Func<TimeSpan, CancellationToken, Task>? delay = null)
    {
        this.drain = drain;
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
                    attempt = Math.Min(attempt + 1, 6);
                    try
                    {
                        await delay(
                            TimeSpan.FromSeconds(1 << attempt),
                            stop.Token).ConfigureAwait(false);
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
