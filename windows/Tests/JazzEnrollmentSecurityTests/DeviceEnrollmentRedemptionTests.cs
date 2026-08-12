using System.Text;
using System.Text.Json.Nodes;
using JazzEnrollmentSecurity;
using JazzEnrollmentSecurityTests.Support;

namespace JazzEnrollmentSecurityTests;

/// <summary>
/// The native redemption state machine and document grammar, driven by the shared HTTP fixture.
/// </summary>
/// <remarks>
/// The transport is a seam, so nothing here talks to a server. What is being tested is the part that
/// is portable: which documents are accepted, in what order state is committed, and - for every
/// refusal - that it lands before a claim carrying this device's proof key is ever submitted.
/// </remarks>
public sealed class DeviceEnrollmentRedemptionTests
{
    private const string GoldenClaimId = "jcl_22222222222222222222222222222222";

    [Fact]
    public void TheBootstrapParserAcceptsAPrefixedRouteAndRejectsTampering()
    {
        JsonObject fixture = HttpFixture();
        string text = EnrollmentContract.CanonicalText(fixture["bootstrap"]!.DeepClone());

        DeviceRedemptionBootstrap parsed = DeviceRedemptionBootstrap.Parse(text);
        Assert.Equal(
            "https://native.example.test/jazz/api/device-enrollment/redemptions/" + parsed.BootstrapId,
            parsed.RedemptionUrl);

        var extra = (JsonObject)fixture["bootstrap"]!.DeepClone();
        extra["authorityBindingSHA256"] = new string('a', 64);
        Assert.Equal(
            DeviceEnrollmentRedemptionError.MalformedBootstrap,
            Assert.Throws<DeviceEnrollmentRedemptionException>(
                () => DeviceRedemptionBootstrap.Parse(EnrollmentContract.CanonicalText(extra))).Reason);

        var wrongRoute = (JsonObject)fixture["bootstrap"]!.DeepClone();
        wrongRoute["redemptionURL"] =
            "https://native.example.test/api/device-enrollment/redemptions/jbt_99999999999999999999999999999999";
        Assert.Equal(
            DeviceEnrollmentRedemptionError.InsecureRedemptionRoute,
            Assert.Throws<DeviceEnrollmentRedemptionException>(
                () => DeviceRedemptionBootstrap.Parse(EnrollmentContract.CanonicalText(wrongRoute))).Reason);

        string duplicate = text.Replace(
            "\"kind\":\"jazz-device-redemption-bootstrap\"",
            "\"kind\":\"jazz-device-redemption-bootstrap\",\"kind\":\"jazz-device-redemption-bootstrap\"",
            StringComparison.Ordinal);
        Assert.Equal(
            DeviceEnrollmentRedemptionError.MalformedBootstrap,
            Assert.Throws<DeviceEnrollmentRedemptionException>(
                () => DeviceRedemptionBootstrap.Parse(duplicate)).Reason);
    }

    [Theory]
    [InlineData("http://native.example.test/jazz/api/device-enrollment/redemptions/", "plain HTTP")]
    [InlineData("https://native.example.test/jazz/api/device-enrollment/redemptions/", "trailing-slash route")]
    [InlineData("https://native.example.test//jazz/api/device-enrollment/redemptions/", "empty path segment")]
    public void ARouteThatIsNotTheCanonicalRedemptionEndpointIsRefused(string prefix, string reason)
    {
        JsonObject fixture = HttpFixture();
        var bootstrap = (JsonObject)fixture["bootstrap"]!.DeepClone();
        string bootstrapId = bootstrap["bootstrapId"]!.GetValue<string>();
        bootstrap["redemptionURL"] = prefix.EndsWith("redemptions/", StringComparison.Ordinal)
            ? prefix + bootstrapId + "/"
            : prefix + bootstrapId;

        Assert.Throws<DeviceEnrollmentRedemptionException>(
            () => DeviceRedemptionBootstrap.Parse(EnrollmentContract.CanonicalText(bootstrap)));
        Assert.NotNull(reason);
    }

