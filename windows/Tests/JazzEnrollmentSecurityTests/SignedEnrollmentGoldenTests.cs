using System.Text.Json.Nodes;
using JazzCaptureCore.Enrollment;
using JazzEnrollmentSecurity;
using JazzEnrollmentSecurityTests.Support;

namespace JazzEnrollmentSecurityTests;

/// <summary>
/// Every shared contract vector under <c>contract/enrollment/</c> that this module is meant to
/// accept, verified end to end.
/// </summary>
public sealed class SignedEnrollmentGoldenTests
{
    private static readonly DateTimeOffset Now = DateTimeOffset.Parse(
        "2026-07-24T09:35:00Z",
        System.Globalization.CultureInfo.InvariantCulture,
        System.Globalization.DateTimeStyles.AdjustToUniversal | System.Globalization.DateTimeStyles.AssumeUniversal);

    /// <summary>
    /// The fixture corpus is discovered, not listed: a vector added to the contract must be
    /// verified by this client or this test fails.
    /// </summary>
    public static TheoryData<string> SignedFixtures()
    {
        var data = new TheoryData<string>();
        foreach (string name in EnrollmentContract.SignedFixtureNames())
        {
            data.Add(name);
        }

        return data;
    }

    [Theory]
    [MemberData(nameof(SignedFixtures))]
    public void EverySignedContractFixtureVerifiesAndMatchesItsExpectedPayload(string name)
    {
        using var harness = new SignedEnrollmentHarness();
        JsonObject golden = SignedEnrollmentHarness.Golden(name);

        AuthorizedSignedDeviceBundle authorized = harness.Importer.Authorize(
            SignedEnrollmentHarness.GoldenJwsText(golden),
            Now);

        JsonObject expected = (JsonObject)golden["expectedPayload"]!;
        SignedDeviceBundlePayload payload = authorized.Payload;
        Assert.Equal(expected["schemaVersion"]!.GetValue<long>(), payload.SchemaVersion);
        Assert.Equal(expected["kind"]!.GetValue<string>(), payload.Kind);
        Assert.Equal(expected["bundleId"]!.GetValue<string>(), payload.BundleId);
        Assert.Equal(expected["generation"]!.GetValue<long>(), payload.Generation);
        Assert.Equal(expected["issuer"]!.GetValue<string>(), payload.Issuer);
        Assert.Equal(expected["audience"]!.GetValue<string>(), payload.Audience);
        Assert.Equal(expected["issuedAt"]!.GetValue<string>(), payload.IssuedAt);
        Assert.Equal(expected["bundleExpiresAt"]!.GetValue<string>(), payload.BundleExpiresAt);
        Assert.Equal(expected["deviceId"]!.GetValue<string>(), payload.DeviceId);
        Assert.Equal(expected["companyId"]!.GetValue<string>(), payload.CompanyId);
        Assert.Equal(expected["areaId"]!.GetValue<string>(), payload.AreaId);
        Assert.Equal(expected["projectId"]!.GetValue<string>(), payload.ProjectId);
        Assert.Equal(expected["stackURL"]!.GetValue<string>(), payload.StackUrl);
        Assert.Equal(expected["archiveIngestURL"]!.GetValue<string>(), payload.ArchiveIngestUrl);
        Assert.Equal(expected["token"]!.GetValue<string>(), payload.Token);
        Assert.Equal(expected["tokenId"]!.GetValue<string>(), payload.TokenId);
        Assert.Equal(expected["expiresAt"]!.GetValue<string>(), payload.ExpiresAt);
        Assert.Equal(
            expected["tokenBucketScope"]!.GetValue<string>(),
            payload.TokenBucketScope.ToWire());
        Assert.Equal(OptionalString(expected, "sinkBucketId"), payload.SinkBucketId);
        Assert.Equal(OptionalString(expected, "streamSourceId"), payload.StreamSourceId);
        Assert.Equal(OptionalString(expected, "streamEndpoint"), payload.StreamEndpoint);
        Assert.Equal(
            ((JsonArray)expected["componentAccess"]!).Select(node => node!.GetValue<string>()).ToArray(),
            payload.ComponentAccess.ToArray());
        Assert.Equal(EnrollmentAcceptanceDecision.First, authorized.Acceptance);
    }

