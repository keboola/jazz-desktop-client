using JasnostCaptureCore;

namespace JasnostCaptureCoreTests;

/// <summary>
/// Pins the two typed-text redaction rules of ANNEX-HOST section 2 and the shared sanitizer that
/// bounds every free-text field an archive carries.
/// </summary>
public sealed class RedactionTests
{
    private const string Bullet = "•";
    private const string Ellipsis = "…";

    [Fact]
    public void RedactTypedMasksEmailsAndLongDigitRuns()
    {
        (string? value, bool wasMasked) = Redaction.RedactTyped("john@doe.com 12345678");

        Assert.Equal(Bullet + Bullet + Bullet + "@" + Bullet + Bullet + Bullet + " " + new string('•', 8), value);
        Assert.True(wasMasked);
    }

    [Fact]
    public void RedactTypedLeavesOrdinaryTextUntouched()
    {
        (string? value, bool wasMasked) = Redaction.RedactTyped("hello world");

        Assert.Equal("hello world", value);
        Assert.False(wasMasked);
    }

    [Fact]
    public void RedactTypedKeepsDigitRunsShorterThanSevenCharacters()
    {
        (string? value, bool wasMasked) = Redaction.RedactTyped("order 123456 shipped");

        Assert.Equal("order 123456 shipped", value);
        Assert.False(wasMasked);
    }

    [Fact]
    public void RedactTypedMasksASevenDigitRunWithTheSameLength()
    {
        (string? value, bool wasMasked) = Redaction.RedactTyped("1234567");

        Assert.Equal(new string('•', 7), value);
        Assert.True(wasMasked);
    }

    [Fact]
    public void RedactTypedDropsValuesThatAreEmptyAfterTrimming()
    {
        (string? value, bool wasMasked) = Redaction.RedactTyped("   \t  ");

        Assert.Null(value);
        Assert.False(wasMasked);
    }

    [Fact]
    public void RedactTypedTruncatesAtTheConfiguredLength()
    {
        (string? value, bool wasMasked) = Redaction.RedactTyped(new string('a', 250));

        Assert.Equal(new string('a', Redaction.DefaultMaxLength) + Ellipsis, value);
        Assert.False(wasMasked);
    }

    [Fact]
    public void SanitizeTrimsDropsEmptyAndBoundsLength()
    {
        Assert.Null(Redaction.Sanitize(null));
        Assert.Null(Redaction.Sanitize("   "));
        Assert.Equal("Save", Redaction.Sanitize("  Save  "));
        Assert.Equal("abc" + Ellipsis, Redaction.Sanitize("abcdef", maxLength: 3));
    }

    [Fact]
    public void SanitizeNeverSplitsASurrogatePair()
    {
        // U+1F600 occupies two UTF-16 code units; truncating between them would emit a lone
        // surrogate, which the canonical JSON writer rejects outright.
        string? value = Redaction.Sanitize("ab\U0001F600cd", maxLength: 3);

        Assert.Equal("ab" + Ellipsis, value);
    }
}
