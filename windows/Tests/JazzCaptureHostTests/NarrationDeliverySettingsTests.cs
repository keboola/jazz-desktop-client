using JazzCapture;
using JazzCaptureCore.Audio;

namespace JazzCaptureHostTests;

/// <summary>
/// Mirror of <see cref="EventDeliverySettingsTests"/> for the narration clip spool's own compiled-in
/// bounds. Pins the documented defaults (issue #84 amendments 1 and 4: 512 MiB / 48 hours, and a
/// 10-minute upload call budget) and every rejection <see cref="NarrationDeliverySettings.Validate"/>
/// must enforce -- including the cross-check that <see cref="NarrationDeliverySettings.MaximumClipBytes"/>
/// must always admit a real maximal (30-minute, 16 kHz mono) sealed clip.
/// </summary>
public sealed class NarrationDeliverySettingsTests
{
    [Fact]
    public void TheDefaultsAreTheDocumentedAmendedValuesAndValidate()
    {
        var settings = new NarrationDeliverySettings();

        Assert.Equal(64L * 1024 * 1024, settings.MaximumClipBytes);
        Assert.Equal(512L * 1024 * 1024, settings.SpoolByteCeiling);
        Assert.Equal(TimeSpan.FromHours(48), settings.SpoolRetention);
        Assert.Equal(TimeSpan.FromSeconds(10), settings.PrepareBudget);
        Assert.Equal(TimeSpan.FromSeconds(5), settings.PrepareCleanupBudget);
        Assert.Equal(TimeSpan.FromMinutes(10), settings.UploadCallBudget);
        Assert.Equal(TimeSpan.FromSeconds(10), settings.UploadBackoffInitial);
        Assert.Equal(TimeSpan.FromMinutes(15), settings.UploadBackoffCeiling);
        Assert.True(Path.IsPathFullyQualified(settings.SpoolDirectory));
        Assert.Contains(Path.Combine("Jazz", "spool", "narration"), settings.SpoolDirectory, StringComparison.OrdinalIgnoreCase);

        settings.Validate();
    }

    /// <summary>
    /// Pins the plan's own arithmetic: a maximal sealed clip is
    /// <c>NarrationWave.BytesPerSecond * 60 * 30 + NarrationWave.HeaderLength</c> = 57,600,044 bytes,
    /// and <see cref="NarrationDeliverySettings.MaximumClipBytes"/> must clear it (with ~16%
    /// headroom at the default of 64 MiB) or a full-length label would be refused every time.
    /// </summary>
    [Fact]
    public void MaximumClipBytesAdmitsARealMaximalSealedClip()
    {
        long maximalSealedClip = (long)NarrationWave.BytesPerSecond * 60 * 30 + NarrationWave.HeaderLength;

        Assert.Equal(57_600_044L, maximalSealedClip);
        Assert.True(
            maximalSealedClip <= new NarrationDeliverySettings().MaximumClipBytes,
            "MaximumClipBytes must admit a real 30-minute, 16 kHz mono sealed clip.");
    }

    [Fact]
    public void ValidateRejectsAMaximumClipBytesBelowTheRealMaximalSealedClip()
    {
        long maximalSealedClip = (long)NarrationWave.BytesPerSecond * 60 * 30 + NarrationWave.HeaderLength;
        var settings = new NarrationDeliverySettings { MaximumClipBytes = maximalSealedClip - 1 };

        Assert.Throws<ArgumentOutOfRangeException>(settings.Validate);
    }

    [Theory]
    [InlineData(nameof(NarrationDeliverySettings.PrepareBudget))]
    [InlineData(nameof(NarrationDeliverySettings.PrepareCleanupBudget))]
    [InlineData(nameof(NarrationDeliverySettings.UploadCallBudget))]
    [InlineData(nameof(NarrationDeliverySettings.UploadBackoffInitial))]
    [InlineData(nameof(NarrationDeliverySettings.UploadBackoffCeiling))]
    public void ADurationLongerThanATimeoutApiCanRepresentIsRejected(string bound)
    {
        TimeSpan tooLong = ScreenshotDeliverySettings.MaximumTimerDuration + TimeSpan.FromMilliseconds(1);
        var settings = new NarrationDeliverySettings();
        settings = bound switch
        {
            nameof(NarrationDeliverySettings.PrepareBudget) => settings with { PrepareBudget = tooLong },
            nameof(NarrationDeliverySettings.PrepareCleanupBudget) => settings with { PrepareCleanupBudget = tooLong },
            nameof(NarrationDeliverySettings.UploadCallBudget) => settings with { UploadCallBudget = tooLong },
            nameof(NarrationDeliverySettings.UploadBackoffInitial) =>
                settings with { UploadBackoffInitial = tooLong, UploadBackoffCeiling = tooLong },
            _ => settings with { UploadBackoffCeiling = tooLong },
        };

        var thrown = Assert.Throws<ArgumentOutOfRangeException>(() => settings.Validate());
        Assert.Equal(bound, thrown.ParamName);
    }

