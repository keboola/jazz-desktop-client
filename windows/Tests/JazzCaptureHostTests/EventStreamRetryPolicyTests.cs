using JazzCapture;

namespace JazzCaptureHostTests;

/// <summary>
/// The jittered, bounded backoff schedule for a retryable event send, and for the drain loop's own
/// pass-level backoff. Mirrors <see cref="ScreenshotUploadRetryPolicyTests"/>, against
/// <see cref="EventDeliverySettings"/>' own defaults (2 s initial, 5 min ceiling) rather than the
/// screenshot policy's much shorter schedule.
/// </summary>
public sealed class EventStreamRetryPolicyTests
{
    private const string IdentityA = "s-0199f0c0-1c00-7a11-b000-00000000000a/0000000001.abc.otlp.json";
    private const string IdentityB = "s-0199f0c0-1c00-7a11-b000-00000000000b/0000000002.def.otlp.json";

    [Theory]
    [InlineData(0, 2_000)]
    [InlineData(1, 2_000)]
    [InlineData(2, 4_000)]
    [InlineData(3, 8_000)]
    [InlineData(4, 16_000)]
    [InlineData(5, 32_000)]
    [InlineData(6, 64_000)]
    [InlineData(7, 128_000)]
    [InlineData(8, 256_000)]
    [InlineData(9, 300_000)]
    [InlineData(10, 300_000)]
    [InlineData(11, 300_000)]
    [InlineData(12, 300_000)]
    public void TheDelayDoublesPerAttemptAndStopsAtTheCeiling(int failedAttempt, long exponentialMilliseconds)
    {
        var settings = new EventDeliverySettings();

        TimeSpan delay = EventStreamRetryPolicy.Delay(failedAttempt, IdentityA, settings);

        // The jitter only ever removes time, and never more than a quarter of it.
        Assert.InRange(
            delay,
            TimeSpan.FromMilliseconds(exponentialMilliseconds * 75 / 100),
            TimeSpan.FromMilliseconds(exponentialMilliseconds));
    }

    [Fact]
    public void TheDelayIsNeverZeroAndNeverExceedsTheCeiling()
    {
        var settings = new EventDeliverySettings();

        foreach (string identity in new[] { IdentityA, IdentityB })
        {
            for (var attempt = 0; attempt <= 40; attempt++)
            {
                TimeSpan delay = EventStreamRetryPolicy.Delay(attempt, identity, settings);
                Assert.InRange(delay, TimeSpan.FromMilliseconds(1), settings.SendBackoffCeiling);
            }
        }
    }

    [Fact]
    public void TheDelayIsDeterministicForTheSameInputs()
    {
        var settings = new EventDeliverySettings();

        for (var attempt = 0; attempt <= 12; attempt++)
        {
            Assert.Equal(
                EventStreamRetryPolicy.Delay(attempt, IdentityA, settings),
                EventStreamRetryPolicy.Delay(attempt, IdentityA, settings));
        }
    }

    [Fact]
    public void DifferentIdentitiesDoNotSynchronizeTheirRetries()
    {
        var settings = new EventDeliverySettings();

        Assert.NotEqual(
            EventStreamRetryPolicy.Delay(6, IdentityA, settings),
            EventStreamRetryPolicy.Delay(6, IdentityB, settings));
    }

    [Fact]
    public void TheDomainDiffersFromEveryOtherRetryPolicyForTheSameIdentity()
    {
        var eventSettings = new EventDeliverySettings
        {
            SendBackoffInitial = TimeSpan.FromSeconds(1),
            SendBackoffCeiling = TimeSpan.FromSeconds(8),
        };
        var screenshotSettings = new ScreenshotDeliverySettings
        {
            UploadBackoffInitial = TimeSpan.FromSeconds(1),
            UploadBackoffCeiling = TimeSpan.FromSeconds(8),
        };

        Assert.NotEqual(
            EventStreamRetryPolicy.Delay(4, IdentityA, eventSettings),
            ScreenshotUploadRetryPolicy.Delay(4, IdentityA, screenshotSettings));
    }

    [Fact]
    public void ANegativeAttemptIsRejected()
    {
        var settings = new EventDeliverySettings();

        Assert.Throws<ArgumentOutOfRangeException>(
            () => EventStreamRetryPolicy.Delay(-1, IdentityA, settings));
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    public void AMissingIdentityIsRejected(string? identity)
    {
        var settings = new EventDeliverySettings();

        Assert.Throws<ArgumentException>(
            () => EventStreamRetryPolicy.Delay(1, identity!, settings));
    }

    [Fact]
    public void MinimumFirstAttemptDelayIsPositiveForTheDefaults()
    {
        var settings = new EventDeliverySettings();

        // Exercised indirectly through Validate (EventDeliverySettingsTests pins the reject/accept
        // boundary); this pins that the defaults themselves clear that floor.
        Exception? thrown = Record.Exception(settings.Validate);

        Assert.Null(thrown);
    }
}
