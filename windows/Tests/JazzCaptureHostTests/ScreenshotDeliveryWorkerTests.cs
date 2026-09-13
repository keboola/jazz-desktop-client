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

    /// <summary>
    /// Regression coverage for Finding 1 (#74 review, third pass) -- see
    /// <c>ScreenshotDeliveryPreparerTests.TheConstructorRequiresANonNullStagingAreaSoAppCanNeverWireOneUpWithoutOne</c>
    /// for the full rationale. This type cannot exist without a staging area either, which is what
    /// lets <c>App.OnStartup</c> leave both the preparer and this worker permanently null -- routing
    /// every downstream call (<c>PrepareScreenshotDelivery</c>'s null-conditional preparer read,
    /// <c>DrainScreenshotDeliveryAsync</c>'s null-worker "nothing due" branch) through their existing
    /// null guards -- rather than ever constructing either one around a null staging area.
    /// </summary>
    [Fact]
    public void TheConstructorRequiresANonNullStagingArea()
    {
        var handler = new Handler();
        using RedirectSafeHttpClient transport = RedirectSafeHttpClient.CreateForTests(handler);
        var client = new KeboolaFilesClient(Bundle(), transport, Settings());

        Assert.Throws<ArgumentNullException>(() => new ScreenshotDeliveryWorker(client, staging: null!));
    }

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
    /// <see cref="DeliveryDrainScheduler"/> has something to sleep on instead of parking
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

    /// <summary>
    /// Regression coverage for Finding 1 (#74 review, second pass): nothing in
    /// <see cref="KeboolaFilesClient.UploadAsync"/> or <see cref="ScreenshotDeliveryWorker.DrainOnceAsync"/>
    /// checks or depends on the <see cref="DeviceBundle.ExpiresAt"/> a client was built from --
    /// <c>UploadAsync</c> authenticates the GCS PUT with the short-lived federation bearer captured
    /// at prepare time, never with the Storage token (see <see cref="KeboolaFilesClient"/>'s own
    /// remarks). That is the load-bearing fact behind <c>App.RefreshScreenshotDelivery</c> retaining
    /// -- rather than replacing with <see langword="null"/> -- the previously published worker when
    /// a fresh <see cref="KeboolaFilesClient"/> cannot be built because the credential has lapsed.
    /// <c>App.xaml.cs</c> has no test coverage of its own (an accepted gap from the #72 review), so
    /// this pins the fact at the seam directly below it: a worker built around a client whose
    /// backing credential already expired before the client was even constructed can still
    /// successfully drain an entry staged earlier.
    /// </summary>
    [Fact]
    public async Task AWorkerBuiltFromAClientWithAnAlreadyExpiredCredentialStillDrainsAlreadyStagedEntries()
    {
        var handler = new Handler();
        using RedirectSafeHttpClient transport = RedirectSafeHttpClient.CreateForTests(handler);
        ScreenshotDeliverySettings settings = Settings();
        var client = new KeboolaFilesClient(ExpiredBundle(), transport, settings);
        var area = new ScreenshotStagingArea(settings);
        var worker = new ScreenshotDeliveryWorker(client, area);
        byte[] bytes = ScreenshotBytes.TinyJpeg;
        ScreenshotFilesRequest request = Request(bytes, "art-expired-credential");
        handler.ResponsesByDigest[request.Sha256] = _ => new HttpResponseMessage(HttpStatusCode.OK);
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), request, bytes));

        await worker.DrainOnceAsync(CancellationToken.None);

        Assert.Equal(0, area.Status.PendingCount);
        Assert.Contains(handler.Requests, r => r.Method == HttpMethod.Put && r.Digest == request.Sha256);
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

    /// <summary>
    /// The Finding 4 (#74 review, second pass) regression test, and the one that matters most: the
    /// staging area's own eviction used to have no notion of what the worker currently has in
    /// flight, so a concurrent <see cref="ScreenshotStagingArea.Stage"/> exceeding the byte ceiling
    /// could evict the exact entry a drain pass was mid-upload for. That entry would then receive
    /// two conflicting terminal outcomes: the upload's own (here, a retry) plus a later eviction
    /// report -- which, folded into <see cref="ScreenshotDeliveryPresentationTracker"/>, is exactly
    /// the inversion the accounting work existed to prevent (a screenshot that uploaded, or is still
    /// trying to, reported to the user as permanently undelivered).
    /// </summary>
    /// <remarks>
    /// Uses a transport that blocks on a <see cref="TaskCompletionSource{TResult}"/> and a real
    /// background <see cref="Task.Run(Func{Task})"/> for the drain pass, so the test's own thread can
    /// call <see cref="ScreenshotStagingArea.Stage"/> while the upload is genuinely in flight -- the
    /// same cross-thread shape as the real capture path (<c>Stage</c>, under the capture engine's own
    /// lock) racing the worker's background task, deterministic because the interleaving point is a
    /// completion source the test controls rather than a sleep.
    /// </remarks>
    [Fact]
    public async Task AnEntryTheWorkerIsProcessingIsNotEvictedByAConcurrentStageAndReceivesExactlyOneTerminalOutcome()
    {
        var handler = new BlockingHandler();
        using RedirectSafeHttpClient transport = RedirectSafeHttpClient.CreateForTests(handler);
        ScreenshotDeliverySettings settings = Settings() with { StagingByteCeiling = 1500 };
        var client = new KeboolaFilesClient(Bundle(), transport, settings);
        var area = new ScreenshotStagingArea(settings);
        var reported = new List<ScreenshotDeliveryOutcomeEvent>();
        var worker = new ScreenshotDeliveryWorker(client, area, e => { lock (reported) reported.Add(e); });

        byte[] inFlightBytes = new byte[1000];
        ScreenshotFilesRequest inFlightRequest = Request(inFlightBytes, "art-in-flight");
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), inFlightRequest, inFlightBytes));

        // Start the drain pass on a real background task; it will read "art-in-flight"'s bytes,
        // call UploadAsync, and block inside the fake transport until this test releases it.
        Task<TimeSpan?> drainTask = Task.Run(() => worker.DrainOnceAsync(CancellationToken.None));
        await handler.RequestReceived.Task;

        // While the upload is genuinely in flight (and therefore leased), stage a second entry
        // large enough that admitting it would need to evict something to stay under the ceiling.
        // Without the lease, EvictOldestLocked would pick "art-in-flight" -- the only, and
        // therefore oldest, entry -- out from under the in-flight upload.
        byte[] concurrentBytes = new byte[900];
        ScreenshotFilesRequest concurrentRequest = Request(concurrentBytes, "art-concurrent");
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), concurrentRequest, concurrentBytes));

        // Both entries are present: the ceiling (1500) is temporarily exceeded (1000 + 900 = 1900)
        // because the only evictable candidate is leased -- the deliberate, bounded relaxation
        // Stage's own remarks document, rather than "art-in-flight" being evicted or "art-concurrent"
        // being refused.
        Assert.Equal(2, area.Status.PendingCount);

        // Let the upload proceed, and make it a retryable failure rather than a success, so
        // "art-in-flight" stays staged after the pass -- this is what lets the assertion below
        // prove the lease was released, not merely that this artifact happened to be removed.
        handler.Gate.SetResult(new HttpResponseMessage(HttpStatusCode.Unauthorized));
        await drainTask;

        List<ScreenshotDeliveryOutcomeEvent> inFlightOutcomes = reported.Where(e => e.ArtifactId == "art-in-flight").ToList();
        Assert.Single(inFlightOutcomes);
        Assert.Equal(ScreenshotDeliveryOutcome.Retrying, inFlightOutcomes[0].Outcome);
        Assert.DoesNotContain(reported, e => e.ArtifactId == "art-in-flight" && e.Outcome == ScreenshotDeliveryOutcome.Evicted);
        Assert.Equal(2, area.Status.PendingCount);

        // The lease is released once the pass concludes: staging one more small entry now evicts
        // "art-in-flight" (the oldest, and no longer leased) rather than leaving it permanently
        // un-evictable.
        byte[] afterReleaseBytes = new byte[10];
        Assert.Equal(
            ScreenshotStageResult.Staged,
            area.Stage(Prepared(), Request(afterReleaseBytes, "art-after-release"), afterReleaseBytes));
        Assert.Equal("art-in-flight", Assert.Single(area.DrainPendingEvictions()));
    }

    /// <summary>
    /// Regression coverage for Finding 4 (#74 review, third pass). The second pass's fix leased an
    /// entry immediately before attempting it, which closed the race for as long as an entry was
    /// actually being attempted -- but <see cref="ScreenshotStagingArea.Drain"/> takes its snapshot
    /// slightly earlier than that lease call, under its own lock, and a concurrent
    /// <see cref="ScreenshotStagingArea.Stage"/> can still evict an entry already in that snapshot
    /// during the gap. Before this fix, <see cref="ScreenshotStagingArea.Lease"/> (now
    /// <see cref="ScreenshotStagingArea.TryLease"/>) silently did nothing for an id that no longer
    /// existed, so the worker went on to attempt it anyway: <see cref="ScreenshotStagingArea.TryReadBytes"/>
    /// failed (nothing left to read) and the worker reported <see cref="ScreenshotDeliveryOutcome.VerificationFailed"/>
    /// -- a second, conflicting terminal outcome for an artifact the eviction had already queued as
    /// <see cref="ScreenshotDeliveryOutcome.Evicted"/>. This forces exactly that gap: while one entry
    /// ("art-in-flight") is genuinely being uploaded (a real await point, deterministic via
    /// <see cref="BlockingHandler"/>), a second entry ("art-b") that was already part of the same
    /// drain pass's snapshot is evicted by a byte-ceiling <see cref="ScreenshotStagingArea.Stage"/>
    /// call from the test's own thread, before the worker's loop ever reaches it.
    /// </summary>
    [Fact]
    public async Task AHandleEvictedBetweenTheSnapshotAndTheLeaseIsSkippedAndReportedExactlyOnceByTheEviction()
    {
        var handler = new BlockingHandler();
        using RedirectSafeHttpClient transport = RedirectSafeHttpClient.CreateForTests(handler);
        ScreenshotDeliverySettings settings = Settings() with { StagingByteCeiling = 1050 };
        var client = new KeboolaFilesClient(Bundle(), transport, settings);
        var area = new ScreenshotStagingArea(settings);
        var reported = new List<ScreenshotDeliveryOutcomeEvent>();
        var worker = new ScreenshotDeliveryWorker(client, area, e => { lock (reported) reported.Add(e); });

        // "art-in-flight" (oldest) and "art-b" both fit comfortably under the ceiling and are both
        // due immediately, so Drain()'s snapshot for the coming pass contains both.
        byte[] inFlightBytes = new byte[1000];
        Assert.Equal(
            ScreenshotStageResult.Staged,
            area.Stage(Prepared(), Request(inFlightBytes, "art-in-flight"), inFlightBytes));
        byte[] bBytes = new byte[10];
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), Request(bBytes, "art-b"), bBytes));

        // Start the drain pass on a real background task; the worker leases and reads
        // "art-in-flight" first (it is the oldest), calls UploadAsync, and blocks inside the fake
        // transport until this test releases it -- "art-b" has not been leased yet at this point,
        // exactly the gap this fix closes.
        Task<TimeSpan?> drainTask = Task.Run(() => worker.DrainOnceAsync(CancellationToken.None));
        await handler.RequestReceived.Task;

        // While "art-in-flight" is genuinely in flight (and therefore leased, so it cannot be
        // picked), stage a third entry large enough that admitting it evicts the oldest *evictable*
        // entry -- "art-b", the only unleased one -- to stay under the ceiling. Without this fix,
        // the worker would still attempt "art-b" once its loop reached it and report a conflicting
        // VerificationFailed.
        byte[] cBytes = new byte[50];
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), Request(cBytes, "art-c"), cBytes));
        Assert.False(area.TryReadBytes("art-b", out _), "art-b must already be evicted by the ceiling.");

        handler.Gate.SetResult(new HttpResponseMessage(HttpStatusCode.OK));
        await drainTask;

        // Skipped, not attempted: no report at all for "art-b" from this pass -- in particular not
        // VerificationFailed, which is what the pre-fix code reported here.
        lock (reported) Assert.DoesNotContain(reported, e => e.ArtifactId == "art-b");

        // The eviction itself is still queued (this pass's own DrainPendingEvictions call happened
        // before "art-b" was ever evicted); a later pass reports it, and it is the only report
        // "art-b" ever receives.
        await worker.DrainOnceAsync(CancellationToken.None);

        List<ScreenshotDeliveryOutcomeEvent> bOutcomes;
        lock (reported) bOutcomes = reported.Where(e => e.ArtifactId == "art-b").ToList();
        Assert.Single(bOutcomes);
        Assert.Equal(ScreenshotDeliveryOutcome.Evicted, bOutcomes[0].Outcome);
    }

    /// <summary>
    /// Anti-leak coverage for Finding 4: an entry's lease must be released even when the transport
    /// throws something other than its own documented outcomes, since <see cref="DrainOneAsync"/>'s
    /// catch-all still counts that as a retryable failure rather than letting the exception escape.
    /// </summary>
    [Fact]
    public async Task ALeaseIsReleasedWhenTheTransportThrows()
    {
        var handler = new Handler();
        using RedirectSafeHttpClient transport = RedirectSafeHttpClient.CreateForTests(handler);
        ScreenshotDeliverySettings settings = Settings() with { StagingByteCeiling = 1005 };
        var client = new KeboolaFilesClient(Bundle(), transport, settings);
        var area = new ScreenshotStagingArea(settings);
        var worker = new ScreenshotDeliveryWorker(client, area);
        byte[] bytes = new byte[1000];
        ScreenshotFilesRequest request = Request(bytes, "art-throws-lease");
        handler.ThrowByDigest[request.Sha256] = new InvalidOperationException("synthetic transport failure");
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), request, bytes));

        await worker.DrainOnceAsync(CancellationToken.None);

        // Still staged (retried), and its lease is gone: staging a small entry now evicts it,
        // proving the finally in DrainOnceAsync released the lease despite the transport throwing.
        byte[] small = new byte[10];
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), Request(small, "art-after-throw"), small));
        Assert.Equal("art-throws-lease", Assert.Single(area.DrainPendingEvictions()));
    }

    /// <summary>
    /// Anti-leak coverage for Finding 4: an entry's lease must be released even when the drain pass
    /// itself is cancelled mid-upload -- <see cref="DrainOnceAsync"/>'s documented contract is that
    /// only genuine cancellation of its token propagates, and this pins that propagation still runs
    /// through the same <c>finally</c> that releases the lease.
    /// </summary>
    [Fact]
    public async Task ALeaseIsReleasedWhenThePassIsCancelled()
    {
        var handler = new BlockingHandler();
        using RedirectSafeHttpClient transport = RedirectSafeHttpClient.CreateForTests(handler);
        ScreenshotDeliverySettings settings = Settings() with { StagingByteCeiling = 1005 };
        var client = new KeboolaFilesClient(Bundle(), transport, settings);
        var area = new ScreenshotStagingArea(settings);
        var worker = new ScreenshotDeliveryWorker(client, area);
        byte[] bytes = new byte[1000];
        ScreenshotFilesRequest request = Request(bytes, "art-cancelled");
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), request, bytes));

        using var cts = new CancellationTokenSource();
        Task<TimeSpan?> drainTask = Task.Run(() => worker.DrainOnceAsync(cts.Token));
        await handler.RequestReceived.Task;

        cts.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => drainTask);

        // Lease released despite the pass itself throwing due to cancellation: staging a small
        // entry now evicts "art-cancelled".
        byte[] small = new byte[10];
        Assert.Equal(ScreenshotStageResult.Staged, area.Stage(Prepared(), Request(small, "art-after-cancel"), small));
        Assert.Equal("art-cancelled", Assert.Single(area.DrainPendingEvictions()));
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

    /// <summary>Same shape as <see cref="Bundle"/> but already expired -- <c>requireUnexpired:
    /// false</c> is required for <see cref="DeviceBundleParser.ParseMvp"/> to accept it at all,
    /// exactly the way <c>App.RefreshScreenshotDelivery</c> itself never asks the parser to enforce
    /// freshness (it parses the bundle once, on the provisioning path, then compares
    /// <c>ExpiresAt</c> against the clock itself at the point of use).</summary>
    private static DeviceBundle ExpiredBundle() => DeviceBundleParser.ParseMvp(
        """
        {"kind":"jazz-device-bundle","enrollmentProfile":"mvp","deviceId":"d","companyId":"c","areaId":"a","projectId":"1","stackURL":"https://connection.keboola.com","archiveIngestURL":"https://example.invalid/api/archive-ingests","token":"123-abcdefghijklmnop","tokenId":"t","expiresAt":"2000-01-01T00:00:00Z","componentAccess":[],"tokenBucketScope":"none"}
        """,
        DateTimeOffset.UtcNow,
        requireUnexpired: false);

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

    /// <summary>
    /// Fake transport that signals <see cref="RequestReceived"/> the moment a call arrives, then
    /// blocks until the test completes <see cref="Gate"/> -- the deterministic, no-sleeping way to
    /// make an upload attempt genuinely "in flight" for as long as a test needs to interleave other
    /// work with it (Finding 4's regression and anti-leak tests). Also respects the caller's own
    /// cancellation token, so cancelling the drain pass's token while a call is blocked here faults
    /// it with <see cref="OperationCanceledException"/> exactly as a real transport would.
    /// </summary>
    private sealed class BlockingHandler : HttpMessageHandler
    {
        public TaskCompletionSource<bool> RequestReceived { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public TaskCompletionSource<HttpResponseMessage> Gate { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request, CancellationToken cancellationToken)
        {
            RequestReceived.TrySetResult(true);
            using CancellationTokenRegistration registration =
                cancellationToken.Register(() => Gate.TrySetCanceled(cancellationToken));
            return await Gate.Task.ConfigureAwait(false);
        }
    }
}
