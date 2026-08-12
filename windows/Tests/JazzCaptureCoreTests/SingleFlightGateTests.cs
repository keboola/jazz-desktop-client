using JazzCaptureCore.Screen;

namespace JazzCaptureCoreTests;

/// <summary>
/// Pins the one physical capture slot: a non-blocking acquire, a budget the caller can walk away
/// from, and a slot that only the real operation releases.
/// </summary>
public sealed class SingleFlightGateTests
{
    private static readonly TimeSpan Budget = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan ShortBudget = TimeSpan.FromMilliseconds(50);
    private static readonly TimeSpan Generous = TimeSpan.FromSeconds(10);

    [Fact]
    public void AFreeSlotRunsTheOperationAndReturnsItsValue()
    {
        var gate = new SingleFlightGate();

        SingleFlightResult<int> result = gate.Run(Budget, () => 7);

        Assert.Equal(SingleFlightOutcome.Completed, result.Outcome);
        Assert.Equal(7, result.Value);
        Assert.False(gate.IsBusy);
        Assert.Equal(1, gate.AdmittedOperations);
    }

    /// <summary>
    /// The rule the whole type exists for: a second caller fails immediately rather than queueing.
    /// A pile of pending screenshots would each hold an admitted journal producer open, so the
    /// backlog would cost the capture rather than just the frame.
    /// </summary>
    [Fact]
    public async Task ASecondCallerFailsFastInsteadOfQueueing()
    {
        var gate = new SingleFlightGate();
        using var occupied = new ManualResetEventSlim();
        using var release = new ManualResetEventSlim();

        Task<SingleFlightResult<int>> first = Task.Run(() => gate.Run(Generous, () =>
        {
            occupied.Set();
            release.Wait();
            return 1;
        }));

        Assert.True(occupied.Wait(Generous));
        Assert.True(gate.IsBusy);

        SingleFlightResult<int> second = gate.Run(Generous, () => 2);
        Assert.Equal(SingleFlightOutcome.Busy, second.Outcome);

        // The refused caller never started an operation, so it never took an admission either.
        Assert.Equal(1, gate.AdmittedOperations);

        release.Set();
        Assert.Equal(SingleFlightOutcome.Completed, (await first).Outcome);
    }

    [Fact]
    public void ACallerThatRunsOutOfBudgetTimesOut()
    {
        var gate = new SingleFlightGate();
        using var release = new ManualResetEventSlim();

        try
        {
            SingleFlightResult<int> result = gate.Run(ShortBudget, () =>
            {
                release.Wait();
                return 1;
            });

            Assert.Equal(SingleFlightOutcome.TimedOut, result.Outcome);

            // The slot is still held: the OS call is genuinely still in flight, and pretending
            // otherwise would let a second request pile onto a wedged one.
            Assert.True(gate.IsBusy);
            Assert.Equal(SingleFlightOutcome.Busy, gate.Run(ShortBudget, () => 2).Outcome);
        }
        finally
        {
            release.Set();
        }
    }

    [Fact]
    public void TheSlotReopensWhenTheAbandonedOperationReallyReturns()
    {
        var gate = new SingleFlightGate();
        using var release = new ManualResetEventSlim();

        Assert.Equal(
            SingleFlightOutcome.TimedOut,
            gate.Run(ShortBudget, () =>
            {
                release.Wait();
                return 1;
            }).Outcome);

        release.Set();
        Assert.True(SpinWait.SpinUntil(() => !gate.IsBusy, Generous));
        Assert.Equal(SingleFlightOutcome.Completed, gate.Run(Budget, () => 3).Outcome);
    }

    [Fact]
    public void AFailingOperationReleasesTheSlotAndRethrows()
    {
        var gate = new SingleFlightGate();

        Assert.Throws<InvalidOperationException>(
            () => gate.Run<int>(Budget, () => throw new InvalidOperationException("capture blew up")));

        Assert.False(gate.IsBusy);
        Assert.Equal(SingleFlightOutcome.Completed, gate.Run(Budget, () => 5).Outcome);
    }

    /// <summary>
    /// A late failure has nobody to report to. It must be observed all the same, or the runtime
    /// surfaces it later as an unrelated unhandled exception.
    /// </summary>
    [Fact]
    public void AFailureAfterTheBudgetElapsedIsObservedAndDropped()
    {
        var gate = new SingleFlightGate();
        using var release = new ManualResetEventSlim();

        Assert.Equal(
            SingleFlightOutcome.TimedOut,
            gate.Run<int>(ShortBudget, () =>
            {
                release.Wait();
                throw new InvalidOperationException("late failure");
            }).Outcome);

        release.Set();
        Assert.True(SpinWait.SpinUntil(() => !gate.IsBusy, Generous));

        GC.Collect();
        GC.WaitForPendingFinalizers();
        Assert.Equal(SingleFlightOutcome.Completed, gate.Run(Budget, () => 11).Outcome);
    }

    [Fact]
    public void ManyConcurrentCallersAdmitExactlyOneAtATime()
    {
        var gate = new SingleFlightGate();
        int concurrent = 0;
        int peak = 0;

        Parallel.For(0, 64, _ => gate.Run(Generous, () =>
        {
            int now = Interlocked.Increment(ref concurrent);
            InterlockedMax(ref peak, now);
            Thread.Sleep(1);
            Interlocked.Decrement(ref concurrent);
            return 0;
        }));

        Assert.Equal(1, peak);
    }

    private static void InterlockedMax(ref int target, int value)
    {
        int seen = Volatile.Read(ref target);
        while (value > seen)
        {
            int previous = Interlocked.CompareExchange(ref target, value, seen);
            if (previous == seen)
            {
                return;
            }

            seen = previous;
        }
    }
}
