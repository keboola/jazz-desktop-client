using System.IO;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using JazzCapture;
using JazzCaptureCore.Consent;

namespace JazzCaptureHostTests;

public sealed class SignedConsentTransportTests : IDisposable
{
    private const string Server = "https://jazz.example.test";
    private const string Code = "enroll-code-0123456789";
    private const string Sid = "S-1-5-21-1-2-3-1001";
    private const string PolicyWithToken =
        "{\"kind\":\"jazz-windows-client-policy\",\"schema\":1,\"status\":\"active\",\"filesToken\":{\"tokenId\":\"tok-1\",\"token\":\"secret\",\"expiresAt\":\"2026-11-23T11:00:00Z\"}}";

    private readonly string _directory = Path.Combine(Path.GetTempPath(), "jazz-signed-" + Guid.NewGuid().ToString("N"));
    private DateTimeOffset _now = new(2026, 11, 23, 10, 0, 0, TimeSpan.Zero);
    private SignedEnrollmentSettings? _settings = new(Server, Code);
    private readonly ConsentIdentity _identity = ConsentIdentity.ForWindows(@"ACME\JNovak", Sid);

    public void Dispose()
    {
        try { Directory.Delete(_directory, true); }
        catch (IOException) { }
    }

    private DeviceKeyStore Keys(string? bundleDeviceId = "pilot-dev-1") => new(_directory, () => bundleDeviceId, tryHardware: false);

    private SignedConsentTransport Create(ScriptedHandler handler, DeviceKeyStore? keys = null) =>
        new(() => _settings, keys ?? Keys(), new HttpClient(handler), "0.27.0", () => _now, () => (@"ACME\JNovak", Sid), () => "PC-01");

    private static bool SignatureVerifies(Seen request, byte[] publicKey)
    {
        var signed = new Dictionary<string, string>
        {
            ["clientVersion"] = request.Header("X-Jazz-Client-Version")!,
            ["deviceId"] = request.Header("X-Jazz-Device-Id")!,
            ["filesTokenId"] = request.Header("X-Jazz-Files-Token-Id") ?? string.Empty,
            ["hostname"] = request.Header("X-Jazz-Hostname")!,
            ["method"] = request.Method.Method,
            ["nonce"] = request.Header("X-Jazz-Device-Nonce")!,
            ["osUser"] = request.Header("X-Jazz-Os-User")!,
            ["path"] = new Uri(request.Uri).AbsolutePath,
            ["timestamp"] = request.Header("X-Jazz-Device-Timestamp")!,
        };
        if (request.Body is not null)
            foreach (JsonProperty property in JsonDocument.Parse(request.Body).RootElement.EnumerateObject())
                signed[property.Name] = property.Value.GetString()!;
        return Verify(DeviceRequestSigning.RequestDomain, DeviceRequestSigning.CanonicalJson(signed), request.Header("X-Jazz-Device-Signature")!, publicKey);
    }

    private static bool Verify(byte[] domain, byte[] payload, string signature, byte[] publicKey)
    {
        using ECDsa key = ECDsa.Create(new ECParameters
        {
            Curve = ECCurve.NamedCurves.nistP256,
            Q = new ECPoint { X = publicKey[1..33], Y = publicKey[33..65] },
        });
        return key.VerifyData(
            domain.Concat(payload).ToArray(),
            Decode(signature),
            HashAlgorithmName.SHA256,
            DSASignatureFormat.IeeeP1363FixedFieldConcatenation);
    }

    private static byte[] Decode(string value)
    {
        string padded = value.Replace('-', '+').Replace('_', '/');
        return Convert.FromBase64String(padded.PadRight(padded.Length + ((4 - (padded.Length % 4)) % 4), '='));
    }

