using JazzCaptureCore.Enrollment;
using JazzEnrollmentSecurity;

namespace JazzEnrollmentSecurityTests;

/// <summary>
/// The character gate every enrollment URL policy sits on.
/// </summary>
/// <remarks>
/// <para>
/// The macOS client rejects any Unicode whitespace, control or format character in a URL string
/// outright, and then parses through <c>URLComponents</c>, which re-encodes any raw non-ASCII that
/// survives - so on that side a raw U+00A0 or a raw emoji in a path can never satisfy "the canonical
/// form equals the input".
/// </para>
/// <para>
/// Two of the four policies restrict the path to empty-or-slash and so would catch a stray
/// character anyway. <see cref="JazzArchiveControlPlaneUrl"/> and <see cref="StreamEndpoint"/> do
/// not: they accept a multi-segment path, and they are the ones a signed bundle carries. A gap here
/// is an admission that Windows grants and macOS refuses.
/// </para>
/// </remarks>
public sealed class UrlCharacterGateTests
{
    public static TheoryData<string, string> ForbiddenCharacters() => new()
    {
        { "\u00A0", "no-break space" },
        { "\u2007", "figure space" },
        { "\u2028", "line separator" },
        { "\u2029", "paragraph separator" },
        { "\u3000", "ideographic space" },
        { "\u200B", "zero width space" },
        { "\u200E", "left-to-right mark" },
        { "\uFEFF", "zero width no-break space" },
        { "\u00AD", "soft hyphen" },
        { "\t", "tab" },
        { "\n", "line feed" },
        { "\u007F", "delete" },
        { "\u0085", "next line" },
        { "\u009F", "application program command" },
        { "\U0001F600", "an astral character" },
        { "\u00E9", "a raw accented letter" },
    };

    [Theory]
    [MemberData(nameof(ForbiddenCharacters))]
    public void AnArchiveIngestPathCarryingANonAsciiCharacterIsRefused(string character, string reason)
    {
        string url = $"https://jazz.example.test/x{character}/api/archive-ingests";

        Assert.Null(JazzArchiveControlPlaneUrl.Normalize(url));
        Assert.NotEqual(url, JazzArchiveControlPlaneUrl.Normalize(url));
        Assert.NotNull(reason);
    }

    [Theory]
    [MemberData(nameof(ForbiddenCharacters))]
    public void AStreamEndpointPathCarryingANonAsciiCharacterIsRefused(string character, string reason)
    {
        Assert.False(
            EnrollmentUrlPolicy.IsSecureEndpoint($"https://stream.example.test/source/x{character}SECRET"));
        Assert.NotNull(reason);
    }

    [Theory]
    [MemberData(nameof(ForbiddenCharacters))]
    public void AnOriginCarryingANonAsciiCharacterIsRefused(string character, string reason)
    {
        Assert.False(EnrollmentUrlPolicy.IsSecureOrigin($"https://jazz.example{character}.test"));
        Assert.Null(KeboolaStack.Normalize($"https://connection{character}.keboola.com"));
        Assert.NotNull(reason);
    }

    [Fact]
    public void APercentEncodedNonAsciiPathSegmentIsStillAccepted()
    {
        // RFC 3986 says non-ASCII travels percent-encoded, and both clients accept that form. Only
        // the raw form is refused, so this closes the gap without narrowing what a deployment may
        // legitimately route through.
        const string url = "https://jazz.example.test/x%F0%9F%98%80/api/archive-ingests";

        Assert.Equal(url, JazzArchiveControlPlaneUrl.Normalize(url));
        Assert.True(EnrollmentUrlPolicy.IsSecureEndpoint("https://stream.example.test/source/%C3%A9"));
    }

    [Fact]
    public void PercentDecodingRefusesNonAsciiRatherThanReplacingIt()
    {
        // Re-encoding per UTF-16 code unit split surrogate pairs and turned each half into U+FFFD,
        // so a path could decode to something it did not say. Nothing may be guessed here: the
        // decoded form is what the '..' and '//' route checks are made against.
        Assert.Null(StrictAbsoluteUrl.TryRemovePercentEncoding("/a%2Fb/\U0001F600"));
        Assert.Null(StrictAbsoluteUrl.TryRemovePercentEncoding("/\U0001F600"));
        Assert.Null(StrictAbsoluteUrl.TryRemovePercentEncoding("/\ud800%41"));
        Assert.Equal("/a/b", StrictAbsoluteUrl.TryRemovePercentEncoding("/a/b"));
        Assert.Equal("/a b", StrictAbsoluteUrl.TryRemovePercentEncoding("/a%20b"));
        Assert.Equal("/\U0001F600", StrictAbsoluteUrl.TryRemovePercentEncoding("/%F0%9F%98%80"));
    }

    [Fact]
    public void PercentDecodingRefusesTruncatedAndInvalidEscapes()
    {
        Assert.Null(StrictAbsoluteUrl.TryRemovePercentEncoding("/a%"));
        Assert.Null(StrictAbsoluteUrl.TryRemovePercentEncoding("/a%4"));
        Assert.Null(StrictAbsoluteUrl.TryRemovePercentEncoding("/a%zz"));
        Assert.Null(StrictAbsoluteUrl.TryRemovePercentEncoding("/a%FF"));
    }

    [Theory]
    [MemberData(nameof(ForbiddenCharacters))]
    public async Task ASignedBundleWhoseIngestPathCarriesSuchACharacterMakesNoTokenBearingRequest(
        string character,
        string reason)
    {
        using var harness = new Support.SignedEnrollmentHarness();
        System.Text.Json.Nodes.JsonObject golden =
            Support.SignedEnrollmentHarness.Golden("01-sink-scope.json");
        System.Text.Json.Nodes.JsonObject payload =
            Support.SignedEnrollmentHarness.DecodedPayload(golden);
        payload["archiveIngestURL"] = $"https://jazz.example.test/x{character}/api/archive-ingests";

        SignedEnrollmentException error = Assert.Throws<SignedEnrollmentException>(
            () => harness.Importer.Authorize(
                harness.SignedEnvelope(
                    golden["jws"]!["protected"]!.GetValue<string>(),
                    Support.SignedEnrollmentHarness.Canonical(payload)),
                SignedEnrollmentRefusalTests.Instant("2026-07-24T09:35:00Z")));

        Assert.Equal(SignedEnrollmentError.InvalidPayload, error.Reason);
        Assert.NotNull(reason);
        await Task.CompletedTask;
    }
}
