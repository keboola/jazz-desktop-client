using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using JazzCapture;
using JazzCaptureCore.Consent;

namespace JazzCaptureHostTests;

public sealed class EntraConsentTransportTests
{
    private const string Server = "https://jazz.example.test";
    private const string Tenant = "11111111-1111-1111-1111-111111111111";
    private const string Person = "22222222-2222-2222-2222-222222222222";
    private const string TextHash = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";

    private static readonly EntraEnrollmentSettings Settings = new(
        Server, "0c89b602-6c0c-40f4-bea8-977e470211ca", "7b1c8f2e-3a4d-4e5f-9a6b-0c1d2e3f4a5b");

    private static readonly ConsentIdentity EntraIdentity = ConsentIdentity.ForEntra(Tenant, Person, @"AzureAD\JNovak");

    private static EntraConsentTransport Create(
        HttpMessageHandler handler,
        string? token = "token-value",
        string? deviceId = "dev-1",
        EntraEnrollmentSettings? settings = null,
        (string, string?)? windowsUser = null) =>
        new(
            () => new EntraEnrollmentRead(settings ?? Settings, null),
            new FixedTokens(token),
            new HttpClient(handler),
            () => deviceId,
            "0.27.0",
            () => windowsUser ?? (@"AzureAD\JNovak", "S-1-5-21-1-2-3-1001"));

    [Fact]
    public async Task FetchesThePolicyWithTheEntraTokenDeviceIdVersionAndOsUser()
    {
        var handler = new Handler(HttpStatusCode.OK, "{\"kind\":\"jazz-windows-client-policy\"}");

        PolicyFetchResult result = await Create(handler).FetchPolicyAsync(EntraIdentity, null, CancellationToken.None);

        Assert.Equal(PolicyFetchOutcome.Fetched, result.Outcome);
        Assert.Equal("{\"kind\":\"jazz-windows-client-policy\"}", result.Json);
        Seen request = Assert.Single(handler.Requests);
        Assert.Equal(HttpMethod.Get, request.Method);
        Assert.Equal(Server + "/device/policy", request.Uri);
        Assert.Equal("token-value", request.Header("X-Jazz-Entra-Token"));
        Assert.Equal("dev-1", request.Header("X-Jazz-Device-Id"));
        Assert.Equal("0.27.0", request.Header("X-Jazz-Client-Version"));
        Assert.Equal(@"azuread\jnovak", request.Header("X-Jazz-Os-User"));
        Assert.Null(request.Header("X-Jazz-Device-Signature"));
    }

    [Theory]
    [InlineData(HttpStatusCode.UpgradeRequired, PolicyFetchOutcome.TooOld)]
    [InlineData(HttpStatusCode.Forbidden, PolicyFetchOutcome.Unavailable)]
    [InlineData(HttpStatusCode.ServiceUnavailable, PolicyFetchOutcome.Unavailable)]
        public async Task MapsPolicyStatusCodes(HttpStatusCode status, PolicyFetchOutcome expected)
    {
        PolicyFetchResult result = await Create(new Handler(status, "{}")).FetchPolicyAsync(EntraIdentity, null, CancellationToken.None);

        Assert.Equal(expected, result.Outcome);
    }

    [Fact]
    public async Task ANotModifiedAnswerKeepsThePolicyAndTheEtagIsSentAndRead()
    {
        var handler = new Handler(HttpStatusCode.NotModified, string.Empty);

        PolicyFetchResult result = await Create(handler).FetchPolicyAsync(EntraIdentity, "\"4-abc\"", CancellationToken.None);

        Assert.Equal(PolicyFetchOutcome.NotModified, result.Outcome);
        Assert.Equal("\"4-abc\"", Assert.Single(handler.Requests).Header("If-None-Match"));
    }

