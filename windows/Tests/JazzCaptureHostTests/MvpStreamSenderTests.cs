using System.Net;
using System.Net.Http;
using System.Text;
using JazzCapture;
using JazzCaptureCore;
using JazzCaptureCore.Enrollment;

namespace JazzCaptureHostTests;

/// <summary>
/// <see cref="MvpStreamSender"/> is the classified <c>/v1/logs</c> transport <see cref="EventDeliveryWorker"/>
/// drains through. Issue #48 replaces the old two-valued <c>StreamDeliveryStatus</c> with
/// <see cref="EventSendOutcome"/> and deletes the non-durable <c>MvpStreamDispatcher</c> outright
/// (§2.6 R2 of the plan): <c>DispatcherReportsBoundedBackpressure</c>,
/// <c>DispatcherSerializesAndSurvivesStatusFailure</c> and
/// <c>DispatcherDoesNotRegressSynchronousStreamingStatus</c> are deleted from this file because they
/// pinned the very defect (dropping events under backpressure, and at process exit) issue #48 exists
/// to remove -- they are not moved, ported, or replaced one-for-one; the durable spool and
/// <see cref="EventDeliveryWorker"/> tests cover the behaviour that replaces them.
/// </summary>
public sealed class MvpStreamSenderTests
{
    [Fact]
    public async Task PostsCanonicalLogsWithoutAuthorizationHeader()
    {
        var handler = new RecordingHandler(HttpStatusCode.OK);
        using RedirectSafeHttpClient client = RedirectSafeHttpClient.CreateForTests(handler);

        EventSendOutcome result = await new MvpStreamSender("https://stream.example.invalid/capability", client)
            .SendBodyAsync(Body(), Settings(), CancellationToken.None);

        Assert.Equal(EventSendOutcome.Acknowledged, result);
        Assert.Equal("https://stream.example.invalid/capability/v1/logs", handler.Uri);
        Assert.Null(handler.Authorization);
        Assert.False(handler.HasStorageToken);
        Assert.Contains("resourceLogs", handler.Body);
    }

    /// <summary>
    /// Mirrors <c>KeboolaFilesClient</c>'s shipped classification rule and the #48 plan's §2.5
    /// table -- amended by a PR review finding for 401/403, see <see cref="EventSendOutcome.Unauthorized"/>'s
    /// own remarks: 2xx acknowledges; 400/422 are terminal (the body is the problem, identical bytes
    /// will never be accepted); 401/403 are not the body's fault either, but are no longer an
    /// ordinary retry -- issue #48's own acceptance criterion requires revocation to stop networking,
    /// not retry it every few minutes for up to 48 hours, so these classify as
    /// <see cref="EventSendOutcome.Unauthorized"/> instead; everything else -- a redirect (impossible
    /// to actually follow, since <see cref="RedirectSafeHttpClient"/> structurally cannot, but still
    /// classified as retryable rather than a body problem), 408/429/5xx -- is an ordinary retry.
    /// </summary>
    [Theory]
    [InlineData(HttpStatusCode.OK, EventSendOutcome.Acknowledged)]
    [InlineData(HttpStatusCode.NoContent, EventSendOutcome.Acknowledged)]
    [InlineData(HttpStatusCode.BadRequest, EventSendOutcome.Dropped)]
    [InlineData(HttpStatusCode.UnprocessableEntity, EventSendOutcome.Dropped)]
    [InlineData(HttpStatusCode.Found, EventSendOutcome.Retry)]
    [InlineData(HttpStatusCode.Unauthorized, EventSendOutcome.Unauthorized)]
    [InlineData(HttpStatusCode.Forbidden, EventSendOutcome.Unauthorized)]
    [InlineData(HttpStatusCode.RequestTimeout, EventSendOutcome.Retry)]
    [InlineData(HttpStatusCode.TooManyRequests, EventSendOutcome.Retry)]
    [InlineData(HttpStatusCode.InternalServerError, EventSendOutcome.Retry)]
    [InlineData(HttpStatusCode.ServiceUnavailable, EventSendOutcome.Retry)]
    public async Task ClassifiesEachResponseCode(HttpStatusCode code, EventSendOutcome expected)
    {
        var handler = new RecordingHandler(code);
        using RedirectSafeHttpClient client = RedirectSafeHttpClient.CreateForTests(handler);

        EventSendOutcome result = await new MvpStreamSender("https://stream.example.invalid/secret", client)
            .SendBodyAsync(Body(), Settings(), CancellationToken.None);

        Assert.Equal(expected, result);
        Assert.Null(handler.Authorization);
        Assert.False(handler.HasStorageToken);
    }

