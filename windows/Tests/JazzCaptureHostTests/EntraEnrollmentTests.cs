using System.Net;
using System.Net.Http;
using System.Text;
using JazzCapture;
using JazzCaptureCore.Enrollment;

namespace JazzCaptureHostTests;

public sealed class EntraEnrollmentTests
{
    private const string Server = "https://jazz.example.test";
    private const string ClientId = "0c89b602-6c0c-40f4-bea8-977e470211ca";
    private const string ApiId = "7b1c8f2e-3a4d-4e5f-9a6b-0c1d2e3f4a5b";
    private const string BundleSecret = "8625-TEST-ONLY-SCOPED-DEVICE-TOKEN";

    private static readonly EntraEnrollmentSettings Settings = new(Server, ClientId, ApiId);

    [Fact]
    public void AbsentSettingsReadAsUnconfigured()
    {
        EntraEnrollmentRead read = new EntraEnrollmentPolicyStore((_, _, _) => null, ("", "", "")).Read();
        Assert.Null(read.Settings);
        Assert.Null(read.Detail);
    }

    [Fact]
    public void BuiltInPairIsUsedWhenTheRegistryIsEmpty()
    {
        var store = new EntraEnrollmentPolicyStore((_, _, _) => null, ("https://jazz.example.test/", ClientId, ApiId));
        EntraEnrollmentSettings settings = Assert.IsType<EntraEnrollmentSettings>(store.Read().Settings);
        Assert.Equal("https://jazz.example.test", settings.ServerUrl);
        Assert.Equal(ClientId, settings.ClientId);
        Assert.Equal(ApiId + "/Jazz.Device.Enroll", settings.Scope);
    }

    [Fact]
    public void RegistryPairReplacesTheBuiltInPair()
    {
        var store = new EntraEnrollmentPolicyStore(
            (hive, _, name) => hive != CaptureAtLaunchPolicyStore.InstallerHive ? null
                : name == EntraEnrollmentPolicyStore.ServerUrlValueName ? "https://staging.example.test" : "11111111-2222-3333-4444-555555555555",
            ("https://jazz.example.test", ClientId, ApiId));
        EntraEnrollmentSettings settings = Assert.IsType<EntraEnrollmentSettings>(store.Read().Settings);
        Assert.Equal("https://staging.example.test", settings.ServerUrl);
        Assert.Equal("11111111-2222-3333-4444-555555555555", settings.ClientId);
    }

    [Fact]
    public void IncompleteBuiltInPairIsReportedNotUsed()
    {
        EntraEnrollmentRead read = new EntraEnrollmentPolicyStore((_, _, _) => null, ("https://jazz.example.test", ClientId, "")).Read();
        Assert.Null(read.Settings);
        Assert.StartsWith("built-in", read.Detail, StringComparison.Ordinal);
    }

    [Fact]
    public void ThisBuildHasNoBuiltInPairYet()
    {
        Assert.Equal(string.Empty, BuildIdentity.DefaultEnrollmentServerUrl);
        Assert.Equal(string.Empty, BuildIdentity.DefaultEntraClientId);
        Assert.Equal(string.Empty, BuildIdentity.DefaultEntraApiId);
    }

    [Fact]
    public void ManagedPairWinsOverInstallerPair()
    {
        var store = new EntraEnrollmentPolicyStore((hive, _, name) => (hive, name) switch
        {
            (CaptureAtLaunchPolicyStore.ManagedHive, EntraEnrollmentPolicyStore.ServerUrlValueName) => "https://managed.example/",
            (CaptureAtLaunchPolicyStore.ManagedHive, EntraEnrollmentPolicyStore.ClientIdValueName) => ClientId.ToUpperInvariant(),
            (CaptureAtLaunchPolicyStore.ManagedHive, EntraEnrollmentPolicyStore.ApiIdValueName) => ApiId,
            (_, EntraEnrollmentPolicyStore.ServerUrlValueName) => "https://installer.example",
            _ => "11111111-2222-3333-4444-555555555555",
        });

        EntraEnrollmentSettings settings = Assert.IsType<EntraEnrollmentSettings>(store.Read().Settings);
        Assert.Equal("https://managed.example", settings.ServerUrl);
        Assert.Equal(ClientId, settings.ClientId);
        Assert.Equal(ApiId, settings.ApiId);
        Assert.Equal(ApiId + "/Jazz.Device.Enroll", settings.Scope);
        Assert.Equal(new Uri("https://managed.example/device/entra/bundle/start"), settings.StartUri);
    }