    [Fact]
    public async Task AnUnpinnedCopiedBootstrapCannotEvenCreateADeviceIdentity()
    {
        JsonObject fixture = HttpFixture();
        var bootstrap = (JsonObject)fixture["bootstrap"]!.DeepClone();
        bootstrap["redemptionURL"] =
            "https://attacker.example.test/api/device-enrollment/redemptions/"
            + bootstrap["bootstrapId"]!.GetValue<string>();
        var harness = new RedemptionHarness(Instant("2026-07-24T09:01:00Z"));

        DeviceEnrollmentRedemptionException error =
            await Assert.ThrowsAsync<DeviceEnrollmentRedemptionException>(
                () => harness.Coordinator.BeginAsync(EnrollmentContract.CanonicalText(bootstrap)));

        Assert.Equal(DeviceEnrollmentRedemptionError.InsecureRedemptionRoute, error.Reason);
        Assert.Null(harness.PendingStore.Load());
        Assert.Equal(0, harness.Backend.GenerateCount);
        Assert.Equal(0, harness.Transport.ContextCount);
        Assert.Empty(harness.Transport.SubmittedClaims);
    }

    [Theory]
    [InlineData("issuer", "https://attacker.example.test")]
    [InlineData("audience", "some-other-client")]
    [InlineData("companyId", "not-acme")]
    [InlineData("areaId", "not-finance")]
    [InlineData("projectId", "9999")]
    [InlineData("deviceId", "other-device")]
    [InlineData("bundleId", "jdb_99999999999999999999999999999999")]
    [InlineData("stackURL", "https://connection.keboola.com/path")]
    [InlineData("archiveIngestURL", "https://attacker.example.test/api/archive-ingests/")]
    public async Task ASubstitutedAuthorityStopsBeforeAnyClaimIsCreatedOrSubmitted(string field, string value)
    {
        JsonObject fixture = HttpFixture();
        var context = (JsonObject)fixture["context"]!.DeepClone();
        context[field] = value;
        var harness = new RedemptionHarness(
            Instant("2026-07-24T09:01:00Z"),
            context: EnrollmentContract.Canonical(context));

        DeviceEnrollmentRedemptionException error =
            await Assert.ThrowsAsync<DeviceEnrollmentRedemptionException>(
                () => harness.Coordinator.BeginAsync(BootstrapText(fixture)));

        Assert.Equal(DeviceEnrollmentRedemptionError.AuthorityMismatch, error.Reason);

        // The device key is created from the context's authority binding, and the claim carries that
        // key. Refusing after either would mean this machine had already bound itself to a
        // substituted authority.
        Assert.Equal(0, harness.Backend.GenerateCount);
        Assert.Empty(harness.Transport.SubmittedClaims);
        Assert.Equal(0, harness.Transport.PollCount);
    }

    [Theory]
    [InlineData("stackURL", "https://connection.other.keboola.cloud")]
    [InlineData("archiveIngestURL", "https://attacker.example.test/api/archive-ingests")]
    public async Task AnAlreadyEnrolledDeviceRefusesASubstitutedRoutingAuthorityBeforeAnyClaim(
        string field,
        string value)
    {
        // The stack and archive origins are not pinned by the code-signed policy - a deployment
        // chooses them - but they are covered by the authority binding digest that names the local
        // key set. Substituting one therefore asks this device to bind a second identity, which the
        // single-slot vault refuses before a claim carrying any key is built.
        JsonObject fixture = HttpFixture();
        var pendingStore = new MemoryRedemptionPendingStore();
        var backend = new FakeHardwareKeyBackend();
        var identityStore = new MemoryIdentityStore();

        var genuine = new RedemptionTransport(
            EnrollmentContract.Canonical(fixture["context"]!.DeepClone()),
            EnrollmentContract.Canonical(fixture["pendingResponse"]!.DeepClone()));
        DeviceEnrollmentRedemptionCoordinator first = RedemptionHarness.Coordinate(
            pendingStore, backend, identityStore, genuine, Instant("2026-07-24T09:01:00Z"));
        Assert.Null(await first.BeginAsync(BootstrapText(fixture)));
        Assert.Equal(1, backend.GenerateCount);

        var substituted = (JsonObject)fixture["context"]!.DeepClone();
        substituted[field] = value;
        var rogue = new RedemptionTransport(
            EnrollmentContract.Canonical(substituted),
            EnrollmentContract.Canonical(fixture["pendingResponse"]!.DeepClone()));
        DeviceEnrollmentRedemptionCoordinator second = RedemptionHarness.Coordinate(
            new MemoryRedemptionPendingStore(),
            backend,
            identityStore,
            rogue,
            Instant("2026-07-24T09:01:00Z"));

        DeviceEnrollmentIdentityException error = await Assert.ThrowsAsync<DeviceEnrollmentIdentityException>(
            () => second.BeginAsync(BootstrapText(fixture)));

        Assert.Equal(DeviceEnrollmentIdentityError.BindingConflict, error.Reason);
        Assert.Empty(rogue.SubmittedClaims);
        Assert.Equal(0, rogue.PollCount);
        Assert.Equal(1, backend.GenerateCount);
    }