    /// <summary>
    /// <see cref="NarrationDeliverySettings.SpoolRetention"/> is compared against a clock and never
    /// handed to a timer API, matching the identical carve-out
    /// <see cref="EventDeliverySettings.SpoolRetention"/> already documents.
    /// </summary>
    [Fact]
    public void ASpoolRetentionLongerThanTheTimerLimitIsStillValid()
    {
        var settings = new NarrationDeliverySettings
        {
            SpoolRetention = ScreenshotDeliverySettings.MaximumTimerDuration + TimeSpan.FromDays(30),
        };

        settings.Validate();
    }

    [Fact]
    public void ValidateRejectsANonPositiveMaximumClipBytes()
    {
        var settings = new NarrationDeliverySettings { MaximumClipBytes = 0 };

        Assert.Throws<ArgumentOutOfRangeException>(settings.Validate);
    }

    [Fact]
    public void ValidateRejectsANonPositiveSpoolByteCeiling()
    {
        var settings = new NarrationDeliverySettings { SpoolByteCeiling = 0 };

        var thrown = Assert.Throws<ArgumentOutOfRangeException>(settings.Validate);
        Assert.Equal(nameof(NarrationDeliverySettings.SpoolByteCeiling), thrown.ParamName);
    }

    /// <summary>
    /// The plan's §2.2 floor is hard: "under ~110 MiB two maximal clips cannot coexist". A ceiling
    /// that admits only one maximal clip at a time would thrash on every second full-length label.
    /// </summary>
    [Fact]
    public void ValidateRejectsASpoolByteCeilingThatCannotAdmitTwoMaximalClips()
    {
        var settings = new NarrationDeliverySettings
        {
            MaximumClipBytes = 64L * 1024 * 1024,
            SpoolByteCeiling = 64L * 1024 * 1024 + 1,
        };

        var thrown = Assert.Throws<ArgumentOutOfRangeException>(settings.Validate);
        Assert.Equal(nameof(NarrationDeliverySettings.SpoolByteCeiling), thrown.ParamName);
    }

    [Fact]
    public void ValidateAcceptsASpoolByteCeilingOfExactlyTwiceTheMaximumClipBytes()
    {
        var settings = new NarrationDeliverySettings
        {
            MaximumClipBytes = 64L * 1024 * 1024,
            SpoolByteCeiling = 2 * 64L * 1024 * 1024,
        };

        Exception? thrown = Record.Exception(settings.Validate);

        Assert.Null(thrown);
    }

    /// <summary>
    /// Copilot review round 2: the cross-check used to read <c>SpoolByteCeiling &lt; 2 *
    /// MaximumClipBytes</c>, whose multiplication overflows a signed 64-bit integer for a
    /// sufficiently large custom <see cref="NarrationDeliverySettings.MaximumClipBytes"/>, wrapping
    /// negative and making a tiny <see cref="NarrationDeliverySettings.SpoolByteCeiling"/> wrongly
    /// pass. This pins that a ceiling far too small to hold even one such clip is still rejected.
    /// </summary>
    [Fact]
    public void ValidateRejectsATinySpoolByteCeilingEvenWhenMaximumClipBytesIsHugeEnoughToOverflowTheOldCheck()
    {
        var settings = new NarrationDeliverySettings
        {
            MaximumClipBytes = long.MaxValue / 2,
            SpoolByteCeiling = 1024,
        };

        var thrown = Assert.Throws<ArgumentOutOfRangeException>(settings.Validate);
        Assert.Equal(nameof(NarrationDeliverySettings.SpoolByteCeiling), thrown.ParamName);
    }

    [Fact]
    public void ValidateRejectsANonPositiveSpoolRetention()
    {
        var settings = new NarrationDeliverySettings { SpoolRetention = TimeSpan.Zero };

        Assert.Throws<ArgumentOutOfRangeException>(settings.Validate);
    }

    [Fact]
    public void ValidateRejectsAnUploadBackoffCeilingShorterThanTheInitialDelay()
    {
        var settings = new NarrationDeliverySettings
        {
            UploadBackoffInitial = TimeSpan.FromMinutes(1),
            UploadBackoffCeiling = TimeSpan.FromSeconds(1),
        };

        Assert.Throws<ArgumentOutOfRangeException>(settings.Validate);
    }

    [Fact]
    public void ValidateRejectsAnUploadBackoffInitialThatCannotProduceAPositiveDelayAfterJitter()
    {
        var settings = new NarrationDeliverySettings { UploadBackoffInitial = TimeSpan.FromMilliseconds(1) };

        Assert.Throws<ArgumentOutOfRangeException>(settings.Validate);
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    public void ValidateRejectsAMissingSpoolDirectory(string spoolDirectory)
    {
        var settings = new NarrationDeliverySettings { SpoolDirectory = spoolDirectory };

        Assert.Throws<ArgumentException>(settings.Validate);
    }

    [Fact]
    public void ValidateRejectsARelativeSpoolDirectory()
    {
        var settings = new NarrationDeliverySettings { SpoolDirectory = @"Jazz\spool\narration" };

        Assert.Throws<ArgumentException>(settings.Validate);
    }

    [Fact]
    public void SettingsLoadProducesANarrationDeliveryConfigurationThatValidates()
    {
        (Settings settings, _) = Settings.Load();

        settings.NarrationDelivery.Validate();
    }
}
