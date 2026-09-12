using JazzCapture;

namespace JazzCaptureHostTests;

/// <summary>
/// <see cref="ScreenshotDeliveryPresentation.Describe"/> is the tray's only diagnostic surface for
/// screenshot delivery -- this codebase has no logging framework -- so every state it can render has
/// to be covered explicitly, modelled on the closed <c>codex/68-screenshot-files</c> branch's own
/// <c>ScreenshotDeliveryStatusTests.RendersOnlySafeStateAndCount</c>.
/// </summary>
public sealed class ScreenshotDeliveryPresentationTests
{
    [Theory]
    [InlineData(ScreenshotDeliveryPresentationState.NotProvisioned, 0, "not provisioned")]
    [InlineData(ScreenshotDeliveryPresentationState.Uploading, 2, "uploading 2")]
    [InlineData(ScreenshotDeliveryPresentationState.Retrying, 3, "retrying 3")]
    [InlineData(ScreenshotDeliveryPresentationState.UpToDate, 0, "up to date")]
    [InlineData(ScreenshotDeliveryPresentationState.UpToDate, 4, "waiting 4")]
    [InlineData(ScreenshotDeliveryPresentationState.Abandoned, 1, "1 undelivered")]
    [InlineData(ScreenshotDeliveryPresentationState.Abandoned, 5, "5 undelivered")]
    public void RendersOnlySafeStateAndCount(
        ScreenshotDeliveryPresentationState state, int count, string expected)
    {
        string text = new ScreenshotDeliveryPresentation(state, count).Describe();

        Assert.Equal(expected, text);
        Assert.DoesNotContain("secret", text, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("https", text, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("token", text, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("\\", text, StringComparison.Ordinal);
        Assert.DoesNotContain("/", text, StringComparison.Ordinal);
    }

    /// <summary>
    /// The tray's own <c>Truncate</c> caps every menu line at 63 characters
    /// (<c>TrayHost.cs:996</c>), and the rendered text here is prefixed with "Screenshots: " before
    /// it reaches that cap. A pending or abandoned count large enough to matter in practice must
    /// still read as a complete sentence, not get chopped mid-number.
    /// </summary>
    [Theory]
    [InlineData(ScreenshotDeliveryPresentationState.NotProvisioned)]
    [InlineData(ScreenshotDeliveryPresentationState.Uploading)]
    [InlineData(ScreenshotDeliveryPresentationState.Retrying)]
    [InlineData(ScreenshotDeliveryPresentationState.UpToDate)]
    [InlineData(ScreenshotDeliveryPresentationState.Abandoned)]
    public void StaysWithinTheTraysSixtyThreeCharacterLineBudgetForALargeCount(
        ScreenshotDeliveryPresentationState state)
    {
        string line = "Screenshots: " + new ScreenshotDeliveryPresentation(state, int.MaxValue).Describe();

        Assert.True(line.Length <= 63, $"'{line}' is {line.Length} characters long.");
    }
}

/// <summary>
/// <see cref="ScreenshotDeliveryPresentationTracker"/> is the only place this design accumulates a
/// terminally-dropped screenshot count: the staging area removes an entry the moment it is dropped
/// (see <c>ScreenshotStagingArea.Remove</c>), so nothing else in the process remembers that it ever
/// existed. These tests pin the aggregation rules the App wires the delivery worker's outcome events
/// through, in particular that a dangling Files id is never allowed to read as "up to date" again.
/// </summary>
public sealed class ScreenshotDeliveryPresentationTrackerTests
{
    [Fact]
    public void ReportsNotProvisionedWheneverNoCredentialExistsRegardlessOfPendingCount()
    {
        var tracker = new ScreenshotDeliveryPresentationTracker();

        ScreenshotDeliveryPresentation presentation = tracker.Resolve(provisioned: false, pendingCount: 5);

        Assert.Equal(ScreenshotDeliveryPresentationState.NotProvisioned, presentation.State);
    }

    [Fact]
    public void ReportsUpToDateWhenNothingIsPendingAndNothingWasEverAbandoned()
    {
        var tracker = new ScreenshotDeliveryPresentationTracker();

        ScreenshotDeliveryPresentation presentation = tracker.Resolve(provisioned: true, pendingCount: 0);

        Assert.Equal(ScreenshotDeliveryPresentationState.UpToDate, presentation.State);
        Assert.Equal(0, presentation.Count);
    }

    [Fact]
    public void ReportsUploadingWhilePendingAndNoAttemptHasFailedYet()
    {
        var tracker = new ScreenshotDeliveryPresentationTracker();

        ScreenshotDeliveryPresentation presentation = tracker.Resolve(provisioned: true, pendingCount: 3);

        Assert.Equal(ScreenshotDeliveryPresentationState.Uploading, presentation.State);
        Assert.Equal(3, presentation.Count);
    }

    [Fact]
    public void ReportsRetryingAfterAWorkerRetryOutcomeWhilePendingStaysNonZero()
    {
        var tracker = new ScreenshotDeliveryPresentationTracker();
        tracker.OnOutcome(new ScreenshotDeliveryOutcomeEvent("artifact-1", ScreenshotDeliveryOutcome.Retrying));

        ScreenshotDeliveryPresentation presentation = tracker.Resolve(provisioned: true, pendingCount: 1);

        Assert.Equal(ScreenshotDeliveryPresentationState.Retrying, presentation.State);
        Assert.Equal(1, presentation.Count);
    }

    [Fact]
    public void AnAcknowledgedOutcomeClearsARetryingImpressionForTheNextAttempt()
    {
        var tracker = new ScreenshotDeliveryPresentationTracker();
        tracker.OnOutcome(new ScreenshotDeliveryOutcomeEvent("artifact-1", ScreenshotDeliveryOutcome.Retrying));
        tracker.OnOutcome(new ScreenshotDeliveryOutcomeEvent("artifact-1", ScreenshotDeliveryOutcome.Acknowledged));

        ScreenshotDeliveryPresentation presentation = tracker.Resolve(provisioned: true, pendingCount: 1);

        Assert.Equal(ScreenshotDeliveryPresentationState.Uploading, presentation.State);
    }

    /// <summary>
    /// The tray must not claim delivery succeeded when a Files id is left dangling. Once the queue
    /// drains back to empty, "up to date" would say exactly that, so an abandoned screenshot has to
    /// keep surfacing here instead.
    /// </summary>
    [Fact]
    public void KeepsReportingAbandonedScreenshotsAfterTheQueueDrainsToEmpty()
    {
        var tracker = new ScreenshotDeliveryPresentationTracker();
        tracker.OnOutcome(new ScreenshotDeliveryOutcomeEvent("artifact-1", ScreenshotDeliveryOutcome.Dropped));

        ScreenshotDeliveryPresentation presentation = tracker.Resolve(provisioned: true, pendingCount: 0);

        Assert.Equal(ScreenshotDeliveryPresentationState.Abandoned, presentation.State);
        Assert.Equal(1, presentation.Count);
    }

    [Fact]
    public void CountsAVerificationFailureAsAbandonedTooAndAccumulatesAcrossMultipleDrops()
    {
        var tracker = new ScreenshotDeliveryPresentationTracker();
        tracker.OnOutcome(new ScreenshotDeliveryOutcomeEvent("a", ScreenshotDeliveryOutcome.VerificationFailed));
        tracker.OnOutcome(new ScreenshotDeliveryOutcomeEvent("b", ScreenshotDeliveryOutcome.Dropped));

        ScreenshotDeliveryPresentation presentation = tracker.Resolve(provisioned: true, pendingCount: 0);

        Assert.Equal(ScreenshotDeliveryPresentationState.Abandoned, presentation.State);
        Assert.Equal(2, presentation.Count);
    }

    /// <summary>
    /// Active pending work always outranks a stale abandoned count: a screenshot dropped earlier in
    /// the session must not hide that new screenshots are uploading fine right now. The abandoned
    /// count is not lost -- <see cref="KeepsReportingAbandonedScreenshotsAfterTheQueueDrainsToEmpty"/>
    /// covers that it resurfaces once the queue empties again.
    /// </summary>
    [Fact]
    public void PrefersCurrentPendingWorkOverAStaleAbandonedCountWhenNewScreenshotsAreQueued()
    {
        var tracker = new ScreenshotDeliveryPresentationTracker();
        tracker.OnOutcome(new ScreenshotDeliveryOutcomeEvent("a", ScreenshotDeliveryOutcome.Dropped));

        ScreenshotDeliveryPresentation presentation = tracker.Resolve(provisioned: true, pendingCount: 2);

        Assert.Equal(ScreenshotDeliveryPresentationState.Uploading, presentation.State);
        Assert.Equal(2, presentation.Count);
    }

    [Fact]
    public void ReportsNotProvisionedEvenAfterScreenshotsWereAbandonedWhileProvisioned()
    {
        var tracker = new ScreenshotDeliveryPresentationTracker();
        tracker.OnOutcome(new ScreenshotDeliveryOutcomeEvent("a", ScreenshotDeliveryOutcome.Dropped));

        ScreenshotDeliveryPresentation presentation = tracker.Resolve(provisioned: false, pendingCount: 0);

        Assert.Equal(ScreenshotDeliveryPresentationState.NotProvisioned, presentation.State);
    }

    /// <summary>
    /// Regression coverage for the #74 review's "global retry flag" finding: the tracker used to keep
    /// one shared "something is retrying" flag, so an <see cref="ScreenshotDeliveryOutcome.Acknowledged"/>
    /// for one artifact could clear the retrying impression left by a completely different artifact
    /// that is still backing off. Tracking retrying ids per artifact fixes it -- an unrelated
    /// acknowledgement must not turn "Retrying" back into "Uploading".
    /// </summary>
    [Fact]
    public void AnAcknowledgementForADifferentArtifactDoesNotClearAnotherArtifactsRetryingState()
    {
        var tracker = new ScreenshotDeliveryPresentationTracker();
        tracker.OnOutcome(new ScreenshotDeliveryOutcomeEvent("art-retrying", ScreenshotDeliveryOutcome.Retrying));

        tracker.OnOutcome(new ScreenshotDeliveryOutcomeEvent("art-unrelated", ScreenshotDeliveryOutcome.Acknowledged));

        ScreenshotDeliveryPresentation presentation = tracker.Resolve(provisioned: true, pendingCount: 1);
        Assert.Equal(ScreenshotDeliveryPresentationState.Retrying, presentation.State);
    }

    /// <summary>
    /// Continuation of <see cref="AnAcknowledgementForADifferentArtifactDoesNotClearAnotherArtifactsRetryingState"/>:
    /// once the still-retrying artifact itself reaches a terminal outcome, "Retrying" must stop being
    /// rendered.
    /// </summary>
    [Theory]
    [InlineData(ScreenshotDeliveryOutcome.Acknowledged)]
    [InlineData(ScreenshotDeliveryOutcome.Dropped)]
    [InlineData(ScreenshotDeliveryOutcome.VerificationFailed)]
    [InlineData(ScreenshotDeliveryOutcome.Evicted)]
    public void RetryingStopsRenderingOnceTheRetryingArtifactItselfReachesATerminalOutcome(
        ScreenshotDeliveryOutcome terminalOutcome)
    {
        var tracker = new ScreenshotDeliveryPresentationTracker();
        tracker.OnOutcome(new ScreenshotDeliveryOutcomeEvent("art-retrying", ScreenshotDeliveryOutcome.Retrying));
        tracker.OnOutcome(new ScreenshotDeliveryOutcomeEvent("art-unrelated", ScreenshotDeliveryOutcome.Acknowledged));

        tracker.OnOutcome(new ScreenshotDeliveryOutcomeEvent("art-retrying", terminalOutcome));

        ScreenshotDeliveryPresentation presentation = tracker.Resolve(provisioned: true, pendingCount: 0);
        Assert.NotEqual(ScreenshotDeliveryPresentationState.Retrying, presentation.State);
    }

    /// <summary>
    /// Guards against the retrying set growing without bound: every id that ever enters it
    /// (<see cref="ScreenshotDeliveryOutcome.Retrying"/>) must have exactly one terminal outcome that
    /// removes it again, so once every retrying artifact resolves, the tracker must stop rendering
    /// "Retrying" even though several distinct artifacts passed through the set over the tracker's
    /// lifetime.
    /// </summary>
    [Fact]
    public void TheRetryingSetShrinksBackToEmptyOnceEveryArtifactInItReachesATerminalOutcome()
    {
        var tracker = new ScreenshotDeliveryPresentationTracker();
        tracker.OnOutcome(new ScreenshotDeliveryOutcomeEvent("art-1", ScreenshotDeliveryOutcome.Retrying));
        tracker.OnOutcome(new ScreenshotDeliveryOutcomeEvent("art-2", ScreenshotDeliveryOutcome.Retrying));
        tracker.OnOutcome(new ScreenshotDeliveryOutcomeEvent("art-3", ScreenshotDeliveryOutcome.Retrying));
        Assert.Equal(
            ScreenshotDeliveryPresentationState.Retrying,
            tracker.Resolve(provisioned: true, pendingCount: 3).State);

        tracker.OnOutcome(new ScreenshotDeliveryOutcomeEvent("art-1", ScreenshotDeliveryOutcome.Acknowledged));
        tracker.OnOutcome(new ScreenshotDeliveryOutcomeEvent("art-2", ScreenshotDeliveryOutcome.Dropped));
        tracker.OnOutcome(new ScreenshotDeliveryOutcomeEvent("art-3", ScreenshotDeliveryOutcome.Evicted));

        ScreenshotDeliveryPresentation presentation = tracker.Resolve(provisioned: true, pendingCount: 0);
        Assert.NotEqual(ScreenshotDeliveryPresentationState.Retrying, presentation.State);
        Assert.Equal(ScreenshotDeliveryPresentationState.Abandoned, presentation.State);
        Assert.Equal(2, presentation.Count);
    }

    /// <summary>
    /// An eviction (Finding 1's new outcome) must count as abandoned exactly like a drop or a
    /// verification failure, since it too leaves a Files id permanently dangling.
    /// </summary>
    [Fact]
    public void CountsAnEvictionAsAbandonedTooAndKeepsReportingItAfterTheQueueDrains()
    {
        var tracker = new ScreenshotDeliveryPresentationTracker();
        tracker.OnOutcome(new ScreenshotDeliveryOutcomeEvent("art-evicted", ScreenshotDeliveryOutcome.Evicted));

        ScreenshotDeliveryPresentation presentation = tracker.Resolve(provisioned: true, pendingCount: 0);

        Assert.Equal(ScreenshotDeliveryPresentationState.Abandoned, presentation.State);
        Assert.Equal(1, presentation.Count);
    }
}

/// <summary>
/// <c>DeliveryStatusPublisher{T}</c> is the seam below <c>App.PrepareScreenshotDelivery</c>
/// that Finding 2 (#74 review, second pass) actually lives at -- <c>App.xaml.cs</c> itself has no
/// test coverage (an accepted gap from the #72 review). These tests pin the two properties that
/// wiring depends on: a declined prepare's projected presentation (e.g. "not provisioned") reaches
/// the wrapped delegate on the first decline and on every one after a real change, and repeated
/// declines while nothing has changed -- which can happen once per click for an entire unprovisioned
/// session -- do not keep re-pushing.
/// </summary>
public sealed class ScreenshotDeliveryStatusPublisherTests
{
    private static readonly ScreenshotDeliveryPresentation NotProvisioned =
        new(ScreenshotDeliveryPresentationState.NotProvisioned, 0);
    private static readonly ScreenshotDeliveryPresentation Abandoned =
        new(ScreenshotDeliveryPresentationState.Abandoned, 1);
    private static readonly ScreenshotDeliveryPresentation Uploading =
        new(ScreenshotDeliveryPresentationState.Uploading, 1);

    [Fact]
    public void TheFirstPushIfChangedCallAlwaysPushesEvenWithNoPriorBaseline()
    {
        var pushed = new List<ScreenshotDeliveryPresentation>();
        var publisher = new DeliveryStatusPublisher<ScreenshotDeliveryPresentation>(pushed.Add);

        publisher.PushIfChanged(NotProvisioned);

        Assert.Equal(new[] { NotProvisioned }, pushed);
    }

    /// <summary>
    /// Regression coverage for Finding 2: a credential that lapses mid-session declines every
    /// subsequent prepare, and a screenshot-bearing observation can happen once per click. Without
    /// coalescing, every one of those declines would re-push an identical "not provisioned" line.
    /// </summary>
    [Fact]
    public void ASecondConsecutiveDeclineWithTheSamePresentationDoesNotPushAgain()
    {
        var pushed = new List<ScreenshotDeliveryPresentation>();
        var publisher = new DeliveryStatusPublisher<ScreenshotDeliveryPresentation>(pushed.Add);
        publisher.PushIfChanged(NotProvisioned);

        publisher.PushIfChanged(NotProvisioned);

        Assert.Single(pushed);
    }

    [Fact]
    public void AChangeAfterARepeatedDeclinePushesAgain()
    {
        var pushed = new List<ScreenshotDeliveryPresentation>();
        var publisher = new DeliveryStatusPublisher<ScreenshotDeliveryPresentation>(pushed.Add);
        publisher.PushIfChanged(NotProvisioned);
        publisher.PushIfChanged(NotProvisioned);

        publisher.PushIfChanged(Abandoned);

        Assert.Equal(new[] { NotProvisioned, Abandoned }, pushed);
    }

    [Fact]
    public void PushAlwaysPushesRegardlessOfTheBaseline()
    {
        var pushed = new List<ScreenshotDeliveryPresentation>();
        var publisher = new DeliveryStatusPublisher<ScreenshotDeliveryPresentation>(pushed.Add);
        var upToDate = new ScreenshotDeliveryPresentation(ScreenshotDeliveryPresentationState.UpToDate, 0);
        publisher.Push(upToDate);

        publisher.Push(upToDate);

        Assert.Equal(new[] { upToDate, upToDate }, pushed);
    }

    /// <summary>
    /// Pins that the baseline is shared across both methods: a <c>DeliveryStatusPublisher{T}.Push</c>
    /// from one call site (e.g. a successful stage) must be visible to a later
    /// <c>DeliveryStatusPublisher{T}.PushIfChanged</c> from a different call site (e.g.
    /// a declined prepare), so the two can never disagree about what the tray currently shows.
    /// </summary>
    [Fact]
    public void APushUpdatesTheBaselineThatALaterPushIfChangedComparesAgainst()
    {
        var pushed = new List<ScreenshotDeliveryPresentation>();
        var publisher = new DeliveryStatusPublisher<ScreenshotDeliveryPresentation>(pushed.Add);
        publisher.Push(Uploading);

        publisher.PushIfChanged(Uploading);

        Assert.Single(pushed);
    }

    /// <summary>
    /// Regression coverage for Finding 3 (#74 review, third pass). The previous shape of this type
    /// recorded each call's presentation as the shared baseline under its own lock, but then invoked
    /// the wrapped delegate outside that lock with no coordination between concurrent callers: an
    /// older presentation's delegate call could complete after a newer one's already had, and once
    /// that happened <c>DeliveryStatusPublisher{T}.PushIfChanged</c>'s own change
    /// detection would suppress every later call that merely repeated the (correct) baseline,
    /// leaving the tray stuck showing the stale value indefinitely. This forces exactly that
    /// interleaving deterministically -- a capture-path-shaped <c>Push</c> call is blocked inside the
    /// delegate (the same shape a slow tray marshal would have) while a worker-shaped
    /// <c>PushIfChanged</c> call for a newer state arrives and must return immediately rather than
    /// wait for it -- and pins that releasing the in-flight call then delivers the newer state next,
    /// never reasserting the older one afterwards and never getting stuck.
    /// </summary>
    [Fact]
    public async Task ANewerConcurrentPushIsDeliveredAfterAnInFlightOlderOneRatherThanReorderedOrStuck()
    {
        var upToDate = new ScreenshotDeliveryPresentation(ScreenshotDeliveryPresentationState.UpToDate, 0);
        var pushed = new List<ScreenshotDeliveryPresentation>();
        var firstCallEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        // A synchronous gate, not a Task, so the blocking delegate below (which must itself be
        // synchronous to match the real production callback shape -- Action<ScreenshotDeliveryPresentation>)
        // waits on it without tripping the analyzer that flags blocking *Task* operations in a test
        // method; the block itself is deliberate here, not the accidental deadlock risk that rule
        // exists to catch.
        using var releaseFirstCall = new ManualResetEventSlim(initialState: false);
        var publisher = new DeliveryStatusPublisher<ScreenshotDeliveryPresentation>(presentation =>
        {
            lock (pushed) pushed.Add(presentation);
            if (presentation.Equals(Uploading))
            {
                firstCallEntered.TrySetResult();
                releaseFirstCall.Wait(TimeSpan.FromSeconds(2));
            }
        });

        Task firstPush = Task.Run(() => publisher.Push(Uploading));
        await firstCallEntered.Task.WaitAsync(TimeSpan.FromSeconds(2));

        // The delegate is genuinely blocked inside the first (older) call right now. A second,
        // newer presentation recorded while that is true must return immediately rather than wait
        // for the in-flight delegate call to finish -- the capture path must never block here.
        Task secondPush = Task.Run(() => publisher.PushIfChanged(upToDate));
        await secondPush.WaitAsync(TimeSpan.FromSeconds(2));

        // The delegate has only been entered once so far, for the older presentation; the newer
        // one has been recorded as the baseline but not yet delivered.
        lock (pushed) Assert.Equal(new[] { Uploading }, pushed);

        releaseFirstCall.Set();
        await firstPush.WaitAsync(TimeSpan.FromSeconds(2));

        // Releasing the in-flight call lets the same delivery loop pick up and send the newer
        // presentation next, deterministically before Push itself returns -- not reordered ahead of
        // it, and not left stuck on the older value.
        lock (pushed) Assert.Equal(new[] { Uploading, upToDate }, pushed);
    }

    /// <summary>
    /// Regression coverage for Finding 1 (#74 review, fourth pass).
    /// <c>DeliveryStatusPublisher{T}.DrainDeliveryQueue</c> used to call the sink with
    /// no isolation, so a sink that threw even once propagated out of the loop and left the
    /// publisher's internal "delivering" flag stuck <see langword="true"/> forever -- every later
    /// <c>DeliveryStatusPublisher{T}.Push</c>/<c>DeliveryStatusPublisher{T}.PushIfChanged</c>
    /// call would then see delivery already "in progress" and merely overwrite the pending slot
    /// without ever starting a new drain, permanently freezing the tray's "Screenshots:" line -- the
    /// one diagnostic this codebase has. This forces the sink to throw while a second, newer value
    /// is already queued (the same blocking-then-queue interleaving
    /// <see cref="ANewerConcurrentPushIsDeliveredAfterAnInFlightOlderOneRatherThanReorderedOrStuck"/>
    /// uses) and pins two things: the same drain pass still goes on to deliver the newer, already
    /// -queued value despite the throw, and -- proof the flag was actually cleared rather than
    /// stranded -- a completely separate, later push still gets delivered too.
    /// </summary>
    [Fact]
    public async Task AThrowingSinkStillDeliversAQueuedNewerValueAndDoesNotWedgeLaterPushes()
    {
        var pushed = new List<ScreenshotDeliveryPresentation>();
        var firstCallEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var releaseFirstCall = new ManualResetEventSlim(initialState: false);
        var publisher = new DeliveryStatusPublisher<ScreenshotDeliveryPresentation>(presentation =>
        {
            lock (pushed) pushed.Add(presentation);
            if (presentation.Equals(Uploading))
            {
                firstCallEntered.TrySetResult();
                releaseFirstCall.Wait(TimeSpan.FromSeconds(2));
                throw new InvalidOperationException("sink misbehaving");
            }
        });

        Task firstPush = Task.Run(() => publisher.Push(Uploading));
        await firstCallEntered.Task.WaitAsync(TimeSpan.FromSeconds(2));

        // Queue a newer value while the first (about to throw) call is still blocked inside the
        // sink -- exactly the interleaving that used to matter for ordering, now repurposed to
        // check that a throw does not strand it.
        Task secondPush = Task.Run(() => publisher.PushIfChanged(NotProvisioned));
        await secondPush.WaitAsync(TimeSpan.FromSeconds(2));

        releaseFirstCall.Set();

        // Push itself must never surface the sink's exception: DrainDeliveryQueue swallows it,
        // matching every other best-effort observer in this codebase.
        await firstPush.WaitAsync(TimeSpan.FromSeconds(2));

        // The same drain loop must have gone on to deliver the newer, already-queued value despite
        // the throw, rather than abandoning it.
        lock (pushed) Assert.Equal(new[] { Uploading, NotProvisioned }, pushed);

        // And the flag must have been cleared, not stranded: an unrelated push made afterwards still
        // gets through instead of being silently swallowed forever.
        publisher.Push(Abandoned);
        lock (pushed) Assert.Equal(new[] { Uploading, NotProvisioned, Abandoned }, pushed);
    }

    /// <summary>
    /// Regression coverage for Finding 1 (#74 review, fifth pass). Before this fix,
    /// <c>DeliveryStatusPublisher{T}.Deliver</c> recorded the baseline before
    /// <c>_push</c> ever ran, so a throw from the sink still left that value marked as delivered.
    /// With nothing newer queued afterwards, a later identical
    /// <c>DeliveryStatusPublisher{T}.PushIfChanged</c> call was then suppressed as "no
    /// change" even though the tray never actually received it -- the one state that failed to reach
    /// the tray could never be retried, and with no logging framework it simply vanished. This pins
    /// that the retry actually reaches the sink.
    /// </summary>
    [Fact]
    public void AThrowingSinkWithNothingNewerQueuedDoesNotSuppressALaterIdenticalPushIfChanged()
    {
        var pushed = new List<ScreenshotDeliveryPresentation>();
        var shouldThrow = true;
        var publisher = new DeliveryStatusPublisher<ScreenshotDeliveryPresentation>(presentation =>
        {
            pushed.Add(presentation);
            if (shouldThrow)
            {
                shouldThrow = false;
                throw new InvalidOperationException("sink misbehaving");
            }
        });

        publisher.PushIfChanged(Uploading);
        Assert.Equal(new[] { Uploading }, pushed);

        // The sink never actually delivered Uploading -- it threw -- so an identical later
        // PushIfChanged for the same presentation must reach the sink again rather than being
        // suppressed as "no change".
        publisher.PushIfChanged(Uploading);

        Assert.Equal(new[] { Uploading, Uploading }, pushed);
    }

    /// <summary>
    /// Companion to <see cref="AThrowingSinkWithNothingNewerQueuedDoesNotSuppressALaterIdenticalPushIfChanged"/>:
    /// proves the fix does not over-clear. When a newer value is already queued at the moment the
    /// sink throws for the older one, that newer value must still be delivered on the same drain
    /// pass, and it -- not <see langword="null"/> -- must become the baseline, so a subsequent
    /// distinct push still gets suppressed or delivered exactly as it would have without any failure
    /// having happened at all.
    /// </summary>
    [Fact]
    public void AThrowingSinkWithANewerValueAlreadyQueuedStillDeliversItWithoutClobberingTheBaseline()
    {
        var pushed = new List<ScreenshotDeliveryPresentation>();
        DeliveryStatusPublisher<ScreenshotDeliveryPresentation>? publisher = null;
        var firstCall = true;
        publisher = new DeliveryStatusPublisher<ScreenshotDeliveryPresentation>(presentation =>
        {
            pushed.Add(presentation);
            if (firstCall && presentation.Equals(Uploading))
            {
                firstCall = false;
                // Queue a newer value reentrantly while still inside the sink's own call for
                // Uploading. Deliver sees delivery already in progress and only records it into
                // _pendingDelivery, trusting this same drain loop to pick it up on its next
                // iteration -- exactly the shape a genuinely concurrent caller would also produce.
                publisher!.PushIfChanged(NotProvisioned);
                throw new InvalidOperationException("sink misbehaving");
            }
        });

        publisher.PushIfChanged(Uploading);

        // The throw must not have stranded the already-queued newer value: it still gets delivered
        // in the same drain pass.
        Assert.Equal(new[] { Uploading, NotProvisioned }, pushed);

        // Because a newer value was pending when Uploading's delivery failed, the fix must not have
        // cleared the baseline out from under it: NotProvisioned is the current baseline, so a repeat
        // of it is still suppressed as "no change" ...
        publisher.PushIfChanged(NotProvisioned);
        Assert.Equal(new[] { Uploading, NotProvisioned }, pushed);

        // ... while a genuinely distinct push still gets through normally.
        publisher.PushIfChanged(Abandoned);
        Assert.Equal(new[] { Uploading, NotProvisioned, Abandoned }, pushed);
    }
}
