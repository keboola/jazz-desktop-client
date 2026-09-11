using System.Net;
using System.Text;
using JazzCapture;
using JazzCaptureCore;
using JazzCaptureCore.Enrollment;

namespace JazzCaptureHostTests;

public sealed class MvpStreamSenderTests
{
    [Fact]
    public async Task PostsCanonicalLogsWithoutAuthorizationHeader()
    {
        var handler = new RecordingHandler(HttpStatusCode.OK);
        using var client = new HttpClient(handler);
        StreamDeliveryStatus result = await new MvpStreamSender("https://stream.example.invalid/capability", client)
            .SendAsync(new ActivityEvent { EventId = "evt-1", SessionId = "s-1", Timestamp = "2026-01-01T00:00:00.000Z", EventType = "click" }, Context(), CancellationToken.None);
        Assert.Equal(StreamDeliveryStatus.Streaming, result);
        Assert.Equal("https://stream.example.invalid/capability/v1/logs", handler.Uri);
        Assert.Null(handler.Authorization);
        Assert.False(handler.HasStorageToken);
        Assert.Contains("resourceLogs", handler.Body);
    }

    [Theory]
    [InlineData(HttpStatusCode.Found)]
    [InlineData(HttpStatusCode.InternalServerError)]
    public async Task RedirectAndNonSuccessAreSafe(HttpStatusCode code)
    {
        var handler = new RecordingHandler(code); using var client = new HttpClient(handler);
        StreamDeliveryStatus result = await new MvpStreamSender("https://stream.example.invalid/secret", client).SendAsync(Event(), Context(), CancellationToken.None);
        Assert.Equal(StreamDeliveryStatus.Unreachable, result); Assert.Null(handler.Authorization); Assert.False(handler.HasStorageToken);
    }

    [Fact]
    public async Task SendExactPostsDurableBytesUnchangedWithLegacyContentType()
    {
        byte[] body = Encoding.UTF8.GetBytes("{\"resourceLogs\":[{\"exact\":true}]}");
        var handler = new RecordingHandler(HttpStatusCode.NoContent);
        using var client = new HttpClient(handler);

        StreamDeliveryStatus result = await new MvpStreamSender(
            "https://stream.example.invalid/capability", client)
            .SendExactAsync(body, CancellationToken.None);

        Assert.Equal(StreamDeliveryStatus.Streaming, result);
        Assert.Equal("https://stream.example.invalid/capability/v1/logs", handler.Uri);
        Assert.Equal("application/json", handler.ContentType);
        Assert.Equal(body, handler.Bytes);
        Assert.Null(handler.Authorization);
        Assert.False(handler.HasStorageToken);
    }

    [Fact]
    public async Task SendExactReturnsUnreachableForNonSuccess()
    {
        var handler = new RecordingHandler(HttpStatusCode.InternalServerError);
        using var client = new HttpClient(handler);

        StreamDeliveryStatus result = await new MvpStreamSender(
            "https://stream.example.invalid/capability", client)
            .SendExactAsync([1, 2, 3], CancellationToken.None);

        Assert.Equal(StreamDeliveryStatus.Unreachable, result);
        Assert.Equal(new byte[] { 1, 2, 3 }, handler.Bytes);
    }