    [Fact]
    public async Task AContextWhoseDeviceScopeDigestDoesNotRecomputeIsRefused()
    {
        JsonObject fixture = HttpFixture();
        var context = (JsonObject)fixture["context"]!.DeepClone();
        context["deviceScopeSHA256"] = new string('f', 64);
        var harness = new RedemptionHarness(
            Instant("2026-07-24T09:01:00Z"),
            context: EnrollmentContract.Canonical(context));

        DeviceEnrollmentRedemptionException error =
            await Assert.ThrowsAsync<DeviceEnrollmentRedemptionException>(
                () => harness.Coordinator.BeginAsync(BootstrapText(fixture)));

        Assert.Equal(DeviceEnrollmentRedemptionError.AuthorityMismatch, error.Reason);
        Assert.Equal(0, harness.Backend.GenerateCount);
        Assert.Empty(harness.Transport.SubmittedClaims);
    }

    [Fact]
    public async Task TheContractContextDigestsRecomputeExactly()
    {
        // The fixture's deviceScopeSHA256 was produced by the server. Accepting it proves the
        // canonical-digest construction here is the same one, not merely a self-consistent one.
        JsonObject fixture = HttpFixture();
        var harness = new RedemptionHarness(Instant("2026-07-24T09:01:00Z"));

        RedeemedDeviceEnrollment? result = await harness.Coordinator.BeginAsync(BootstrapText(fixture));

        Assert.Null(result);
        Assert.Equal(1, harness.Transport.ContextCount);
        Assert.Single(harness.Transport.SubmittedClaims);
        DeviceRedemptionPendingIdentity? pending = harness.Coordinator.PendingIdentity();
        Assert.NotNull(pending);
        Assert.Equal("https://jazz.example.test", pending.Issuer);
        Assert.Equal("jazz-desktop-client", pending.Audience);
    }

    [Fact]
    public async Task ARestartRetriesTheExactClaimBytesAndThenPolls()
    {
        JsonObject fixture = HttpFixture();
        var pendingStore = new MemoryRedemptionPendingStore();
        var backend = new FakeHardwareKeyBackend();
        var identityStore = new MemoryIdentityStore();
        var transport = new RedemptionTransport(
            EnrollmentContract.Canonical(fixture["context"]!.DeepClone()),
            EnrollmentContract.Canonical(fixture["pendingResponse"]!.DeepClone()))
        {
            FailFirstSubmit = true,
        };

        DeviceEnrollmentRedemptionCoordinator first = RedemptionHarness.Coordinate(
            pendingStore, backend, identityStore, transport, Instant("2026-07-24T09:01:00Z"));
        DeviceEnrollmentRedemptionException lost =
            await Assert.ThrowsAsync<DeviceEnrollmentRedemptionException>(
                () => first.BeginAsync(BootstrapText(fixture)));
        Assert.Equal(DeviceEnrollmentRedemptionError.ServerUnavailable, lost.Reason);
        Assert.True(first.HasPendingEnrollment());

        DeviceEnrollmentRedemptionCoordinator restarted = RedemptionHarness.Coordinate(
            pendingStore, backend, identityStore, transport, Instant("2026-07-24T09:01:01Z"));
        Assert.Null(await restarted.ResumeAsync());
        Assert.Equal(2, transport.SubmittedClaims.Count);

        // The retry must be the same bytes: the server bound its one-shot claim slot to them.
        Assert.Equal(transport.SubmittedClaims[0], transport.SubmittedClaims[1]);
        Assert.Equal(1, backend.GenerateCount);

        Assert.Null(await restarted.ResumeAsync());
        Assert.Equal(1, transport.PollCount);
        Assert.Equal(2, transport.SubmittedClaims.Count);
    }

