using JazzCaptureCore;
using JazzCaptureCore.Delivery;

namespace JazzCaptureCoreTests;

/// <summary>
/// The retry schedule: bounded, jittered, and derived from the durable delivery identity rather than
/// from anything the process happens to hold in memory.
/// </summary>
public sealed class ArchiveDeliveryRetryPolicyTests
{
    private const string DeliveryA = "del-0197f0c0-1c00-7a11-b000-00000000000a";
    private const string DeliveryB = "del-0197f0c0-1c00-7a11-b000-00000000000b";

    [Theory]
    [InlineData(0, 2_000)]
    [InlineData(1, 2_000)]
    [InlineData(2, 4_000)]
    [InlineData(3, 8_000)]
    [InlineData(9, 300_000)]
    [InlineData(50, 300_000)]
    public void TheDelayDoublesPerAttemptAndStopsAtTheCap(int failedAttempt, long exponentialMilliseconds)
    {
        long delay = ArchiveDeliveryRetryPolicy.DelayMilliseconds(failedAttempt, DeliveryA);

        // The jitter only ever removes time, and never more than a quarter of it.
        Assert.InRange(delay, exponentialMilliseconds * 75 / 100, exponentialMilliseconds);
    }

    [Fact]
    public void TheDelayIsNeverZeroAndNeverExceedsTheCap()
    {
        foreach (string deliveryId in new[] { DeliveryA, DeliveryB })
        {
            for (var attempt = 0; attempt <= 40; attempt++)
            {
                long delay = ArchiveDeliveryRetryPolicy.DelayMilliseconds(attempt, deliveryId);
                Assert.InRange(delay, 1, ArchiveDeliveryRetryPolicy.MaximumDelayMilliseconds);
            }
        }
    }

    [Fact]
    public void OneDeliveryComputesTheSameScheduleEveryTime()
    {
        // This is what makes a relaunch preserve a backoff instead of restarting it.
        for (var attempt = 0; attempt <= 12; attempt++)
        {
            Assert.Equal(
                ArchiveDeliveryRetryPolicy.DelayMilliseconds(attempt, DeliveryA),
                ArchiveDeliveryRetryPolicy.DelayMilliseconds(attempt, DeliveryA));
        }
    }

    [Fact]
    public void DifferentDeliveriesDoNotSynchronizeTheirRetries()
    {
        // At the cap the window is 75 seconds wide, so two identities landing on the same
        // millisecond would mean the jitter is not keyed on the identity at all.
        Assert.NotEqual(
            ArchiveDeliveryRetryPolicy.DelayMilliseconds(9, DeliveryA),
            ArchiveDeliveryRetryPolicy.DelayMilliseconds(9, DeliveryB));
    }

    [Fact]
    public void TheWatermarkIsTheAnchorPlusTheDelay()
    {
        var anchor = new DateTimeOffset(2026, 8, 12, 9, 0, 0, TimeSpan.Zero);

        DateTimeOffset due = ArchiveDeliveryRetryPolicy.NextAttemptAt(anchor, 3, DeliveryA);

        Assert.Equal(
            anchor.AddMilliseconds(ArchiveDeliveryRetryPolicy.DelayMilliseconds(3, DeliveryA)),
            due);
        Assert.True(due > anchor);
    }

    [Fact]
    public void AnIdentityTheQueueCouldNotHaveMintedIsRefused()
    {
        var anchor = DateTimeOffset.UnixEpoch;

        Assert.Throws<ArgumentException>(() => ArchiveDeliveryRetryPolicy.NextAttemptAt(anchor, 1, "uop-1"));
        Assert.Throws<ArgumentException>(
            () => ArchiveDeliveryRetryPolicy.NextAttemptAt(anchor, 1, "del-not-a-uuid"));
        Assert.Throws<ArgumentOutOfRangeException>(
            () => ArchiveDeliveryRetryPolicy.NextAttemptAt(anchor, -1, DeliveryA));
    }

    [Fact]
    public void AMintedDeliveryIdentityIsAcceptedByThePolicy()
    {
        string deliveryId = DeliveryIds.NewDeliveryId();

        Assert.True(DeliveryIds.IsDeliveryId(deliveryId));
        Assert.InRange(
            ArchiveDeliveryRetryPolicy.NextAttemptAt(DateTimeOffset.UnixEpoch, 1, deliveryId),
            DateTimeOffset.UnixEpoch.AddMilliseconds(1),
            DateTimeOffset.UnixEpoch.AddMilliseconds(ArchiveDeliveryRetryPolicy.InitialDelayMilliseconds));
    }

    [Fact]
    public void ADeliveryIdentityIsMintedFreshEveryTime()
    {
        var minted = new HashSet<string>(StringComparer.Ordinal);
        for (var index = 0; index < 64; index++)
        {
            Assert.True(minted.Add(DeliveryIds.NewDeliveryId()));
        }
    }

    [Fact]
    public void TheWatermarkRoundTripsThroughTheArchiveTimestampFormat()
    {
        var anchor = new DateTimeOffset(2026, 8, 12, 9, 0, 0, TimeSpan.Zero);

        DateTimeOffset due = ArchiveDeliveryRetryPolicy.NextAttemptAt(anchor, 5, DeliveryA);
        string text = Timestamps.IsoMillisUtc(due);

        Assert.Equal(due, Timestamps.TryParseRfc3339(text));
    }
}