    [Fact]
    public async Task EnrollsOnceWithTheCodeAndTheDeviceKeyThenSignsEveryPolicyRequest()
    {
        var handler = new ScriptedHandler(request => request.Uri.EndsWith("/device/enroll", StringComparison.Ordinal)
            ? Reply(HttpStatusCode.OK, "{\"kind\":\"jazz-device-enrollment-bundle\"}")
            : Reply(HttpStatusCode.OK, PolicyWithToken, "\"4-abc\""));
        SignedConsentTransport transport = Create(handler);

        PolicyFetchResult first = await transport.FetchPolicyAsync(_identity, null, CancellationToken.None);
        PolicyFetchResult second = await transport.FetchPolicyAsync(_identity, "\"4-abc\"", CancellationToken.None);

        Assert.Equal(PolicyFetchOutcome.Fetched, first.Outcome);
        Assert.Equal("\"4-abc\"", first.ETag);
        Assert.Equal(PolicyFetchOutcome.Fetched, second.Outcome);
        Assert.Equal(new[] { "/device/enroll", "/device/policy", "/device/policy" }, handler.Requests.Select(r => new Uri(r.Uri).AbsolutePath).ToArray());

        Seen enroll = handler.Requests[0];
        Assert.Equal(Code, enroll.Header("X-Jazz-Enrollment-Code"));
        Assert.Equal("0.27.0", enroll.Header("X-Jazz-Client-Version"));
        using JsonDocument body = JsonDocument.Parse(enroll.Body!);
        JsonElement root = body.RootElement;
        Assert.Equal("pilot-dev-1", root.GetProperty("deviceId").GetString());
        Assert.Equal("software", root.GetProperty("keyProtection").GetString());
        Assert.Equal(@"acme\jnovak", root.GetProperty("osUser").GetString());
        Assert.DoesNotContain(Code, enroll.Body!, StringComparison.Ordinal);
        byte[] publicKey = Decode(root.GetProperty("proofPublicKey").GetString()!);
        Assert.Equal(65, publicKey.Length);
        Assert.NotEqual(root.GetProperty("proofPublicKey").GetString(), root.GetProperty("wrappingPublicKey").GetString());
        var enrolled = new Dictionary<string, string>();
        foreach (JsonProperty property in root.EnumerateObject())
            if (property.Name != "proof") enrolled[property.Name] = property.Value.GetString()!;
        Assert.True(Verify(DeviceRequestSigning.EnrollDomain, DeviceRequestSigning.CanonicalJson(enrolled), root.GetProperty("proof").GetString()!, publicKey));

        Assert.True(SignatureVerifies(handler.Requests[1], publicKey));
        Assert.True(SignatureVerifies(handler.Requests[2], publicKey));
        Assert.Null(handler.Requests[1].Header("If-None-Match"));
        Assert.Equal("\"4-abc\"", handler.Requests[2].Header("If-None-Match"));
        Assert.Equal(@"acme\jnovak", handler.Requests[1].Header("X-Jazz-Os-User"));
        Assert.Equal("PC-01", handler.Requests[1].Header("X-Jazz-Hostname"));
        Assert.NotEqual(handler.Requests[1].Header("X-Jazz-Device-Nonce"), handler.Requests[2].Header("X-Jazz-Device-Nonce"));
    }

    [Fact]
    public async Task OnlyTheIdAndTheEndOfTheFilesTokenAreKeptAndTheIdIsSentNextTime()
    {
        var handler = new ScriptedHandler(request => request.Uri.EndsWith("/device/enroll", StringComparison.Ordinal)
            ? Reply(HttpStatusCode.OK, "{}")
            : Reply(HttpStatusCode.OK, PolicyWithToken));
        SignedConsentTransport transport = Create(handler);

        await transport.FetchPolicyAsync(_identity, null, CancellationToken.None);
        await transport.FetchPolicyAsync(_identity, null, CancellationToken.None);

        Assert.Equal("tok-1", handler.Requests[2].Header("X-Jazz-Files-Token-Id"));
        foreach (string file in Directory.EnumerateFiles(_directory))
            Assert.DoesNotContain("secret", Encoding.UTF8.GetString(File.ReadAllBytes(file)), StringComparison.Ordinal);
    }

