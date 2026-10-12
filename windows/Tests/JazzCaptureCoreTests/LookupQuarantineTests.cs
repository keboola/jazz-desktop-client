using JazzCaptureCore.Accessibility;

namespace JazzCaptureCoreTests;

/// <summary>
/// Pins the expiring quarantine behind the Windows page-URL and selection reads (issue #111): a slow
/// or failing provider costs a bounded, growing pause for that one key, and the read comes back on its
/// own once the provider answers again.
/// </summary>
public sealed class LookupQuarantineTests
{
    private static readonly TimeSpan Budget = TimeSpan.FromMilliseconds(150);
    private static readonly TimeSpan Tick = TimeSpan.FromTicks(1);

    private static readonly LookupQuarantineOptions Options = new(
        initialBackoff: TimeSpan.FromSeconds(30),
        maxBackoff: TimeSpan.FromMinutes(5),
        capacity: 256,
        idleRetention: TimeSpan.FromMinutes(30));

    private readonly ManualClock _clock = new();

    private LookupQuarantine<string> Create(LookupQuarantineOptions? options = null) =>
        new(options ?? Options, _clock);

    /// <summary>Runs one lookup on <paramref name="key"/> that ends in <paramref name="outcome"/>.</summary>
    private static void Run(LookupQuarantine<string> quarantine, string key, LookupOutcome outcome)
    {
        LookupAttempt<string> attempt = quarantine.TryBegin(key, Budget)
            ?? throw new InvalidOperationException($"{key} was not admitted.");
        Assert.True(attempt.TryStart());
        attempt.Complete(outcome);
    }

    /// <summary>Asserts the key is refused until exactly <paramref name="cooldown"/> has passed.</summary>
    private void AssertCooldown(LookupQuarantine<string> quarantine, string key, TimeSpan cooldown)
    {
        _clock.Advance(cooldown - Tick);
        Assert.Null(quarantine.TryBegin(key, Budget));
        _clock.Advance(Tick);
    }

    [Fact]
    public void AHealthyKeyIsAdmittedAndNotAProbe()
    {
        var quarantine = Create();

        LookupAttempt<string>? attempt = quarantine.TryBegin("a", Budget);

        Assert.NotNull(attempt);
        Assert.False(attempt!.IsProbe);
    }

    [Fact]
    public void AFailureTripsTheKeyForTheInitialBackoff()
    {
        var quarantine = Create();

        Run(quarantine, "a", LookupOutcome.Failed);

        AssertCooldown(quarantine, "a", TimeSpan.FromSeconds(30));
        LookupAttempt<string>? probe = quarantine.TryBegin("a", Budget);
        Assert.NotNull(probe);
        Assert.True(probe!.IsProbe);
    }

    /// <summary>
    /// Expiry makes the key eligible for exactly one recovery probe. Letting every click through the
    /// moment the cooldown ends would queue a burst of lookups behind a provider that is still slow.
    /// </summary>
    [Fact]
    public void OnlyOneRecoveryProbeIsAdmittedAtATime()
    {
        var quarantine = Create();
        Run(quarantine, "a", LookupOutcome.Failed);
        _clock.Advance(TimeSpan.FromSeconds(30));

        Assert.NotNull(quarantine.TryBegin("a", Budget));
        Assert.Null(quarantine.TryBegin("a", Budget));
    }

    /// <summary>
    /// Expiry is not forgiveness. A probe that fails again doubles the pause, which proves the
    /// history outlived both the cooldown and the pruning that other keys trigger meanwhile.
    /// </summary>
    [Fact]
    public void AFailedProbeDoublesTheBackoffBecauseHistorySurvivesExpiryAndPruning()
    {
        var quarantine = Create(Options with { Capacity = 2 });
        Run(quarantine, "a", LookupOutcome.Failed);
        _clock.Advance(TimeSpan.FromSeconds(30));

        // Capacity pressure runs the eviction pass; a key whose history is still pending its probe
        // is not idle and must not be forgotten while healthier candidates exist.
        Run(quarantine, "b", LookupOutcome.Found);
        Run(quarantine, "c", LookupOutcome.Found);

        Run(quarantine, "a", LookupOutcome.Failed);

        AssertCooldown(quarantine, "a", TimeSpan.FromSeconds(60));
        Assert.NotNull(quarantine.TryBegin("a", Budget));
    }