    [Fact]
    public void EverySignedContractFixtureNamesTheSameTrustAnchorAsTheLocalTestKey()
    {
        using var harness = new SignedEnrollmentHarness();
        foreach (string name in EnrollmentContract.SignedFixtureNames())
        {
            JsonObject trusted = (JsonObject)SignedEnrollmentHarness.Golden(name)["trustedPublicKey"]!;
            Assert.Equal("OKP", trusted["kty"]!.GetValue<string>());
            Assert.Equal("Ed25519", trusted["crv"]!.GetValue<string>());
            Assert.Equal(harness.KeyId, trusted["kid"]!.GetValue<string>());
            Assert.Equal(harness.PublicKeyBase64Url, trusted["x"]!.GetValue<string>());
        }
    }

    [Fact]
    public async Task BothServerGoldensVerifyAndAdvanceOneAtomicPerDeviceLedger()
    {
        using var harness = new SignedEnrollmentHarness();
        JsonObject sink = SignedEnrollmentHarness.Golden("01-sink-scope.json");
        JsonObject archiveOnly = SignedEnrollmentHarness.Golden("02-archive-only-none-scope.json");
        var probe = new TokenRequestProbe();

        (AuthorizedSignedDeviceBundle first, _) = await harness.Importer.AuthorizeThenAsync(
            SignedEnrollmentHarness.GoldenJwsText(sink),
            Now,
            probe.RequestAsync);
        Assert.Equal(EnrollmentAcceptanceDecision.First, first.Acceptance);
        Assert.Equal(7, first.Payload.Generation);
        Assert.Equal(JazzArchiveTokenBucketScope.Sink, first.Payload.TokenBucketScope);
        Assert.Equal(
            "ec80eb2df35b457027e5704fe523e45fba7200b12df23c68a4005284281985d2",
            first.EnvelopeDigest);

        (AuthorizedSignedDeviceBundle advanced, _) = await harness.Importer.AuthorizeThenAsync(
            SignedEnrollmentHarness.GoldenJwsText(archiveOnly),
            Now,
            probe.RequestAsync);
        Assert.Equal(EnrollmentAcceptanceDecision.Advanced, advanced.Acceptance);
        Assert.Equal(8, advanced.Payload.Generation);
        Assert.Null(advanced.Payload.SinkBucketId);
        Assert.Null(advanced.Payload.StreamEndpoint);
        Assert.Equal(
            "be82b857609ef77165bfc4ea8f7c41fb493dc839179e68ae5b08676c45e19bba",
            advanced.EnvelopeDigest);
        Assert.Equal(2, probe.RequestCount);

        IReadOnlyDictionary<string, EnrollmentAcceptanceRecord> records = harness.Store.Records();
        Assert.Equal(8, records["mac-finance-01"].Generation);
        Assert.Equal("jdb_018ff3a2679a7bd18a5e6c3d4b2a1909", records["mac-finance-01"].BundleId);

        // The ledger is a replay record, not a credential store: nothing token-bearing may land in it.
        string ledger = File.ReadAllText(harness.Store.FilePath);
        Assert.DoesNotContain("TEST-ARCHIVE-TOKEN", ledger, StringComparison.Ordinal);
        Assert.DoesNotContain("stream.example.test", ledger, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ByteIdenticalGenerationIsIdempotentAndMayRetryNetwork()
    {
        using var harness = new SignedEnrollmentHarness();
        string text = SignedEnrollmentHarness.GoldenJwsText(
            SignedEnrollmentHarness.Golden("01-sink-scope.json"));
        var probe = new TokenRequestProbe();

        (AuthorizedSignedDeviceBundle first, _) =
            await harness.Importer.AuthorizeThenAsync(text, Now, probe.RequestAsync);
        (AuthorizedSignedDeviceBundle second, _) =
            await harness.Importer.AuthorizeThenAsync(text, Now, probe.RequestAsync);

        Assert.Equal(EnrollmentAcceptanceDecision.First, first.Acceptance);
        Assert.Equal(EnrollmentAcceptanceDecision.Idempotent, second.Acceptance);
        Assert.Equal(first.EnvelopeDigest, second.EnvelopeDigest);
        Assert.Equal(2, probe.RequestCount);
    }

    private static string? OptionalString(JsonObject value, string key) =>
        value[key] is JsonNode node ? node.GetValue<string>() : null;
}
