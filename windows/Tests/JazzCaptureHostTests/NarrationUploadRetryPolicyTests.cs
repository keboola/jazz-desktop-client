using JazzCapture;

namespace JazzCaptureHostTests;

/// <summary>
/// The jittered, bounded backoff schedule for a retryable narration upload, and for the drain
/// loop's own pass-level backoff. Mirrors <see cref="EventStreamRetryPolicyTests"/>, against
/// <see cref="NarrationDeliverySettings"/>' own defaults (10 s initial, 15 min ceiling).
/// </summary>
public sealed class NarrationUploadRetryPolicyTests
{
    private const string IdentityA = "s-0199f0c0-1c00-7a11-b000-00000000000a/0000000001.abc.narration.audio";
    private const string IdentityB = "s-0199f0c0-1c00-7a11-b000-00000000000b/0000000002.def.narration.audio";

    [Theory]
    [InlineData(0, 10_000)]
    [InlineData(1, 10_000)]
    [InlineData(2, 20_000)]
    [InlineData(3, 40_000)]
    [InlineData(4, 80_000)]
    [InlineData(5, 160_000)]
    [InlineData(6, 320_000)]
    [InlineData(7, 640_000)]
    // 10 s << 6 == 640 s is the largest power-of-two multiple of the 10 s initial that still fits
    // under the 900 s (15 min) ceiling -- the next doubling (1280 s) would overshoot it, so the
    // schedule plateaus here and never actually reaches the literal 900 s ceiling value.
    [InlineData(8, 640_000)]
    [InlineData(9, 640_000)]
    [InlineData(10, 640_000)]
    public void TheDelayDoublesPerAttemptThenPlateausAtTheHighestStepUnderTheCeiling(int failedAttempt, long exponentialMilliseconds)
    {
        var settings = new NarrationDeliverySettings();

        TimeSpan delay = NarrationUploadRetryPolicy.Delay(failedAttempt, IdentityA, settings);

        Assert.InRange(
            delay,
            TimeSpan.FromMilliseconds(exponentialMilliseconds * 75 / 100),
            TimeSpan.FromMilliseconds(exponentialMilliseconds));
    }

    [Fact]
    public void TheDelayIsNeverZeroAndNeverExceedsTheCeiling()
    {
        var settings = new NarrationDeliverySettings();

        foreach (string identity in new[] { IdentityA, IdentityB })
        {
            for (var attempt = 0; attempt <= 40; attempt++)
            {
                TimeSpan delay = NarrationUploadRetryPolicy.Delay(attempt, identity, settings);
                Assert.InRange(delay, TimeSpan.FromMilliseconds(1), settings.UploadBackoffCeiling);
            }
        }
    }

    [Fact]
    public void TheDelayIsDeterministicForTheSameInputs()
    {
        var settings = new NarrationDeliverySettings();

        for (var attempt = 0; attempt <= 12; attempt++)
        {
            Assert.Equal(
                NarrationUploadRetryPolicy.Delay(attempt, IdentityA, settings),
                NarrationUploadRetryPolicy.Delay(attempt, IdentityA, settings));
        }
    }

    [Fact]
    public void DifferentIdentitiesDoNotSynchronizeTheirRetries()
    {
        var settings = new NarrationDeliverySettings();

        Assert.NotEqual(
            NarrationUploadRetryPolicy.Delay(6, IdentityA, settings),
            NarrationUploadRetryPolicy.Delay(6, IdentityB, settings));
    }

    [Fact]
    public void TheDomainDiffersFromEveryOtherRetryPolicyForTheSameIdentity()
    {
        var narrationSettings = new NarrationDeliverySettings
        {
            UploadBackoffInitial = TimeSpan.FromSeconds(1),
            UploadBackoffCeiling = TimeSpan.FromSeconds(8),
        };
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
            NarrationUploadRetryPolicy.Delay(4, IdentityA, narrationSettings),
            EventStreamRetryPolicy.Delay(4, IdentityA, eventSettings));
        Assert.NotEqual(
            NarrationUploadRetryPolicy.Delay(4, IdentityA, narrationSettings),
            ScreenshotUploadRetryPolicy.Delay(4, IdentityA, screenshotSettings));
    }

    [Fact]
    public void ANegativeAttemptIsRejected()
    {
        var settings = new NarrationDeliverySettings();

        Assert.Throws<ArgumentOutOfRangeException>(
            () => NarrationUploadRetryPolicy.Delay(-1, IdentityA, settings));
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    public void AMissingIdentityIsRejected(string? identity)
    {
        var settings = new NarrationDeliverySettings();

        Assert.Throws<ArgumentException>(
            () => NarrationUploadRetryPolicy.Delay(1, identity!, settings));
    }

    [Fact]
    public void MinimumFirstAttemptDelayIsPositiveForTheDefaults()
    {
        var settings = new NarrationDeliverySettings();

        Exception? thrown = Record.Exception(settings.Validate);

        Assert.Null(thrown);
    }
}