    [Fact]
    public void TheBackoffDoublesUpToTheCap()
    {
        var quarantine = Create();
        Run(quarantine, "a", LookupOutcome.Failed);

        foreach (int seconds in new[] { 30, 60, 120, 240, 300, 300 })
        {
            AssertCooldown(quarantine, "a", TimeSpan.FromSeconds(seconds));
            Run(quarantine, "a", LookupOutcome.Failed);
        }
    }

    [Theory]
    [InlineData(LookupOutcome.Found)]
    [InlineData(LookupOutcome.Absent)]
    public void ACompletedLookupResetsHistory(LookupOutcome outcome)
    {
        var quarantine = Create();
        Run(quarantine, "a", LookupOutcome.Failed);
        _clock.Advance(TimeSpan.FromSeconds(30));
        Run(quarantine, "a", LookupOutcome.Failed);
        _clock.Advance(TimeSpan.FromSeconds(60));

        Run(quarantine, "a", outcome);

        // Healthy again: no probe gating, and the next failure starts over at the initial backoff.
        LookupAttempt<string>? first = quarantine.TryBegin("a", Budget);
        Assert.False(first!.IsProbe);
        Assert.NotNull(quarantine.TryBegin("a", Budget));
        Assert.True(first.TryStart());
        first.Complete(LookupOutcome.Failed);
        AssertCooldown(quarantine, "a", TimeSpan.FromSeconds(30));
    }

    /// <summary>
    /// A skipped probe asked the provider nothing, so it proves nothing either way: the slot is
    /// freed for the next click and the history it was probing stays.
    /// </summary>
    [Fact]
    public void ASkippedProbeNeitherResetsNorExtends()
    {
        var quarantine = Create();
        Run(quarantine, "a", LookupOutcome.Failed);
        _clock.Advance(TimeSpan.FromSeconds(30));

        LookupAttempt<string> probe = quarantine.TryBegin("a", Budget)!;
        Assert.True(probe.TryStart());
        probe.Complete(LookupOutcome.Skipped);

        LookupAttempt<string>? next = quarantine.TryBegin("a", Budget);
        Assert.True(next!.IsProbe);
        Assert.True(next.TryStart());
        next.Complete(LookupOutcome.Failed);
        AssertCooldown(quarantine, "a", TimeSpan.FromSeconds(60));
    }

    /// <summary>
    /// Today's code quarantined on the caller's timeout, on an exception and on an over-budget
    /// execution, so one bad lookup could be reported three times. It is still one failure.
    /// </summary>
    [Fact]
    public void ATimeoutAndALateFailureForTheSameAttemptCountOnce()
    {
        var quarantine = Create();
        LookupAttempt<string> attempt = quarantine.TryBegin("a", Budget)!;
        Assert.True(attempt.TryStart());

        _clock.Advance(Budget + Tick);
        attempt.Abandon();
        attempt.Complete(LookupOutcome.Failed);
        attempt.Complete(LookupOutcome.Failed);

        AssertCooldown(quarantine, "a", TimeSpan.FromSeconds(30));
    }

    [Fact]
    public void ConcurrentFailuresOfOneHealthyKeyAreOneTrip()
    {
        var quarantine = Create();
        LookupAttempt<string> first = quarantine.TryBegin("a", Budget)!;
        LookupAttempt<string> second = quarantine.TryBegin("a", Budget)!;
        Assert.True(first.TryStart());
        Assert.True(second.TryStart());

        first.Complete(LookupOutcome.Failed);
        second.Complete(LookupOutcome.Failed);

        AssertCooldown(quarantine, "a", TimeSpan.FromSeconds(30));
    }

    [Fact]
    public void ACompletionAtTheDeadlineIsInTimeAndOneTickLaterIsAFailure()
    {
        var quarantine = Create();

        LookupAttempt<string> onTime = quarantine.TryBegin("a", Budget)!;
        Assert.True(onTime.TryStart());
        _clock.Advance(Budget);
        onTime.Complete(LookupOutcome.Found);
        Assert.False(quarantine.TryBegin("a", Budget)!.IsProbe);

        LookupAttempt<string> late = quarantine.TryBegin("b", Budget)!;
        Assert.True(late.TryStart());
        _clock.Advance(Budget + Tick);
        late.Complete(LookupOutcome.Found);
        AssertCooldown(quarantine, "b", TimeSpan.FromSeconds(30));
    }