    [Fact]
    public async Task FailureIsEndpointSafe()
    {
        using RedirectSafeHttpClient client = RedirectSafeHttpClient.CreateForTests(new ThrowingHandler());

        EventSendOutcome result = await new MvpStreamSender("https://stream.example.invalid/secret", client)
            .SendBodyAsync(Body(), Settings(), CancellationToken.None);

        Assert.Equal(EventSendOutcome.Retry, result);
        Assert.DoesNotContain("secret", result.ToString(), StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// The call budget is the only deadline in force (<see cref="RedirectSafeHttpClient"/> disables
    /// <see cref="HttpClient"/>'s own hidden 100-second default), so a transport that never responds
    /// must still return within a bounded wait, classified as retryable rather than hanging or
    /// throwing.
    /// </summary>
    [Fact]
    public async Task ASendThatOutlivesItsCallBudgetIsAbandonedAsRetry()
    {
        using RedirectSafeHttpClient client = RedirectSafeHttpClient.CreateForTests(new NeverRespondingHandler());
        EventDeliverySettings settings = Settings() with { SendCallBudget = TimeSpan.FromMilliseconds(50) };

        EventSendOutcome result = await new MvpStreamSender("https://stream.example.invalid/capability", client)
            .SendBodyAsync(Body(), settings, CancellationToken.None)
            .WaitAsync(TimeSpan.FromSeconds(2));

        Assert.Equal(EventSendOutcome.Retry, result);
    }

    /// <summary>
    /// <see cref="RedirectSafeHttpClient"/> is the type-level proof <see cref="MvpStreamSender"/>
    /// relies on for "never follows a redirect" -- pinning that a redirect-following handler cannot
    /// even be used to construct one, regardless of which sender it would back.
    /// </summary>
    [Fact]
    public void TheSenderCannotBeBuiltOverARedirectFollowingClient()
    {
        Assert.Throws<ArgumentException>(
            () => RedirectSafeHttpClient.CreateForTests(new HttpClientHandler { AllowAutoRedirect = true }));
    }

    /// <summary>
    /// Adapted from the pre-#48 dispatcher-era test of the same name: the credential gate must never
    /// invoke the sender at all for an expired protected value. <see cref="MvpDeliveryPolicy"/>'s
    /// return type changed from the deleted <c>StreamDeliveryStatus.NotProvisioned</c> to
    /// <see cref="EventSendOutcome.Retry"/> (issue #48 §3.5: an unprovisioned target leaves the entry
    /// spooled rather than being classified as anything else), which this test could not stay
    /// byte-for-byte "unmodified" for -- the deleted enum simply no longer exists in the assembly
    /// (see <c>EventDeliveryPresentationTests.TheBackpressureVocabularyIsGone</c>) -- but the
    /// guarantee it pins is unchanged: zero sends for an expired credential.
    /// </summary>
    [Fact]
    public async Task ExpiredProtectedCredentialNeverCallsSender()
    {
        DeviceBundle expired = DeviceBundleParser.ParseMvp("""
        {"kind":"jazz-device-bundle","enrollmentProfile":"mvp","deviceId":"d","companyId":"c","areaId":"a","projectId":"1","stackURL":"https://connection.keboola.com","archiveIngestURL":"https://example.invalid/api/archive-ingests","streamSourceId":"s","streamEndpoint":"https://stream.example.invalid/secret","token":"1-abcdefghijklmnop","tokenId":"t","expiresAt":"2000-01-01T00:00:00Z","componentAccess":[],"tokenBucketScope":"none"}
        """, DateTimeOffset.UtcNow, requireUnexpired: false);
        int sends = 0;

        EventSendOutcome result = await MvpDeliveryPolicy.DeliverIfActiveAsync(
            expired, DateTimeOffset.UtcNow, _ => { sends++; return Task.FromResult(EventSendOutcome.Acknowledged); });

        Assert.Equal(EventSendOutcome.Retry, result);
        Assert.Equal(0, sends);
    }

    private static EventDeliverySettings Settings() => new();

    private static SessionContext Context() => new("s-1", new string('a', 32), new string('b', 16), "2026-01-01T00:00:00.000Z", null, "u", "h", null, null);

    private static ActivityEvent Event(string id = "evt-1") => new() { EventId = id, SessionId = "s-1", Timestamp = "2026-01-01T00:00:00.000Z", EventType = "click" };

    private static byte[] Body() =>
        Encoding.UTF8.GetBytes(OtlpMapper.LogsRequest(new[] { Event() }, Context()).ToJsonString());

    private sealed class RecordingHandler(HttpStatusCode code) : HttpMessageHandler
    {
        public string? Uri { get; private set; }
        public string? Authorization { get; private set; }
        public bool HasStorageToken { get; private set; }
        public string Body { get; private set; } = "";

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Uri = request.RequestUri!.AbsoluteUri;
            Authorization = request.Headers.Authorization?.ToString();
            HasStorageToken = request.Headers.Contains("X-StorageApi-Token");
            Body = await request.Content!.ReadAsStringAsync(cancellationToken);
            return new HttpResponseMessage(code);
        }
    }

    private sealed class ThrowingHandler : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            throw new HttpRequestException("https://stream.example.invalid/secret");
    }

    private sealed class NeverRespondingHandler : HttpMessageHandler
    {
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken).ConfigureAwait(false);
            throw new InvalidOperationException("unreachable");
        }
    }
}