    [Fact]
    public async Task SendExactPropagatesCallerCancellation()
    {
        var handler = new RecordingHandler(HttpStatusCode.OK);
        using var client = new HttpClient(handler);
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            new MvpStreamSender("https://stream.example.invalid/capability", client)
                .SendExactAsync([1], cancellation.Token));
    }

    [Fact]
    public async Task DispatcherSerializesAndSurvivesStatusFailure()
    {
        var order = new List<string>();
        var first = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); var second = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        await using var dispatcher = new MvpStreamDispatcher(async (e, _, _) => { if (e.EventId == "1") { first.SetResult(); await release.Task; } order.Add(e.EventId); if (e.EventId == "2") second.SetResult(); return StreamDeliveryStatus.Streaming; }, _ => throw new InvalidOperationException());
        dispatcher.Enqueue(Event("1"), Context()); dispatcher.Enqueue(Event("2"), Context());
        await first.Task; release.SetResult(); await second.Task;
        Assert.Equal(new[] { "1", "2" }, order);
    }

    [Fact]
    public async Task DispatcherReportsBoundedBackpressure()
    {
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); var states = new List<StreamDeliveryStatus>();
        await using var dispatcher = new MvpStreamDispatcher(async (_, _, _) => { entered.SetResult(); await release.Task; return StreamDeliveryStatus.Streaming; }, states.Add);
        dispatcher.Enqueue(Event("first"), Context()); await entered.Task;
        for (int i = 0; i < 65; i++) dispatcher.Enqueue(Event(i.ToString()), Context());
        Assert.Contains(StreamDeliveryStatus.Backpressure, states); release.SetResult();
    }

    [Fact]
    public async Task DispatcherDoesNotRegressSynchronousStreamingStatus()
    {
        var states = new List<StreamDeliveryStatus>(); var streamed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); var deliveredTwice = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); int deliveries = 0;
        await using var dispatcher = new MvpStreamDispatcher((_, _, _) => { if (Interlocked.Increment(ref deliveries) == 2) deliveredTwice.SetResult(); return Task.FromResult(StreamDeliveryStatus.Streaming); }, state => { states.Add(state); if (state == StreamDeliveryStatus.Streaming) streamed.SetResult(); });
        dispatcher.Enqueue(Event(), Context()); dispatcher.Enqueue(Event("next"), Context());
        await streamed.Task; await deliveredTwice.Task;
        Assert.Equal(StreamDeliveryStatus.Streaming, states.Last());
        Assert.DoesNotContain(StreamDeliveryStatus.Waiting, states);
        Assert.Equal(1, states.Count(state => state == StreamDeliveryStatus.Streaming));
    }

    [Fact]
    public async Task ExpiredProtectedCredentialNeverCallsSender()
    {
        DeviceBundle expired = DeviceBundleParser.ParseMvp("""
        {"kind":"jazz-device-bundle","enrollmentProfile":"mvp","deviceId":"d","companyId":"c","areaId":"a","projectId":"1","stackURL":"https://connection.keboola.com","archiveIngestURL":"https://example.invalid/api/archive-ingests","streamSourceId":"s","streamEndpoint":"https://stream.example.invalid/secret","token":"1-abcdefghijklmnop","tokenId":"t","expiresAt":"2000-01-01T00:00:00Z","componentAccess":[],"tokenBucketScope":"none"}
        """, DateTimeOffset.UtcNow, requireUnexpired: false);
        int sends = 0;
        StreamDeliveryStatus result = await MvpDeliveryPolicy.DeliverIfActiveAsync(expired, DateTimeOffset.UtcNow, _ => { sends++; return Task.FromResult(StreamDeliveryStatus.Streaming); });
        Assert.Equal(StreamDeliveryStatus.NotProvisioned, result); Assert.Equal(0, sends);
    }

    [Fact]
    public async Task FailureIsEndpointSafe()
    {
        using var client = new HttpClient(new ThrowingHandler());
        StreamDeliveryStatus result = await new MvpStreamSender("https://stream.example.invalid/secret", client)
            .SendAsync(new ActivityEvent { EventId = "evt-1", SessionId = "s-1", Timestamp = "2026-01-01T00:00:00.000Z", EventType = "click" }, Context(), CancellationToken.None);
        Assert.Equal(StreamDeliveryStatus.Unreachable, result);
        Assert.DoesNotContain("secret", result.ToString(), StringComparison.OrdinalIgnoreCase);
    }

    private static SessionContext Context() => new("s-1", new string('a', 32), new string('b', 16), "2026-01-01T00:00:00.000Z", null, "u", "h", null, null);
    private static ActivityEvent Event(string id = "evt-1") => new() { EventId = id, SessionId = "s-1", Timestamp = "2026-01-01T00:00:00.000Z", EventType = "click" };
    private sealed class RecordingHandler(HttpStatusCode code) : HttpMessageHandler
    {
        public string? Uri { get; private set; } public string? Authorization { get; private set; } public bool HasStorageToken { get; private set; } public string? ContentType { get; private set; } public string Body { get; private set; } = ""; public byte[] Bytes { get; private set; } = [];
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        { Uri = request.RequestUri!.AbsoluteUri; Authorization = request.Headers.Authorization?.ToString(); HasStorageToken = request.Headers.Contains("X-StorageApi-Token"); ContentType = request.Content?.Headers.ContentType?.MediaType; Bytes = await request.Content!.ReadAsByteArrayAsync(cancellationToken); Body = Encoding.UTF8.GetString(Bytes); return new HttpResponseMessage(code); }
    }
    private sealed class ThrowingHandler : HttpMessageHandler { protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => throw new HttpRequestException("https://stream.example.invalid/secret"); }
}