    [Fact]
    public async Task AnExpiredPendingRecordIsAtomicallyReplacedAndDiscardTouchesNoIdentity()
    {
        JsonObject fixture = HttpFixture();
        var pendingStore = new MemoryRedemptionPendingStore();
        var backend = new FakeHardwareKeyBackend();
        var identityStore = new MemoryIdentityStore();
        var transport = new RedemptionTransport(Array.Empty<byte>(), Array.Empty<byte>())
        {
            AlwaysFail = true,
        };

        DeviceEnrollmentRedemptionCoordinator first = RedemptionHarness.Coordinate(
            pendingStore, backend, identityStore, transport, Instant("2026-07-24T09:01:00Z"));
        await Assert.ThrowsAsync<DeviceEnrollmentRedemptionException>(
            () => first.BeginAsync(BootstrapText(fixture)));

        var replacement = (JsonObject)fixture["bootstrap"]!.DeepClone();
        replacement["bootstrapId"] = "jbt_99999999999999999999999999999999";
        replacement["bundleId"] = "jdb_99999999999999999999999999999999";
        replacement["issuedAt"] = "2026-07-24T09:16:00Z";
        replacement["serverTime"] = "2026-07-24T09:16:00Z";
        replacement["expiresAt"] = "2026-07-24T09:31:00Z";
        replacement["redemptionURL"] =
            "https://native.example.test/jazz/api/device-enrollment/redemptions/jbt_99999999999999999999999999999999";

        DeviceEnrollmentRedemptionCoordinator second = RedemptionHarness.Coordinate(
            pendingStore, backend, identityStore, transport, Instant("2026-07-24T09:16:01Z"));
        await Assert.ThrowsAsync<DeviceEnrollmentRedemptionException>(
            () => second.BeginAsync(EnrollmentContract.CanonicalText(replacement)));

        JsonObject persisted = (JsonObject)JsonNode.Parse(pendingStore.Load()!)!;
        Assert.Equal(
            "jbt_99999999999999999999999999999999",
            ((JsonObject)persisted["bootstrap"]!)["bootstrapId"]!.GetValue<string>());

        second.DiscardPendingEnrollment();
        Assert.False(second.HasPendingEnrollment());
        Assert.Null(pendingStore.Load());
        Assert.Equal(0, backend.GenerateCount);
    }

    [Fact]
    public async Task AStillLivePendingRecordRefusesASecondBootstrap()
    {
        JsonObject fixture = HttpFixture();
        var harness = new RedemptionHarness(Instant("2026-07-24T09:01:00Z"));
        await harness.Coordinator.BeginAsync(BootstrapText(fixture));

        var replacement = (JsonObject)fixture["bootstrap"]!.DeepClone();
        replacement["bootstrapId"] = "jbt_99999999999999999999999999999999";
        replacement["redemptionURL"] =
            "https://native.example.test/jazz/api/device-enrollment/redemptions/jbt_99999999999999999999999999999999";

        DeviceEnrollmentRedemptionException error =
            await Assert.ThrowsAsync<DeviceEnrollmentRedemptionException>(
                () => harness.Coordinator.BeginAsync(EnrollmentContract.CanonicalText(replacement)));

        Assert.Equal(DeviceEnrollmentRedemptionError.PendingConflict, error.Reason);
    }

