using System.Net;
using JazzCapture;
using JazzCaptureCore;

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
    public async Task DispatcherSerializesAndSurvivesStatusFailure()
    {
        var order = new List<string>();
        var first = new TaskCompletionSource(); var release = new TaskCompletionSource();
        await using var dispatcher = new MvpStreamDispatcher(async (e, _, _) => { if (e.EventId == "1") { first.SetResult(); await release.Task; } order.Add(e.EventId); return StreamDeliveryStatus.Streaming; }, _ => throw new InvalidOperationException());
        dispatcher.Enqueue(Event("1"), Context()); dispatcher.Enqueue(Event("2"), Context());
        await first.Task; release.SetResult();
        for (var i = 0; i < 20 && order.Count != 2; i++) await Task.Yield();
        Assert.Equal(new[] { "1", "2" }, order);
    }

    [Fact]
    public async Task DispatcherReportsBoundedBackpressure()
    {
        var entered = new TaskCompletionSource(); var release = new TaskCompletionSource(); var states = new List<StreamDeliveryStatus>();
        await using var dispatcher = new MvpStreamDispatcher(async (_, _, _) => { entered.SetResult(); await release.Task; return StreamDeliveryStatus.Streaming; }, states.Add);
        dispatcher.Enqueue(Event("first"), Context()); await entered.Task;
        for (int i = 0; i < 65; i++) dispatcher.Enqueue(Event(i.ToString()), Context());
        Assert.Contains(StreamDeliveryStatus.Backpressure, states); release.SetResult();
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
        public string? Uri { get; private set; } public string? Authorization { get; private set; } public bool HasStorageToken { get; private set; } public string Body { get; private set; } = "";
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        { Uri = request.RequestUri!.AbsoluteUri; Authorization = request.Headers.Authorization?.ToString(); HasStorageToken = request.Headers.Contains("X-StorageApi-Token"); Body = await request.Content!.ReadAsStringAsync(cancellationToken); return new HttpResponseMessage(code); }
    }
    private sealed class ThrowingHandler : HttpMessageHandler { protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => throw new HttpRequestException("https://stream.example.invalid/secret"); }
}
