using JazzCapture;

namespace JazzCaptureHostTests;

/// <summary>
/// <see cref="NarrationDeliveryPresentation.Describe"/> is the tray's fourth delivery line
/// (issue #84, §2.8), modelled directly on <see cref="EventDeliveryPresentationTests"/>. Every state
/// it can render must be covered explicitly, and none of them may render as an error.
/// </summary>
public sealed class NarrationDeliveryPresentationTests
{
    [Theory]
    [InlineData(NarrationDeliveryPresentationState.NotProvisioned, 0, "not provisioned")]
    [InlineData(NarrationDeliveryPresentationState.UpToDate, 0, "up to date")]
    [InlineData(NarrationDeliveryPresentationState.Uploading, 2, "uploading 2")]
    [InlineData(NarrationDeliveryPresentationState.Retrying, 3, "retrying 3")]
    [InlineData(NarrationDeliveryPresentationState.Abandoned, 1, "1 undelivered")]
    [InlineData(NarrationDeliveryPresentationState.Abandoned, 5, "5 undelivered")]
    [InlineData(NarrationDeliveryPresentationState.Unavailable, 0, "spool unavailable; narration not delivered")]
    public void RendersOnlySafeStateAndCount(NarrationDeliveryPresentationState state, int count, string expected)
    {
        string text = new NarrationDeliveryPresentation(state, count).Describe();

        Assert.Equal(expected, text);
        Assert.DoesNotContain("secret", text, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("https", text, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("token", text, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("\\", text, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData(NarrationDeliveryPresentationState.NotProvisioned)]
    [InlineData(NarrationDeliveryPresentationState.UpToDate)]
    [InlineData(NarrationDeliveryPresentationState.Uploading)]
    [InlineData(NarrationDeliveryPresentationState.Retrying)]
    [InlineData(NarrationDeliveryPresentationState.Abandoned)]
    [InlineData(NarrationDeliveryPresentationState.Unavailable)]
    public void NoStateRendersAsAnError(NarrationDeliveryPresentationState state)
    {
        string text = new NarrationDeliveryPresentation(state, 0).Describe();

        Assert.False(text.StartsWith('!'));
    }

    [Fact]
    public void StaysWithinTheTraysSixtyThreeCharacterLineBudgetForALargeCount()
    {
        foreach (NarrationDeliveryPresentationState state in Enum.GetValues<NarrationDeliveryPresentationState>())
        {
            string line = "Narration: " + new NarrationDeliveryPresentation(state, int.MaxValue).Describe();
            Assert.True(line.Length <= 63, $"'{line}' is {line.Length} characters long.");
        }
    }
}

/// <summary>
/// <see cref="NarrationDeliveryPresentationTracker"/> aggregates the spool's live pending/retrying
/// state with the delivery worker's outcome events into one <see cref="NarrationDeliveryPresentation"/>.
/// Mirrors <see cref="EventDeliveryPresentationTrackerTests"/>.
/// </summary>
public sealed class NarrationDeliveryPresentationTrackerTests
{
    [Fact]
    public void ReportsNotProvisionedWheneverNoTargetExistsRegardlessOfPendingCount()
    {
        var tracker = new NarrationDeliveryPresentationTracker();

        NarrationDeliveryPresentation presentation = tracker.Resolve(provisioned: false, pendingCount: 5, anyRetrying: false);

        Assert.Equal(NarrationDeliveryPresentationState.NotProvisioned, presentation.State);
    }

    [Fact]
    public void ReportsUpToDateWhenNothingIsPendingAndNothingWasEverAbandoned()
    {
        var tracker = new NarrationDeliveryPresentationTracker();

        NarrationDeliveryPresentation presentation = tracker.Resolve(provisioned: true, pendingCount: 0, anyRetrying: false);

        Assert.Equal(NarrationDeliveryPresentationState.UpToDate, presentation.State);
        Assert.Equal(0, presentation.Count);
    }

    [Fact]
    public void ReportsUploadingWhilePendingAndNothingIsRetrying()
    {
        var tracker = new NarrationDeliveryPresentationTracker();

        NarrationDeliveryPresentation presentation = tracker.Resolve(provisioned: true, pendingCount: 3, anyRetrying: false);

        Assert.Equal(NarrationDeliveryPresentationState.Uploading, presentation.State);
        Assert.Equal(3, presentation.Count);
    }

    [Fact]
    public void ReportsRetryingWhenTheSpoolReportsAnyRetryingRegardlessOfOutcomeHistory()
    {
        var tracker = new NarrationDeliveryPresentationTracker();

        NarrationDeliveryPresentation presentation = tracker.Resolve(provisioned: true, pendingCount: 1, anyRetrying: true);

        Assert.Equal(NarrationDeliveryPresentationState.Retrying, presentation.State);
    }

    [Fact]
    public void KeepsReportingAbandonedClipsAfterTheSpoolDrainsToEmpty()
    {
        var tracker = new NarrationDeliveryPresentationTracker();
        tracker.OnOutcome(new NarrationDeliveryOutcomeEvent("s-1/0000000001.abc", NarrationDeliveryOutcome.Dropped));

        NarrationDeliveryPresentation presentation = tracker.Resolve(provisioned: true, pendingCount: 0, anyRetrying: false);

        Assert.Equal(NarrationDeliveryPresentationState.Abandoned, presentation.State);
        Assert.Equal(1, presentation.Count);
    }

    [Fact]
    public void CountsEvictionsRefusalsAndVerificationFailuresAsAbandonedTooAndAccumulates()
    {
        var tracker = new NarrationDeliveryPresentationTracker();
        tracker.OnOutcome(new NarrationDeliveryOutcomeEvent("a", NarrationDeliveryOutcome.Evicted));
        tracker.OnOutcome(new NarrationDeliveryOutcomeEvent("b", NarrationDeliveryOutcome.Refused));
        tracker.OnOutcome(new NarrationDeliveryOutcomeEvent("c", NarrationDeliveryOutcome.VerificationFailed));
        tracker.OnOutcome(new NarrationDeliveryOutcomeEvent("d", NarrationDeliveryOutcome.Dropped));

        NarrationDeliveryPresentation presentation = tracker.Resolve(provisioned: true, pendingCount: 0, anyRetrying: false);

        Assert.Equal(NarrationDeliveryPresentationState.Abandoned, presentation.State);
        Assert.Equal(4, presentation.Count);
    }

    [Fact]
    public void PrefersCurrentPendingWorkOverAStaleAbandonedCountWhenNewClipsAreQueued()
    {
        var tracker = new NarrationDeliveryPresentationTracker();
        tracker.OnOutcome(new NarrationDeliveryOutcomeEvent("a", NarrationDeliveryOutcome.Dropped));

        NarrationDeliveryPresentation presentation = tracker.Resolve(provisioned: true, pendingCount: 2, anyRetrying: false);

        Assert.Equal(NarrationDeliveryPresentationState.Uploading, presentation.State);
        Assert.Equal(2, presentation.Count);
    }

    /// <summary>
    /// An abandoned tally must not be hidden behind <c>NotProvisioned</c>: an unprovisioned machine
    /// accumulating evictions/refusals/terminal drops is the ordinary case #53 scope 4 describes.
    /// </summary>
    [Fact]
    public void ReportsAbandonedRatherThanNotProvisionedWhenClipsWereAbandonedWhileUnprovisioned()
    {
        var tracker = new NarrationDeliveryPresentationTracker();
        tracker.OnOutcome(new NarrationDeliveryOutcomeEvent("a", NarrationDeliveryOutcome.Dropped));

        NarrationDeliveryPresentation presentation = tracker.Resolve(provisioned: false, pendingCount: 0, anyRetrying: false);

        Assert.Equal(NarrationDeliveryPresentationState.Abandoned, presentation.State);
        Assert.Equal(1, presentation.Count);
    }

    [Fact]
    public void ReportsNotProvisionedWhenNothingWasEverAbandoned()
    {
        var tracker = new NarrationDeliveryPresentationTracker();

        NarrationDeliveryPresentation presentation = tracker.Resolve(provisioned: false, pendingCount: 0, anyRetrying: false);

        Assert.Equal(NarrationDeliveryPresentationState.NotProvisioned, presentation.State);
    }

    [Fact]
    public void AcknowledgedAndRetryingOutcomesDoNotAffectTheAbandonedTally()
    {
        var tracker = new NarrationDeliveryPresentationTracker();
        tracker.OnOutcome(new NarrationDeliveryOutcomeEvent("a", NarrationDeliveryOutcome.Acknowledged));
        tracker.OnOutcome(new NarrationDeliveryOutcomeEvent("b", NarrationDeliveryOutcome.Retrying));

        NarrationDeliveryPresentation presentation = tracker.Resolve(provisioned: true, pendingCount: 0, anyRetrying: false);

        Assert.Equal(NarrationDeliveryPresentationState.UpToDate, presentation.State);
    }
}
