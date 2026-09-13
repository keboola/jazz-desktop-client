using System.Net;
using System.Net.Http;
using System.Text;
using JazzCapture;
using JazzCaptureCore.Enrollment;

namespace JazzCaptureHostTests;

/// <summary>
/// <see cref="NarrationDeliveryWorker"/> is the upload-then-emit half of issue #84: prepare, upload,
/// stamp the sidecar with the real Files id, hand the finished event to a caller-supplied spool
/// delegate, then remove the pair. These tests exercise the ordering (§2.6), the dangling-allocation
/// rule (R5), the no-attempt-budget retry policy, the crash-recovery re-entry at an already-stamped
/// clip, and amendment 2's reversal of §2.3 (terminal upload failure emits the row anyway, with
/// <c>AudioFileId</c> null).
/// </summary>
public sealed class NarrationDeliveryWorkerTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), "jazz-narration-worker-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            try { Directory.Delete(root, recursive: true); }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
        }
    }

    [Fact]
    public async Task ASuccessfulUploadStampsTheFilesIdSpoolsTheEventAndRemovesThePair()
    {
        var handler = new Handler();
        using RedirectSafeHttpClient transport = RedirectSafeHttpClient.CreateForTests(handler);
        var client = new KeboolaFilesClient(Bundle(), transport, Budgets());
        var spool = new NarrationSpool(Settings());
        var spooled = new List<PendingNarration>();
        var worker = new NarrationDeliveryWorker(client, spool, pending => { spooled.Add(pending); return true; });
        string session = SessionId();
        Assert.Equal(NarrationSpoolAdmission.Staged, spool.Stage(Pending(session, 1), NarrationBytes.TinyClip()));

        await worker.DrainOnceAsync(CancellationToken.None);

        Assert.Equal(0, spool.Status.PendingCount);
        PendingNarration emitted = Assert.Single(spooled);
        Assert.Equal(77, emitted.FilesId);
        Assert.Contains(handler.Requests, r => r.Method == HttpMethod.Put);
        Assert.DoesNotContain(handler.Requests, r => r.Method == HttpMethod.Delete);
    }

    /// <summary>Amendment 2 to the #84 plan, reversing §2.3: a terminal prepare rejection still
    /// emits exactly one row, with <c>AudioFileId</c> null (which <c>OtlpMapper</c> projects as
    /// <c>""</c>), and the pair is then removed.</summary>
    [Fact]
    public async Task ATerminalPrepareRejectionEmitsTheRowWithAnEmptyAudioFileIdAndRemovesThePair()
    {
        var handler = new Handler { PrepareStatus = HttpStatusCode.BadRequest };
        using RedirectSafeHttpClient transport = RedirectSafeHttpClient.CreateForTests(handler);
        var client = new KeboolaFilesClient(Bundle(), transport, Budgets());
        var spool = new NarrationSpool(Settings());
        var spooled = new List<PendingNarration>();
        var worker = new NarrationDeliveryWorker(client, spool, pending => { spooled.Add(pending); return true; });
        string session = SessionId();
        Assert.Equal(NarrationSpoolAdmission.Staged, spool.Stage(Pending(session, 1), NarrationBytes.TinyClip()));

        await worker.DrainOnceAsync(CancellationToken.None);

        Assert.Equal(0, spool.Status.PendingCount);
        PendingNarration emitted = Assert.Single(spooled);
        Assert.Null(emitted.FilesId);
        Assert.DoesNotContain(handler.Requests, r => r.Method == HttpMethod.Put);
    }

    /// <summary>Same amendment, for a terminal (400) rejection from the PUT instead of prepare.
    /// The dangling-allocation rule (R5) also applies: the allocation prepare just minted is deleted
    /// best-effort, because the row it might have referenced was never emitted with it.</summary>
    [Fact]
    public async Task ATerminalPutRejectionEmitsTheRowWithAnEmptyAudioFileIdAndDeletesTheDanglingAllocation()
    {
        var handler = new Handler { PutStatus = HttpStatusCode.BadRequest };
        using RedirectSafeHttpClient transport = RedirectSafeHttpClient.CreateForTests(handler);
        var client = new KeboolaFilesClient(Bundle(), transport, Budgets());
        var spool = new NarrationSpool(Settings());
        var spooled = new List<PendingNarration>();
        var worker = new NarrationDeliveryWorker(client, spool, pending => { spooled.Add(pending); return true; });
        string session = SessionId();
        Assert.Equal(NarrationSpoolAdmission.Staged, spool.Stage(Pending(session, 1), NarrationBytes.TinyClip()));

        await worker.DrainOnceAsync(CancellationToken.None);

        Assert.Equal(0, spool.Status.PendingCount);
        PendingNarration emitted = Assert.Single(spooled);
        Assert.Null(emitted.FilesId);
        Assert.Contains(handler.Requests, r => r.Method == HttpMethod.Delete && r.Path == "/v2/storage/files/77");
    }

    /// <summary>
    /// The third terminal cause -- staged bytes no longer matching the sidecar's own length or
    /// digest -- must follow the identical amendment-2 ordering as the other two: the row is built
    /// and spooled <em>before</em> the pair is removed, not after. Regression coverage for a review
    /// finding: <see cref="NarrationSpool.ReadBlob"/> used to remove the pair itself the moment it
    /// detected the mismatch, which meant the sidecar -- the only thing that could rebuild the event
    /// -- was already gone before <see cref="NarrationDeliveryWorker"/> ever got a chance to spool
    /// the row, inverting the ordering amendment 2 requires. A fake spool delegate records the
    /// spool's own pending count at the moment it is called, so this pins the <em>order</em>, not
    /// merely the end state.
    /// </summary>
    [Fact]
    public async Task StagedBytesThatNoLongerMatchTheSidecarEmitTheRowWithAnEmptyAudioFileIdBeforeRemovingThePair()
    {
        var spool = new NarrationSpool(Settings());
        string session = SessionId();
        Assert.Equal(NarrationSpoolAdmission.Staged, spool.Stage(Pending(session, 1), NarrationBytes.TinyClip()));
        string blobPath = Directory.EnumerateFiles(Path.Combine(root, session), "*.narration.audio").Single();
        byte[] corrupted = NarrationBytes.TinyClip();
        corrupted[0] ^= 0xFF;
        File.WriteAllBytes(blobPath, corrupted);

        int? pendingCountWhenSpooled = null;
        var spooled = new List<PendingNarration>();
        var worker = new NarrationDeliveryWorker(client: null, spool, pending =>
        {
            pendingCountWhenSpooled = spool.Status.PendingCount;
            spooled.Add(pending);
            return true;
        });

        await worker.DrainOnceAsync(CancellationToken.None);

        PendingNarration emitted = Assert.Single(spooled);
        Assert.Null(emitted.FilesId);
        // The pair was still staged -- not yet removed -- at the moment the row was spooled.
        Assert.Equal(1, pendingCountWhenSpooled);
        Assert.Equal(0, spool.Status.PendingCount);
    }

    [Fact]
    public async Task ARetryablePrepareFailureKeepsTheClipStagedAndEmitsNoRow()
    {
        var handler = new Handler { PrepareStatus = HttpStatusCode.ServiceUnavailable };
        using RedirectSafeHttpClient transport = RedirectSafeHttpClient.CreateForTests(handler);
        var client = new KeboolaFilesClient(Bundle(), transport, Budgets());
        var spool = new NarrationSpool(Settings());
        var spooled = new List<PendingNarration>();
        var worker = new NarrationDeliveryWorker(client, spool, pending => { spooled.Add(pending); return true; });
        string session = SessionId();
        Assert.Equal(NarrationSpoolAdmission.Staged, spool.Stage(Pending(session, 1), NarrationBytes.TinyClip()));

        await worker.DrainOnceAsync(CancellationToken.None);

        Assert.Equal(1, spool.Status.PendingCount);
        Assert.Empty(spooled);
        Assert.True(spool.AnyRetrying);
    }

    /// <summary>R5: unlike screenshot delivery, narration must delete a dangling allocation whose
    /// event has not gone out -- here for the ordinary retryable case, not only the terminal one.</summary>
    [Fact]
    public async Task ARetryableUploadFailureDeletesTheJustMintedAllocationAndKeepsTheClipStaged()
    {
        var handler = new Handler { PutStatus = HttpStatusCode.ServiceUnavailable };
        using RedirectSafeHttpClient transport = RedirectSafeHttpClient.CreateForTests(handler);
        var client = new KeboolaFilesClient(Bundle(), transport, Budgets());
        var spool = new NarrationSpool(Settings());
        var spooled = new List<PendingNarration>();
        var worker = new NarrationDeliveryWorker(client, spool, pending => { spooled.Add(pending); return true; });
        string session = SessionId();
        Assert.Equal(NarrationSpoolAdmission.Staged, spool.Stage(Pending(session, 1), NarrationBytes.TinyClip()));

        await worker.DrainOnceAsync(CancellationToken.None);

        Assert.Equal(1, spool.Status.PendingCount);
        Assert.Empty(spooled);
        Assert.Contains(handler.Requests, r => r.Method == HttpMethod.Delete && r.Path == "/v2/storage/files/77");
    }

    /// <summary>Crash recovery (§2.1, §2.6 step 4): a clip whose sidecar already carries a stamped
    /// Files id -- as if a previous process crashed between the stamp and the event being spooled --
    /// must skip prepare and upload entirely on the next pass.</summary>
    [Fact]
    public async Task AnAlreadyStampedClipSkipsPrepareAndUploadAndReEntersDirectlyAtTheSpoolStep()
    {
        var handler = new Handler();
        using RedirectSafeHttpClient transport = RedirectSafeHttpClient.CreateForTests(handler);
        var client = new KeboolaFilesClient(Bundle(), transport, Budgets());
        var spool = new NarrationSpool(Settings());
        string session = SessionId();
        Assert.Equal(NarrationSpoolAdmission.Staged, spool.Stage(Pending(session, 1), NarrationBytes.TinyClip()));
        string key = Assert.Single(spool.Drain()).Key;
        Assert.True(spool.TryStampFilesId(key, 999));

        var spooled = new List<PendingNarration>();
        var worker = new NarrationDeliveryWorker(client, spool, pending => { spooled.Add(pending); return true; });
        await worker.DrainOnceAsync(CancellationToken.None);

        Assert.Equal(0, spool.Status.PendingCount);
        PendingNarration emitted = Assert.Single(spooled);
        Assert.Equal(999, emitted.FilesId);
        Assert.Empty(handler.Requests);
    }

    /// <summary>§2.6 step 6: a refusal from the event spool must keep the pair staged (already
    /// stamped) rather than uploading a second time on the next pass.</summary>
    [Fact]
    public async Task AnEventSpoolRefusalKeepsTheClipStagedAndTheNextPassDoesNotReUpload()
    {
        var handler = new Handler();
        using RedirectSafeHttpClient transport = RedirectSafeHttpClient.CreateForTests(handler);
        var client = new KeboolaFilesClient(Bundle(), transport, Budgets());
        var clock = new MutableClock(DateTimeOffset.UtcNow);
        var spool = new NarrationSpool(Settings(), clock.Now);
        string session = SessionId();
        string key = SessionKeyOf(session, 1);
        Assert.Equal(NarrationSpoolAdmission.Staged, spool.Stage(Pending(session, 1), NarrationBytes.TinyClip()));
        var worker = new NarrationDeliveryWorker(client, spool, _ => false);

        await worker.DrainOnceAsync(CancellationToken.None);

        Assert.Equal(1, spool.Status.PendingCount);
        Assert.Equal(1, handler.Requests.Count(r => r.Method == HttpMethod.Put));

        // The refusal above already stamped the sidecar and called RecordRetry, scheduling a real
        // backoff delay -- advance the injected clock past it so the second pass's own Drain() call
        // actually returns this clip as due.
        clock.Advance(NarrationUploadRetryPolicy.Delay(1, key, new NarrationDeliverySettings()) + TimeSpan.FromMilliseconds(1));

        // Second pass: FilesId is already stamped, so no second prepare/upload may occur even
        // though the clip is still staged.
        var secondWorker = new NarrationDeliveryWorker(client, spool, _ => true);
        await secondWorker.DrainOnceAsync(CancellationToken.None);

        Assert.Equal(0, spool.Status.PendingCount);
        Assert.Equal(1, handler.Requests.Count(r => r.Method == HttpMethod.Put));
    }

    [Fact]
    public async Task ANullClientRetriesEveryNotYetStampedClipWithoutThrowing()
    {
        var spool = new NarrationSpool(Settings());
        string session = SessionId();
        Assert.Equal(NarrationSpoolAdmission.Staged, spool.Stage(Pending(session, 1), NarrationBytes.TinyClip()));
        var worker = new NarrationDeliveryWorker(client: null, spool, _ => true);

        await worker.DrainOnceAsync(CancellationToken.None);

        Assert.Equal(1, spool.Status.PendingCount);
        Assert.True(spool.AnyRetrying);
    }

    /// <summary>A null client must not block an already-stamped clip from still reaching the event
    /// spool -- see <see cref="NarrationDeliveryWorker"/>'s own remarks on why this differs from
    /// <c>EventDeliveryWorker</c>'s "no target, park everything" behaviour.</summary>
    [Fact]
    public async Task ANullClientStillLetsAnAlreadyStampedClipReachTheEventSpool()
    {
        var handler = new Handler();
        using RedirectSafeHttpClient transport = RedirectSafeHttpClient.CreateForTests(handler);
        var client = new KeboolaFilesClient(Bundle(), transport, Budgets());
        var spool = new NarrationSpool(Settings());
        string session = SessionId();
        Assert.Equal(NarrationSpoolAdmission.Staged, spool.Stage(Pending(session, 1), NarrationBytes.TinyClip()));
        string key = Assert.Single(spool.Drain()).Key;
        Assert.True(spool.TryStampFilesId(key, 555));

        var spooled = new List<PendingNarration>();
        var worker = new NarrationDeliveryWorker(client: null, spool, pending => { spooled.Add(pending); return true; });

        await worker.DrainOnceAsync(CancellationToken.None);

        Assert.Equal(0, spool.Status.PendingCount);
        Assert.Equal(555, Assert.Single(spooled).FilesId);
    }

    /// <summary>
    /// Regression coverage for a review finding: <see cref="NarrationSpool.Drain"/> returns clips
    /// oldest-first regardless of upload state, so an older not-yet-stamped clip that reports
    /// <see cref="NarrationDeliveryOutcome.Retrying"/> only because no client exists must not strand
    /// a newer, already-stamped clip behind it -- the already-stamped one needs no client at all to
    /// reach the event spool, and there is no wasted network attempt to avoid by halting the pass
    /// for the client-null case the way there is for a genuine network retry.
    /// </summary>
    [Fact]
    public async Task ANullClientDoesNotStrandAnAlreadyStampedClipBehindAnOlderNotYetStampedOne()
    {
        var clock = new MutableClock(DateTimeOffset.UtcNow);
        var spool = new NarrationSpool(Settings(), clock.Now);
        string session = SessionId();
        PendingNarration older = Pending(session, 1) with { StagedAt = JazzCaptureCore.Timestamps.IsoMillisUtc(clock.Now()) };
        Assert.Equal(NarrationSpoolAdmission.Staged, spool.Stage(older, NarrationBytes.TinyClip(1)));
        clock.Advance(TimeSpan.FromSeconds(1));
        PendingNarration newer = Pending(session, 2) with { StagedAt = JazzCaptureCore.Timestamps.IsoMillisUtc(clock.Now()) };
        Assert.Equal(NarrationSpoolAdmission.Staged, spool.Stage(newer, NarrationBytes.TinyClip(2)));

        var due = spool.Drain();
        Assert.Equal(2, due.Count);
        string newerKey = due[1].Key; // oldest-first: the newer clip is second.
        Assert.True(spool.TryStampFilesId(newerKey, 777));

        var spooled = new List<PendingNarration>();
        var worker = new NarrationDeliveryWorker(client: null, spool, pending => { spooled.Add(pending); return true; });

        await worker.DrainOnceAsync(CancellationToken.None);

        // The older, not-yet-stamped clip is still staged (retrying, no client) -- but the newer,
        // already-stamped one was still spooled and removed in this same pass.
        Assert.Equal(1, spool.Status.PendingCount);
        Assert.Equal(777, Assert.Single(spooled).FilesId);
    }

    /// <summary>Issue #84 §2.6: stops the whole pass at the first retryable failure -- narration
    /// clips are large and few, so a later clip must not be attempted this pass once an earlier one
    /// has already failed retryably.</summary>
    [Fact]
    public async Task APassStopsAtTheFirstRetryableFailureAndDoesNotAttemptLaterClips()
    {
        var handler = new Handler { PutStatus = HttpStatusCode.ServiceUnavailable };
        using RedirectSafeHttpClient transport = RedirectSafeHttpClient.CreateForTests(handler);
        var client = new KeboolaFilesClient(Bundle(), transport, Budgets());
        var spool = new NarrationSpool(Settings());
        string sessionA = SessionId();
        string sessionB = SessionId();
        Assert.Equal(NarrationSpoolAdmission.Staged, spool.Stage(Pending(sessionA, 1), NarrationBytes.TinyClip(1)));
        Assert.Equal(NarrationSpoolAdmission.Staged, spool.Stage(Pending(sessionB, 1), NarrationBytes.TinyClip(2)));
        var worker = new NarrationDeliveryWorker(client, spool, _ => true);

        await worker.DrainOnceAsync(CancellationToken.None);

        // Both clips are still staged (the second was never attempted this pass), but only one PUT
        // was actually issued.
        Assert.Equal(2, spool.Status.PendingCount);
        Assert.Equal(1, handler.Requests.Count(r => r.Method == HttpMethod.Put));
    }

    [Fact]
    public async Task EvictionsAndRefusalsAreReportedRegardlessOfWhetherAUsableClientExists()
    {
        var clock = new MutableClock(DateTimeOffset.UtcNow);
        var spool = new NarrationSpool(Settings(retention: TimeSpan.FromMinutes(1)), clock.Now);
        string session = SessionId();
        Assert.Equal(
            NarrationSpoolAdmission.Staged,
            spool.Stage(Pending(session, 1), NarrationBytes.TinyClip()));

        clock.Advance(TimeSpan.FromMinutes(2));
        var outcomes = new List<NarrationDeliveryOutcomeEvent>();
        var worker = new NarrationDeliveryWorker(client: null, spool, _ => true, outcomes.Add);

        await worker.DrainOnceAsync(CancellationToken.None);

        Assert.Contains(outcomes, o => o.Outcome == NarrationDeliveryOutcome.Evicted);
    }

    private string SessionId() => JazzCaptureCore.Identifiers.Prefixed("s");

    private static string SessionKeyOf(string sessionId, int sequence) =>
        sessionId + "/" + sequence.ToString("D10", System.Globalization.CultureInfo.InvariantCulture)
            + "." + Sha256Hex(NarrationBytes.TinyClip());

    private static string Sha256Hex(byte[] bytes) =>
        Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes)).ToLowerInvariant();

    private static DeviceBundle Bundle() => DeviceBundleParser.ParseMvp(
        """
        {"kind":"jazz-device-bundle","enrollmentProfile":"mvp","deviceId":"d","companyId":"c","areaId":"a","projectId":"1","stackURL":"https://connection.keboola.com","archiveIngestURL":"https://example.invalid/api/archive-ingests","token":"123-abcdefghijklmnop","tokenId":"t","expiresAt":"2099-01-01T00:00:00Z","componentAccess":[],"tokenBucketScope":"none"}
        """,
        DateTimeOffset.UtcNow);

    private static FilesCallBudgets Budgets() => new(
        PrepareBudget: TimeSpan.FromSeconds(3),
        UploadCallBudget: TimeSpan.FromSeconds(10),
        PrepareCleanupBudget: TimeSpan.FromSeconds(2));

    private NarrationDeliverySettings Settings(TimeSpan? retention = null) => new()
    {
        SpoolDirectory = root,
        SpoolByteCeiling = 512L * 1024 * 1024,
        SpoolRetention = retention ?? TimeSpan.FromHours(48),
    };

    private PendingNarration Pending(string sessionId, int sequence) => new(
        SessionId: sessionId,
        ArchiveId: "ar-test",
        CaptureId: "cap-test",
        ArtifactId: "art-test-" + sequence,
        EventId: sessionId + "-" + sequence,
        Sequence: sequence,
        Timestamp: "2026-01-01T00:00:00.000Z",
        LabelId: "lbl-1",
        Label: "Task step",
        MediaType: "audio/wav",
        Sha256: new string('0', 64),
        ByteLength: 0,
        StagedAt: JazzCaptureCore.Timestamps.IsoMillisUtc(DateTimeOffset.UtcNow),
        TraceId: "trace-1",
        SpanId: "span-1",
        SessionStartedAt: "2026-01-01T00:00:00.000Z",
        User: "user1",
        InstanceName: "machine1",
        ServiceName: "jazz-capture",
        FilesId: null);

    private sealed class MutableClock
    {
        private DateTimeOffset _now;

        public MutableClock(DateTimeOffset start) => _now = start;

        public DateTimeOffset Now() => _now;

        public void Advance(TimeSpan by) => _now += by;
    }

    private sealed class Handler : HttpMessageHandler
    {
        public string Prepare { get; set; } =
            "{\"id\":77,\"provider\":\"gcp\",\"gcsUploadParams\":{\"bucket\":\"bucket\",\"key\":\"prefix/object.wav\",\"access_token\":\"fake-federation\"}}";
        public HttpStatusCode PrepareStatus { get; set; } = HttpStatusCode.OK;
        public HttpStatusCode PutStatus { get; set; } = HttpStatusCode.OK;
        public HttpStatusCode DeleteStatus { get; set; } = HttpStatusCode.NoContent;

        public List<(HttpMethod Method, string Path)> Requests { get; } = [];

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage r, CancellationToken ct)
        {
            Requests.Add((r.Method, r.RequestUri!.AbsolutePath));

            if (r.Method == HttpMethod.Delete)
            {
                return Task.FromResult(new HttpResponseMessage(DeleteStatus));
            }

            if (r.Method == HttpMethod.Put)
            {
                return Task.FromResult(new HttpResponseMessage(PutStatus));
            }

            return Task.FromResult(
                new HttpResponseMessage(PrepareStatus) { Content = new StringContent(Prepare, Encoding.UTF8, "application/json") });
        }
    }
}
