using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using JazzEnrollmentSecurity;
using JazzEnrollmentSecurityTests.Support;

namespace JazzEnrollmentSecurityTests;

/// <summary>
/// Every way a signed enrollment bundle must be refused, each asserting that the refusal happened
/// before anything token-bearing ran.
/// </summary>
/// <remarks>
/// <see cref="TokenRequestProbe"/> stands in for the first call that would carry the bundle's
/// scoped Storage token off the machine. Each negative asserts its counter did not move, because a
/// policy check that runs after the request has already gone out is not a check.
/// </remarks>
public sealed class SignedEnrollmentRefusalTests
{
    private static readonly DateTimeOffset Now = Instant("2026-07-24T09:35:00Z");

    [Fact]
    public async Task UnsignedBundleMakesZeroTokenBearingRequests()
    {
        using var harness = new SignedEnrollmentHarness();
        await AssertRejected(
            harness,
            SignedEnrollmentError.MalformedEnvelope,
            """{"kind":"jazz-device-bundle","token":"8625-1-NOT-A-REAL-TOKEN"}""");
    }

    [Fact]
    public async Task CompactAndGeneralJwsSerializationsAreNotAcceptedAsFlattened()
    {
        using var harness = new SignedEnrollmentHarness();
        JsonObject golden = SignedEnrollmentHarness.Golden("01-sink-scope.json");
        JsonObject jws = (JsonObject)golden["jws"]!;
        string protectedSegment = jws["protected"]!.GetValue<string>();
        string payloadSegment = jws["payload"]!.GetValue<string>();
        string signature = jws["signature"]!.GetValue<string>();

        // Compact serialization: a bare string, not a flattened JSON envelope.
        await AssertRejected(
            harness,
            SignedEnrollmentError.MalformedEnvelope,
            $"\"{protectedSegment}.{payloadSegment}.{signature}\"");

        // General serialization: the signature lives in an array, and an unprotected per-signature
        // header would come along with it.
        await AssertRejected(
            harness,
            SignedEnrollmentError.MalformedEnvelope,
            EnrollmentContract.CanonicalText(new JsonObject
            {
                ["payload"] = payloadSegment,
                ["signatures"] = new JsonArray(new JsonObject
                {
                    ["protected"] = protectedSegment,
                    ["signature"] = signature,
                }),
            }));

        // Detached payload: the signing input is not fully present in the document.
        await AssertRejected(
            harness,
            SignedEnrollmentError.MalformedEnvelope,
            EnrollmentContract.CanonicalText(new JsonObject
            {
                ["protected"] = protectedSegment,
                ["signature"] = signature,
            }));
    }

    [Fact]
    public async Task UnprotectedHeaderIsNeverPartOfTheTrustBoundary()
    {
        using var harness = new SignedEnrollmentHarness();
        JsonObject golden = SignedEnrollmentHarness.Golden("01-sink-scope.json");
        var envelope = (JsonObject)golden["jws"]!.DeepClone();

        // An unprotected header carrying an embedded JWK is the classic key-confusion shape.
        envelope["header"] = new JsonObject { ["jwk"] = golden["trustedPublicKey"]!.DeepClone() };

        await AssertRejected(
            harness,
            SignedEnrollmentError.MalformedEnvelope,
            EnrollmentContract.CanonicalText(envelope));
    }

    [Fact]
    public async Task FlippedPayloadByteMakesZeroTokenBearingRequests()
    {
        using var harness = new SignedEnrollmentHarness();
        JsonObject golden = SignedEnrollmentHarness.Golden("01-sink-scope.json");
        JsonObject payload = SignedEnrollmentHarness.DecodedPayload(golden);
        payload["archiveIngestURL"] = "https://attacker.invalid/api/archive-ingests";

        await AssertRejected(
            harness,
            SignedEnrollmentError.InvalidSignature,
            SignedEnrollmentHarness.EnvelopeText(
                golden["jws"]!["protected"]!.GetValue<string>(),
                EnrollmentEncoding.EncodeBase64Url(SignedEnrollmentHarness.Canonical(payload)),
                golden["jws"]!["signature"]!.GetValue<string>()));
    }

