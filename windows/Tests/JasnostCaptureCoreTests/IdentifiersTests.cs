using System.Globalization;
using System.Text.RegularExpressions;
using JasnostCaptureCore;

namespace JasnostCaptureCoreTests;

public class IdentifiersTests
{
    private const string UuidV7Pattern =
        "^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$";

    private static byte[] ConstantRandom() => new byte[]
    {
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    };

    [Fact]
    public void UuidV7_MatchesRfc9562Shape()
    {
        var now = DateTimeOffset.FromUnixTimeMilliseconds(1781344800123L);
        string id = Identifiers.UuidV7(now, ConstantRandom);

        Assert.Matches(UuidV7Pattern, id);
        Assert.Equal(36, id.Length);
    }

    [Fact]
    public void UuidV7_EncodesTheClockAs48BitBigEndianEpochMillis()
    {
        const long millis = 1781344800123L;
        var now = DateTimeOffset.FromUnixTimeMilliseconds(millis);
        string id = Identifiers.UuidV7(now, ConstantRandom);

        string prefix = id.Substring(0, 8) + id.Substring(9, 4);
        Assert.Equal(millis.ToString("x12", CultureInfo.InvariantCulture), prefix);
    }

    [Fact]
    public void UuidV7_SetsVersionAndVariantNibbles()
    {
        var now = DateTimeOffset.FromUnixTimeMilliseconds(0L);

        string allZero = Identifiers.UuidV7(now, () => new byte[10]);
        Assert.Equal("00000000-0000-7000-8000-000000000000", allZero);

        string allOnes = Identifiers.UuidV7(now, ConstantRandom);
        Assert.Equal("00000000-0000-7fff-bfff-ffffffffffff", allOnes);
    }

    [Fact]
    public void UuidV7_IsLowercaseAndTimeOrdered()
    {
        var earlier = DateTimeOffset.FromUnixTimeMilliseconds(1781344800000L);
        var later = DateTimeOffset.FromUnixTimeMilliseconds(1781344800001L);

        string a = Identifiers.UuidV7(earlier, () => new byte[10]);
        string b = Identifiers.UuidV7(later, () => new byte[10]);

        Assert.Equal(a, a.ToLowerInvariant());
        Assert.True(string.CompareOrdinal(a, b) < 0);
    }

    [Fact]
    public void UuidV7_Parameterless_UsesRandomBytesAndCurrentClock()
    {
        string first = Identifiers.UuidV7();
        string second = Identifiers.UuidV7();

        Assert.Matches(UuidV7Pattern, first);
        Assert.Matches(UuidV7Pattern, second);
        Assert.NotEqual(first, second);
    }

    [Fact]
    public void UuidV7_RejectsShortRandomSource()
    {
        var now = DateTimeOffset.FromUnixTimeMilliseconds(0L);
        Assert.Throws<ArgumentException>(() => Identifiers.UuidV7(now, () => new byte[9]));
    }

    [Fact]
    public void UuidV7_RejectsPre1970Clock()
    {
        var now = DateTimeOffset.FromUnixTimeMilliseconds(-1L);
        Assert.Throws<ArgumentOutOfRangeException>(() => Identifiers.UuidV7(now, () => new byte[10]));
    }

    [Fact]
    public void Prefixed_JoinsPrefixAndUuidWithHyphen()
    {
        string id = Identifiers.Prefixed("ar");

        Assert.StartsWith("ar-", id, StringComparison.Ordinal);
        Assert.Matches(UuidV7Pattern, id.Substring(3));
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    public void Prefixed_RejectsEmptyPrefix(string prefix)
    {
        Assert.Throws<ArgumentException>(() => Identifiers.Prefixed(prefix));
    }

    [Fact]
    public void EventId_ConcatenatesSessionIdAndSequence()
    {
        Assert.Equal("s-abc-0", Identifiers.EventId("s-abc", 0));
        Assert.Equal("s-abc-17", Identifiers.EventId("s-abc", 17));
    }

    [Fact]
    public void OtlpIds_ProduceLowercaseHexOfTheRightLength()
    {
        string traceId = OtlpIds.TraceId();
        string spanId = OtlpIds.SpanId();

        Assert.Equal(32, traceId.Length);
        Assert.Equal(16, spanId.Length);
        Assert.Matches("^[0-9a-f]{32}$", traceId);
        Assert.Matches("^[0-9a-f]{16}$", spanId);
        Assert.NotEqual(traceId, OtlpIds.TraceId());
        Assert.NotEqual(spanId, OtlpIds.SpanId());
    }

    [Fact]
    public void OtlpIds_AreNotAllZero()
    {
        Assert.DoesNotMatch("^0{32}$", OtlpIds.TraceId());
        Assert.DoesNotMatch("^0{16}$", OtlpIds.SpanId());
    }
}