    [Fact]
    public async Task TheFilesTokenIsRenewedWithASignedRequestShortlyBeforeItEnds()
    {
        var handler = new ScriptedHandler(request => new Uri(request.Uri).AbsolutePath switch
        {
            "/device/enroll" => Reply(HttpStatusCode.OK, "{}"),
            "/device/token/renew" => Reply(HttpStatusCode.OK, "{\"tokenId\":\"tok-2\",\"token\":\"x\",\"expiresAt\":\"2026-11-23T12:00:00Z\",\"kid\":\"k1\"}"),
            _ => Reply(HttpStatusCode.OK, PolicyWithToken),
        });
        SignedConsentTransport transport = Create(handler);
        await transport.FetchPolicyAsync(_identity, null, CancellationToken.None);
        _now = new DateTimeOffset(2026, 11, 23, 10, 55, 0, TimeSpan.Zero);

        await transport.FetchPolicyAsync(_identity, null, CancellationToken.None);

        string[] paths = handler.Requests.Select(r => new Uri(r.Uri).AbsolutePath).ToArray();
        Assert.Equal(new[] { "/device/enroll", "/device/policy", "/device/token/renew", "/device/policy" }, paths);
        Assert.Equal(HttpMethod.Post, handler.Requests[2].Method);
        Assert.Equal("tok-1", handler.Requests[2].Header("X-Jazz-Files-Token-Id"));
        Assert.Equal("tok-2", handler.Requests[3].Header("X-Jazz-Files-Token-Id"));
    }

    [Fact]
    public async Task WithoutTheEnrollmentCodeAnUnenrolledDeviceSendsNothing()
    {
        _settings = new SignedEnrollmentSettings(Server, null);
        var handler = new ScriptedHandler(_ => Reply(HttpStatusCode.OK, "{}"));
        SignedConsentTransport transport = Create(handler);

        Assert.Equal(PolicyFetchOutcome.Unavailable, (await transport.FetchPolicyAsync(_identity, null, CancellationToken.None)).Outcome);
        Assert.Equal(PostOutcome.Unavailable, (await transport.PostDecisionAsync(_identity, new DecisionPost(ConsentDecision.Declined, null, null, null), CancellationToken.None)).Outcome);

        Assert.Empty(handler.Requests);
    }

    [Fact]
    public async Task NoServerUrlSendsNothingAndAnEntraIdentityIsNotServedBySignedRoute()
    {
        var handler = new ScriptedHandler(_ => Reply(HttpStatusCode.OK, "{}"));
        _settings = null;
        Assert.Equal(PolicyFetchOutcome.Unavailable, (await Create(handler).FetchPolicyAsync(_identity, null, CancellationToken.None)).Outcome);
        _settings = new SignedEnrollmentSettings(Server, Code);
        ConsentIdentity entra = ConsentIdentity.ForEntra("11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222", "x");
        Assert.Equal(PolicyFetchOutcome.Unavailable, (await Create(handler).FetchPolicyAsync(entra, null, CancellationToken.None)).Outcome);

        Assert.Empty(handler.Requests);
    }

    [Fact]
    public async Task ARefusedEnrollmentLeavesTheDeviceUnenrolledAndRetriesOnlyAfterFiveMinutes()
    {
        var handler = new ScriptedHandler(_ => Reply(HttpStatusCode.Forbidden, "{}"));
        SignedConsentTransport transport = Create(handler);

        Assert.Equal(PolicyFetchOutcome.Unavailable, (await transport.FetchPolicyAsync(_identity, null, CancellationToken.None)).Outcome);
        Assert.Equal(PolicyFetchOutcome.Unavailable, (await transport.FetchPolicyAsync(_identity, null, CancellationToken.None)).Outcome);
        Assert.Single(handler.Requests);
        Assert.False(Keys().LoadOrCreate().Enrolled);

        _now += TimeSpan.FromMinutes(6);
        await transport.FetchPolicyAsync(_identity, null, CancellationToken.None);

        Assert.Equal(2, handler.Requests.Count);
    }

    [Theory]
    [InlineData(HttpStatusCode.NotModified, PolicyFetchOutcome.NotModified)]
    [InlineData(HttpStatusCode.UpgradeRequired, PolicyFetchOutcome.TooOld)]
    [InlineData(HttpStatusCode.Unauthorized, PolicyFetchOutcome.Unavailable)]
    [InlineData(HttpStatusCode.ServiceUnavailable, PolicyFetchOutcome.Unavailable)]
    public async Task MapsPolicyStatusCodes(HttpStatusCode status, PolicyFetchOutcome expected)
    {
        var handler = new ScriptedHandler(request => request.Uri.EndsWith("/device/enroll", StringComparison.Ordinal)
            ? Reply(HttpStatusCode.OK, "{}")
            : Reply(status, "{}"));

        Assert.Equal(expected, (await Create(handler).FetchPolicyAsync(_identity, "\"1\"", CancellationToken.None)).Outcome);
    }

