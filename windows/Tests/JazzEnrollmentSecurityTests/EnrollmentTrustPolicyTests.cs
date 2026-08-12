using System.Text;
using JazzEnrollmentSecurity;
using JazzEnrollmentSecurityTests.Support;

namespace JazzEnrollmentSecurityTests;

/// <summary>
/// The code-signed trust root: what it accepts, what it refuses, and what it refuses to infer.
/// </summary>
public sealed class EnrollmentTrustPolicyTests
{
    private const string Issuer = "https://jazz.example.test";
    private const string Audience = "jazz-desktop-client";

    [Fact]
    public void ARotationSetOfAnchorsLoadsAndBothKeyIdsResolve()
    {
        string encoded = new SignedEnrollmentHarness().PublicKeyBase64Url;

        EnrollmentTrustPolicy? policy = EnrollmentTrustBootstrap.Load(Configuration($$"""
            {
              "JazzEnrollmentIssuer": "{{Issuer}}",
              "JazzEnrollmentAudience": "{{Audience}}",
              "JazzEnrollmentEd25519PublicKeys": {
                "2026-07-primary": "{{encoded}}",
                "2026-08-next": "{{encoded}}"
              }
            }
            """));

        Assert.NotNull(policy);
        Assert.Equal(Issuer, policy.Issuer);
        Assert.True(policy.HasPublicKey("2026-07-primary"));
        Assert.True(policy.HasPublicKey("2026-08-next"));
        Assert.False(policy.HasPublicKey("2026-09-unknown"));
    }

    [Fact]
    public void AConfigurationWithNoAnchorDictionaryIsUnusable()
    {
        // The bundle names a kid; it never carries a key. A configuration missing the anchor set is
        // not "trust anything", it is "trust nothing".
        Assert.Null(EnrollmentTrustBootstrap.Load(Configuration($$"""
            {
              "JazzEnrollmentIssuer": "{{Issuer}}",
              "JazzEnrollmentAudience": "{{Audience}}"
            }
            """)));
    }

    [Fact]
    public async Task AFixtureKeyEmbeddedInABundleNeverBootstrapsTrust()
    {
        // The contract goldens ship a trustedPublicKey for the benefit of test harnesses. Feeding
        // the whole fixture document to an importer with no configured anchor must still refuse.
        var importer = new SignedEnrollmentImporter(trustPolicy: null, acceptanceStore: null);
        string wholeFixture = EnrollmentContract.CanonicalText(
            SignedEnrollmentHarness.Golden("01-sink-scope.json"));

        SignedEnrollmentException error = Assert.Throws<SignedEnrollmentException>(
            () => importer.Authorize(wholeFixture, DateTimeOffset.UnixEpoch));

        Assert.Equal(SignedEnrollmentError.TrustUnavailable, error.Reason);
        await Task.CompletedTask;
    }

    [Theory]
    [InlineData("https://jazz.example.test:99999", "port outside the valid range")]
    [InlineData("http://jazz.example.test", "plain HTTP on a public host")]
    [InlineData("https://jazz.example.test/path", "an origin with a path")]
    [InlineData("not-a-url", "not a URL at all")]
    public void AnIssuerThatIsNotACanonicalOriginIsRefused(string issuer, string reason)
    {
        string encoded = new SignedEnrollmentHarness().PublicKeyBase64Url;

        Assert.Null(EnrollmentTrustBootstrap.Load(Configuration($$"""
            {
              "JazzEnrollmentIssuer": "{{issuer}}",
              "JazzEnrollmentAudience": "{{Audience}}",
              "JazzEnrollmentEd25519PublicKeys": { "k": "{{encoded}}" }
            }
            """)));
        Assert.NotNull(reason);
    }

    [Theory]
    [InlineData("", EnrollmentTrustPolicyError.InvalidAudience)]
    [InlineData(" padded ", EnrollmentTrustPolicyError.InvalidAudience)]
    public void AnInvalidAudienceIsRefused(string audience, EnrollmentTrustPolicyError expected)
    {
        string encoded = new SignedEnrollmentHarness().PublicKeyBase64Url;

        EnrollmentTrustPolicyException error = Assert.Throws<EnrollmentTrustPolicyException>(
            () => new EnrollmentTrustPolicy(
                Issuer,
                audience,
                new Dictionary<string, string> { ["k"] = encoded }));

        Assert.Equal(expected, error.Reason);
    }