    /// <summary>
    /// A lookup still queued when its caller gave up never reached the provider, so the worker must
    /// drop it rather than spend the single STA thread on an answer nobody is waiting for — and the
    /// key must not be blamed for time it spent waiting behind somebody else.
    /// </summary>
    [Fact]
    public void ALookupStillQueuedAtItsDeadlineIsDroppedWithoutBlame()
    {
        var quarantine = Create();

        LookupAttempt<string> abandoned = quarantine.TryBegin("a", Budget)!;
        abandoned.Abandon();
        Assert.False(abandoned.TryStart());

        LookupAttempt<string> expired = quarantine.TryBegin("a", Budget)!;
        _clock.Advance(Budget);
        Assert.False(expired.TryStart());

        Assert.False(quarantine.TryBegin("a", Budget)!.IsProbe);
    }

    [Fact]
    public void ADroppedProbeFreesTheSlotForTheNextClick()
    {
        var quarantine = Create();
        Run(quarantine, "a", LookupOutcome.Failed);
        _clock.Advance(TimeSpan.FromSeconds(30));

        LookupAttempt<string> probe = quarantine.TryBegin("a", Budget)!;
        probe.Abandon();

        Assert.True(quarantine.TryBegin("a", Budget)!.IsProbe);
    }

    /// <summary>
    /// UI Automation cannot be cancelled, so a probe whose caller timed out is still running on the
    /// worker. Admitting another one behind it would only queue a second call into the same provider.
    /// </summary>
    [Fact]
    public void AProbeThatTimedOutHoldsItsSlotUntilTheWorkerFinishesIt()
    {
        var quarantine = Create();
        Run(quarantine, "a", LookupOutcome.Failed);
        _clock.Advance(TimeSpan.FromSeconds(30));

        LookupAttempt<string> probe = quarantine.TryBegin("a", Budget)!;
        Assert.True(probe.TryStart());
        probe.Abandon();

        _clock.Advance(TimeSpan.FromMinutes(10));
        Assert.Null(quarantine.TryBegin("a", Budget));

        probe.Complete(LookupOutcome.Found);

        // The late answer released the slot but did not clear the failure the timeout recorded.
        LookupAttempt<string>? next = quarantine.TryBegin("a", Budget);
        Assert.True(next!.IsProbe);
    }

    [Fact]
    public void AStaleCompletionDoesNotTouchARecreatedEntry()
    {
        var quarantine = Create(Options with { Capacity = 1 });
        LookupAttempt<string> stale = quarantine.TryBegin("a", Budget)!;
        Assert.True(stale.TryStart());

        // "b" evicts the healthy "a"; "a" then evicts "b" and comes back as a fresh entry.
        Run(quarantine, "b", LookupOutcome.Found);
        Run(quarantine, "a", LookupOutcome.Found);

        stale.Complete(LookupOutcome.Failed);

        Assert.False(quarantine.TryBegin("a", Budget)!.IsProbe);
    }

    [Fact]
    public void AStaleCompletionDoesNotTouchAnEntryRecreatedAfterIdleRetention()
    {
        var quarantine = Create();
        LookupAttempt<string> stale = quarantine.TryBegin("a", Budget)!;
        Assert.True(stale.TryStart());

        _clock.Advance(TimeSpan.FromMinutes(30));
        Run(quarantine, "a", LookupOutcome.Found);
        stale.Complete(LookupOutcome.Failed);

        Assert.False(quarantine.TryBegin("a", Budget)!.IsProbe);
    }

    /// <summary>The point of keying by window: one slow window leaves its siblings alone.</summary>
    [Fact]
    public void KeysAreIndependent()
    {
        var quarantine = Create();

        Run(quarantine, "slow", LookupOutcome.Failed);

        Assert.Null(quarantine.TryBegin("slow", Budget));
        Assert.False(quarantine.TryBegin("other", Budget)!.IsProbe);
    }

    [Fact]
    public void AtCapacityHealthyHistoryIsEvictedBeforeACooldown()
    {
        var quarantine = Create(Options with { Capacity = 2 });
        Run(quarantine, "cooling", LookupOutcome.Failed);
        Run(quarantine, "healthy", LookupOutcome.Found);

        Assert.NotNull(quarantine.TryBegin("new", Budget));

        Assert.Equal(2, quarantine.TrackedKeys);
        Assert.Null(quarantine.TryBegin("cooling", Budget));
    }

