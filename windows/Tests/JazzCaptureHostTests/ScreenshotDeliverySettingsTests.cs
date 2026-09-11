using JazzCapture;

namespace JazzCaptureHostTests;

/// <summary>
/// Prepare-early screenshot delivery has no hardcoded timeouts, budgets, limits, or retention: every
/// bound lives in <see cref="ScreenshotDeliverySettings"/> and is validated once at startup. These
/// tests pin the documented defaults, exercise every rejection <see cref="ScreenshotDeliverySettings.Validate"/>
/// must enforce, guard against the staging directory silently becoming the closed branch's durable
/// spool, and check the jittered upload backoff schedule computed by
/// <see cref="ScreenshotUploadRetryPolicy"/>.
/// </summary>
public sealed class ScreenshotDeliverySettingsTests
{
    [Fact]
    public void TheDefaultsAreTheDocumentedValuesAndValidate()
    {
        var settings = new ScreenshotDeliverySettings();

        Assert.Equal(TimeSpan.FromSeconds(3), settings.PrepareBudget);
        Assert.Equal(5, settings.UploadAttempts);
        Assert.Equal(TimeSpan.FromSeconds(1), settings.UploadBackoffInitial);
        Assert.Equal(TimeSpan.FromSeconds(8), settings.UploadBackoffCeiling);
        Assert.Equal(TimeSpan.FromSeconds(30), settings.UploadCallBudget);
        Assert.Equal(TimeSpan.FromSeconds(2), settings.PrepareWaitGrace);
        Assert.Equal(TimeSpan.FromSeconds(2), settings.PrepareCleanupBudget);
        Assert.Equal(256L * 1024 * 1024, settings.StagingByteCeiling);
        Assert.Equal(TimeSpan.FromHours(24), settings.StagingRetention);

        settings.Validate();
    }