    [Theory]
    [InlineData("http://jazz.example.test", ClientId)]
    [InlineData("https://jazz.example.test/?x=1", ClientId)]
    [InlineData(Server, "not-a-guid")]
    [InlineData(Server, null)]
    [InlineData(null, ClientId)]
    public void IncompleteOrInvalidPairIsRefused(string? url, string? clientId)
    {
        var store = new EntraEnrollmentPolicyStore((hive, _, name) =>
            hive != CaptureAtLaunchPolicyStore.InstallerHive ? null
            : name == EntraEnrollmentPolicyStore.ServerUrlValueName ? url : clientId);

        EntraEnrollmentRead read = store.Read();
        Assert.Null(read.Settings);
        Assert.Contains(EntraEnrollmentPolicyStore.ClientIdValueName, read.Detail);
    }

    [Fact]
    public async Task FetchStartsTheJobPollsAndReturnsTheBundleOnce()
    {
        var handler = new ScriptedHandler(
            Json(HttpStatusCode.OK, """{"jobId":"job-1","deviceId":"entra-abc"}"""),
            Json(HttpStatusCode.OK, """{"status":"running","detail":null}"""),
            Json(HttpStatusCode.OK, "{\"status\":\"done\",\"detail\":null,\"bundle\":{\"kind\":\"jazz-device-bundle\",\"token\":\"" + BundleSecret + "\"}}"));
        var client = new EntraBundleClient(new HttpClient(handler), new FixedTokens("entra-access-token"), NoDelay);

        EntraBundleResult result = await client.FetchAsync(Settings, "PC-01", CancellationToken.None);

        Assert.Equal(EntraBundleOutcome.Received, result.Outcome);
        Assert.Contains(BundleSecret, result.BundleJson);
        Assert.DoesNotContain(BundleSecret, result.ToString(), StringComparison.Ordinal);
        Assert.Equal(3, handler.Requests.Count);
        Assert.All(handler.Requests, r => Assert.Equal("entra-access-token", r.EntraToken));
        Assert.Equal(HttpMethod.Post, handler.Requests[0].Method);
        Assert.Equal(Server + "/device/entra/bundle/start", handler.Requests[0].Uri);
        Assert.Equal("""{"hostName":"PC-01"}""", handler.Requests[0].Body);
        Assert.Equal(Server + "/device/entra/bundle/status/job-1", handler.Requests[2].Uri);
    }

    [Fact]
    public async Task NoSilentTokenMeansSignInRequiredAndNoRequest()
    {
        var handler = new ScriptedHandler();
        var client = new EntraBundleClient(new HttpClient(handler), new FixedTokens(null), NoDelay);

        EntraBundleResult result = await client.FetchAsync(Settings, "PC-01", CancellationToken.None);

        Assert.Equal(EntraBundleOutcome.SignInRequired, result.Outcome);
        Assert.Empty(handler.Requests);
    }

    [Fact]
    public async Task MsalFailureShowsItsErrorCode()
    {
        var client = new EntraBundleClient(new HttpClient(new ScriptedHandler()), new ThrowingTokens(), NoDelay);

        EntraBundleResult result = await client.FetchAsync(Settings, "PC-01", CancellationToken.None);

        Assert.Equal(EntraBundleOutcome.Unavailable, result.Outcome);
        Assert.Contains("(invalid_request)", result.Reason, StringComparison.Ordinal);
    }

    [Fact]
    public async Task InteractiveSignInUsesTheDialogTokenNotTheSilentOne()
    {
        var handler = new ScriptedHandler(
            Json(HttpStatusCode.OK, """{"jobId":"job-1"}"""),
            Json(HttpStatusCode.OK, "{\"status\":\"done\",\"bundle\":{\"kind\":\"jazz-device-bundle\"}}"));
        var client = new EntraBundleClient(new HttpClient(handler), new FixedTokens(null, "dialog-token"), NoDelay);

        EntraBundleResult result = await client.FetchAsync(Settings, "PC-01", CancellationToken.None, new IntPtr(1));

        Assert.Equal(EntraBundleOutcome.Received, result.Outcome);
        Assert.All(handler.Requests, r => Assert.Equal("dialog-token", r.EntraToken));
    }