    /// <summary>
    /// When every tracked key is cooling down or probing there is nothing safe to forget, so a new
    /// key is refused rather than admitted untracked: an unbounded number of untracked slow lookups
    /// is exactly the cost the quarantine exists to cap.
    /// </summary>
    [Fact]
    public void WhenEveryEntryIsActiveANewKeyIsRefused()
    {
        var quarantine = Create(Options with { Capacity = 1 });
        Run(quarantine, "cooling", LookupOutcome.Failed);

        Assert.Null(quarantine.TryBegin("new", Budget));
        Assert.Equal(1, quarantine.TrackedKeys);

        _clock.Advance(TimeSpan.FromSeconds(30));
        LookupAttempt<string> probe = quarantine.TryBegin("cooling", Budget)!;
        Assert.Null(quarantine.TryBegin("new", Budget));

        Assert.True(probe.TryStart());
        probe.Complete(LookupOutcome.Found);
        Assert.NotNull(quarantine.TryBegin("new", Budget));
    }

    [Fact]
    public void IdleRetentionClearsHistory()
    {
        var quarantine = Create();
        Run(quarantine, "a", LookupOutcome.Failed);
        _clock.Advance(TimeSpan.FromSeconds(30));
        Run(quarantine, "a", LookupOutcome.Failed);

        _clock.Advance(TimeSpan.FromMinutes(30));

        LookupAttempt<string>? attempt = quarantine.TryBegin("a", Budget);
        Assert.False(attempt!.IsProbe);
        Assert.True(attempt.TryStart());
        attempt.Complete(LookupOutcome.Failed);
        AssertCooldown(quarantine, "a", TimeSpan.FromSeconds(30));
    }

    [Fact]
    public void OptionsRejectNonsense()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => Options with { InitialBackoff = TimeSpan.Zero });
        Assert.Throws<ArgumentOutOfRangeException>(() => Options with { MaxBackoff = TimeSpan.FromSeconds(1) });
        Assert.Throws<ArgumentOutOfRangeException>(() => Options with { Capacity = 0 });
        Assert.Throws<ArgumentOutOfRangeException>(() => Options with { IdleRetention = TimeSpan.Zero });
    }

    [Fact]
    public async Task ConcurrentUseKeepsItsInvariants()
    {
        var quarantine = Create(Options with { Capacity = 8 });
        LookupOutcome[] outcomes = { LookupOutcome.Found, LookupOutcome.Absent, LookupOutcome.Failed, LookupOutcome.Skipped };

        Task[] workers = Enumerable.Range(0, 8).Select(worker => Task.Run(() =>
        {
            var random = new Random(worker);
            for (int i = 0; i < 5_000; i++)
            {
                LookupAttempt<string>? attempt = quarantine.TryBegin($"k{random.Next(16)}", Budget);
                if (attempt is null)
                {
                    continue;
                }

                switch (random.Next(3))
                {
                    case 0:
                        attempt.Abandon();
                        if (attempt.TryStart())
                        {
                            attempt.Complete(outcomes[random.Next(outcomes.Length)]);
                        }

                        break;
                    case 1:
                        if (attempt.TryStart())
                        {
                            attempt.Abandon();
                            attempt.Complete(outcomes[random.Next(outcomes.Length)]);
                        }

                        break;
                    default:
                        if (attempt.TryStart())
                        {
                            attempt.Complete(outcomes[random.Next(outcomes.Length)]);
                        }

                        break;
                }

                if (i % 100 == 0)
                {
                    _clock.Advance(TimeSpan.FromSeconds(7));
                }

                Assert.InRange(quarantine.TrackedKeys, 0, 8);
            }
        })).ToArray();

        await Task.WhenAll(workers);

        // Every attempt reached a terminal state, so no probe slot may still be held: once all
        // cooldowns have run out, every key is admitted again.
        _clock.Advance(TimeSpan.FromHours(1));
        for (int key = 0; key < 16; key++)
        {
            Assert.NotNull(quarantine.TryBegin($"k{key}", Budget));
        }
    }
}
