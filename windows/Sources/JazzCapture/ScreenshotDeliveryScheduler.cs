namespace JazzCapture;

/// <summary>Coalesces detached delivery nudges into one cancellable worker. It intentionally never
/// joins the worker on shutdown: capture completion must not wait for a network operation.</summary>
public sealed class ScreenshotDeliveryScheduler : IDisposable
{
    private readonly Func<CancellationToken, Task> drain;
    private readonly Func<TimeSpan, CancellationToken, Task> delay;
    private readonly CancellationTokenSource stop = new();
    private readonly object lifetime = new();
    private Task? worker;
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
    {
        Task? pending;
        lock (lifetime)
        {
            if (disposed)
            {
                return;
            }

            disposed = true;
            stop.Cancel();
            pending = worker;
        }

        if (pending is null)
        {
            stop.Dispose();
            return;
        }

        _ = pending.ContinueWith(
            _ => stop.Dispose(),
            CancellationToken.None,
            TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);
    }
}
