using System.Net;
using System.Net.Http;
using JazzCapture;
using JazzCaptureCore;

namespace JazzCaptureHostTests;

public sealed class ClientPolicyClientTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "jazz-policy-" + Guid.NewGuid().ToString("N"));

    [Fact]
    public async Task FetchesParsesAndCachesPolicy()
    {
        var state = new FirstRunStateStore(_root);
        DateTimeOffset now = new(2026, 9, 14, 12, 0, 0, TimeSpan.Zero);
        int calls = 0;
        using var http = new HttpClient(new DelegateHandler(_ =>
        {
            calls++;
            Assert.Equal(ClientPolicy.LatestUrl.AbsoluteUri, _.RequestUri?.AbsoluteUri);
            return Json("{\"kind\":\"jazz-windows-client-policy\",\"schema\":1,\"pauseReminderMinutes\":15}");
        }));
        using var client = new ClientPolicyClient(state, _root, http, () => now, TimeSpan.FromHours(1));

        ClientPolicy? policy = await client.CheckAsync(CancellationToken.None);
        Assert.Equal(15, policy?.PauseReminderMinutes);
        Assert.Equal(1, calls);
        Assert.Equal(15, client.ReadCache()?.PauseReminderMinutes);

        Assert.Equal(15, (await client.CheckAsync(CancellationToken.None))?.PauseReminderMinutes);
        Assert.Equal(1, calls);
    }

    [Fact]
    public async Task InvalidDocumentKeepsCacheAndDoesNotThrow()
    {
        Directory.CreateDirectory(_root);
        File.WriteAllText(
            Path.Combine(_root, "client-policy.json"),
            "{\"kind\":\"jazz-windows-client-policy\",\"schema\":1,\"pauseReminderMinutes\":20}");
        var state = new FirstRunStateStore(_root);
        using var http = new HttpClient(new DelegateHandler(_ => Json("{\"kind\":\"nope\"}")));
        using var client = new ClientPolicyClient(state, _root, http, () => DateTimeOffset.UtcNow, TimeSpan.Zero);

        ClientPolicy? policy = await client.CheckAsync(CancellationToken.None);
        Assert.Equal(20, policy?.PauseReminderMinutes);
    }

    public void Dispose()
    {
        if (Directory.Exists(_root)) Directory.Delete(_root, true);
    }

    private static HttpResponseMessage Json(string value) => new(HttpStatusCode.OK)
    {
        Content = new StringContent(value, System.Text.Encoding.UTF8, "application/json")
    };

    private sealed class DelegateHandler(Func<HttpRequestMessage, HttpResponseMessage> send) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            Task.FromResult(send(request));
    }
}
