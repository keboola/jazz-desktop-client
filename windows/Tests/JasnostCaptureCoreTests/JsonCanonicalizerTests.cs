using System.Text.Json.Nodes;
using JasnostCaptureCore.Json;
using JasnostCaptureCoreTests.Support;

namespace JasnostCaptureCoreTests;

public class JsonCanonicalizerTests
{
    /// <summary>RFC 8785 Appendix B input document.</summary>
    private const string Rfc8785Input =
        @"{
  ""numbers"": [333333333.33333329, 1E30, 4.50, 2e-3, 0.000000000000000000000000001],
  ""string"": ""\u20ac$\u000F\u000aA'\u0042\u0022\u005c\\\""\/"",
  ""literals"": [null, true, false]
}";

    private const string Rfc8785Sha256 = "2d5e01a318d0f0879ab568c4be289c8b1f64ef8921a53c6277d5e069978baacb";

    [Fact]
    public void Canonicalize_Rfc8785SelfCheckVector_ProducesExpectedTextAndDigest()
    {
        string expected =
            "{\"literals\":[null,true,false],"
            + "\"numbers\":[333333333.3333333,1e+30,4.5,0.002,1e-27],"
            + "\"string\":\"\u20ac$" + @"\u000f\nA'B\""\\\\\""/" + "\"}";

        JsonNode? parsed = JsonStrictParser.Parse(Rfc8785Input);

        Assert.Equal(expected, JsonCanonicalizer.Canonicalize(parsed));
        Assert.Equal(Rfc8785Sha256, JsonCanonicalizer.Sha256Hex(parsed));
    }

    [Fact]
    public void Canonicalize_SortsKeysByUtf16CodeUnitOrder()
    {
        // Insertion order is deliberately the reverse of the expected canonical order.
        var obj = new JsonObject
        {
            ["\uFB33"] = 1,
            ["\U0001F600"] = 1,
            ["\u20ac"] = 1,
            ["\u00f6"] = 1,
            ["\u0080"] = 1,
            ["1"] = 1,
            ["\r"] = 1,
        };

        string expected =
            "{\"\\r\":1,\"1\":1,\"\u0080\":1,\"\u00f6\":1,\"\u20ac\":1,\"\U0001F600\":1,\"\uFB33\":1}";

        Assert.Equal(expected, JsonCanonicalizer.Canonicalize(obj));
    }

    [Fact]
    public void Parse_DuplicateObjectKeys_Throws()
    {
        Assert.Throws<FormatException>(() => JsonStrictParser.Parse(@"{""a"":1,""a"":2}"));
    }

    [Fact]
    public void Parse_NonFiniteLiterals_Throw()
    {
        Assert.Throws<FormatException>(() => JsonStrictParser.Parse(@"{""a"":NaN}"));
        Assert.Throws<FormatException>(() => JsonStrictParser.Parse(@"{""a"":Infinity}"));
        Assert.Throws<FormatException>(() => JsonStrictParser.Parse(@"{""a"":-Infinity}"));
    }

    [Fact]
    public void Parse_IntegerOutsideSafeRange_Throws()
    {
        Assert.Throws<FormatException>(() => JsonStrictParser.Parse("9007199254740992"));
        Assert.Throws<FormatException>(() => JsonStrictParser.Parse("-9007199254740992"));
        Assert.Equal("9007199254740991", JsonCanonicalizer.Canonicalize(JsonStrictParser.Parse("9007199254740991")));
        Assert.Equal("-9007199254740991", JsonCanonicalizer.Canonicalize(JsonStrictParser.Parse("-9007199254740991")));
    }

    [Theory]
    [InlineData("[333333333.33333329]", "[333333333.3333333]")]
    [InlineData("[1E30]", "[1e+30]")]
    [InlineData("[4.50]", "[4.5]")]
    [InlineData("[2e-3]", "[0.002]")]
    [InlineData("[0.000000000000000000000000001]", "[1e-27]")]
    [InlineData("[1e21]", "[1e+21]")]
    [InlineData("[1e20]", "[100000000000000000000]")]
    [InlineData("[0.0000001]", "[1e-7]")]
    [InlineData("[0.000001]", "[0.000001]")]
    [InlineData("[-0.5]", "[-0.5]")]
    [InlineData("[0]", "[0]")]
    public void Canonicalize_FormatsNumbersLikeEs6(string input, string expected)
    {
        Assert.Equal(expected, JsonCanonicalizer.Canonicalize(JsonStrictParser.Parse(input)));
    }

    [Fact]
    public void Canonicalize_EscapesOnlyTheRequiredCharacters()
    {
        var obj = new JsonObject
        {
            ["a"] = "\b\t\n\f\r\"\\",
            ["b"] = "\u0000\u0001\u001f",
            ["c"] = "/<>&+'\u00e9\u20ac",
        };

        string expected =
            "{\"a\":\"" + @"\b\t\n\f\r\""\\" + "\","
            + "\"b\":\"" + @"\u0000\u0001\u001f" + "\","
            + "\"c\":\"/<>&+'\u00e9\u20ac\"}";

        Assert.Equal(expected, JsonCanonicalizer.Canonicalize(obj));
    }

    [Fact]
    public void Canonicalize_LoneSurrogate_Throws()
    {
        var obj = new JsonObject { ["a"] = "\ud800" };
        Assert.Throws<FormatException>(() => JsonCanonicalizer.Canonicalize(obj));

        var withKey = new JsonObject { ["\udc00"] = 1 };
        Assert.Throws<FormatException>(() => JsonCanonicalizer.Canonicalize(withKey));
    }

    [Fact]
    public void Canonicalize_NonFiniteDoubles_Throw()
    {
        Assert.Throws<FormatException>(() => JsonCanonicalizer.Canonicalize(JsonValue.Create(double.NaN)));
        Assert.Throws<FormatException>(() => JsonCanonicalizer.Canonicalize(JsonValue.Create(double.PositiveInfinity)));
        Assert.Throws<FormatException>(() => JsonCanonicalizer.Canonicalize(JsonValue.Create(double.NegativeInfinity)));
    }

    [Fact]
    public void Sha256Hex_OfEmptyObject_IsStable()
    {
        Assert.Equal("{}", JsonCanonicalizer.Canonicalize(new JsonObject()));
        Assert.Equal(
            "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a",
            JsonCanonicalizer.Sha256Hex(new JsonObject()));
    }

    [Fact]
    public void DeepEquals_ComparesByValueAndKind()
    {
        Assert.True(JsonDeepComparer.DeepEquals(JsonStrictParser.Parse("64"), JsonStrictParser.Parse("64.0")));
        Assert.True(JsonDeepComparer.DeepEquals(
            JsonStrictParser.Parse(@"{""a"":1,""b"":2}"),
            JsonStrictParser.Parse(@"{""b"":2,""a"":1}")));
        Assert.False(JsonDeepComparer.DeepEquals(JsonStrictParser.Parse("[1,2]"), JsonStrictParser.Parse("[2,1]")));
        Assert.False(JsonDeepComparer.DeepEquals(JsonStrictParser.Parse(@"""7"""), JsonStrictParser.Parse("7")));
        Assert.False(JsonDeepComparer.DeepEquals(JsonStrictParser.Parse("true"), JsonStrictParser.Parse("1")));
        Assert.True(JsonDeepComparer.DeepEquals(null, JsonStrictParser.Parse("null")));
    }
}