    [Fact]
    public async Task NoTokenNoDeviceOrTheSignedRouteSendsNothing()
    {
        var handler = new Handler(HttpStatusCode.OK, "{}");
        ConsentIdentity signed = ConsentIdentity.ForWindows(@"acme\jnovak", "S-1-5-21-1-2-3-1001");

        Assert.Equal(PolicyFetchOutcome.Unavailable, (await Create(handler, token: null).FetchPolicyAsync(EntraIdentity, null, CancellationToken.None)).Outcome);
        Assert.Equal(PolicyFetchOutcome.Unavailable, (await Create(handler, deviceId: null).FetchPolicyAsync(EntraIdentity, null, CancellationToken.None)).Outcome);
        Assert.Equal(PolicyFetchOutcome.Unavailable, (await Create(handler).FetchPolicyAsync(signed, null, CancellationToken.None)).Outcome);
        Assert.Equal(PostOutcome.Unavailable, (await Create(handler).PostDecisionAsync(signed, new DecisionPost(ConsentDecision.Declined, null, null, null), CancellationToken.None)).Outcome);

        Assert.Empty(handler.Requests);
    }

    [Fact]
    public async Task APolicyThatIsTooLargeIsNotUsed()
    {
        string huge = "{\"x\":\"" + new string('a', DevicePolicy.MaximumDocumentBytes) + "\"}";

        PolicyFetchResult result = await Create(new Handler(HttpStatusCode.OK, huge)).FetchPolicyAsync(EntraIdentity, null, CancellationToken.None);

        Assert.Equal(PolicyFetchOutcome.Unavailable, result.Outcome);
    }

    [Fact]
    public async Task PostsTheDecisionWithTextVersionHashAndModeAndNoSidOnTheEntraRoute()
    {
        var handler = new Handler(HttpStatusCode.OK, "{}");

        PostResult result = await Create(handler).PostDecisionAsync(
            EntraIdentity,
            new DecisionPost(ConsentDecision.Agreed, "0.3", TextHash, "continuous"),
            CancellationToken.None);

        Assert.Equal(PostOutcome.Accepted, result.Outcome);
        Seen request = Assert.Single(handler.Requests);
        Assert.Equal(HttpMethod.Post, request.Method);
        Assert.Equal(Server + "/device/consent", request.Uri);
        using JsonDocument body = JsonDocument.Parse(request.Body!);
        Assert.Equal(
            new[] { "captureMode", "consentKey", "decision", "textHash", "textVersion" },
            body.RootElement.EnumerateObject().Select(property => property.Name).OrderBy(name => name, StringComparer.Ordinal).ToArray());
        Assert.Equal(Tenant + "/" + Person, body.RootElement.GetProperty("consentKey").GetString());
        Assert.Equal("agreed", body.RootElement.GetProperty("decision").GetString());
        Assert.Equal("0.3", body.RootElement.GetProperty("textVersion").GetString());
        Assert.Equal(TextHash, body.RootElement.GetProperty("textHash").GetString());
        Assert.Equal("continuous", body.RootElement.GetProperty("captureMode").GetString());
    }

    [Fact]
    public void TheSignedRouteBodyCarriesTheWindowsSidAndTheLowerCaseName()
    {
        ConsentIdentity signed = ConsentIdentity.ForWindows(@"ACME\JNovak", "S-1-5-21-1-2-3-1001");

        using JsonDocument body = JsonDocument.Parse(
            EntraConsentTransport.Body(signed, new DecisionPost(ConsentDecision.Withdrawn, null, null, "session")));

        Assert.Equal("S-1-5-21-1-2-3-1001", body.RootElement.GetProperty("windowsSid").GetString());
        Assert.Equal(@"acme\jnovak", body.RootElement.GetProperty("consentKey").GetString());
        Assert.Equal("withdrawn", body.RootElement.GetProperty("decision").GetString());
        Assert.False(body.RootElement.TryGetProperty("textVersion", out _));
    }

    [Theory]
    [InlineData(HttpStatusCode.OK, PostOutcome.Accepted)]
    [InlineData(HttpStatusCode.Forbidden, PostOutcome.Refused)]
    [InlineData(HttpStatusCode.UpgradeRequired, PostOutcome.TooOld)]
    [InlineData(HttpStatusCode.UnprocessableEntity, PostOutcome.Unavailable)]
    [InlineData(HttpStatusCode.BadGateway, PostOutcome.Unavailable)]
    public async Task MapsConsentStatusCodes(HttpStatusCode status, PostOutcome expected)
    {
        PostResult result = await Create(new Handler(status, "{}")).PostDecisionAsync(
            EntraIdentity, new DecisionPost(ConsentDecision.Declined, null, null, null), CancellationToken.None);

        Assert.Equal(expected, result.Outcome);
    }