    [Fact]
    public async Task ASignedDecisionCarriesTheSidTheTextVersionTheHashAndTheModeInTheBodyAndTheSignature()
    {
        var handler = new ScriptedHandler(request => request.Uri.EndsWith("/device/enroll", StringComparison.Ordinal)
            ? Reply(HttpStatusCode.OK, "{}")
            : Reply(HttpStatusCode.OK, "{}"));
        SignedConsentTransport transport = Create(handler);

        PostResult result = await transport.PostDecisionAsync(
            _identity, new DecisionPost(ConsentDecision.Agreed, "0.3", new string('a', 64), "continuous"), CancellationToken.None);

        Assert.Equal(PostOutcome.Accepted, result.Outcome);
        Seen post = handler.Requests[1];
        Assert.Equal(HttpMethod.Post, post.Method);
        Assert.Equal(Server + "/device/consent", post.Uri);
        using JsonDocument body = JsonDocument.Parse(post.Body!);
        Assert.Equal(
            new[] { "captureMode", "consentKey", "decision", "textHash", "textVersion", "windowsSid" },
            body.RootElement.EnumerateObject().Select(property => property.Name).OrderBy(name => name, StringComparer.Ordinal).ToArray());
        Assert.Equal(Sid, body.RootElement.GetProperty("windowsSid").GetString());
        Assert.Equal(@"acme\jnovak", body.RootElement.GetProperty("consentKey").GetString());
        using JsonDocument enroll = JsonDocument.Parse(handler.Requests[0].Body!);
        Assert.True(SignatureVerifies(post, Decode(enroll.RootElement.GetProperty("proofPublicKey").GetString()!)));
    }

    [Theory]
    [InlineData(HttpStatusCode.Forbidden, PostOutcome.Refused)]
    [InlineData(HttpStatusCode.UpgradeRequired, PostOutcome.TooOld)]
    [InlineData(HttpStatusCode.Unauthorized, PostOutcome.Unavailable)]
    public async Task MapsConsentStatusCodes(HttpStatusCode status, PostOutcome expected)
    {
        var handler = new ScriptedHandler(request => request.Uri.EndsWith("/device/enroll", StringComparison.Ordinal)
            ? Reply(HttpStatusCode.OK, "{}")
            : Reply(status, "{}"));

        PostResult result = await Create(handler).PostDecisionAsync(
            _identity, new DecisionPost(ConsentDecision.Agreed, "0.3", null, null), CancellationToken.None);

        Assert.Equal(expected, result.Outcome);
    }

    [Fact]
    public async Task TheWindowsIdentityIsTheQualifiedNameAndTheSid()
    {
        ConsentIdentity? identity = await Create(new ScriptedHandler(_ => Reply(HttpStatusCode.OK, "{}"))).ResolveIdentityAsync(CancellationToken.None);

        Assert.Equal(ConsentIdentity.ForWindows(@"acme\jnovak", Sid), identity);
    }