    [Fact]
    public async Task FlippedSignatureByteMakesZeroTokenBearingRequests()
    {
        using var harness = new SignedEnrollmentHarness();
        JsonObject jws = (JsonObject)SignedEnrollmentHarness.Golden("01-sink-scope.json")["jws"]!;
        byte[] signature = EnrollmentEncoding.DecodeBase64Url(
            jws["signature"]!.GetValue<string>(),
            maximumBytes: 64)!;
        signature[0] ^= 1;

        await AssertRejected(
            harness,
            SignedEnrollmentError.InvalidSignature,
            SignedEnrollmentHarness.EnvelopeText(
                jws["protected"]!.GetValue<string>(),
                jws["payload"]!.GetValue<string>(),
                EnrollmentEncoding.EncodeBase64Url(signature)));
    }

    [Fact]
    public async Task ValidSignatureByAnUntrustedKeyMakesZeroTokenBearingRequests()
    {
        using var harness = new SignedEnrollmentHarness();
        JsonObject golden = SignedEnrollmentHarness.Golden("01-sink-scope.json");
        JsonObject payload = SignedEnrollmentHarness.DecodedPayload(golden);

        // A second, perfectly well-formed Ed25519 key signs the untouched payload and reuses the
        // trusted kid. Only the out-of-band anchor decides, so this must still fail.
        using var attacker = new UntrustedEd25519Signer();
        string protectedSegment = golden["jws"]!["protected"]!.GetValue<string>();
        string payloadSegment = EnrollmentEncoding.EncodeBase64Url(
            SignedEnrollmentHarness.Canonical(payload));

        await AssertRejected(
            harness,
            SignedEnrollmentError.InvalidSignature,
            SignedEnrollmentHarness.EnvelopeText(
                protectedSegment,
                payloadSegment,
                EnrollmentEncoding.EncodeBase64Url(
                    attacker.Sign(Encoding.ASCII.GetBytes(protectedSegment + "." + payloadSegment)))));
    }

    [Fact]
    public async Task UnknownKidMakesZeroTokenBearingRequests()
    {
        using var harness = new SignedEnrollmentHarness();
        JsonObject jws = (JsonObject)SignedEnrollmentHarness.Golden("01-sink-scope.json")["jws"]!;
        byte[] protectedBytes = SignedEnrollmentHarness.Canonical(new JsonObject
        {
            ["alg"] = "EdDSA",
            ["kid"] = "unknown-but-well-formed",
            ["typ"] = SignedEnrollmentVerifier.ExpectedType,
        });

        await AssertRejected(
            harness,
            SignedEnrollmentError.UnknownKey,
            SignedEnrollmentHarness.EnvelopeText(
                EnrollmentEncoding.EncodeBase64Url(protectedBytes),
                jws["payload"]!.GetValue<string>(),
                jws["signature"]!.GetValue<string>()));
    }

    [Theory]
    [InlineData("none")]
    [InlineData("ES256")]
    [InlineData("HS256")]
    [InlineData("RS256")]
    [InlineData("eddsa")]
    public async Task AnyAlgorithmOtherThanEdDsaMakesZeroTokenBearingRequests(string algorithm)
    {
        using var harness = new SignedEnrollmentHarness();
        JsonObject jws = (JsonObject)SignedEnrollmentHarness.Golden("01-sink-scope.json")["jws"]!;
        byte[] protectedBytes = SignedEnrollmentHarness.Canonical(new JsonObject
        {
            ["alg"] = algorithm,
            ["kid"] = harness.KeyId,
            ["typ"] = SignedEnrollmentVerifier.ExpectedType,
        });

        await AssertRejected(
            harness,
            SignedEnrollmentError.UnsupportedAlgorithm,
            SignedEnrollmentHarness.EnvelopeText(
                EnrollmentEncoding.EncodeBase64Url(protectedBytes),
                jws["payload"]!.GetValue<string>(),
                jws["signature"]!.GetValue<string>()));
    }

