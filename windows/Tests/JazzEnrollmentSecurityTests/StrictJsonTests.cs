using System.Text;
using System.Text.Json.Nodes;
using JazzEnrollmentSecurity;

namespace JazzEnrollmentSecurityTests;

/// <summary>
/// Everything the macOS <c>StrictJSON</c> refuses must be refused here too.
/// </summary>
/// <remarks>
/// The two clients read the same signed bytes. A document one accepts and the other rejects is a
/// contract split; a document one accepts <em>differently</em> - the duplicate-key case - is worse,
/// because both would report success while disagreeing about the credential inside.
/// </remarks>
public sealed class StrictJsonTests
{
    [Theory]
    [InlineData("""{"a":1,"a":2}""", "duplicate top-level key")]
    [InlineData("""{"outer":{"a":1,"a":2}}""", "duplicate nested key")]
    [InlineData("""{"a":1} {"b":2}""", "trailing document")]
    [InlineData("""{"a":1}trailing""", "trailing garbage")]
    [InlineData("""{"a":1},""", "trailing comma after the document")]
    [InlineData("""{"a":NaN}""", "NaN literal")]
    [InlineData("""{"a":Infinity}""", "Infinity literal")]
    [InlineData("""{"a":-Infinity}""", "negative Infinity literal")]
    [InlineData("""{"a":1e400}""", "number that overflows to infinity")]
    [InlineData("""{"a":9007199254740992}""", "integer beyond the safe range")]
    [InlineData("""{"a":-9007199254740992}""", "negative integer beyond the safe range")]
    [InlineData("""{"a":01}""", "leading zero")]
    [InlineData("""{"a":+1}""", "explicit plus sign")]
    [InlineData("""{"a":.5}""", "missing integer part")]
    [InlineData("""{"a":1.}""", "missing fraction digits")]
    [InlineData("""{"a":1,}""", "trailing comma in an object")]
    [InlineData("""{"a":[1,]}""", "trailing comma in an array")]
    [InlineData("""{"a":1}//comment""", "line comment")]
    [InlineData("""{/*c*/"a":1}""", "block comment")]
    [InlineData("""{'a':1}""", "single-quoted key")]
    [InlineData("""{a:1}""", "unquoted key")]
    [InlineData("""{"a":'x'}""", "single-quoted value")]
    [InlineData("""{"a":"\x41"}""", "invalid string escape")]
    [InlineData("{\"a\":\"line\nbreak\"}", "unescaped control character in a string")]
    [InlineData("", "empty document")]
    [InlineData("   ", "whitespace-only document")]
    [InlineData("""{"a":1""", "unterminated object")]
    public void StrictParsingRefusesMalformedDocuments(string text, string reason)
    {
        byte[] utf8 = Encoding.UTF8.GetBytes(text);

        Assert.False(StrictJson.IsStrictDocument(utf8), reason);
        Assert.Null(StrictJson.TryParseObject(utf8));
    }

    [Fact]
    public void StrictParsingRefusesInvalidUtf8()
    {
        // 0xFF is not a legal UTF-8 byte anywhere. Decoding to a string first would substitute
        // U+FFFD and hide it, which is why the parser works on the received bytes.
        byte[] utf8 = { 0x7b, 0x22, 0x61, 0x22, 0x3a, 0x22, 0xff, 0x22, 0x7d };

        Assert.False(StrictJson.IsStrictDocument(utf8));
        Assert.Null(StrictJson.TryParseObject(utf8));
    }

    [Theory]
    [InlineData("""{"a":1}""")]
    [InlineData("""{"a":{"b":[1,2,3]},"c":null}""")]
    [InlineData("""{"a":"Žluťoučký/路径"}""")]
    [InlineData("""{"a":9007199254740991}""")]
    public void StrictParsingAcceptsWellFormedDocuments(string text)
    {
        byte[] utf8 = Encoding.UTF8.GetBytes(text);

        Assert.True(StrictJson.IsStrictDocument(utf8));
        Assert.NotNull(StrictJson.TryParseObject(utf8));
    }

    [Fact]
    public void ANonObjectDocumentIsNotAnObject()
    {
        Assert.True(StrictJson.IsStrictDocument("""[1,2]"""u8));
        Assert.Null(StrictJson.TryParseObject("""[1,2]"""u8));
        Assert.Null(StrictJson.TryParseObject(""""just a string""""u8));
    }

    [Fact]
    public void CanonicalityIsCheckedAgainstTheExactReceivedBytes()
    {
        Assert.NotNull(StrictJson.TryParseCanonicalObject("""{"a":1,"b":2}"""u8));

        // Same document, different spelling: reordered keys, and a whitespace-padded form.
        Assert.Null(StrictJson.TryParseCanonicalObject("""{"b":2,"a":1}"""u8));
        Assert.Null(StrictJson.TryParseCanonicalObject("""{ "a":1,"b":2 }"""u8));
        Assert.Null(StrictJson.TryParseCanonicalObject("""{"a":1,"b":2.0}"""u8));
    }

    [Fact]
    public void CanonicalizationRefusesALoneSurrogate()
    {
        var value = new JsonObject { ["a"] = "\ud800" };

        Assert.Null(EnrollmentEncoding.TryCanonicalJson(value));
    }

    [Fact]
    public void KeySetChecksAreExact()
    {
        JsonObject value = StrictJson.TryParseObject("""{"a":1,"b":2}"""u8)!;

        Assert.True(StrictJson.HasExactlyKeys(value, new[] { "a", "b" }));
        Assert.False(StrictJson.HasExactlyKeys(value, new[] { "a" }));
        Assert.False(StrictJson.HasExactlyKeys(value, new[] { "a", "b", "c" }));
        Assert.True(StrictJson.HasOnlyKeys(value, new[] { "a", "b", "c" }));
        Assert.False(StrictJson.HasOnlyKeys(value, new[] { "a" }));
    }

    [Fact]
    public void TypedAccessorsRefuseTheWrongJsonType()
    {
        JsonObject value = StrictJson.TryParseObject(
            """{"text":"x","number":7,"null":null,"array":["a"],"mixed":["a",1],"object":{}}"""u8)!;

        Assert.Equal("x", StrictJson.StringOrNull(value, "text"));
        Assert.Null(StrictJson.StringOrNull(value, "number"));
        Assert.Null(StrictJson.StringOrNull(value, "null"));
        Assert.Null(StrictJson.StringOrNull(value, "absent"));
        Assert.Equal(7, StrictJson.IntegerOrNull(value, "number"));
        Assert.Null(StrictJson.IntegerOrNull(value, "text"));
        Assert.True(StrictJson.IsExplicitNull(value, "null"));
        Assert.False(StrictJson.IsExplicitNull(value, "absent"));
        Assert.False(StrictJson.IsExplicitNull(value, "text"));
        Assert.Equal(new[] { "a" }, StrictJson.StringArrayOrNull(value, "array"));
        Assert.Null(StrictJson.StringArrayOrNull(value, "mixed"));
        Assert.Null(StrictJson.StringArrayOrNull(value, "text"));
        Assert.NotNull(StrictJson.ObjectOrNull(value, "object"));
        Assert.Null(StrictJson.ObjectOrNull(value, "array"));
    }
}