    [Fact]
    public async Task TheAutomaticPollContractProgressesFrom202To202ToAnExact200()
    {
        GoldenScenario scenario = GoldenScenario.Create();

        Assert.Null(await scenario.Coordinator.BeginAsync(scenario.BootstrapText));
        Assert.Null(await scenario.Coordinator.ResumeAsync());
        RedeemedDeviceEnrollment? redeemed = await scenario.Coordinator.ResumeAsync();

        Assert.NotNull(redeemed);
        Assert.Equal(
            scenario.ExpectedSignedBundle,
            Encoding.UTF8.GetBytes(redeemed.ExactSignedBundle));
        Assert.Equal(2, scenario.Transport.PollCount);
        Assert.True(scenario.Coordinator.HasPendingEnrollment());

        scenario.Coordinator.CompleteActivation(redeemed.BootstrapId);
        Assert.False(scenario.Coordinator.HasPendingEnrollment());
    }

    [Theory]
    [InlineData("application/jazz-device-bundle+json")]
    [InlineData("application/jazz-device-enrollment-sealed+json; charset=utf-8")]
    [InlineData("application/json")]
    public async Task ReadyRefusesALegacyOrParameterizedContentTypeAndRetainsPending(string contentType)
    {
        GoldenScenario scenario = GoldenScenario.Create(contentType: contentType);

        Assert.Null(await scenario.Coordinator.BeginAsync(scenario.BootstrapText));
        Assert.Null(await scenario.Coordinator.ResumeAsync());

        DeviceEnrollmentRedemptionException error =
            await Assert.ThrowsAsync<DeviceEnrollmentRedemptionException>(
                () => scenario.Coordinator.ResumeAsync());

        Assert.Equal(DeviceEnrollmentRedemptionError.MalformedResponse, error.Reason);
        Assert.True(scenario.Coordinator.HasPendingEnrollment());
    }

    [Fact]
    public async Task ReadyRefusesAMismatchedEnvelopeDigestHeader()
    {
        GoldenScenario scenario = GoldenScenario.Create(etag: "\"sha256:" + new string('0', 64) + "\"");

        Assert.Null(await scenario.Coordinator.BeginAsync(scenario.BootstrapText));
        Assert.Null(await scenario.Coordinator.ResumeAsync());

        Assert.Equal(
            DeviceEnrollmentRedemptionError.MalformedResponse,
            (await Assert.ThrowsAsync<DeviceEnrollmentRedemptionException>(
                () => scenario.Coordinator.ResumeAsync())).Reason);
    }

    [Fact]
    public async Task ReadyRefusesASealAddressedToADifferentBundle()
    {
        GoldenScenario scenario = GoldenScenario.Create(bootstrapBundleId: "jdb_018ff3a2679a7bd18a5e6c3d4b2a1909");

        Assert.Null(await scenario.Coordinator.BeginAsync(scenario.BootstrapText));
        Assert.Null(await scenario.Coordinator.ResumeAsync());

        Assert.Equal(
            DeviceEnrollmentRedemptionError.SignedBundleMismatch,
            (await Assert.ThrowsAsync<DeviceEnrollmentRedemptionException>(
                () => scenario.Coordinator.ResumeAsync())).Reason);
    }

    [Theory]
    [InlineData(401, DeviceEnrollmentRedemptionError.Unauthorized)]
    [InlineData(410, DeviceEnrollmentRedemptionError.BootstrapExpired)]
    [InlineData(423, DeviceEnrollmentRedemptionError.Quarantined)]
    [InlineData(500, DeviceEnrollmentRedemptionError.ServerUnavailable)]
    [InlineData(404, DeviceEnrollmentRedemptionError.ServerUnavailable)]
    public async Task ServerStatusCodesMapToOperatorSafeRefusals(int status, DeviceEnrollmentRedemptionError expected)
    {
        JsonObject fixture = HttpFixture();
        var harness = new RedemptionHarness(Instant("2026-07-24T09:01:00Z"));
        harness.Transport.ContextStatusCode = status;

        DeviceEnrollmentRedemptionException error =
            await Assert.ThrowsAsync<DeviceEnrollmentRedemptionException>(
                () => harness.Coordinator.BeginAsync(BootstrapText(fixture)));

        Assert.Equal(expected, error.Reason);
        Assert.Equal(0, harness.Backend.GenerateCount);
    }