    [Fact]
    public async Task WrongTypeInTheProtectedHeaderMakesZeroTokenBearingRequests()
    {
        using var harness = new SignedEnrollmentHarness();
        JsonObject jws = (JsonObject)SignedEnrollmentHarness.Golden("01-sink-scope.json")["jws"]!;
        byte[] protectedBytes = SignedEnrollmentHarness.Canonical(new JsonObject
        {
            ["alg"] = "EdDSA",
            ["kid"] = harness.KeyId,
            ["typ"] = "JWT",
        });

        await AssertRejected(
            harness,
            SignedEnrollmentError.InvalidProtectedHeader,
            SignedEnrollmentHarness.EnvelopeText(
                EnrollmentEncoding.EncodeBase64Url(protectedBytes),
                jws["payload"]!.GetValue<string>(),
                jws["signature"]!.GetValue<string>()));
    }

    [Fact]
    public async Task SubstitutedAuthorityMakesZeroTokenBearingRequests()
    {
        using var harness = new SignedEnrollmentHarness();
        JsonObject golden = SignedEnrollmentHarness.Golden("01-sink-scope.json");
        string protectedSegment = golden["jws"]!["protected"]!.GetValue<string>();

        JsonObject wrongIssuer = SignedEnrollmentHarness.DecodedPayload(golden);
        wrongIssuer["issuer"] = "https://other.example.test";
        await AssertRejected(
            harness,
            SignedEnrollmentError.IssuerMismatch,
            harness.SignedEnvelope(protectedSegment, SignedEnrollmentHarness.Canonical(wrongIssuer)));

        JsonObject wrongAudience = SignedEnrollmentHarness.DecodedPayload(golden);
        wrongAudience["audience"] = "some-other-client";
        await AssertRejected(
            harness,
            SignedEnrollmentError.AudienceMismatch,
            harness.SignedEnvelope(protectedSegment, SignedEnrollmentHarness.Canonical(wrongAudience)));
    }

    [Fact]
    public async Task ExpiredSignedBundleMakesZeroTokenBearingRequests()
    {
        using var harness = new SignedEnrollmentHarness();
        JsonObject golden = SignedEnrollmentHarness.Golden("01-sink-scope.json");
        JsonObject payload = SignedEnrollmentHarness.DecodedPayload(golden);
        payload["issuedAt"] = "2026-07-24T08:00:00Z";
        payload["bundleExpiresAt"] = "2026-07-24T08:15:00Z";

        await AssertRejected(
            harness,
            SignedEnrollmentError.BundleExpired,
            harness.SignedEnvelope(
                golden["jws"]!["protected"]!.GetValue<string>(),
                SignedEnrollmentHarness.Canonical(payload)));
    }

    [Fact]
    public async Task FutureDatedBundleMakesZeroTokenBearingRequests()
    {
        using var harness = new SignedEnrollmentHarness();
        JsonObject golden = SignedEnrollmentHarness.Golden("01-sink-scope.json");
        JsonObject payload = SignedEnrollmentHarness.DecodedPayload(golden);
        payload["issuedAt"] = "2026-07-24T12:00:00Z";
        payload["bundleExpiresAt"] = "2026-07-24T12:15:00Z";
        payload["expiresAt"] = "2026-08-23T12:00:00Z";

        await AssertRejected(
            harness,
            SignedEnrollmentError.NotYetValid,
            harness.SignedEnvelope(
                golden["jws"]!["protected"]!.GetValue<string>(),
                SignedEnrollmentHarness.Canonical(payload)));
    }

    [Fact]
    public async Task RollbackToAnOlderGenerationMakesNoAdditionalTokenBearingRequest()
    {
        using var harness = new SignedEnrollmentHarness();
        var probe = new TokenRequestProbe();

        await harness.Importer.AuthorizeThenAsync(
            SignedEnrollmentHarness.GoldenJwsText(
                SignedEnrollmentHarness.Golden("02-archive-only-none-scope.json")),
            Now,
            probe.RequestAsync);
        Assert.Equal(1, probe.RequestCount);

        await AssertRejected(
            harness,
            SignedEnrollmentError.Rollback,
            SignedEnrollmentHarness.GoldenJwsText(
                SignedEnrollmentHarness.Golden("01-sink-scope.json")),
            probe);
        Assert.Equal(1, probe.RequestCount);
    }

