using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using JazzCapture;
using JazzCaptureCore;

namespace JazzCaptureHostTests;

public sealed class MsiUpdateApplierTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "jazz-msi-update-" + Guid.NewGuid().ToString("N"));

    [Fact]
    public async Task DownloadsVerifiesAndStartsInstaller()
    {
        byte[] payload = "fake-msi-bytes"u8.ToArray();
        AvailableRelease release = Release(payload);
        string? started = null;
        var applier = new MsiUpdateApplier(path => { started = path; return true; });
        using var http = new HttpClient(new DelegateHandler(_ => Bytes(payload)));

        MsiUpdateApplyResult result = await applier.ApplyAsync(release, _root, http, CancellationToken.None);

        Assert.True(result.Started);
        Assert.Null(result.Error);
        Assert.Equal(Path.Combine(_root, "JazzCapture-0.26.6-win-x64-unsigned.msi"), started);
        Assert.Equal(payload, File.ReadAllBytes(started!));
        Assert.False(File.Exists(started + ".part"));
    }

    [Fact]
    public async Task RejectsChecksumMismatchWithoutStartingInstaller()
    {
        byte[] payload = "fake-msi-bytes"u8.ToArray();
        AvailableRelease release = Release(payload, sha256: new string('b', 64));
        bool started = false;
        var applier = new MsiUpdateApplier(_ => { started = true; return true; });
        using var http = new HttpClient(new DelegateHandler(_ => Bytes(payload)));

        MsiUpdateApplyResult result = await applier.ApplyAsync(release, _root, http, CancellationToken.None);

        Assert.False(result.Started);
        Assert.Equal("Update file did not match its checksum.", result.Error);
        Assert.False(started);
        Assert.False(Directory.EnumerateFiles(_root).Any());
    }

    [Fact]
    public async Task RejectsOversizedBodyWithoutStartingInstaller()
    {
        byte[] payload = "fake-msi-bytes"u8.ToArray();
        AvailableRelease release = Release(payload, size: payload.Length - 1);
        bool started = false;
        var applier = new MsiUpdateApplier(_ => { started = true; return true; });
        using var http = new HttpClient(new DelegateHandler(_ => Bytes(payload)));

        MsiUpdateApplyResult result = await applier.ApplyAsync(release, _root, http, CancellationToken.None);

        Assert.False(result.Started);
        Assert.Equal("Update package size did not match the release.", result.Error);
        Assert.False(started);
    }

    [Fact]
    public async Task HttpFailureDoesNotStartInstaller()
    {
        byte[] payload = "fake-msi-bytes"u8.ToArray();
        AvailableRelease release = Release(payload);
        bool started = false;
        var applier = new MsiUpdateApplier(_ => { started = true; return true; });
        using var http = new HttpClient(new DelegateHandler(_ => new HttpResponseMessage(HttpStatusCode.NotFound)));

        MsiUpdateApplyResult result = await applier.ApplyAsync(release, _root, http, CancellationToken.None);

        Assert.False(result.Started);
        Assert.Equal("Update download failed.", result.Error);
        Assert.False(started);
    }

    public void Dispose()
    {
        if (Directory.Exists(_root)) Directory.Delete(_root, true);
    }

    private static AvailableRelease Release(byte[] payload, string? sha256 = null, long? size = null)
    {
        string hash = sha256 ?? Convert.ToHexString(SHA256.HashData(payload));
        return new AvailableRelease(
            new Version(0, 26, 6),
            new Uri("https://github.com/keboola/jazz-windows-releases/releases/tag/v0.26.6"),
            new Uri("https://github.com/keboola/jazz-windows-releases/releases/download/v0.26.6/JazzCapture-0.26.6-win-x64-unsigned.msi"),
            hash,
            size ?? payload.Length);
    }

    private static HttpResponseMessage Bytes(byte[] payload) => new(HttpStatusCode.OK)
    {
        Content = new ByteArrayContent(payload)
    };

    private sealed class DelegateHandler(Func<HttpRequestMessage, HttpResponseMessage> send) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            Task.FromResult(send(request));
    }
}
