using System.Text;
using JazzCaptureCore.Enrollment;
using JazzEnrollmentSecurity;

namespace JazzEnrollmentSecurityTests;

/// <summary>Base64url, key ids, scalar counting and the URL policies the signed payload leans on.</summary>
public sealed class EnrollmentEncodingTests
{
    [Theory]
    [InlineData("", "")]
    [InlineData("66", "Zg")]
    [InlineData("666f", "Zm8")]
    [InlineData("666f6f", "Zm9v")]
    [InlineData("fbff", "-_8")]
    public void Base64UrlIsUnpaddedAndUsesTheUrlAlphabet(string hex, string expected)
    {
        Assert.Equal(expected, EnrollmentEncoding.EncodeBase64Url(Convert.FromHexString(hex)));
    }

    [Fact]
    public void Base64UrlRoundTripsEveryByteValue()
    {
        byte[] all = Enumerable.Range(0, 256).Select(value => (byte)value).ToArray();

        string encoded = EnrollmentEncoding.EncodeBase64Url(all);

        Assert.Equal(all, EnrollmentEncoding.DecodeBase64Url(encoded, maximumBytes: 256));
    }

    [Theory]
    [InlineData("Zm9v+", "standard-alphabet plus")]
    [InlineData("Zm9v/", "standard-alphabet slash")]
    [InlineData("Zm9v=", "padding")]
    [InlineData("Zm 9v", "embedded space")]
    [InlineData("Z", "one leftover character")]
    [InlineData("", "empty segment")]
    public void Base64UrlRefusesEverythingOutsideTheStrictAlphabet(string value, string reason)
    {
        Assert.Null(EnrollmentEncoding.DecodeBase64Url(value, maximumBytes: 64));
        Assert.NotNull(reason);
    }

    [Fact]
    public void Base64UrlRefusesNonZeroTrailingBits()
    {
        // "Zh" and "Zg" both decode to 0x66, but only "Zg" re-encodes to itself. Accepting both
        // would give one payload two spellings and therefore two distinct signing inputs.
        Assert.Equal(new byte[] { 0x66 }, EnrollmentEncoding.DecodeBase64Url("Zg", maximumBytes: 1));
        Assert.Null(EnrollmentEncoding.DecodeBase64Url("Zh", maximumBytes: 1));
    }

    [Fact]
    public void Base64UrlEnforcesTheByteCeiling()
    {
        string encoded = EnrollmentEncoding.EncodeBase64Url(new byte[64]);

        Assert.NotNull(EnrollmentEncoding.DecodeBase64Url(encoded, maximumBytes: 64));
        Assert.Null(EnrollmentEncoding.DecodeBase64Url(encoded, maximumBytes: 32));
    }

    [Theory]
    [InlineData("test-2026-07-rfc8032-1", true)]
    [InlineData("a", true)]
    [InlineData("A.b_c-1", true)]
    [InlineData("", false)]
    [InlineData("has space", false)]
    [InlineData("has/slash", false)]
    [InlineData("Žluť", false)]
    public void KeyIdsFollowTheContractPattern(string value, bool expected)
    {
        Assert.Equal(expected, EnrollmentEncoding.IsValidKeyId(value));
    }

    [Fact]
    public void KeyIdsLongerThan128CharactersAreRefused()
    {
        Assert.True(EnrollmentEncoding.IsValidKeyId(new string('a', 128)));
        Assert.False(EnrollmentEncoding.IsValidKeyId(new string('a', 129)));
    }

    [Fact]
    public void ScalarCountMatchesTheServerSchemaNotUtf16Length()
    {
        Assert.Equal(3, EnrollmentEncoding.ScalarCount("abc"));
        Assert.Equal(1, EnrollmentEncoding.ScalarCount("\U0001F600"));
        Assert.Equal(2, "\U0001F600".Length);
        Assert.Equal(4, EnrollmentEncoding.ScalarCount("Žluť"));
    }

    [Fact]
    public void HexSha256MatchesTheKnownEmptyDigest()
    {
        Assert.Equal(
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            EnrollmentEncoding.HexSha256(ReadOnlySpan<byte>.Empty));
    }

    [Theory]
    [InlineData("https://jazz.example.test", true)]
    [InlineData("https://jazz.example.test/", true)]
    [InlineData("https://jazz.example.test:8443", true)]
    [InlineData("http://localhost:4318", true)]
    [InlineData("http://127.0.0.1", true)]
    [InlineData("http://[::1]", true)]
    [InlineData("http://jazz.example.test", false)]
    [InlineData("https://jazz.example.test:99999", false)]
    [InlineData("https://jazz.example.test/path", false)]
    [InlineData("https://jazz.example.test?a=b", false)]
    [InlineData("https://jazz.example.test#f", false)]
    [InlineData("https://user:pass@jazz.example.test", false)]
    [InlineData(" https://jazz.example.test", false)]
    [InlineData("https://jazz.example.test\\", false)]
    [InlineData("jazz.example.test", false)]
    [InlineData("", false)]
    public void SecureOriginPolicyMatchesTheMacOsClient(string value, bool expected)
    {
        Assert.Equal(expected, EnrollmentUrlPolicy.IsSecureOrigin(value));
    }

    [Theory]
    [InlineData("https://stream.example.test/source/SECRET", true)]
    [InlineData("http://localhost:4318/source/SECRET", true)]
    [InlineData("https://stream.example.test:99999/source", false)]
    [InlineData("http://stream.example.test/source", false)]
    [InlineData("https://stream.example.test/source?a=b", false)]
    [InlineData("https://stream.example.test/source#f", false)]
    public void SignedStreamEndpointPolicyMatchesTheMacOsClient(string value, bool expected)
    {
        Assert.Equal(expected, EnrollmentUrlPolicy.IsSecureEndpoint(value));
    }

    [Theory]
    [InlineData("https://connection.keboola.com", "https://connection.keboola.com")]
    [InlineData("https://connection.keboola.com/", "https://connection.keboola.com")]
    [InlineData("https://CONNECTION.KEBOOLA.COM", "https://connection.keboola.com")]
    [InlineData(" https://connection.keboola.com ", "https://connection.keboola.com")]
    [InlineData("https://connection.north-europe.azure.keboola.com", "https://connection.north-europe.azure.keboola.com")]
    [InlineData("https://connection.tenant.keboola.cloud", "https://connection.tenant.keboola.cloud")]
    [InlineData("https://connection.keboola.com:443", null)]
    [InlineData("https://connection.keboola.com/path", null)]
    [InlineData("http://connection.keboola.com", null)]
    [InlineData("https://evil.example.test", null)]
    [InlineData("https://connection.keboola.com.evil.test", null)]
    [InlineData("https://notconnection.keboola.com", null)]
    public void KeboolaStackNormalizationMatchesTheMacOsClient(string value, string? expected)
    {
        Assert.Equal(expected, KeboolaStack.Normalize(value));
    }
}
