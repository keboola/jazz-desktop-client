using JazzCaptureCore.Input;

namespace JazzCaptureCoreTests;

/// <summary>
/// Pins the click-multiplicity and click-versus-drag arithmetic the coordinator defers on.
/// </summary>
/// <remarks>
/// The contract the coordinator depends on is narrow but load-bearing: a release that continues the
/// previous sequence reports a count above 1, and a release that starts a new one reports exactly 1.
/// The coordinator reads that as "my deferred click has been displaced" and publishes the waiting
/// click before replacing it; without the guarantee below, a second click at a different place
/// inside the double-click window would silently erase the first.
/// </remarks>
public sealed class PointerGestureTrackerTests
{
    private const uint DoubleClickMillis = 500;

    private static GestureMetrics Metrics() => new(
        DoubleClickMillis,
        DoubleClickWidth: 4,
        DoubleClickHeight: 4,
        DragWidth: 4,
        DragHeight: 4);

    private static PointerRelease Click(PointerGestureTracker tracker, int x, int y, uint timeMs)
    {
        tracker.OnDown(x, y);
        return tracker.OnUp(x, y, timeMs);
    }

    [Fact]
    public void ASingleClickIsCountOne()
    {
        var tracker = new PointerGestureTracker(Metrics());

        Assert.Equal(new PointerRelease(false, 1), Click(tracker, 10, 10, 1000));
    }

    [Fact]
    public void ASecondClickInsideTheWindowAndRectangleContinuesTheSequence()
    {
        var tracker = new PointerGestureTracker(Metrics());

        Click(tracker, 10, 10, 1000);
        Assert.Equal(2, Click(tracker, 12, 12, 1200).ClickCount);
        Assert.Equal(3, Click(tracker, 10, 11, 1400).ClickCount);
    }

    [Fact]
    public void MultiplicityStopsAtTriple()
    {
        var tracker = new PointerGestureTracker(Metrics());

        Click(tracker, 10, 10, 1000);
        Click(tracker, 10, 10, 1100);
        Click(tracker, 10, 10, 1200);

        Assert.Equal(3, Click(tracker, 10, 10, 1300).ClickCount);
    }

    [Fact]
    public void AClickOutsideTheRectangleStartsAFreshSequenceEvenInsideTheTimeWindow()
    {
        var tracker = new PointerGestureTracker(Metrics());

        Click(tracker, 10, 10, 1000);

        // This is the case that used to lose the first click: well inside the double-click window,
        // but far enough away that it is a different gesture.
        Assert.Equal(1, Click(tracker, 400, 400, 1100).ClickCount);
    }

    [Fact]
    public void AClickAfterTheTimeWindowStartsAFreshSequenceEvenAtTheSamePoint()
    {
        var tracker = new PointerGestureTracker(Metrics());

        Click(tracker, 10, 10, 1000);

        Assert.Equal(1, Click(tracker, 10, 10, 1000 + DoubleClickMillis + 1).ClickCount);
    }

    [Fact]
    public void TheTimeWindowIsInclusiveAtItsBoundary()
    {
        var tracker = new PointerGestureTracker(Metrics());

        Click(tracker, 10, 10, 1000);

        Assert.Equal(2, Click(tracker, 10, 10, 1000 + DoubleClickMillis).ClickCount);
    }

    [Fact]
    public void TravelBeyondTheDragThresholdIsADragAndNeverCoalesces()
    {
        var tracker = new PointerGestureTracker(Metrics());

        tracker.OnDown(10, 10);
        PointerRelease release = tracker.OnUp(200, 10, 1000);

        Assert.True(release.IsDrag);
        Assert.Equal(1, release.ClickCount);

        // A drag clears the sequence, so the click after it starts over.
        Assert.Equal(1, Click(tracker, 200, 10, 1100).ClickCount);
    }

    [Fact]
    public void TravelInsideTheDragThresholdIsStillAClick()
    {
        var tracker = new PointerGestureTracker(Metrics());

        tracker.OnDown(10, 10);
        PointerRelease release = tracker.OnUp(14, 14, 1000);

        Assert.False(release.IsDrag);
        Assert.Equal(1, release.ClickCount);
    }

    [Fact]
    public void ResetSequenceMakesTheNextClickASingleAgain()
    {
        var tracker = new PointerGestureTracker(Metrics());

        Click(tracker, 10, 10, 1000);
        tracker.ResetSequence();

        Assert.Equal(1, Click(tracker, 10, 10, 1100).ClickCount);
    }

    [Fact]
    public void NotResettingAfterADisplacingClickKeepsThatClickAsTheHeadOfItsSequence()
    {
        var tracker = new PointerGestureTracker(Metrics());

        Click(tracker, 10, 10, 1000);

        // The coordinator flushes the first click here, deliberately without ResetSequence, because
        // the tracker has already accepted this release as the head of a new sequence.
        Assert.Equal(1, Click(tracker, 400, 400, 1100).ClickCount);

        // A genuine double-click at the new location must therefore still be recognised.
        Assert.Equal(2, Click(tracker, 400, 400, 1200).ClickCount);
    }

    [Fact]
    public void TheDoubleClickBudgetIsTheSystemWindowTheHostSupplied()
    {
        var tracker = new PointerGestureTracker(Metrics());

        Assert.Equal(DoubleClickMillis, tracker.DoubleClickBudget());
    }
}