    [Theory]
    [InlineData("", EnrollmentTrustPolicyError.InvalidPublicKey)]
    [InlineData("AAAA", EnrollmentTrustPolicyError.InvalidPublicKey)]
    [InlineData("not base64url!", EnrollmentTrustPolicyError.InvalidPublicKey)]
    public void AnAnchorThatIsNotA32ByteEd25519KeyIsRefused(string encoded, EnrollmentTrustPolicyError expected)
    {
        EnrollmentTrustPolicyException error = Assert.Throws<EnrollmentTrustPolicyException>(
            () => new EnrollmentTrustPolicy(
                Issuer,
                Audience,
                new Dictionary<string, string> { ["k"] = encoded }));

        Assert.Equal(expected, error.Reason);
    }

    [Fact]
    public void AnAnchorKeyIdOutsideTheContractPatternIsRefused()
    {
        string encoded = new SignedEnrollmentHarness().PublicKeyBase64Url;

        EnrollmentTrustPolicyException error = Assert.Throws<EnrollmentTrustPolicyException>(
            () => new EnrollmentTrustPolicy(
                Issuer,
                Audience,
                new Dictionary<string, string> { ["has space"] = encoded }));

        Assert.Equal(EnrollmentTrustPolicyError.InvalidKeyId, error.Reason);
    }

    [Fact]
    public void AnEmptyAnchorSetIsRefused()
    {
        EnrollmentTrustPolicyException error = Assert.Throws<EnrollmentTrustPolicyException>(
            () => new EnrollmentTrustPolicy(Issuer, Audience, new Dictionary<string, string>()));

        Assert.Equal(EnrollmentTrustPolicyError.MissingPublicKeys, error.Reason);
    }

    [Fact]
    public void AConfigurationDocumentOfTheWrongShapeIsUnusable()
    {
        Assert.Null(EnrollmentTrustConfiguration.TryParse("""{"JazzEnrollmentIssuer": 7}"""u8));
        Assert.Null(EnrollmentTrustConfiguration.TryParse("""{"JazzEnrollmentEd25519PublicKeys": []}"""u8));
        Assert.Null(EnrollmentTrustConfiguration.TryParse("""{"JazzEnrollmentEd25519PublicKeys": {"k": 1}}"""u8));
        Assert.Null(EnrollmentTrustConfiguration.TryParse("""{"JazzEnrollmentRedemptionOrigins": "x"}"""u8));
        Assert.Null(EnrollmentTrustConfiguration.TryParse("""{"Unexpected": 1}"""u8));
        Assert.Null(EnrollmentTrustConfiguration.TryParse("""{"JazzEnrollmentIssuer":"a","JazzEnrollmentIssuer":"b"}"""u8));
    }

    [Theory]
    [InlineData("https://native.example.test", true)]
    [InlineData("https://native.example.test:8443", true)]
    [InlineData("https://native.example.test/", false)]
    [InlineData("http://native.example.test", false)]
    [InlineData("https://native.example.test?a=b", false)]
    [InlineData("https://user@native.example.test", false)]
    public void TheRedemptionOriginAllowlistOnlyAcceptsCanonicalOrigins(string origin, bool accepted)
    {
        if (accepted)
        {
            Assert.NotNull(new EnrollmentRedemptionRoutePolicy(new[] { origin }));
            return;
        }

        Assert.Equal(
            EnrollmentTrustPolicyError.InvalidRedemptionOrigins,
            Assert.Throws<EnrollmentTrustPolicyException>(
                () => new EnrollmentRedemptionRoutePolicy(new[] { origin })).Reason);
    }

    [Fact]
    public void AnEmptyOrDuplicatedRedemptionAllowlistIsRefused()
    {
        Assert.Throws<EnrollmentTrustPolicyException>(
            () => new EnrollmentRedemptionRoutePolicy(Array.Empty<string>()));
        Assert.Throws<EnrollmentTrustPolicyException>(
            () => new EnrollmentRedemptionRoutePolicy(
                new[] { "https://native.example.test", "https://native.example.test" }));
    }

    [Fact]
    public void TheRedemptionAllowlistMatchesOriginsAndNotHostSuffixes()
    {
        var policy = new EnrollmentRedemptionRoutePolicy(new[] { "https://native.example.test" });

        Assert.True(policy.Allows("https://native.example.test/jazz/api/device-enrollment/redemptions/x"));
        Assert.False(policy.Allows("https://evil.native.example.test/jazz"));
        Assert.False(policy.Allows("https://native.example.test.evil.test/jazz"));
        Assert.False(policy.Allows("https://native.example.test:8443/jazz"));
        Assert.False(policy.Allows("http://native.example.test/jazz"));
    }

    private static EnrollmentTrustConfiguration Configuration(string json) =>
        EnrollmentTrustConfiguration.TryParse(Encoding.UTF8.GetBytes(json))
        ?? throw new InvalidOperationException("The test configuration document is itself malformed.");
}