    [Fact]
    public async Task ReusedGenerationWithADifferentBundleIdMakesNoAdditionalTokenBearingRequest()
    {
        using var harness = new SignedEnrollmentHarness();
        JsonObject golden = SignedEnrollmentHarness.Golden("01-sink-scope.json");
        var probe = new TokenRequestProbe();

        await harness.Importer.AuthorizeThenAsync(
            SignedEnrollmentHarness.GoldenJwsText(golden),
            Now,
            probe.RequestAsync);
        Assert.Equal(1, probe.RequestCount);

        JsonObject collision = SignedEnrollmentHarness.DecodedPayload(golden);
        collision["bundleId"] = "jdb_018ff3a2679a7bd18a5e6c3d4b2a1910";
        await AssertRejected(
            harness,
            SignedEnrollmentError.Collision,
            harness.SignedEnvelope(
                golden["jws"]!["protected"]!.GetValue<string>(),
                SignedEnrollmentHarness.Canonical(collision)),
            probe);
        Assert.Equal(1, probe.RequestCount);
    }

    [Fact]
    public async Task ReusedBundleIdAtANewerGenerationMakesNoAdditionalTokenBearingRequest()
    {
        using var harness = new SignedEnrollmentHarness();
        JsonObject golden = SignedEnrollmentHarness.Golden("01-sink-scope.json");
        var probe = new TokenRequestProbe();

        await harness.Importer.AuthorizeThenAsync(
            SignedEnrollmentHarness.GoldenJwsText(golden),
            Now,
            probe.RequestAsync);
        Assert.Equal(1, probe.RequestCount);

        // Same bundle id, new generation, new signed content: the bundle id is a global identity,
        // so re-minting one is a replay attempt however well signed it is.
        JsonObject replay = SignedEnrollmentHarness.DecodedPayload(golden);
        replay["generation"] = 9;
        replay["tokenId"] = "999999";
        await AssertRejected(
            harness,
            SignedEnrollmentError.Collision,
            harness.SignedEnvelope(
                golden["jws"]!["protected"]!.GetValue<string>(),
                SignedEnrollmentHarness.Canonical(replay)),
            probe);
        Assert.Equal(1, probe.RequestCount);
    }

    [Fact]
    public async Task MissingTrustAnchorFailsClosedBeforeAnyRequest()
    {
        using var harness = new SignedEnrollmentHarness(includeTrustAnchor: false);
        await AssertRejected(
            harness,
            SignedEnrollmentError.TrustUnavailable,
            SignedEnrollmentHarness.GoldenJwsText(
                SignedEnrollmentHarness.Golden("01-sink-scope.json")));
    }

    [Fact]
    public async Task DuplicateKeysInEverySignedLayerFailClosedBeforeAnyRequest()
    {
        using var harness = new SignedEnrollmentHarness();
        JsonObject jws = (JsonObject)SignedEnrollmentHarness.Golden("01-sink-scope.json")["jws"]!;
        string protectedSegment = jws["protected"]!.GetValue<string>();
        string payloadSegment = jws["payload"]!.GetValue<string>();
        string signature = jws["signature"]!.GetValue<string>();
        var probe = new TokenRequestProbe();

        await AssertRejected(
            harness,
            SignedEnrollmentError.MalformedEnvelope,
            $$"""{"protected":"{{protectedSegment}}","payload":"{{payloadSegment}}","payload":"{{payloadSegment}}","signature":"{{signature}}"}""",
            probe);

        string duplicateProtected =
            $$"""{"alg":"EdDSA","kid":"{{harness.KeyId}}","kid":"{{harness.KeyId}}","typ":"{{SignedEnrollmentVerifier.ExpectedType}}"}""";
        await AssertRejected(
            harness,
            SignedEnrollmentError.InvalidProtectedHeader,
            SignedEnrollmentHarness.EnvelopeText(
                EnrollmentEncoding.EncodeBase64Url(Encoding.UTF8.GetBytes(duplicateProtected)),
                payloadSegment,
                signature),
            probe);

        string payloadText = Encoding.UTF8.GetString(
            EnrollmentEncoding.DecodeBase64Url(payloadSegment, maximumBytes: 98_304)!);
        int tokenIndex = payloadText.IndexOf("\"token\":", StringComparison.Ordinal);
        string duplicatePayload = payloadText[..tokenIndex]
            + "\"token\":\"attacker-controlled\","
            + payloadText[tokenIndex..];
        await AssertRejected(
            harness,
            SignedEnrollmentError.InvalidPayload,
            harness.SignedEnvelope(protectedSegment, Encoding.UTF8.GetBytes(duplicatePayload)),
            probe);

        Assert.Equal(0, probe.RequestCount);
    }

