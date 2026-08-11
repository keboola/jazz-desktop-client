using System.Globalization;
using JasnostCaptureCore;

namespace JasnostCaptureCoreTests;

public class TimestampsTests
{
    [Theory]
    [InlineData("2026-06-13T10:00:00Z", 1781344800000000000L)]
    [InlineData("2026-06-13T10:00:00.123Z", 1781344800123000000L)]
    [InlineData("2026-06-13T10:00:00.123456789Z", 1781344800123456789L)]
    [InlineData("2026-06-13T10:00:00.1234567891Z", 1781344800123456789L)]
    [InlineData("2026-06-13T10:00:00.5Z", 1781344800500000000L)]
    [InlineData("2026-06-13T12:00:00.5+02:00", 1781344800500000000L)]
    [InlineData("2026-06-13T12:00:00+02:00", 1781344800000000000L)]
    [InlineData("1970-01-01T00:00:00Z", 0L)]
    [InlineData("1970-01-01T00:00:00.000000001Z", 1L)]
    public void UnixNanos_ParsesIso8601ExactlyToNanoseconds(string input, long expected)
    {
        Assert.Equal(expected, Timestamps.UnixNanos(input));
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("not-a-date")]
    [InlineData("2026-06-13")]
    [InlineData("1969-12-31T23:59:59Z")]
    [InlineData("2026-06-13T10:00:00")]
    public void UnixNanos_RejectsUnparseableAndPre1970(string input)
    {
        Assert.Null(Timestamps.UnixNanos(input));
    }

    [Fact]
    public void UnixNanos_NullInput_ReturnsNull()
    {
        Assert.Null(Timestamps.UnixNanos(null!));
    }

    [Fact]
    public void UnixNanos_KeepsFullPrecisionBeyondTicks()
    {
        // 100 ns ticks cannot represent the last two digits; the integer path must.
        Assert.Equal(1781344800123456789L, Timestamps.UnixNanos("2026-06-13T10:00:00.123456789Z"));
        Assert.Equal(1781344800000000007L, Timestamps.UnixNanos("2026-06-13T10:00:00.000000007Z"));
    }

    [Fact]
    public void IsoMillisUtc_RendersExactlyThreeFractionalDigitsInUtc()
    {
        var moment = new DateTimeOffset(2026, 6, 13, 12, 0, 0, 456, TimeSpan.FromHours(2));
        Assert.Equal("2026-06-13T10:00:00.456Z", Timestamps.IsoMillisUtc(moment));

        var whole = new DateTimeOffset(2026, 6, 13, 10, 0, 0, TimeSpan.Zero);
        Assert.Equal("2026-06-13T10:00:00.000Z", Timestamps.IsoMillisUtc(whole));
    }

    [Fact]
    public void IsoMillisUtc_RoundTripsThroughUnixNanos()
    {
        var moment = new DateTimeOffset(2026, 6, 13, 10, 0, 0, 123, TimeSpan.Zero);
        string rendered = Timestamps.IsoMillisUtc(moment);
        Assert.Equal(1781344800123000000L, Timestamps.UnixNanos(rendered));
    }

    [Fact]
    public void IsoMillisUtc_IsCultureInvariant()
    {
        CultureInfo original = CultureInfo.CurrentCulture;
        try
        {
            CultureInfo.CurrentCulture = new CultureInfo("ar-SA");
            var moment = new DateTimeOffset(2026, 6, 13, 10, 0, 0, 7, TimeSpan.Zero);
            Assert.Equal("2026-06-13T10:00:00.007Z", Timestamps.IsoMillisUtc(moment));
        }
        finally
        {
            CultureInfo.CurrentCulture = original;
        }
    }
}