    [Fact]
    public async Task AnExpiredBootstrapIsRefusedBeforeAnyRequest()
    {
        JsonObject fixture = HttpFixture();
        var harness = new RedemptionHarness(Instant("2026-07-24T09:30:00Z"));

        DeviceEnrollmentRedemptionException error =
            await Assert.ThrowsAsync<DeviceEnrollmentRedemptionException>(
                () => harness.Coordinator.BeginAsync(BootstrapText(fixture)));

        Assert.Equal(DeviceEnrollmentRedemptionError.BootstrapExpired, error.Reason);
        Assert.Equal(0, harness.Transport.ContextCount);
        Assert.Equal(0, harness.Backend.GenerateCount);
    }

    [Fact]
    public async Task APendingStatusNamingADifferentClaimIsRefused()
    {
        JsonObject fixture = HttpFixture();
        var pendingResponse = (JsonObject)fixture["pendingResponse"]!.DeepClone();
        pendingResponse["claimId"] = "jcl_44444444444444444444444444444444";
        var harness = new RedemptionHarness(
            Instant("2026-07-24T09:01:00Z"),
            pending: EnrollmentContract.Canonical(pendingResponse));

        DeviceEnrollmentRedemptionException error =
            await Assert.ThrowsAsync<DeviceEnrollmentRedemptionException>(
                () => harness.Coordinator.BeginAsync(BootstrapText(fixture)));

        Assert.Equal(DeviceEnrollmentRedemptionError.MalformedResponse, error.Reason);
    }

    [Fact]
    public void ACorruptPendingRecordIsNotTreatedAsAbsence()
    {
        var pendingStore = new MemoryRedemptionPendingStore();
        pendingStore.Replace(Encoding.UTF8.GetBytes("""{"schemaVersion":1}"""));
        DeviceEnrollmentRedemptionCoordinator coordinator = RedemptionHarness.Coordinate(
            pendingStore,
            new FakeHardwareKeyBackend(),
            new MemoryIdentityStore(),
            new RedemptionTransport(Array.Empty<byte>(), Array.Empty<byte>()),
            Instant("2026-07-24T09:01:00Z"));

        Assert.True(coordinator.HasPendingEnrollment());
        Assert.Equal(
            DeviceEnrollmentRedemptionError.PendingStateUnavailable,
            Assert.Throws<DeviceEnrollmentRedemptionException>(() => coordinator.PendingIdentity()).Reason);
    }

    [Fact]
    public async Task CompletingAnActivationForADifferentBootstrapIsRefused()
    {
        JsonObject fixture = HttpFixture();
        var harness = new RedemptionHarness(Instant("2026-07-24T09:01:00Z"));
        await harness.Coordinator.BeginAsync(BootstrapText(fixture));

        Assert.Equal(
            DeviceEnrollmentRedemptionError.PendingConflict,
            Assert.Throws<DeviceEnrollmentRedemptionException>(
                () => harness.Coordinator.CompleteActivation("jbt_99999999999999999999999999999999")).Reason);
        Assert.True(harness.Coordinator.HasPendingEnrollment());
    }

    private static JsonObject HttpFixture() =>
        EnrollmentContract.ReadObject("device-bound", "http-fixtures", "01-native-redemption-http.json");

    private static string BootstrapText(JsonObject fixture) =>
        EnrollmentContract.CanonicalText(fixture["bootstrap"]!.DeepClone());

    private static DateTimeOffset Instant(string value) => SignedEnrollmentRefusalTests.Instant(value);

