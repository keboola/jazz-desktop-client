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

    /// <summary>
    /// Regression coverage for the #74 review's defect A: <see cref="ScreenshotDeliveryWorker.DrainOnceAsync"/>
    /// must surface how soon the retryable entry it just backed off is due again, so
    /// <see cref="ScreenshotDeliveryScheduler"/> has something to sleep on instead of parking
    /// forever with nothing to wake it.
    /// </summary>
    [Fact]
    public async Task ARetryableFailureReturnsTheEntrysComputedBackoffAsTheNextDueTime()
    {
        var clock = new MutableClock(DateTimeOffset.UtcNow);
        var handler = new Handler();
        using RedirectSafeHttpClient transport = RedirectSafeHttpClient.CreateForTests(handler);
        ScreenshotDeliverySettings settings = Settings();
        var client = new KeboolaFilesClient(Bundle(), transport, settings);
        var area = new ScreenshotStagingArea(settings, clock.Now);
        var worker = new ScreenshotDeliveryWorker(client, area);
        byte[] bytes = ScreenshotBytes.TinyJpeg;
        const string artifactId = "art-due-after-retry";
        ScreenshotFilesRequest request = Request(bytes, artifactId);
        handler.ResponsesByDigest[request.Sha256] = _ => new HttpResponseMessage(HttpStatusCode.Unauthorized);
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), request, bytes));

        TimeSpan? due = await worker.DrainOnceAsync(CancellationToken.None);

        TimeSpan expected = ScreenshotUploadRetryPolicy.Delay(1, artifactId, settings);
        Assert.Equal(expected, due);
    }

    [Fact]
    public async Task ADrainWithNothingStagedReturnsNull()
    {
        var handler = new Handler();
        using RedirectSafeHttpClient transport = RedirectSafeHttpClient.CreateForTests(handler);
        ScreenshotDeliverySettings settings = Settings();
        var client = new KeboolaFilesClient(Bundle(), transport, settings);
        var area = new ScreenshotStagingArea(settings);
        var worker = new ScreenshotDeliveryWorker(client, area);

        TimeSpan? due = await worker.DrainOnceAsync(CancellationToken.None);

        Assert.Null(due);
    }

    /// <summary>
    /// Regression coverage for the #74 review's eviction-visibility finding: a byte-ceiling eviction
    /// removes an already-prepared entry whose Files id has already gone out on an emitted event, so
    /// the worker must report it as a terminal outcome exactly like an upload's own
    /// <see cref="ScreenshotDeliveryOutcome.Dropped"/> -- otherwise
    /// <see cref="ScreenshotDeliveryPresentationTracker"/> never learns the id is dangling and the
    /// tray can read "up to date" while it still is. The eviction happens purely through
    /// <see cref="ScreenshotStagingArea.Stage"/> (no upload attempt is ever made for "art-evicted");
    /// this pins that <see cref="ScreenshotDeliveryWorker.DrainOnceAsync"/> still finds and reports it
    /// even though the entry never reached <see cref="ScreenshotStagingArea.Drain"/>. Nothing else is
    /// staged, so once the drain pass completes the queue is fully empty and the tray must not read
    /// "up to date" -- it must keep reporting the abandoned screenshot as undelivered.
    /// </summary>
    [Fact]
    public async Task AByteCeilingEvictionIsReportedAsATerminalOutcomeAndTheTrayNeverClaimsUpToDate()
    {
        var handler = new Handler();
        using RedirectSafeHttpClient transport = RedirectSafeHttpClient.CreateForTests(handler);
        ScreenshotDeliverySettings settings = Settings() with { StagingByteCeiling = 2000 };
        var client = new KeboolaFilesClient(Bundle(), transport, settings);
        var area = new ScreenshotStagingArea(settings);
        var tracker = new ScreenshotDeliveryPresentationTracker();
        var worker = new ScreenshotDeliveryWorker(client, area, tracker.OnOutcome);
        byte[] a = new byte[1000];
        byte[] b = new byte[1200];
        ScreenshotFilesRequest requestA = Request(a, "art-evicted");
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), requestA, a));
        // Evicts "art-evicted" (the only, and therefore oldest, entry) to make room for b; nothing is
        // ever uploaded for it.
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), Request(b, "art-b"), b));
        handler.ResponsesByDigest[Request(b, "art-b").Sha256] = _ => new HttpResponseMessage(HttpStatusCode.OK);

        await worker.DrainOnceAsync(CancellationToken.None);

        Assert.DoesNotContain(handler.Requests, r => r.Digest == requestA.Sha256);
        Assert.Equal(0, area.Status.PendingCount);
        ScreenshotDeliveryPresentation presentation = tracker.Resolve(provisioned: true, pendingCount: area.Status.PendingCount);
        Assert.Equal(ScreenshotDeliveryPresentationState.Abandoned, presentation.State);
        Assert.Equal(1, presentation.Count);
    }

    /// <summary>
    /// Regression coverage for the #74 review's stale-status finding: an eviction sweep with nothing
    /// else to upload must still surface a status change, not leave a caller's last-seen "uploading"
    /// impression stale. Reporting the eviction through the same <c>onOutcome</c> callback an upload
    /// outcome uses is what makes this automatic -- this test pins that the callback actually fires
    /// even though <see cref="ScreenshotStagingArea.Drain"/> itself never surfaces the evicted entry.
    /// </summary>
    [Fact]
    public async Task ADrainPassThatOnlyEvictsStillReportsAnOutcomeToRefreshAStaleStatus()
    {
        var handler = new Handler();
        using RedirectSafeHttpClient transport = RedirectSafeHttpClient.CreateForTests(handler);
        ScreenshotDeliverySettings settings = Settings() with { StagingByteCeiling = 1000 };
        var client = new KeboolaFilesClient(Bundle(), transport, settings);
        var area = new ScreenshotStagingArea(settings);
        var reported = new List<ScreenshotDeliveryOutcomeEvent>();
        var worker = new ScreenshotDeliveryWorker(client, area, reported.Add);
        byte[] small = new byte[10];
        byte[] fillsTheCeiling = new byte[1000];
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), Request(small, "art-small"), small));
        // Evicts "art-small" to make room; the replacement is never handed to a due drain in this
        // test (kept beyond its own backoff would still be picked up, but that is not what this test
        // is pinning), so DrainOnceAsync's only outcome this pass is the eviction itself.
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), Request(fillsTheCeiling, "art-fills"), fillsTheCeiling));
        handler.ResponsesByDigest[Request(fillsTheCeiling, "art-fills").Sha256] = _ => new HttpResponseMessage(HttpStatusCode.OK);

        await worker.DrainOnceAsync(CancellationToken.None);

        Assert.Contains(reported, e => e.ArtifactId == "art-small" && e.Outcome == ScreenshotDeliveryOutcome.Evicted);
    }

    /// <summary>
    /// Companion to <see cref="AByteCeilingEvictionIsReportedAsATerminalOutcomeAndTheTrayNeverClaimsUpToDate"/>
    /// for the other eviction path: an age eviction is driven entirely by the injected clock (no real
    /// sleeping), and must reach the tracker as an abandoned outcome exactly the same way.
    /// </summary>
    [Fact]
    public async Task AnAgeEvictionIsReportedAsATerminalOutcomeDrivenByTheInjectedClock()
    {
        var clock = new MutableClock(DateTimeOffset.UtcNow);
        var handler = new Handler();
        using RedirectSafeHttpClient transport = RedirectSafeHttpClient.CreateForTests(handler);
        ScreenshotDeliverySettings settings = Settings() with { StagingRetention = TimeSpan.FromMinutes(30) };
        var client = new KeboolaFilesClient(Bundle(), transport, settings);
        var area = new ScreenshotStagingArea(settings, clock.Now);
        var tracker = new ScreenshotDeliveryPresentationTracker();
        var worker = new ScreenshotDeliveryWorker(client, area, tracker.OnOutcome);
        byte[] bytes = ScreenshotBytes.TinyJpeg;
        ScreenshotFilesRequest request = Request(bytes, "art-aged-out");
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), request, bytes));

        clock.Advance(TimeSpan.FromMinutes(31));
        await worker.DrainOnceAsync(CancellationToken.None);

        Assert.DoesNotContain(handler.Requests, r => r.Digest == request.Sha256);
        Assert.Equal(0, area.Status.PendingCount);
        ScreenshotDeliveryPresentation presentation = tracker.Resolve(provisioned: true, pendingCount: 0);
        Assert.Equal(ScreenshotDeliveryPresentationState.Abandoned, presentation.State);
        Assert.Equal(1, presentation.Count);
    }

    [Fact]
    public async Task ADrainThatUploadsEverythingSuccessfullyAlsoReturnsNull()
    {
        var handler = new Handler();
        using RedirectSafeHttpClient transport = RedirectSafeHttpClient.CreateForTests(handler);
        ScreenshotDeliverySettings settings = Settings();
        var client = new KeboolaFilesClient(Bundle(), transport, settings);
        var area = new ScreenshotStagingArea(settings);
        var worker = new ScreenshotDeliveryWorker(client, area);
        byte[] bytes = ScreenshotBytes.TinyJpeg;
        ScreenshotFilesRequest request = Request(bytes, "art-drains-clean");
        handler.ResponsesByDigest[request.Sha256] = _ => new HttpResponseMessage(HttpStatusCode.OK);
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), request, bytes));

        TimeSpan? due = await worker.DrainOnceAsync(CancellationToken.None);

        Assert.Null(due);
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
