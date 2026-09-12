using System.Reflection;
using JazzCapture;

namespace JazzCaptureHostTests;

/// <summary>
/// <see cref="EventDeliveryPresentation.Describe"/> is the tray's only diagnostic surface for event
/// delivery -- this codebase has no logging framework -- replacing the old two-valued
/// <c>StreamDeliveryStatus</c> and its <c>"backpressure; events dropped"</c> line. Every state it can
/// render has to be covered explicitly, and none of them may render as an error (#53 scope 5, and the
/// "Decisions on the plan's open questions" comment on issue #48).
/// </summary>
public sealed class EventDeliveryPresentationTests
{
    [Theory]
    [InlineData(EventDeliveryPresentationState.NotProvisioned, 0, "not provisioned")]
    [InlineData(EventDeliveryPresentationState.UpToDate, 0, "up to date")]
    [InlineData(EventDeliveryPresentationState.Sending, 2, "sending 2")]
    [InlineData(EventDeliveryPresentationState.Retrying, 3, "retrying 3")]
    [InlineData(EventDeliveryPresentationState.Abandoned, 1, "1 undelivered")]
    [InlineData(EventDeliveryPresentationState.Abandoned, 5, "5 undelivered")]
    [InlineData(EventDeliveryPresentationState.Unavailable, 0, "spool unavailable; events not delivered")]
    public void RendersOnlySafeStateAndCount(EventDeliveryPresentationState state, int count, string expected)
    {
        string text = new EventDeliveryPresentation(state, count).Describe();

        Assert.Equal(expected, text);
        Assert.DoesNotContain("secret", text, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("https", text, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("token", text, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("\\", text, StringComparison.Ordinal);
        Assert.DoesNotContain("/", text, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData(EventDeliveryPresentationState.NotProvisioned)]
    [InlineData(EventDeliveryPresentationState.UpToDate)]
    [InlineData(EventDeliveryPresentationState.Sending)]
    [InlineData(EventDeliveryPresentationState.Retrying)]
    [InlineData(EventDeliveryPresentationState.Abandoned)]
    [InlineData(EventDeliveryPresentationState.Unavailable)]
    public void NoStateRendersAsAnError(EventDeliveryPresentationState state)
    {
        string text = new EventDeliveryPresentation(state, 0).Describe();

        Assert.False(text.StartsWith('!'));
    }

    /// <summary>
    /// Regression coverage guarding against the old vocabulary quietly resurfacing: a member named
    /// <c>Backpressure</c> anywhere in this assembly, or the deleted <c>StreamDeliveryStatus</c> type
    /// itself still existing, would mean issue #48's replacement was undone rather than completed.
    /// </summary>
    [Fact]
    public void TheBackpressureVocabularyIsGone()
    {
        Assembly assembly = typeof(EventDeliveryPresentation).Assembly;

        Assert.Null(assembly.GetType("JazzCapture.StreamDeliveryStatus"));
        Assert.DoesNotContain(
            assembly.GetTypes(),
            type => type.IsEnum && Enum.GetNames(type).Contains("Backpressure"));
    }

    [Fact]
    public void StaysWithinTheTraysSixtyThreeCharacterLineBudgetForALargeCount()
    {
        foreach (EventDeliveryPresentationState state in Enum.GetValues<EventDeliveryPresentationState>())
        {
            string line = "Streaming: " + new EventDeliveryPresentation(state, int.MaxValue).Describe();
            Assert.True(line.Length <= 63, $"'{line}' is {line.Length} characters long.");
        }
    }
}

/// <summary>
/// <see cref="EventDeliveryPresentationTracker"/> aggregates the spool's live pending/retrying state
/// with the delivery worker's outcome events into one <see cref="EventDeliveryPresentation"/>.
/// </summary>
public sealed class EventDeliveryPresentationTrackerTests
{
    [Fact]
    public void ReportsNotProvisionedWheneverNoTargetExistsRegardlessOfPendingCount()
    {
        var tracker = new EventDeliveryPresentationTracker();

        EventDeliveryPresentation presentation = tracker.Resolve(provisioned: false, pendingCount: 5, anyRetrying: false);

        Assert.Equal(EventDeliveryPresentationState.NotProvisioned, presentation.State);
    }

    [Fact]
    public void ReportsUpToDateWhenNothingIsPendingAndNothingWasEverAbandoned()
    {
        var tracker = new EventDeliveryPresentationTracker();

        EventDeliveryPresentation presentation = tracker.Resolve(provisioned: true, pendingCount: 0, anyRetrying: false);

        Assert.Equal(EventDeliveryPresentationState.UpToDate, presentation.State);
        Assert.Equal(0, presentation.Count);
    }

    [Fact]
    public void ReportsSendingWhilePendingAndNothingIsRetrying()
    {
        var tracker = new EventDeliveryPresentationTracker();

        EventDeliveryPresentation presentation = tracker.Resolve(provisioned: true, pendingCount: 3, anyRetrying: false);

        Assert.Equal(EventDeliveryPresentationState.Sending, presentation.State);
        Assert.Equal(3, presentation.Count);
    }

    [Fact]
    public void ReportsRetryingWhenTheSpoolReportsAnyRetryingRegardlessOfOutcomeHistory()
    {
        var tracker = new EventDeliveryPresentationTracker();

        EventDeliveryPresentation presentation = tracker.Resolve(provisioned: true, pendingCount: 1, anyRetrying: true);

        Assert.Equal(EventDeliveryPresentationState.Retrying, presentation.State);
    }

    [Fact]
    public void KeepsReportingAbandonedEventsAfterTheSpoolDrainsToEmpty()
    {
        var tracker = new EventDeliveryPresentationTracker();
        tracker.OnOutcome(new EventDeliveryOutcomeEvent("s-1/0000000001.abc.otlp.json", EventDeliveryOutcome.Dropped));

        EventDeliveryPresentation presentation = tracker.Resolve(provisioned: true, pendingCount: 0, anyRetrying: false);

        Assert.Equal(EventDeliveryPresentationState.Abandoned, presentation.State);
        Assert.Equal(1, presentation.Count);
    }

    [Fact]
    public void CountsEvictionsRefusalsAndVerificationFailuresAsAbandonedTooAndAccumulates()
    {
        var tracker = new EventDeliveryPresentationTracker();
        tracker.OnOutcome(new EventDeliveryOutcomeEvent("a", EventDeliveryOutcome.Evicted));
        tracker.OnOutcome(new EventDeliveryOutcomeEvent("b", EventDeliveryOutcome.Refused));
        tracker.OnOutcome(new EventDeliveryOutcomeEvent("c", EventDeliveryOutcome.VerificationFailed));
        tracker.OnOutcome(new EventDeliveryOutcomeEvent("d", EventDeliveryOutcome.Dropped));

        EventDeliveryPresentation presentation = tracker.Resolve(provisioned: true, pendingCount: 0, anyRetrying: false);

        Assert.Equal(EventDeliveryPresentationState.Abandoned, presentation.State);
        Assert.Equal(4, presentation.Count);
    }

    [Fact]
    public void PrefersCurrentPendingWorkOverAStaleAbandonedCountWhenNewEventsAreQueued()
    {
        var tracker = new EventDeliveryPresentationTracker();
        tracker.OnOutcome(new EventDeliveryOutcomeEvent("a", EventDeliveryOutcome.Dropped));

        EventDeliveryPresentation presentation = tracker.Resolve(provisioned: true, pendingCount: 2, anyRetrying: false);

        Assert.Equal(EventDeliveryPresentationState.Sending, presentation.State);
        Assert.Equal(2, presentation.Count);
    }

    [Fact]
    public void ReportsNotProvisionedEvenAfterEventsWereAbandonedWhileProvisioned()
    {
        var tracker = new EventDeliveryPresentationTracker();
        tracker.OnOutcome(new EventDeliveryOutcomeEvent("a", EventDeliveryOutcome.Dropped));

        EventDeliveryPresentation presentation = tracker.Resolve(provisioned: false, pendingCount: 0, anyRetrying: false);

        Assert.Equal(EventDeliveryPresentationState.NotProvisioned, presentation.State);
    }

    [Fact]
    public void AcknowledgedAndRetryingOutcomesDoNotAffectTheAbandonedTally()
    {
        var tracker = new EventDeliveryPresentationTracker();
        tracker.OnOutcome(new EventDeliveryOutcomeEvent("a", EventDeliveryOutcome.Acknowledged));
        tracker.OnOutcome(new EventDeliveryOutcomeEvent("b", EventDeliveryOutcome.Retrying));

        EventDeliveryPresentation presentation = tracker.Resolve(provisioned: true, pendingCount: 0, anyRetrying: false);

        Assert.Equal(EventDeliveryPresentationState.UpToDate, presentation.State);
    }
}