    [Fact]
    public async Task TenantRefusalIsReportedAsRefused()
    {
        var handler = new ScriptedHandler(Json(HttpStatusCode.Forbidden,
            """{"detail":{"code":"ENTRA_TENANT_NOT_ALLOWED","message":"no"}}"""));
        var client = new EntraBundleClient(new HttpClient(handler), new FixedTokens("t"), NoDelay);

        EntraBundleResult result = await client.FetchAsync(Settings, "PC-01", CancellationToken.None);

        Assert.Equal(EntraBundleOutcome.Refused, result.Outcome);
        Assert.Equal("Your organization is not enabled for Jazz.", result.Reason);
    }

    [Fact]
    public async Task ServerErrorAndJobErrorAreUnavailable()
    {
        var down = new EntraBundleClient(new HttpClient(new ScriptedHandler(Json(HttpStatusCode.ServiceUnavailable, "{}"))), new FixedTokens("t"), NoDelay);
        Assert.Equal(EntraBundleOutcome.Unavailable, (await down.FetchAsync(Settings, "PC-01", CancellationToken.None)).Outcome);

        var failed = new EntraBundleClient(new HttpClient(new ScriptedHandler(
            Json(HttpStatusCode.OK, """{"jobId":"job-1"}"""),
            Json(HttpStatusCode.OK, """{"status":"error","detail":"mint failed"}"""))), new FixedTokens("t"), NoDelay);
        Assert.Equal(EntraBundleOutcome.Unavailable, (await failed.FetchAsync(Settings, "PC-01", CancellationToken.None)).Outcome);
    }

    [Theory]
    [InlineData("""{"detail":{"code":"ENTRA_SCOPE_MISSING","message":"no"}}""", "(ENTRA_SCOPE_MISSING)")]
    [InlineData("""{"detail":{"code":"Click https://evil.test now","message":"no"}}""", "(401)")]
    [InlineData("not json", "(401)")]
    public async Task RefusalShowsOnlyAPlainServerCode(string body, string expected)
    {
        var client = new EntraBundleClient(new HttpClient(new ScriptedHandler(Json(HttpStatusCode.Unauthorized, body))), new FixedTokens("t"), NoDelay);

        EntraBundleResult result = await client.FetchAsync(Settings, "PC-01", CancellationToken.None);

        Assert.Equal(EntraBundleOutcome.Refused, result.Outcome);
        Assert.EndsWith(expected + ".", result.Reason, StringComparison.Ordinal);
    }

    [Fact]
    public async Task RevokedDeviceIsReportedAsRefused()
    {
        var handler = new ScriptedHandler(Json(HttpStatusCode.Conflict, """{"detail":{"code":"DEVICE_REVOKED","message":"no"}}"""));
        var client = new EntraBundleClient(new HttpClient(handler), new FixedTokens("t"), NoDelay);

        EntraBundleResult result = await client.FetchAsync(Settings, "PC-01", CancellationToken.None);

        Assert.Equal(EntraBundleOutcome.Refused, result.Outcome);
        Assert.Equal("An administrator revoked this device.", result.Reason);
    }

    [Fact]
    public async Task SlowJobStopsAtTheOverallDeadline()
    {
        var handler = new ScriptedHandler(
            Json(HttpStatusCode.OK, """{"jobId":"job-1"}"""),
            Json(HttpStatusCode.OK, """{"status":"running"}"""));
        var client = new EntraBundleClient(new HttpClient(handler), new FixedTokens("t"),
            (delay, ct) => Task.Delay(Timeout.InfiniteTimeSpan, ct), TimeSpan.FromMilliseconds(100));

        EntraBundleResult result = await client.FetchAsync(Settings, "PC-01", CancellationToken.None);

        Assert.Equal(EntraBundleOutcome.Unavailable, result.Outcome);
        Assert.Contains("in time", result.Reason, StringComparison.Ordinal);
    }