    [Fact]
    public async Task ANetworkErrorIsUnavailable()
    {
        PolicyFetchResult result = await Create(new ThrowingHandler()).FetchPolicyAsync(EntraIdentity, null, CancellationToken.None);

        Assert.Equal(PolicyFetchOutcome.Unavailable, result.Outcome);
    }

    [Fact]
    public async Task ANonAsciiUserNameIsNotSentAsAHeader()
    {
        var handler = new Handler(HttpStatusCode.OK, "{}");
        ConsentIdentity identity = ConsentIdentity.ForEntra(Tenant, Person, "ACME\\Novák");

        await Create(handler).FetchPolicyAsync(identity, null, CancellationToken.None);

        Assert.Null(Assert.Single(handler.Requests).Header("X-Jazz-Os-User"));
    }

    [Fact]
    public async Task TheEntraPersonIsTheTenantAndObjectOfTheToken()
    {
        string payload = Convert.ToBase64String(Encoding.UTF8.GetBytes($"{{\"tid\":\"{Tenant}\",\"oid\":\"{Person}\"}}"))
            .TrimEnd('=').Replace('+', '-').Replace('/', '_');

        ConsentIdentity? identity = await Create(new Handler(HttpStatusCode.OK, "{}"), token: "e30." + payload + ".sig")
            .ResolveIdentityAsync(CancellationToken.None);

        Assert.Equal(ConsentIdentity.ForEntra(Tenant, Person, @"AzureAD\JNovak"), identity);
    }

    [Fact]
    public async Task WithEntraConfiguredAMissingTokenNamesNoPersonAndNeverFallsBackToTheWindowsKey()
    {
        ConsentIdentity? identity = await Create(new Handler(HttpStatusCode.OK, "{}"), token: null)
            .ResolveIdentityAsync(CancellationToken.None);

        Assert.Null(identity);
    }

    [Fact]
    public async Task WithoutEntraTheEntraTransportNamesNoPerson()
    {
        var transport = new EntraConsentTransport(
            () => new EntraEnrollmentRead(null, null),
            new FixedTokens(null),
            new HttpClient(new Handler(HttpStatusCode.OK, "{}")),
            () => null,
            "0.27.0",
            () => (@"ACME\JNovak", "S-1-5-21-1-2-3-1001"));

        Assert.Null(await transport.ResolveIdentityAsync(CancellationToken.None));
    }

    private sealed record Seen(HttpMethod Method, string Uri, Dictionary<string, string> Headers, string? Body)
    {
        internal string? Header(string name) => Headers.TryGetValue(name, out string? value) ? value : null;
    }

    private sealed class Handler(HttpStatusCode status, string body) : HttpMessageHandler
    {
        internal List<Seen> Requests { get; } = [];

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Requests.Add(new Seen(
                request.Method,
                request.RequestUri!.ToString(),
                request.Headers.ToDictionary(header => header.Key, header => string.Join(",", header.Value), StringComparer.OrdinalIgnoreCase),
                request.Content is null ? null : await request.Content.ReadAsStringAsync(cancellationToken)));
            return new HttpResponseMessage(status) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
        }
    }

    private sealed class ThrowingHandler : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            throw new HttpRequestException("offline");
    }

    private sealed class FixedTokens(string? token) : IEntraTokenSource
    {
        public Task<string?> AcquireSilentAsync(EntraEnrollmentSettings settings, CancellationToken cancellationToken) =>
            Task.FromResult(token);

        public Task<string?> AcquireInteractiveAsync(EntraEnrollmentSettings settings, IntPtr parentWindow, CancellationToken cancellationToken) =>
            Task.FromResult(token);
    }
}
