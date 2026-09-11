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
/// <see cref="ScreenshotDeliveryStatusPublisher"/> is the seam below <c>App.PrepareScreenshotDelivery</c>
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
        var publisher = new ScreenshotDeliveryStatusPublisher(pushed.Add);

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
        var publisher = new ScreenshotDeliveryStatusPublisher(pushed.Add);
        publisher.PushIfChanged(NotProvisioned);

        publisher.PushIfChanged(NotProvisioned);

        Assert.Single(pushed);
    }

    [Fact]
    public void AChangeAfterARepeatedDeclinePushesAgain()
    {
        var pushed = new List<ScreenshotDeliveryPresentation>();
        var publisher = new ScreenshotDeliveryStatusPublisher(pushed.Add);
        publisher.PushIfChanged(NotProvisioned);
        publisher.PushIfChanged(NotProvisioned);

        publisher.PushIfChanged(Abandoned);

        Assert.Equal(new[] { NotProvisioned, Abandoned }, pushed);
    }

    [Fact]
    public void PushAlwaysPushesRegardlessOfTheBaseline()
    {
        var pushed = new List<ScreenshotDeliveryPresentation>();
        var publisher = new ScreenshotDeliveryStatusPublisher(pushed.Add);
        var upToDate = new ScreenshotDeliveryPresentation(ScreenshotDeliveryPresentationState.UpToDate, 0);
        publisher.Push(upToDate);

        publisher.Push(upToDate);

        Assert.Equal(new[] { upToDate, upToDate }, pushed);
    }

    /// <summary>
    /// Pins that the baseline is shared across both methods: a <see cref="ScreenshotDeliveryStatusPublisher.Push"/>
    /// from one call site (e.g. a successful stage) must be visible to a later
    /// <see cref="ScreenshotDeliveryStatusPublisher.PushIfChanged"/> from a different call site (e.g.
    /// a declined prepare), so the two can never disagree about what the tray currently shows.
    /// </summary>
    [Fact]
    public void APushUpdatesTheBaselineThatALaterPushIfChangedComparesAgainst()
    {
        var pushed = new List<ScreenshotDeliveryPresentation>();
        var publisher = new ScreenshotDeliveryStatusPublisher(pushed.Add);
        publisher.Push(Uploading);

        publisher.PushIfChanged(Uploading);

        Assert.Single(pushed);
    }

    /// <summary>
    /// Regression coverage for Finding 3 (#74 review, third pass). The previous shape of this type
    /// recorded each call's presentation as the shared baseline under its own lock, but then invoked
    /// the wrapped delegate outside that lock with no coordination between concurrent callers: an
    /// older presentation's delegate call could complete after a newer one's already had, and once
    /// that happened <see cref="ScreenshotDeliveryStatusPublisher.PushIfChanged"/>'s own change
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
        var publisher = new ScreenshotDeliveryStatusPublisher(presentation =>
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
}