    /// <summary>A coordinator over in-memory state and the shared HTTP fixture's documents.</summary>
    private sealed class RedemptionHarness
    {
        public RedemptionHarness(DateTimeOffset now, byte[]? context = null, byte[]? pending = null)
        {
            JsonObject fixture = HttpFixture();
            PendingStore = new MemoryRedemptionPendingStore();
            Backend = new FakeHardwareKeyBackend();
            Transport = new RedemptionTransport(
                context ?? EnrollmentContract.Canonical(fixture["context"]!.DeepClone()),
                pending ?? EnrollmentContract.Canonical(fixture["pendingResponse"]!.DeepClone()));
            Coordinator = Coordinate(PendingStore, Backend, new MemoryIdentityStore(), Transport, now);
        }

        public MemoryRedemptionPendingStore PendingStore { get; }

        public FakeHardwareKeyBackend Backend { get; }

        public RedemptionTransport Transport { get; }

        public DeviceEnrollmentRedemptionCoordinator Coordinator { get; }

        public static DeviceEnrollmentRedemptionCoordinator Coordinate(
            MemoryRedemptionPendingStore pendingStore,
            FakeHardwareKeyBackend backend,
            MemoryIdentityStore identityStore,
            RedemptionTransport transport,
            DateTimeOffset now,
            string claimId = "jcl_33333333333333333333333333333333") =>
            new(
                pendingStore,
                transport,
                DeviceEnrollmentIdentityVault.CreateHardwareBacked(identityStore, backend),
                new EnrollmentTrustPolicy(
                    "https://jazz.example.test",
                    "jazz-desktop-client",
                    new Dictionary<string, string>
                    {
                        ["test-2026-07-rfc8032-1"] = "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo",
                    }),
                new EnrollmentRedemptionRoutePolicy(new[] { "https://native.example.test" }),
                () => claimId,
                () => now);
    }

    /// <summary>The 202 -> 202 -> 200 path, wired to the real cross-platform sealed bundle.</summary>
    private sealed class GoldenScenario
    {
        private GoldenScenario(
            DeviceEnrollmentRedemptionCoordinator coordinator,
            RedemptionTransport transport,
            string bootstrapText,
            byte[] expectedSignedBundle)
        {
            Coordinator = coordinator;
            Transport = transport;
            BootstrapText = bootstrapText;
            ExpectedSignedBundle = expectedSignedBundle;
        }

        public DeviceEnrollmentRedemptionCoordinator Coordinator { get; }

        public RedemptionTransport Transport { get; }

        public string BootstrapText { get; }

        public byte[] ExpectedSignedBundle { get; }

