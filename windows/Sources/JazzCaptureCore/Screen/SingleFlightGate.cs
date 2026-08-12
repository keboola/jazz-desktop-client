using System.Runtime.ExceptionServices;

namespace JazzCaptureCore.Screen;

/// <summary>How a <see cref="SingleFlightGate"/> call ended.</summary>
public enum SingleFlightOutcome
{
    /// <summary>The operation ran and returned within the budget.</summary>
    Completed,

    /// <summary>The budget elapsed first. The operation is still running.</summary>
    TimedOut,

    /// <summary>An earlier operation still holds the slot; nothing was started.</summary>
    Busy,
}

/// <summary>What one <see cref="SingleFlightGate"/> call produced.</summary>
/// <typeparam name="T">The operation's result type.</typeparam>
/// <param name="Outcome">How the call ended.</param>
/// <param name="Value">The result; only meaningful when the outcome is completed.</param>
public readonly record struct SingleFlightResult<T>(SingleFlightOutcome Outcome, T? Value);

/// <summary>
/// Owns one admission slot for an expensive OS operation, process-wide.
/// </summary>
/// <remarks>
/// <para>
/// Acquisition is non-blocking on purpose. A screenshot is local enrichment of an event that has
/// already happened; queueing requests behind a slow one would trade a missing picture for an
/// unbounded backlog of pending captures, each holding an admitted journal producer open. Callers
/// that arrive while the slot is held fail immediately with <see cref="SingleFlightOutcome.Busy"/>.
/// </para>
/// <para>
/// A caller may give up on its budget, but the physical operation is never cancelled: the OS call
/// is already in flight and several capture paths return from cancellation before their real work
/// has settled. The slot is released by the operation's actual return, so a wedged OS call costs one
/// thread and one request rather than a growing pile of them.
/// </para>
/// </remarks>
public sealed class SingleFlightGate
{
    private int _held;
    private long _admittedOperations;

    /// <summary>Whether an operation currently holds the slot.</summary>
    public bool IsBusy => Volatile.Read(ref _held) != 0;

    /// <summary>How many operations the gate has admitted; a diagnostic, not a control.</summary>
    public long AdmittedOperations => Interlocked.Read(ref _admittedOperations);

    /// <summary>
    /// Runs <paramref name="operation"/> on a worker if the slot is free, waiting at most
    /// <paramref name="budget"/> for it.
    /// </summary>
    /// <typeparam name="T">The operation's result type.</typeparam>
    /// <param name="budget">Longest the caller will wait.</param>
    /// <param name="operation">The work; runs off the calling thread.</param>
    /// <exception cref="Exception">
    /// Whatever the operation threw, rethrown with its original stack once it has returned within
    /// the budget. A failure after the budget elapsed is observed and dropped: nobody is left to
    /// report it to, and an unobserved task exception would surface later as an unrelated crash.
    /// </exception>
    public SingleFlightResult<T> Run<T>(TimeSpan budget, Func<T> operation)
    {
        ArgumentNullException.ThrowIfNull(operation);

        if (Interlocked.CompareExchange(ref _held, 1, 0) != 0)
        {
            return new SingleFlightResult<T>(SingleFlightOutcome.Busy, default);
        }

        Interlocked.Increment(ref _admittedOperations);
        Task<T> physical = Task.Run(() =>
        {
            try
            {
                return operation();
            }
            finally
            {
                Volatile.Write(ref _held, 0);
            }
        });

        // Attached before the wait: if the budget elapses the caller walks away, and a later fault
        // would otherwise be an unobserved task exception.
        _ = physical.ContinueWith(
            faulted => _ = faulted.Exception,
            CancellationToken.None,
            TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);

        try
        {
            if (!physical.Wait(budget))
            {
                return new SingleFlightResult<T>(SingleFlightOutcome.TimedOut, default);
            }
        }
        catch (AggregateException error) when (error.InnerException is { } inner)
        {
            ExceptionDispatchInfo.Capture(inner).Throw();
        }

        return new SingleFlightResult<T>(SingleFlightOutcome.Completed, physical.Result);
    }
}
