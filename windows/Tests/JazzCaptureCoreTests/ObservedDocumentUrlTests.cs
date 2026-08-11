using JazzCaptureCore;

namespace JazzCaptureCoreTests;

/// <summary>
/// Pins the Windows port of the macOS <c>ObservedDocumentURL</c> sanitizer against the same
/// behaviour the Swift suite pins, plus the hostile inputs a browser address really produces.
/// </summary>
/// <remarks>
/// The expectations were taken from the macOS implementation's own output, not from a reading of the
/// rules, because the shape of the result matters as much as the rules do: two clients that disagree
/// about the string for one page make the same evidence look like two different pages.
/// </remarks>
public sealed class ObservedDocumentUrlTests
{
    /// <summary>The four cases the Swift suite pins, transcribed literally.</summary>
    [Theory]
    [InlineData(
        "  HTTPS://Alice:secret@Example.COM/invoices/42?token=private#details  ",
        "https://example.com/invoices/42")]
    [InlineData("data:text/plain,secret", null)]
    [InlineData("javascript:alert(1)", null)]
    [InlineData("https:///missing-host", null)]
    [InlineData("   ", null)]
    public void MatchesTheSwiftTestVectors(string raw, string? expected) =>
        Assert.Equal(expected, ObservedDocumentUrl.Sanitize(raw));

    [Fact]
    public void NullInputYieldsNoDocumentUrl() => Assert.Null(ObservedDocumentUrl.Sanitize(null));

    [Fact]
    public void EmptyInputYieldsNoDocumentUrl() => Assert.Null(ObservedDocumentUrl.Sanitize(string.Empty));

    /// <summary>
    /// The Swift counterpart asserts the properties rather than the literal, so both are asserted
    /// here: the local hierarchy is gone and the basename survives, percent-encoded.
    /// </summary>
    [Fact]
    public void FileUrlKeepsOnlyThePortableBasename()
    {
        string? sanitized = ObservedDocumentUrl.Sanitize("file:///Users/alice/Finance/July Invoice.pdf");

        Assert.NotNull(sanitized);
        Assert.DoesNotContain("alice", sanitized);
        Assert.DoesNotContain("Finance", sanitized);
        Assert.Contains("July%20Invoice.pdf", sanitized);

        // A single slash: macOS builds this from URLComponents with a path and no authority, and
        // Foundation writes "file:/…" for that. Reproduced deliberately so the clients agree.
        Assert.Equal("file:/%3Clocal%3E/July%20Invoice.pdf", sanitized);
    }

    /// <summary>Credentials, tokens and fragments are the three things that must never survive.</summary>
    [Theory]
    [InlineData("https://alice:hunter2@intranet.example/reports", "https://intranet.example/reports")]
    [InlineData("https://alice@intranet.example/reports", "https://intranet.example/reports")]
    [InlineData("https://:hunter2@intranet.example/reports", "https://intranet.example/reports")]
    [InlineData("https://example.com/callback?access_token=eyJhbGciOi", "https://example.com/callback")]
    [InlineData("https://example.com/search?q=salary+of+jane", "https://example.com/search")]
    [InlineData("https://example.com/app#/customers/42/ssn", "https://example.com/app")]
    [InlineData("https://example.com/path?#", "https://example.com/path")]
    public void StripsCredentialsQueriesAndFragments(string raw, string expected) =>
        Assert.Equal(expected, ObservedDocumentUrl.Sanitize(raw));

    [Theory]
    [InlineData("HTTP://LOCALHOST:8080/Path/To/Thing", "http://localhost:8080/Path/To/Thing")]
    [InlineData("hTTps://Example.COM/x", "https://example.com/x")]
    [InlineData("HTTPS://EXAMPLE.COM", "https://example.com")]
    [InlineData("https://EXAMPLE.com/UPPER/Path", "https://example.com/UPPER/Path")]
    public void LowercasesTheSchemeAndHostButNotThePath(string raw, string expected) =>
        Assert.Equal(expected, ObservedDocumentUrl.Sanitize(raw));

    /// <summary>Anything that is not an address the reviewer could recognize is omitted entirely.</summary>
    [Theory]
    [InlineData("ftp://example.com/x")]
    [InlineData("chrome://settings")]
    [InlineData("edge://history")]
    [InlineData("about:blank")]
    [InlineData("mailto:a@b.com")]
    [InlineData("app://com.example.app")]
    [InlineData("data:text/html;base64,PHNjcmlwdD4=")]
    [InlineData("javascript:document.cookie")]
    [InlineData("vbscript:msgbox(1)")]
    [InlineData("example.com/path")]
    [InlineData("/just/a/path")]
    [InlineData("C:\\Users\\bob\\report.pdf")]
    [InlineData("://example.com")]
    [InlineData("https://")]
    [InlineData("http://")]
    [InlineData("file://")]
    [InlineData("not a url at all")]
    public void RejectsEverythingThatIsNotHttpHttpsOrFile(string raw) =>
        Assert.Null(ObservedDocumentUrl.Sanitize(raw));