    [Fact]
    public async Task NonCanonicalProtectedHeaderAndPayloadFailClosed()
    {
        using var harness = new SignedEnrollmentHarness();
        JsonObject golden = SignedEnrollmentHarness.Golden("01-sink-scope.json");
        string protectedSegment = golden["jws"]!["protected"]!.GetValue<string>();
        var probe = new TokenRequestProbe();

        // Pretty-printed but otherwise identical payload: a second spelling of one signed document
        // is a second signing input, so exactly one spelling may be accepted.
        JsonObject payload = SignedEnrollmentHarness.DecodedPayload(golden);
        byte[] pretty = Encoding.UTF8.GetBytes(
            System.Text.Json.JsonSerializer.Serialize(
                payload,
                new System.Text.Json.JsonSerializerOptions { WriteIndented = true }));
        await AssertRejected(
            harness,
            SignedEnrollmentError.NonCanonicalPayload,
            harness.SignedEnvelope(protectedSegment, pretty),
            probe);

        string canonicalPayload = Encoding.UTF8.GetString(SignedEnrollmentHarness.Canonical(payload));
        string escapedSlash = ReplaceFirst(
            canonicalPayload,
            "https://jazz.example.test",
            @"https:\/\/jazz.example.test");
        await AssertRejected(
            harness,
            SignedEnrollmentError.NonCanonicalPayload,
            harness.SignedEnvelope(protectedSegment, Encoding.UTF8.GetBytes(escapedSlash)),
            probe);

        byte[] reorderedProtected = Encoding.UTF8.GetBytes(
            $$"""{"typ":"{{SignedEnrollmentVerifier.ExpectedType}}","kid":"{{harness.KeyId}}","alg":"EdDSA"}""");
        await AssertRejected(
            harness,
            SignedEnrollmentError.NonCanonicalProtectedHeader,
            SignedEnrollmentHarness.EnvelopeText(
                EnrollmentEncoding.EncodeBase64Url(reorderedProtected),
                golden["jws"]!["payload"]!.GetValue<string>(),
                golden["jws"]!["signature"]!.GetValue<string>()),
            probe);

        Assert.Equal(0, probe.RequestCount);
    }

    [Fact]
    public void CanonicalJsonMatchesTheServerForUnicodeAndUnescapedSlash()
    {
        byte[] canonical = EnrollmentEncoding.TryCanonicalJson(new JsonObject
        {
            ["z"] = "Žluťoučký/路径",
            ["a"] = "line\nbreak",
        })!;

        Assert.Equal(
            """{"a":"line\nbreak","z":"Žluťoučký/路径"}""",
            Encoding.UTF8.GetString(canonical));
    }

    [Fact]
    public async Task NonAsciiTokenSurvivesVerificationByteForByte()
    {
        using var harness = new SignedEnrollmentHarness();
        JsonObject golden = SignedEnrollmentHarness.Golden("01-sink-scope.json");
        JsonObject payload = SignedEnrollmentHarness.DecodedPayload(golden);
        payload["token"] = "Žluťoučký/路径";
        var probe = new TokenRequestProbe();

        (AuthorizedSignedDeviceBundle authorized, _) = await harness.Importer.AuthorizeThenAsync(
            harness.SignedEnvelope(
                golden["jws"]!["protected"]!.GetValue<string>(),
                SignedEnrollmentHarness.Canonical(payload)),
            Now,
            probe.RequestAsync);

        Assert.Equal("Žluťoučký/路径", authorized.Payload.Token);
        Assert.Equal(1, probe.RequestCount);
    }