    [Fact]
    public void TheStagingDirectoryIsFullyQualifiedAndNotTheClosedBranchDurableSpool()
    {
        var settings = new ScreenshotDeliverySettings();

        Assert.True(Path.IsPathFullyQualified(settings.StagingDirectory));
        Assert.EndsWith(
            Path.Combine("staging", "screenshots"),
            settings.StagingDirectory,
            StringComparison.OrdinalIgnoreCase);
        Assert.Contains(
            Path.Combine("Jazz", "staging", "screenshots"),
            settings.StagingDirectory,
            StringComparison.OrdinalIgnoreCase);

        // The closed branch's durable screenshot spool lived here. Silently re-pointing the
        // (non-durable) staging area at that path would be a durability lie.
        string closedBranchDurableSpool = Path.Combine("Jazz", "spool", "screenshots");
        Assert.DoesNotContain(
            closedBranchDurableSpool,
            settings.StagingDirectory,
            StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void ValidateRejectsANonPositivePrepareBudget()
    {
        var settings = new ScreenshotDeliverySettings { PrepareBudget = TimeSpan.Zero };

        Assert.Throws<ArgumentOutOfRangeException>(settings.Validate);
    }

    [Fact]
    public void ValidateRejectsFewerThanOneUploadAttempt()
    {
        var settings = new ScreenshotDeliverySettings { UploadAttempts = 0 };

        Assert.Throws<ArgumentOutOfRangeException>(settings.Validate);
    }

    [Fact]
    public void ValidateRejectsANonPositiveInitialUploadBackoff()
    {
        var settings = new ScreenshotDeliverySettings { UploadBackoffInitial = TimeSpan.Zero };

        Assert.Throws<ArgumentOutOfRangeException>(settings.Validate);
    }

    [Fact]
    public void ValidateRejectsAnUploadBackoffCeilingShorterThanTheInitialDelay()
    {
        var settings = new ScreenshotDeliverySettings
        {
            UploadBackoffInitial = TimeSpan.FromSeconds(4),
            UploadBackoffCeiling = TimeSpan.FromSeconds(1),
        };

        Assert.Throws<ArgumentOutOfRangeException>(settings.Validate);
    }

    /// <summary>
    /// Regression coverage for Finding 3 (#74 review, second pass):
    /// <see cref="ScreenshotUploadRetryPolicy.Delay"/> truncates to whole milliseconds before
    /// applying jitter, so a sub-millisecond -- or merely too-small -- <c>UploadBackoffInitial</c>
    /// computes a zero delay for the very first retry, which would let
    /// <see cref="ScreenshotDeliveryScheduler"/>'s exception-path retry loop spin with no backoff at
    /// all. One millisecond is exactly one short of the derived floor: with the jitter floor at 7500
    /// basis points, <c>1ms * 7500 / 10000</c> truncates to zero, but <c>2ms * 7500 / 10000</c> does
    /// not (<see cref="ValidateAcceptsTheSmallestUploadBackoffInitialThatCanProduceAPositiveDelay"/>).
    /// </summary>
    [Fact]
    public void ValidateRejectsAnUploadBackoffInitialThatCannotProduceAPositiveDelayAfterJitter()
    {
        var settings = new ScreenshotDeliverySettings { UploadBackoffInitial = TimeSpan.FromMilliseconds(1) };

        Assert.Throws<ArgumentOutOfRangeException>(settings.Validate);
    }

    /// <summary>
    /// Companion to <see cref="ValidateRejectsAnUploadBackoffInitialThatCannotProduceAPositiveDelayAfterJitter"/>:
    /// two milliseconds is the smallest value that survives the worst-case jitter multiplier without
    /// truncating to zero, so <see cref="ScreenshotDeliverySettings.Validate"/> must accept it.
    /// </summary>
    [Fact]
    public void ValidateAcceptsTheSmallestUploadBackoffInitialThatCanProduceAPositiveDelay()
    {
        var settings = new ScreenshotDeliverySettings { UploadBackoffInitial = TimeSpan.FromMilliseconds(2) };

        Exception? thrown = Record.Exception(settings.Validate);

        Assert.Null(thrown);
    }

    [Fact]
    public void ValidateRejectsANonPositiveUploadCallBudget()
    {
        var settings = new ScreenshotDeliverySettings { UploadCallBudget = TimeSpan.Zero };

        Assert.Throws<ArgumentOutOfRangeException>(settings.Validate);
    }

    [Fact]
    public void ValidateRejectsANonPositivePrepareWaitGrace()
    {
        var settings = new ScreenshotDeliverySettings { PrepareWaitGrace = TimeSpan.Zero };

        Assert.Throws<ArgumentOutOfRangeException>(settings.Validate);
    }

    [Fact]
    public void ValidateRejectsANonPositivePrepareCleanupBudget()
    {
        var settings = new ScreenshotDeliverySettings { PrepareCleanupBudget = TimeSpan.Zero };

        Assert.Throws<ArgumentOutOfRangeException>(settings.Validate);
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    public void ValidateRejectsAMissingStagingDirectory(string stagingDirectory)
    {
        var settings = new ScreenshotDeliverySettings { StagingDirectory = stagingDirectory };

        Assert.Throws<ArgumentException>(settings.Validate);
    }

    [Fact]
    public void ValidateRejectsARelativeStagingDirectory()
    {
        var settings = new ScreenshotDeliverySettings { StagingDirectory = @"Jazz\staging\screenshots" };

        Assert.Throws<ArgumentException>(settings.Validate);
    }

    [Fact]
    public void ValidateRejectsANonPositiveStagingByteCeiling()
    {
        var settings = new ScreenshotDeliverySettings { StagingByteCeiling = 0 };

        Assert.Throws<ArgumentOutOfRangeException>(settings.Validate);
    }

    [Fact]
    public void ValidateRejectsANonPositiveStagingRetention()
    {
        var settings = new ScreenshotDeliverySettings { StagingRetention = TimeSpan.Zero };

        Assert.Throws<ArgumentOutOfRangeException>(settings.Validate);
    }

    [Fact]
    public void SettingsLoadProducesAScreenshotDeliveryConfigurationThatValidates()
    {
        (Settings settings, _) = Settings.Load();

        settings.ScreenshotDelivery.Validate();
    }
}

/// <summary>
/// The jittered, bounded backoff schedule for a background screenshot upload, keyed on the artifact
/// id of the upload rather than on process-local randomness or a durable delivery identity.
/// </summary>
public sealed class ScreenshotUploadRetryPolicyTests
{
    private const string ArtifactA = "art-0199f0c0-1c00-7a11-b000-00000000000a";
    private const string ArtifactB = "art-0199f0c0-1c00-7a11-b000-00000000000b";

    [Theory]
    [InlineData(0, 1_000)]
    [InlineData(1, 1_000)]
    [InlineData(2, 2_000)]
    [InlineData(3, 4_000)]
    [InlineData(4, 8_000)]
    [InlineData(9, 8_000)]
    [InlineData(50, 8_000)]
    public void TheDelayDoublesPerAttemptAndStopsAtTheCeiling(int failedAttempt, long exponentialMilliseconds)
    {
        var settings = new ScreenshotDeliverySettings();

        TimeSpan delay = ScreenshotUploadRetryPolicy.Delay(failedAttempt, ArtifactA, settings);

        // The jitter only ever removes time, and never more than a quarter of it.
        Assert.InRange(
            delay,
            TimeSpan.FromMilliseconds(exponentialMilliseconds * 75 / 100),
            TimeSpan.FromMilliseconds(exponentialMilliseconds));
    }

    [Fact]
    public void TheDelayIsNeverZeroAndNeverExceedsTheCeiling()
    {
        var settings = new ScreenshotDeliverySettings();

        foreach (string artifactId in new[] { ArtifactA, ArtifactB })
        {
            for (var attempt = 0; attempt <= 40; attempt++)
            {
                TimeSpan delay = ScreenshotUploadRetryPolicy.Delay(attempt, artifactId, settings);
                Assert.InRange(delay, TimeSpan.FromMilliseconds(1), settings.UploadBackoffCeiling);
            }
        }
    }

    [Fact]
    public void TheDelayIsDeterministicForTheSameInputs()
    {
        var settings = new ScreenshotDeliverySettings();

        for (var attempt = 0; attempt <= 12; attempt++)
        {
            Assert.Equal(
                ScreenshotUploadRetryPolicy.Delay(attempt, ArtifactA, settings),
                ScreenshotUploadRetryPolicy.Delay(attempt, ArtifactA, settings));
        }
    }

    [Fact]
    public void DifferentArtifactsDoNotSynchronizeTheirRetries()
    {
        var settings = new ScreenshotDeliverySettings();

        // At the ceiling the jitter window is two seconds wide, so two artifact ids landing on
        // the same millisecond would mean the jitter is not keyed on the identity at all.
        Assert.NotEqual(
            ScreenshotUploadRetryPolicy.Delay(4, ArtifactA, settings),
            ScreenshotUploadRetryPolicy.Delay(4, ArtifactB, settings));
    }

    [Fact]
    public void ANegativeAttemptIsRejected()
    {
        var settings = new ScreenshotDeliverySettings();

        Assert.Throws<ArgumentOutOfRangeException>(
            () => ScreenshotUploadRetryPolicy.Delay(-1, ArtifactA, settings));
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    public void AMissingArtifactIdIsRejected(string? artifactId)
    {
        var settings = new ScreenshotDeliverySettings();

        Assert.Throws<ArgumentException>(
            () => ScreenshotUploadRetryPolicy.Delay(1, artifactId!, settings));
    }
}