    /// <summary>
    /// Foundation neither compresses path segments nor drops a default port; matching that keeps the
    /// two clients byte-identical for the same page.
    /// </summary>
    [Theory]
    [InlineData("https://example.com:443/x", "https://example.com:443/x")]
    [InlineData("https://example.com/a/../b", "https://example.com/a/../b")]
    [InlineData("https://example.com/a//b", "https://example.com/a//b")]
    [InlineData("https://example.com/", "https://example.com/")]
    [InlineData("https://example.com", "https://example.com")]
    [InlineData("https://127.0.0.1/x", "https://127.0.0.1/x")]
    [InlineData("https://[::1]:8080/x", "https://[::1]:8080/x")]
    [InlineData("https://example.com./x", "https://example.com./x")]
    public void PreservesTheAddressItselfWithoutNormalizingIt(string raw, string expected) =>
        Assert.Equal(expected, ObservedDocumentUrl.Sanitize(raw));

    [Theory]
    [InlineData("https://example.com/a b", "https://example.com/a%20b")]
    [InlineData("https://example.com/a<b>", "https://example.com/a%3Cb%3E")]
    [InlineData("https://example.com/\u00e4", "https://example.com/%C3%A4")]
    [InlineData("https://example.com/%41", "https://example.com/%41")]
    [InlineData("https://example.com/a%zz", "https://example.com/a%25zz")]
    [InlineData("https://example.com/a%2Fb", "https://example.com/a%2Fb")]
    [InlineData("https://example.com/a;b=c", "https://example.com/a;b=c")]
    [InlineData("https://example.com/a'b", "https://example.com/a'b")]
    [InlineData("https://\u4f8b\u3048.jp/x", "https://xn--r8jz45g.jp/x")]
    public void EncodesThePathTheWayFoundationDoes(string raw, string expected) =>
        Assert.Equal(expected, ObservedDocumentUrl.Sanitize(raw));

    [Theory]
    [InlineData("file:///C:/Users/bob/report.pdf", "file:/%3Clocal%3E/report.pdf")]
    [InlineData("FILE:///X/Report.PDF", "file:/%3Clocal%3E/Report.PDF")]
    [InlineData("file://server/share/doc.txt", "file:/%3Clocal%3E/doc.txt")]
    [InlineData("file:///Users/alice/", "file:/%3Clocal%3E/alice")]
    [InlineData("file:///", "file:/%3Clocal%3E//")]
    [InlineData("file:relative.txt", "file:/%3Clocal%3E/relative.txt")]
    [InlineData("file:///Users/alice/report.pdf?token=abc#page3", "file:/%3Clocal%3E/report.pdf")]
    [InlineData("file:///Users/a%20b/c%20d.pdf", "file:/%3Clocal%3E/c%20d.pdf")]
    [InlineData("file:///x/a%25b.pdf", "file:/%3Clocal%3E/a%25b.pdf")]
    [InlineData("file:///x/%2F.pdf", "file:/%3Clocal%3E/%252F.pdf")]
    [InlineData("file:///x/a+b.pdf", "file:/%3Clocal%3E/a+b.pdf")]
    [InlineData("file:///x/na\u00efve.txt", "file:/%3Clocal%3E/na%C3%AFve.txt")]
    [InlineData("file:///x/%E4%B8%AD%E6%96%87.txt", "file:/%3Clocal%3E/%E4%B8%AD%E6%96%87.txt")]
    public void FileUrlsCollapseToThePlaceholderAndBasename(string raw, string expected) =>
        Assert.Equal(expected, ObservedDocumentUrl.Sanitize(raw));

    /// <summary>
    /// A user directory is where a login name lives, so no sanitized file URL may ever contain one.
    /// </summary>
    [Fact]
    public void FileUrlNeverLeaksTheLocalHierarchy()
    {
        string? sanitized = ObservedDocumentUrl.Sanitize(
            "file:///C:/Users/j.novak/OneDrive - Contoso/Payroll/2026/Q1 bonuses.xlsx");

        Assert.Equal("file:/%3Clocal%3E/Q1%20bonuses.xlsx", sanitized);
        Assert.DoesNotContain("novak", sanitized);
        Assert.DoesNotContain("Contoso", sanitized);
        Assert.DoesNotContain("Payroll", sanitized);
    }

    [Theory]
    [InlineData("  https://example.com/x  ")]
    [InlineData("\thttps://example.com/x\n")]
    [InlineData("\r\n https://example.com/x")]
    public void TrimsSurroundingWhitespaceBeforeParsing(string raw) =>
        Assert.Equal("https://example.com/x", ObservedDocumentUrl.Sanitize(raw));
}
