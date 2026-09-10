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
        Assert.Contains("resourceLogs", handler.Body);
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
    private sealed class RecordingHandler(HttpStatusCode code) : HttpMessageHandler
    {
        public string? Uri { get; private set; } public string? Authorization { get; private set; } public string Body { get; private set; } = "";
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        { Uri = request.RequestUri!.AbsoluteUri; Authorization = request.Headers.Authorization?.ToString(); Body = await request.Content!.ReadAsStringAsync(cancellationToken); return new HttpResponseMessage(code); }
    }
    private sealed class ThrowingHandler : HttpMessageHandler { protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => throw new HttpRequestException("https://stream.example.invalid/secret"); }
}
