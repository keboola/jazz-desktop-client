using JazzCapture;

namespace JazzCaptureHostTests;

/// <summary>
/// Mirror of <see cref="ScreenshotDeliverySettingsTests"/> for the durable event spool's own
/// compiled-in bounds. Pins the documented defaults -- including the two amended-down values from
/// the "Decisions on the plan's open questions" comment on issue #48 (32 MiB / 48 hours, not the
/// plan body's original 128 MiB / 7 days) -- and every rejection <see cref="EventDeliverySettings.Validate"/>
/// must enforce.
/// </summary>
public sealed class EventDeliverySettingsTests
{
    [Fact]
    public void TheDefaultsAreTheDocumentedAmendedValuesAndValidate()
    {
        var settings = new EventDeliverySettings();

        Assert.Equal(32L * 1024 * 1024, settings.SpoolByteCeiling);
        Assert.Equal(TimeSpan.FromHours(48), settings.SpoolRetention);
        Assert.Equal(1L * 1024 * 1024, settings.MaximumBodyBytes);
        Assert.Equal(TimeSpan.FromSeconds(30), settings.SendCallBudget);
        Assert.Equal(TimeSpan.FromSeconds(2), settings.SendBackoffInitial);
        Assert.Equal(TimeSpan.FromMinutes(5), settings.SendBackoffCeiling);
        Assert.True(Path.IsPathFullyQualified(settings.SpoolDirectory));
        Assert.Contains(Path.Combine("Jazz", "spool", "events"), settings.SpoolDirectory, StringComparison.OrdinalIgnoreCase);

        settings.Validate();
    }

    [Theory]
    [InlineData(nameof(EventDeliverySettings.SendCallBudget))]
    [InlineData(nameof(EventDeliverySettings.SendBackoffCeiling))]
    public void ADurationLongerThanATimeoutApiCanRepresentIsRejected(string bound)
    {
        TimeSpan tooLong = ScreenshotDeliverySettings.MaximumTimerDuration + TimeSpan.FromMilliseconds(1);
        var settings = new EventDeliverySettings();
        settings = bound switch
        {
            nameof(EventDeliverySettings.SendCallBudget) => settings with { SendCallBudget = tooLong },
            _ => settings with { SendBackoffCeiling = tooLong },
        };

        var thrown = Assert.Throws<ArgumentOutOfRangeException>(() => settings.Validate());
        Assert.Equal(bound, thrown.ParamName);
    }

    /// <summary>
    /// <see cref="EventDeliverySettings.SpoolRetention"/> is compared against a clock and never
    /// handed to a timer API, so a retention window past the timer limit is unusual but valid --
    /// the identical carve-out <see cref="ScreenshotDeliverySettings.StagingRetention"/> documents.
    /// </summary>
    [Fact]
    public void ASpoolRetentionLongerThanTheTimerLimitIsStillValid()
    {
        var settings = new EventDeliverySettings
        {
            SpoolRetention = ScreenshotDeliverySettings.MaximumTimerDuration + TimeSpan.FromDays(30),
        };

        settings.Validate();
    }

    [Fact]
    public void ValidateRejectsANonPositiveSpoolByteCeiling()
    {
        var settings = new EventDeliverySettings { SpoolByteCeiling = 0 };

        Assert.Throws<ArgumentOutOfRangeException>(settings.Validate);
    }

    [Fact]
    public void ValidateRejectsANonPositiveSpoolRetention()
    {
        var settings = new EventDeliverySettings { SpoolRetention = TimeSpan.Zero };

        Assert.Throws<ArgumentOutOfRangeException>(settings.Validate);
    }

    [Fact]
    public void ValidateRejectsANonPositiveMaximumBodyBytes()
    {
        var settings = new EventDeliverySettings { MaximumBodyBytes = 0 };

        Assert.Throws<ArgumentOutOfRangeException>(settings.Validate);
    }

    [Fact]
    public void ValidateRejectsANonPositiveSendCallBudget()
    {
        var settings = new EventDeliverySettings { SendCallBudget = TimeSpan.Zero };

        Assert.Throws<ArgumentOutOfRangeException>(settings.Validate);
    }

    [Fact]
    public void ValidateRejectsANonPositiveSendBackoffInitial()
    {
        var settings = new EventDeliverySettings { SendBackoffInitial = TimeSpan.Zero };

        Assert.Throws<ArgumentOutOfRangeException>(settings.Validate);
    }

    [Fact]
    public void ValidateRejectsASendBackoffCeilingShorterThanTheInitialDelay()
    {
        var settings = new EventDeliverySettings
        {
            SendBackoffInitial = TimeSpan.FromSeconds(10),
            SendBackoffCeiling = TimeSpan.FromSeconds(1),
        };

        Assert.Throws<ArgumentOutOfRangeException>(settings.Validate);
    }

    [Fact]
    public void ValidateRejectsASendBackoffInitialThatCannotProduceAPositiveDelayAfterJitter()
    {
        var settings = new EventDeliverySettings { SendBackoffInitial = TimeSpan.FromMilliseconds(1) };

        Assert.Throws<ArgumentOutOfRangeException>(settings.Validate);
    }

    [Fact]
    public void ValidateAcceptsTheSmallestSendBackoffInitialThatCanProduceAPositiveDelay()
    {
        var settings = new EventDeliverySettings { SendBackoffInitial = TimeSpan.FromMilliseconds(2) };

        Exception? thrown = Record.Exception(settings.Validate);

        Assert.Null(thrown);
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    public void ValidateRejectsAMissingSpoolDirectory(string spoolDirectory)
    {
        var settings = new EventDeliverySettings { SpoolDirectory = spoolDirectory };

        Assert.Throws<ArgumentException>(settings.Validate);
    }

    [Fact]
    public void ValidateRejectsARelativeSpoolDirectory()
    {
        var settings = new EventDeliverySettings { SpoolDirectory = @"Jazz\spool\events" };

        Assert.Throws<ArgumentException>(settings.Validate);
    }

    [Fact]
    public void SettingsLoadProducesAnEventDeliveryConfigurationThatValidates()
    {
        (Settings settings, _) = Settings.Load();

        settings.EventDelivery.Validate();
    }
}
