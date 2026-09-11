using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using JazzCapture;
using JazzCaptureCore.Enrollment;

namespace JazzCaptureHostTests;

/// <summary>
/// <see cref="ScreenshotDeliveryWorker"/> is one bounded drain pass over
/// <see cref="ScreenshotStagingArea"/>: it re-reads and re-verifies each due entry's bytes, PUTs
/// them through <see cref="KeboolaFilesClient.UploadAsync"/>, and applies the
/// attempt-then-drop policy from <see cref="ScreenshotDeliverySettings"/>. These tests exercise the
/// three outcomes the transport can report (acknowledged, dropped, retry), the bounded-retry
/// schedule driven entirely by an injected clock, and the isolation guarantee that one bad entry
/// can never stall the rest of a drain pass.
/// </summary>
public sealed class ScreenshotDeliveryWorkerTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), "jazz-worker-" + Guid.NewGuid().ToString("N"));

    [Fact]
    public async Task ASuccessfulUploadRemovesTheStagedEntry()
    {
        var handler = new Handler();
        using RedirectSafeHttpClient transport = RedirectSafeHttpClient.CreateForTests(handler);
        ScreenshotDeliverySettings settings = Settings();
        var client = new KeboolaFilesClient(Bundle(), transport, settings);
        var area = new ScreenshotStagingArea(settings);
        var worker = new ScreenshotDeliveryWorker(client, area);
        byte[] bytes = ScreenshotBytes.TinyJpeg;
        ScreenshotFilesRequest request = Request(bytes, "art-ok");
        handler.ResponsesByDigest[request.Sha256] = _ => new HttpResponseMessage(HttpStatusCode.OK);
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), request, bytes));

        await worker.DrainOnceAsync(CancellationToken.None);

        Assert.Equal(0, area.Status.PendingCount);
        Assert.Contains(handler.Requests, r => r.Method == HttpMethod.Put);
    }

    [Fact]
    public async Task ATerminalDroppedUploadRemovesTheStagedEntryAndIssuesNoRemoteDelete()
    {
        var handler = new Handler();
        using RedirectSafeHttpClient transport = RedirectSafeHttpClient.CreateForTests(handler);
        ScreenshotDeliverySettings settings = Settings();
        var client = new KeboolaFilesClient(Bundle(), transport, settings);
        var area = new ScreenshotStagingArea(settings);
        var worker = new ScreenshotDeliveryWorker(client, area);
        byte[] bytes = ScreenshotBytes.TinyJpeg;
        ScreenshotFilesRequest request = Request(bytes, "art-dropped");
        // KeboolaFilesClient.UploadAsync classifies a 400 as Dropped: retrying identical bytes
        // cannot fix a malformed-request response.
        handler.ResponsesByDigest[request.Sha256] = _ => new HttpResponseMessage(HttpStatusCode.BadRequest);
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), request, bytes));

        await worker.DrainOnceAsync(CancellationToken.None);

        Assert.Equal(0, area.Status.PendingCount);
        Assert.DoesNotContain(handler.Requests, r => r.Method == HttpMethod.Delete);
    }

    [Fact]
    public async Task BoundedRetriesAreAttemptedExactlyUploadAttemptsTimesThenTheEntryIsDropped()
    {
        var clock = new MutableClock(DateTimeOffset.UtcNow);
        var handler = new Handler();
        using RedirectSafeHttpClient transport = RedirectSafeHttpClient.CreateForTests(handler);
        ScreenshotDeliverySettings settings = Settings(uploadAttempts: 3);
        var client = new KeboolaFilesClient(Bundle(), transport, settings);
        var area = new ScreenshotStagingArea(settings, clock.Now);
        var worker = new ScreenshotDeliveryWorker(client, area);
        byte[] bytes = ScreenshotBytes.TinyJpeg;
        const string artifactId = "art-retry-then-drop";
        ScreenshotFilesRequest request = Request(bytes, artifactId);
        // 401 -- treated as retryable because the federation credential is short-lived and expiry
        // is the likely cause (KeboolaFilesClient.UploadAsync).
        handler.ResponsesByDigest[request.Sha256] = _ => new HttpResponseMessage(HttpStatusCode.Unauthorized);
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), request, bytes));

        for (int attempt = 1; attempt <= 3; attempt++)
        {
            await worker.DrainOnceAsync(CancellationToken.None);
            Assert.Equal(attempt, handler.Requests.Count(r => r.Method == HttpMethod.Put));

            if (attempt < 3)
            {
                Assert.Equal(1, area.Status.PendingCount);
                TimeSpan expectedDelay = ScreenshotUploadRetryPolicy.Delay(attempt, artifactId, settings);
                clock.Advance(expectedDelay + TimeSpan.FromMilliseconds(1));
            }
        }

        Assert.Equal(0, area.Status.PendingCount);
        Assert.Equal(3, handler.Requests.Count(r => r.Method == HttpMethod.Put));
    }

    [Fact]
    public async Task AnEntryWhoseBackoffHasNotElapsedIsSkippedWithoutAnHttpRequest()
    {
        var clock = new MutableClock(DateTimeOffset.UtcNow);
        var handler = new Handler();
        using RedirectSafeHttpClient transport = RedirectSafeHttpClient.CreateForTests(handler);
        ScreenshotDeliverySettings settings = Settings();
        var client = new KeboolaFilesClient(Bundle(), transport, settings);
        var area = new ScreenshotStagingArea(settings, clock.Now);
        var worker = new ScreenshotDeliveryWorker(client, area);
        byte[] bytes = ScreenshotBytes.TinyJpeg;
        ScreenshotFilesRequest request = Request(bytes, "art-not-due");
        handler.ResponsesByDigest[request.Sha256] = _ => new HttpResponseMessage(HttpStatusCode.Unauthorized);
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), request, bytes));

        await worker.DrainOnceAsync(CancellationToken.None); // first attempt fails, schedules backoff
        int putCountAfterFirstAttempt = handler.Requests.Count(r => r.Method == HttpMethod.Put);
        Assert.Equal(1, putCountAfterFirstAttempt);

        await worker.DrainOnceAsync(CancellationToken.None); // backoff has not elapsed

        Assert.Equal(putCountAfterFirstAttempt, handler.Requests.Count(r => r.Method == HttpMethod.Put));
        Assert.Equal(1, area.Status.PendingCount);
    }

    [Fact]
    public async Task OneEntryThrowingFromTheTransportDoesNotStallTheOthers()
    {
        var handler = new Handler();
        using RedirectSafeHttpClient transport = RedirectSafeHttpClient.CreateForTests(handler);
        ScreenshotDeliverySettings settings = Settings();
        var client = new KeboolaFilesClient(Bundle(), transport, settings);
        var area = new ScreenshotStagingArea(settings);
        var worker = new ScreenshotDeliveryWorker(client, area);

        byte[] failingBytes = ScreenshotBytes.TinyJpeg;
        ScreenshotFilesRequest failingRequest = Request(failingBytes, "art-throws");
        handler.ThrowByDigest[failingRequest.Sha256] = new InvalidOperationException("synthetic transport failure");
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), failingRequest, failingBytes));

        byte[] okBytes = [7, 7, 7, 7, 7, 7, 7, 7];
        ScreenshotFilesRequest okRequest = Request(okBytes, "art-succeeds");
        handler.ResponsesByDigest[okRequest.Sha256] = _ => new HttpResponseMessage(HttpStatusCode.OK);
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), okRequest, okBytes));

        await worker.DrainOnceAsync(CancellationToken.None);

        Assert.Contains(handler.Requests, r => r.Method == HttpMethod.Put && r.Digest == okRequest.Sha256);
        // The second entry uploaded and was removed; the first is still staged but not
        // immediately due again (RecordRetry scheduled its backoff), so Drain() will not surface
        // it right away -- TryReadBytes still finds its bytes, proving it was not dropped.
        Assert.Equal(1, area.Status.PendingCount);
        Assert.False(area.TryReadBytes("art-succeeds", out _));
        Assert.True(area.TryReadBytes("art-throws", out _));
    }

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            try { Directory.Delete(root, recursive: true); }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
        }
    }

    private ScreenshotDeliverySettings Settings(int? uploadAttempts = null) => new()
    {
        StagingDirectory = root,
        UploadAttempts = uploadAttempts ?? 5,
    };

    private static ScreenshotPrepareResult Prepared() => new(1, "bucket", "prefix/object.bin", "fake-federation");

    private static ScreenshotFilesRequest Request(byte[] bytes, string artifactId) => new(
        ArchiveId: "a",
        CaptureId: "c",
        SessionId: "s",
        ArtifactId: artifactId,
        MediaType: "image/jpeg",
        Sha256: Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant(),
        ByteLength: bytes.Length);

    private static DeviceBundle Bundle() => DeviceBundleParser.ParseMvp(
        """
        {"kind":"jazz-device-bundle","enrollmentProfile":"mvp","deviceId":"d","companyId":"c","areaId":"a","projectId":"1","stackURL":"https://connection.keboola.com","archiveIngestURL":"https://example.invalid/api/archive-ingests","token":"123-abcdefghijklmnop","tokenId":"t","expiresAt":"2099-01-01T00:00:00Z","componentAccess":[],"tokenBucketScope":"none"}
        """,
        DateTimeOffset.UtcNow);

    private sealed class MutableClock
    {
        private DateTimeOffset _now;

        public MutableClock(DateTimeOffset start) => _now = start;

        public DateTimeOffset Now() => _now;

        public void Advance(TimeSpan by) => _now += by;
    }

    /// <summary>Fake transport routing responses (or exceptions) by the GCS object digest header,
    /// so a test can control several staged entries' outcomes independently regardless of drain
    /// order.</summary>
    private sealed class Handler : HttpMessageHandler
    {
        public Dictionary<string, Func<HttpRequestMessage, HttpResponseMessage>> ResponsesByDigest { get; } = new();
        public Dictionary<string, Exception> ThrowByDigest { get; } = new();
        public List<(HttpMethod Method, string Path, string? Digest)> Requests { get; } = [];

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage r, CancellationToken ct)
        {
            string? digest = r.Headers.TryGetValues("x-goog-meta-jazz-sha256", out IEnumerable<string>? values)
                ? values.SingleOrDefault()
                : null;
            Requests.Add((r.Method, r.RequestUri!.AbsolutePath, digest));

            if (digest is not null && ThrowByDigest.TryGetValue(digest, out Exception? exception))
            {
                // Faulting the returned task (rather than throwing synchronously out of this
                // override) matches how a real transport failure reaches HttpClient's caller.
                return Task.FromException<HttpResponseMessage>(exception);
            }

            if (digest is not null && ResponsesByDigest.TryGetValue(digest, out Func<HttpRequestMessage, HttpResponseMessage>? responder))
            {
                return Task.FromResult(responder(r));
            }

            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK));
        }
    }
}
