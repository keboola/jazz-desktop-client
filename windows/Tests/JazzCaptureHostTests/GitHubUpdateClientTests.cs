using System.Net;
using System.Net.Http;
using JazzCapture;
using JazzCaptureCore;

namespace JazzCaptureHostTests;

public sealed class GitHubUpdateClientTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "jazz-update-" + Guid.NewGuid().ToString("N"));

    [Fact]
    public async Task PersistsThrottleBeforeRequestAndReportsOnlyNewerTrustedRelease()
    {
        var state = new FirstRunStateStore(_root);
        DateTimeOffset now = new(2026, 9, 10, 8, 0, 0, TimeSpan.Zero);
        int calls = 0;
        using var http = new HttpClient(new DelegateHandler(_ =>
        {
            calls++;
            Assert.Equal(now, state.ReadUpdateAttempt());
            return Json("[{\"tag_name\":\"v0.26.5\",\"html_url\":\"https://github.com/keboola/jazz-desktop-client/releases/tag/v0.26.5\",\"draft\":false,\"prerelease\":false}]");
        }));
        using var client = new GitHubUpdateClient(state, http, () => now, TimeSpan.FromHours(12));

        AvailableRelease? release = await client.CheckAsync(CancellationToken.None);
        Assert.Equal(new Version(0, 26, 5), release?.Version);
        Assert.Equal(1, calls);

        Assert.Null(await client.CheckAsync(CancellationToken.None));
        Assert.Equal(1, calls);
    }

    [Fact]
    public async Task RejectsUnknownLengthBodyOverOneMegabyte()
    {
        var state = new FirstRunStateStore(_root);
        using var http = new HttpClient(new DelegateHandler(_ =>
            new HttpResponseMessage(HttpStatusCode.OK) { Content = new UnknownLengthContent(1_048_577) }));
        using var client = new GitHubUpdateClient(state, http, () => DateTimeOffset.UtcNow, TimeSpan.Zero);

        Assert.Null(await client.CheckAsync(CancellationToken.None));
        Assert.NotNull(state.ReadUpdateAttempt());
    }

    [Fact]
    public async Task NetworkFailureIsInformationalAndStillThrottled()
    {
        var state = new FirstRunStateStore(_root);
        using var http = new HttpClient(new DelegateHandler(_ => throw new HttpRequestException("offline")));
        using var client = new GitHubUpdateClient(state, http, () => DateTimeOffset.UtcNow, TimeSpan.Zero);

        Assert.Null(await client.CheckAsync(CancellationToken.None));
        Assert.NotNull(state.ReadUpdateAttempt());
    }

    private static HttpResponseMessage Json(string value) => new(HttpStatusCode.OK)
    {
        Content = new StringContent(value, System.Text.Encoding.UTF8, "application/json")
    };

    public void Dispose()
    {
        if (Directory.Exists(_root)) Directory.Delete(_root, true);
    }

    private sealed class DelegateHandler(Func<HttpRequestMessage, HttpResponseMessage> send) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            Task.FromResult(send(request));
    }

    private sealed class UnknownLengthContent(int length) : HttpContent
    {
        protected override async Task SerializeToStreamAsync(Stream stream, TransportContext? context) =>
            await stream.WriteAsync(new byte[length]);

        protected override bool TryComputeLength(out long length)
        {
            length = 0;
            return false;
        }
    }
}
