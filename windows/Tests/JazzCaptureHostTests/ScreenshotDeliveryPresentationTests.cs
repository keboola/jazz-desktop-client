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