    [Fact]
    public async Task CallerCancellationIsNotReportedAsAResult()
    {
        var client = new EntraBundleClient(new HttpClient(new ScriptedHandler(
            Json(HttpStatusCode.OK, """{"jobId":"job-1"}"""),
            Json(HttpStatusCode.OK, """{"status":"running"}"""))), new FixedTokens("t"),
            (delay, ct) => Task.Delay(Timeout.InfiniteTimeSpan, ct));
        using var cancel = new CancellationTokenSource(TimeSpan.FromMilliseconds(100));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => client.FetchAsync(Settings, "PC-01", cancel.Token));
    }

    [Fact]
    public void ScheduleAsksForABundleWhenNoneIsActiveOrItEndsSoon()
    {
        DateTimeOffset now = new(2026, 11, 9, 12, 0, 0, TimeSpan.Zero);
        Assert.True(EntraBundleSchedule.NeedsBundle(null, now));
        Assert.True(EntraBundleSchedule.NeedsBundle(BundleExpiring(now.AddMinutes(10)), now));
        Assert.False(EntraBundleSchedule.NeedsBundle(BundleExpiring(now.AddHours(1)), now));
        Assert.Equal(TimeSpan.FromMinutes(15), EntraBundleSchedule.RetryAfter(EntraBundleOutcome.SignInRequired, 0));
        Assert.Equal(TimeSpan.FromSeconds(15), EntraBundleSchedule.RetryAfter(EntraBundleOutcome.Unavailable, 0));
        Assert.Equal(TimeSpan.FromSeconds(300), EntraBundleSchedule.RetryAfter(EntraBundleOutcome.Unavailable, 9));
    }

    private static DeviceBundle BundleExpiring(DateTimeOffset expiry) => new(
        DeviceBundle.ExpectedKind, "entra-abc", "https://connection.keboola.com", "8625", "byok", "general",
        "https://jazz.example.test/api/archive-ingests", null, null, BundleSecret, "1",
        expiry.ToString("yyyy-MM-ddTHH:mm:ssZ", System.Globalization.CultureInfo.InvariantCulture),
        JazzArchiveTokenBucketScope.None, null, [], "mvp");

    private static Task NoDelay(TimeSpan delay, CancellationToken cancellationToken) => Task.CompletedTask;

    private static HttpResponseMessage Json(HttpStatusCode status, string body)
        => new(status) { Content = new StringContent(body, Encoding.UTF8, "application/json") };

    private sealed class ThrowingTokens : IEntraTokenSource
    {
        public Task<string?> AcquireSilentAsync(EntraEnrollmentSettings settings, CancellationToken cancellationToken)
            => throw new Microsoft.Identity.Client.MsalServiceException("invalid_request", "AADSTS90009 test");

        public Task<string?> AcquireInteractiveAsync(EntraEnrollmentSettings settings, IntPtr parentWindow, CancellationToken cancellationToken)
            => throw new Microsoft.Identity.Client.MsalServiceException("invalid_request", "AADSTS90009 test");
    }

    private sealed class FixedTokens(string? token, string? interactiveToken = null) : IEntraTokenSource
    {
        public Task<string?> AcquireSilentAsync(EntraEnrollmentSettings settings, CancellationToken cancellationToken)
            => Task.FromResult(token);

        public Task<string?> AcquireInteractiveAsync(EntraEnrollmentSettings settings, IntPtr parentWindow, CancellationToken cancellationToken)
            => Task.FromResult(interactiveToken);
    }

    private sealed record SeenRequest(HttpMethod Method, string Uri, string? EntraToken, string? Body);

    private sealed class ScriptedHandler(params HttpResponseMessage[] responses) : HttpMessageHandler
    {
        private readonly Queue<HttpResponseMessage> _responses = new(responses);

        public List<SeenRequest> Requests { get; } = [];

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            string? body = request.Content is null ? null : await request.Content.ReadAsStringAsync(cancellationToken);
            Requests.Add(new(request.Method, request.RequestUri!.ToString(), request.Headers.TryGetValues(EntraBundleClient.EntraTokenHeader, out IEnumerable<string>? values) ? values.Single() : null, body));
            return _responses.Count > 0 ? _responses.Dequeue() : new HttpResponseMessage(HttpStatusCode.InternalServerError);
        }
    }
}
