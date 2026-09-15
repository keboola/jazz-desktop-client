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
        // The client ranks candidates against BuildIdentity.ProducerVersion, so a hard-coded tag
        // stops being newer the moment the product reaches it: the 0.26.4 -> 0.26.5 bump turned
        // this fixture into the running version and failed the test rather than the discovery code
        // it covers. Derive the tag from the build so it outranks whatever version ships next.
        Version current = Version.Parse(BuildIdentity.ProducerVersion);
        var newer = new Version(current.Major, current.Minor, current.Build + 1);
        string tag = "v" + newer;
        using var http = new HttpClient(new DelegateHandler(_ =>
        {
            calls++;
            Assert.Equal("https://api.github.com/repos/keboola/jazz-windows-releases/releases", _.RequestUri?.AbsoluteUri);
            Assert.Equal(now, state.ReadUpdateAttempt());
            Assert.Equal("JazzCapture/" + BuildIdentity.ProducerVersion, _.Headers.UserAgent.ToString());
            string version = tag[1..];
            string file = $"JazzCapture-{version}-win-x64-unsigned.msi";
            string sha = new string('a', 64);
            return Json($"[{{\"tag_name\":\"{tag}\",\"html_url\":\"https://github.com/keboola/jazz-windows-releases/releases/tag/{tag}\",\"draft\":false,\"prerelease\":false,\"assets\":[{{\"name\":\"{file}\",\"browser_download_url\":\"https://github.com/keboola/jazz-windows-releases/releases/download/{tag}/{file}\",\"digest\":\"sha256:{sha}\",\"size\":12}}]}}]");
        }));
        using var client = new GitHubUpdateClient(state, http, () => now, TimeSpan.FromHours(12));

        AvailableRelease? release = await client.CheckAsync(CancellationToken.None);
        Assert.Equal(newer, release?.Version);
        Assert.Equal($"https://github.com/keboola/jazz-windows-releases/releases/download/{tag}/JazzCapture-{newer}-win-x64-unsigned.msi", release?.MsiUrl.AbsoluteUri);
        Assert.Equal(new string('a', 64), release?.Sha256);
        Assert.Equal(1, calls);
        Assert.Empty(http.DefaultRequestHeaders.UserAgent);

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