        public static GoldenScenario Create(
            string contentType = "application/jazz-device-enrollment-sealed+json",
            string? etag = null,
            string? bootstrapBundleId = null)
        {
            JsonObject http = HttpFixture();
            JsonObject crypto = EnrollmentContract.ReadObject(
                "device-bound", "fixtures", "01-p256-device-bound-redemption.json");

            var bootstrap = (JsonObject)http["bootstrap"]!.DeepClone();
            bootstrap["issuedAt"] = "2026-07-24T09:30:00Z";
            bootstrap["serverTime"] = "2026-07-24T09:30:00Z";
            bootstrap["expiresAt"] = "2026-07-24T09:41:00Z";
            if (bootstrapBundleId is not null)
            {
                bootstrap["bundleId"] = bootstrapBundleId;
            }

            var context = (JsonObject)http["context"]!.DeepClone();
            context["serverTime"] = "2026-07-24T09:30:00Z";
            context["expiresAt"] = "2026-07-24T09:41:00Z";
            if (bootstrapBundleId is not null)
            {
                context["bundleId"] = bootstrapBundleId;
            }

            var pendingResponse = (JsonObject)http["pendingResponse"]!.DeepClone();
            pendingResponse["claimId"] = GoldenClaimId;
            pendingResponse["serverTime"] = "2026-07-24T09:31:00Z";
            pendingResponse["expiresAt"] = "2026-07-24T09:41:00Z";
            if (bootstrapBundleId is not null)
            {
                pendingResponse["bundleId"] = bootstrapBundleId;
            }

            byte[] sealedBytes = EnrollmentContract.Canonical(crypto["sealedBundle"]!.DeepClone());
            var expected = (JsonObject)crypto["expected"]!;
            var ready = new DeviceRedemptionHttpResponse(
                200,
                sealedBytes,
                new Dictionary<string, string>
                {
                    ["Content-Type"] = contentType,
                    ["ETag"] = etag ?? "\"sha256:" + expected["sealedBundleSha256"]!.GetValue<string>() + "\"",
                    ["X-Jazz-Bundle-SHA256"] = expected["bundleSha256"]!.GetValue<string>(),
                    ["X-Jazz-Bootstrap-Expires-At"] = "2026-07-24T09:41:00Z",
                });

            var transport = new RedemptionTransport(
                EnrollmentContract.Canonical(context),
                EnrollmentContract.Canonical(pendingResponse))
            {
                Ready = ready,
                ReadyAfterPollCount = 2,
            };

            DeviceEnrollmentRedemptionCoordinator coordinator = new(
                new MemoryRedemptionPendingStore(),
                transport,
                DeviceEnrollmentIdentityVault.CreateHardwareBacked(
                    new MemoryIdentityStore(),
                    new FakeHardwareKeyBackend(useGoldenKeys: true)),
                new EnrollmentTrustPolicy(
                    "https://jazz.example.test",
                    "jazz-desktop-client",
                    new Dictionary<string, string>
                    {
                        ["test-2026-07-rfc8032-1"] = "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo",
                    }),
                new EnrollmentRedemptionRoutePolicy(new[] { "https://native.example.test" }),
                () => GoldenClaimId,
                () => Instant("2026-07-24T09:31:00Z"));

            return new GoldenScenario(
                coordinator,
                transport,
                EnrollmentContract.CanonicalText(bootstrap),
                EnrollmentEncoding.DecodeBase64Url(
                    crypto["signedDeviceBundle"]!.GetValue<string>(),
                    maximumBytes: 131_072)!);
        }
    }

    /// <summary>A scripted stand-in for the HTTPS boundary.</summary>
    private sealed class RedemptionTransport : IDeviceRedemptionTransport
    {
        private readonly byte[] context;
        private readonly byte[] pending;
        private readonly object mutex = new();
        private bool didFailSubmit;

        public RedemptionTransport(byte[] context, byte[] pending)
        {
            this.context = context;
            this.pending = pending;
        }

        public bool FailFirstSubmit { get; init; }

        public bool AlwaysFail { get; init; }

        public DeviceRedemptionHttpResponse? Ready { get; init; }

        public int ReadyAfterPollCount { get; init; } = int.MaxValue;

        public int ContextStatusCode { get; set; } = 200;

        public int ContextCount { get; private set; }

        public int PollCount { get; private set; }

        public List<byte[]> SubmittedClaims { get; } = new();

        public Task<DeviceRedemptionHttpResponse> FetchContextAsync(string endpoint, string bearer)
        {
            lock (mutex)
            {
                ContextCount++;
            }

            if (AlwaysFail)
            {
                throw new InvalidOperationException("simulated network failure");
            }

            return Task.FromResult(new DeviceRedemptionHttpResponse(ContextStatusCode, context));
        }

        public Task<DeviceRedemptionHttpResponse> SubmitClaimAsync(string endpoint, string bearer, byte[] exactClaim)
        {
            bool shouldFail;
            lock (mutex)
            {
                SubmittedClaims.Add(exactClaim);
                shouldFail = FailFirstSubmit && !didFailSubmit;
                didFailSubmit = true;
            }

            if (shouldFail)
            {
                throw new InvalidOperationException("simulated lost response");
            }

            return Task.FromResult(new DeviceRedemptionHttpResponse(202, pending));
        }

        public Task<DeviceRedemptionHttpResponse> PollAsync(string endpoint, string bearer)
        {
            int current;
            lock (mutex)
            {
                PollCount++;
                current = PollCount;
            }

            return Task.FromResult(
                current >= ReadyAfterPollCount && Ready is not null
                    ? Ready
                    : new DeviceRedemptionHttpResponse(202, pending));
        }
    }
}