    [Fact]
    public void SchemaMaxLengthCountsUnicodeScalarsLikeTheServer()
    {
        using var harness = new SignedEnrollmentHarness();
        JsonObject golden = SignedEnrollmentHarness.Golden("01-sink-scope.json");
        JsonObject payload = SignedEnrollmentHarness.DecodedPayload(golden);
        string token = string.Concat(Enumerable.Repeat("\U0001F600", 8_192));
        Assert.Equal(8_192, EnrollmentEncoding.ScalarCount(token));
        Assert.Equal(16_384, token.Length);
        payload["token"] = token;

        AuthorizedSignedDeviceBundle authorized = harness.Importer.Authorize(
            harness.SignedEnvelope(
                golden["jws"]!["protected"]!.GetValue<string>(),
                SignedEnrollmentHarness.Canonical(payload)),
            Now);

        Assert.Equal(8_192, EnrollmentEncoding.ScalarCount(authorized.Payload.Token));
        Assert.Equal(EnrollmentAcceptanceDecision.First, authorized.Acceptance);
    }

    [Theory]
    [InlineData("https://jazz.example.test/prefix/api/archive-ingests")]
    [InlineData("http://127.0.0.1:4318/prefix/api/archive-ingests")]
    [InlineData("http://[::1]:4318/api/archive-ingests")]
    public void SignedArchiveIngestAcceptsCanonicalPrefixAndLiteralLoopbackOrigins(string ingestUrl)
    {
        using var harness = new SignedEnrollmentHarness();
        JsonObject golden = SignedEnrollmentHarness.Golden("01-sink-scope.json");
        JsonObject payload = SignedEnrollmentHarness.DecodedPayload(golden);
        payload["archiveIngestURL"] = ingestUrl;

        AuthorizedSignedDeviceBundle authorized = harness.Importer.Authorize(
            harness.SignedEnvelope(
                golden["jws"]!["protected"]!.GetValue<string>(),
                SignedEnrollmentHarness.Canonical(payload)),
            Now);

        Assert.Equal(ingestUrl, authorized.Payload.ArchiveIngestUrl);
        Assert.Equal(
            ingestUrl,
            JazzCaptureCore.Enrollment.JazzArchiveControlPlaneUrl.Normalize(ingestUrl));
    }

    [Theory]
    [InlineData("https://jazz.example.test/api/archive-ingests/")]
    [InlineData("https://jazz.example.test:443/api/archive-ingests")]
    [InlineData("HTTPS://jazz.example.test/api/archive-ingests")]
    [InlineData("https://jazz.example.test/api/archive-ingests?tenant=other")]
    [InlineData("https://jazz.example.test/prefix/../api/archive-ingests")]
    [InlineData("https://jazz.example.test/prefix//api/archive-ingests")]
    [InlineData("https://jazz.example.test/prefix%2fapi/archive-ingests")]
    [InlineData("http://jazz.example.test/api/archive-ingests")]
    public async Task SignedArchiveIngestRejectsEveryNonCanonicalRouteBeforeAnyRequest(string ingestUrl)
    {
        using var harness = new SignedEnrollmentHarness();
        JsonObject golden = SignedEnrollmentHarness.Golden("01-sink-scope.json");
        JsonObject payload = SignedEnrollmentHarness.DecodedPayload(golden);
        payload["archiveIngestURL"] = ingestUrl;

        await AssertRejected(
            harness,
            SignedEnrollmentError.InvalidPayload,
            harness.SignedEnvelope(
                golden["jws"]!["protected"]!.GetValue<string>(),
                SignedEnrollmentHarness.Canonical(payload)));

        Assert.NotEqual(
            ingestUrl,
            JazzCaptureCore.Enrollment.JazzArchiveControlPlaneUrl.Normalize(ingestUrl));
    }