    [Fact]
    public void TheKeysAndTheDeviceIdSurviveARestart()
    {
        DeviceKeyStore first = Keys();
        DeviceKeyRecord created = first.LoadOrCreate();
        DeviceKeyStore second = Keys("another-id");
        DeviceKeyRecord again = second.LoadOrCreate();

        Assert.Equal("pilot-dev-1", created.DeviceId);
        Assert.Equal(created, again);
        Assert.Equal("software", created.KeyProtection);
        IDeviceSigner a = first.OpenProofKey(created);
        Assert.Equal(a.PublicKeyX963, second.OpenProofKey(again).PublicKeyX963);
        Assert.Equal(65, first.WrappingPublicKey(created).Length);
        Assert.NotEqual(a.PublicKeyX963, first.WrappingPublicKey(created));
        Assert.DoesNotContain(
            created.ProofKeyPkcs8!,
            Encoding.UTF8.GetString(File.ReadAllBytes(Path.Combine(_directory, "device-key-v1.bin"))),
            StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("Not-Valid")]
    [InlineData(null)]
    public void ADeviceIdTheServerWouldRefuseIsReplacedByARandomOne(string? bundleId)
    {
        DeviceKeyRecord record = Keys(bundleId).LoadOrCreate();

        Assert.Matches("^jazz-[0-9a-f]{32}$", record.DeviceId);
    }

    [Fact]
    public void ReadsTheEnrollmentUrlAndCodeFromTheManagedValuesFirst()
    {
        var store = new SignedEnrollmentPolicyStore((hive, _, name) => (hive, name) switch
        {
            (CaptureAtLaunchPolicyStore.ManagedHive, "EnrollmentServerUrl") => "https://managed.example/",
            (CaptureAtLaunchPolicyStore.ManagedHive, "EnrollmentCode") => " managed-code ",
            (_, "EnrollmentServerUrl") => "https://installer.example",
            _ => "installer-code",
        });

        Assert.Equal(new SignedEnrollmentSettings("https://managed.example", "managed-code"), store.Read());
    }

    [Fact]
    public void ACodeIsOptionalAndAnInvalidUrlMeansNoSettings()
    {
        Assert.Equal(
            new SignedEnrollmentSettings("https://jazz.example.test", null),
            new SignedEnrollmentPolicyStore((_, _, name) => name == "EnrollmentServerUrl" ? "https://jazz.example.test" : null).Read());
        Assert.Null(new SignedEnrollmentPolicyStore((_, _, name) => name == "EnrollmentServerUrl" ? "http://insecure.example" : "code").Read());
    }

    [Fact]
    public async Task TheRouterUsesEntraWhenConfiguredAndTheSignedRouteOtherwiseWithNoFallback()
    {
        var entra = new RecordingTransport(ConsentIdentity.ForEntra("11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222", "x"));
        var signed = new RecordingTransport(_identity);
        bool entraConfigured = true;
        var router = new ConsentTransportRouter(() => entraConfigured, entra, signed);

        Assert.Equal(ConsentRoute.Entra, (await router.ResolveIdentityAsync(CancellationToken.None))!.Route);
        entra.Identity = null;
        Assert.Null(await router.ResolveIdentityAsync(CancellationToken.None));
        Assert.Equal(0, signed.Calls);

        entraConfigured = false;
        Assert.Equal(ConsentRoute.Signed, (await router.ResolveIdentityAsync(CancellationToken.None))!.Route);
        await router.FetchPolicyAsync(_identity, null, CancellationToken.None);
        Assert.Equal(2, signed.Calls);
    }

    private static HttpResponseMessage Reply(HttpStatusCode status, string body, string? etag = null)
    {
        var response = new HttpResponseMessage(status) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
        if (etag is not null) response.Headers.TryAddWithoutValidation("ETag", etag);
        return response;
    }

    private sealed record Seen(HttpMethod Method, string Uri, Dictionary<string, string> Headers, string? Body)
    {
        internal string? Header(string name) => Headers.TryGetValue(name, out string? value) ? value : null;
    }

    private sealed class ScriptedHandler(Func<Seen, HttpResponseMessage> respond) : HttpMessageHandler
    {
        internal List<Seen> Requests { get; } = [];

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var seen = new Seen(
                request.Method,
                request.RequestUri!.ToString(),
                request.Headers.ToDictionary(header => header.Key, header => string.Join(",", header.Value), StringComparer.OrdinalIgnoreCase),
                request.Content is null ? null : await request.Content.ReadAsStringAsync(cancellationToken));
            Requests.Add(seen);
            return respond(seen);
        }
    }

    private sealed class RecordingTransport(ConsentIdentity? identity) : IConsentTransport
    {
        internal ConsentIdentity? Identity { get; set; } = identity;

        internal int Calls { get; private set; }

        public Task<ConsentIdentity?> ResolveIdentityAsync(CancellationToken cancellationToken)
        {
            Calls++;
            return Task.FromResult(Identity);
        }

        public Task<PolicyFetchResult> FetchPolicyAsync(ConsentIdentity identity, string? ifNoneMatch, CancellationToken cancellationToken)
        {
            Calls++;
            return Task.FromResult(new PolicyFetchResult(PolicyFetchOutcome.Unavailable));
        }

        public Task<PostResult> PostDecisionAsync(ConsentIdentity identity, DecisionPost post, CancellationToken cancellationToken)
        {
            Calls++;
            return Task.FromResult(new PostResult(PostOutcome.Unavailable));
        }
    }
}