    [Fact]
    public async Task StreamSourceWithoutAnEndpointFailsClosed()
    {
        using var harness = new SignedEnrollmentHarness();
        JsonObject golden = SignedEnrollmentHarness.Golden("01-sink-scope.json");
        JsonObject payload = SignedEnrollmentHarness.DecodedPayload(golden);
        payload["streamEndpoint"] = null;

        await AssertRejected(
            harness,
            SignedEnrollmentError.InvalidPayload,
            harness.SignedEnvelope(
                golden["jws"]!["protected"]!.GetValue<string>(),
                SignedEnrollmentHarness.Canonical(payload)));
    }

    [Fact]
    public async Task SinkScopeWithoutASinkBucketFailsClosed()
    {
        using var harness = new SignedEnrollmentHarness();
        JsonObject golden = SignedEnrollmentHarness.Golden("01-sink-scope.json");
        JsonObject payload = SignedEnrollmentHarness.DecodedPayload(golden);
        payload["sinkBucketId"] = null;

        await AssertRejected(
            harness,
            SignedEnrollmentError.InvalidPayload,
            harness.SignedEnvelope(
                golden["jws"]!["protected"]!.GetValue<string>(),
                SignedEnrollmentHarness.Canonical(payload)));
    }

    [Fact]
    public async Task NoneScopeCarryingASinkBucketFailsClosed()
    {
        using var harness = new SignedEnrollmentHarness();
        JsonObject golden = SignedEnrollmentHarness.Golden("02-archive-only-none-scope.json");
        JsonObject payload = SignedEnrollmentHarness.DecodedPayload(golden);
        payload["sinkBucketId"] = "in.c-otlp-somewhere";

        await AssertRejected(
            harness,
            SignedEnrollmentError.InvalidPayload,
            harness.SignedEnvelope(
                golden["jws"]!["protected"]!.GetValue<string>(),
                SignedEnrollmentHarness.Canonical(payload)));
    }

    [Fact]
    public async Task UnsortedOrDuplicatedComponentAccessFailsClosed()
    {
        using var harness = new SignedEnrollmentHarness();
        JsonObject golden = SignedEnrollmentHarness.Golden("01-sink-scope.json");
        string protectedSegment = golden["jws"]!["protected"]!.GetValue<string>();

        JsonObject unsorted = SignedEnrollmentHarness.DecodedPayload(golden);
        unsorted["componentAccess"] = new JsonArray("keboola.zzz", "keboola.aaa");
        await AssertRejected(
            harness,
            SignedEnrollmentError.InvalidPayload,
            harness.SignedEnvelope(protectedSegment, SignedEnrollmentHarness.Canonical(unsorted)));

        JsonObject duplicated = SignedEnrollmentHarness.DecodedPayload(golden);
        duplicated["componentAccess"] = new JsonArray("keboola.aaa", "keboola.aaa");
        await AssertRejected(
            harness,
            SignedEnrollmentError.InvalidPayload,
            harness.SignedEnvelope(protectedSegment, SignedEnrollmentHarness.Canonical(duplicated)));
    }

    private static string ReplaceFirst(string text, string search, string replacement)
    {
        int index = text.IndexOf(search, StringComparison.Ordinal);
        Assert.True(index >= 0, $"'{search}' is not present in the payload.");
        return text[..index] + replacement + text[(index + search.Length)..];
    }

    private static async Task AssertRejected(
        SignedEnrollmentHarness harness,
        SignedEnrollmentError expected,
        string text,
        TokenRequestProbe? probe = null)
    {
        probe ??= new TokenRequestProbe();
        int before = probe.RequestCount;

        SignedEnrollmentException error = await Assert.ThrowsAsync<SignedEnrollmentException>(
            () => harness.Importer.AuthorizeThenAsync(text, Now, probe.RequestAsync));

        Assert.Equal(expected, error.Reason);
        Assert.Equal(before, probe.RequestCount);
    }

    internal static DateTimeOffset Instant(string value) => DateTimeOffset.Parse(
        value,
        CultureInfo.InvariantCulture,
        DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal);
}
