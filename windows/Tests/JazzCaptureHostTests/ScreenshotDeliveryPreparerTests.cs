using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using JazzCapture;
using JazzCaptureCore.Archive;
using JazzCaptureCore.Delivery;
using JazzCaptureCore.Enrollment;

namespace JazzCaptureHostTests;

/// <summary>
/// <see cref="ScreenshotDeliveryPreparer"/> is the capture-path half of prepare-early screenshot
/// delivery: a synchronous <c>Func&lt;ArtifactDeliveryDescriptor, string?&gt;</c> bridging the
/// engine's synchronous seam to the async <see cref="KeboolaFilesClient.PrepareAsync"/>. These
/// tests are the contract issue #73 requires of it: it returns a Files id only when both the
/// prepare and the local stage succeeded, it returns <see langword="null"/> and stages nothing on
/// every other path (no credential, a prepare failure, a budget timeout, a staging refusal), and it
/// never throws -- including when the transport itself throws.
/// </summary>
public sealed class ScreenshotDeliveryPreparerTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), "jazz-preparer-" + Guid.NewGuid().ToString("N"));

    [Fact]
    public void NoCredentialMeansTheResultIsNullAndNothingIsStaged()
    {
        var area = new ScreenshotStagingArea(Settings());
        var preparer = new ScreenshotDeliveryPreparer(
            client: null, area, Settings(), () => { }, CancellationToken.None);

        string? result = preparer.Prepare(Descriptor());

        Assert.Null(result);
        Assert.Equal(0, area.Status.PendingCount);
    }

    [Fact]
    public void ANonScreenshotDescriptorIsIgnoredAndNothingIsStaged()
    {
        var handler = new Handler();
        using RedirectSafeHttpClient transport = RedirectSafeHttpClient.CreateForTests(handler);
        ScreenshotDeliverySettings settings = Settings();
        var client = new KeboolaFilesClient(Bundle(), transport, settings);
        var area = new ScreenshotStagingArea(settings);
        var preparer = new ScreenshotDeliveryPreparer(client, area, settings, () => { }, CancellationToken.None);

        string? result = preparer.Prepare(Descriptor(kind: "narration_clip"));

        Assert.Null(result);
        Assert.Equal(0, area.Status.PendingCount);
        Assert.Empty(handler.Requests);
    }

    [Fact]
    public void APrepareFailureYieldsNullAndStagesNothing()
    {
        var handler = new Handler { PrepareStatus = HttpStatusCode.InternalServerError };
        using RedirectSafeHttpClient transport = RedirectSafeHttpClient.CreateForTests(handler);
        ScreenshotDeliverySettings settings = Settings();
        var client = new KeboolaFilesClient(Bundle(), transport, settings);
        var area = new ScreenshotStagingArea(settings);
        var preparer = new ScreenshotDeliveryPreparer(client, area, settings, () => { }, CancellationToken.None);

        string? result = preparer.Prepare(Descriptor());

        Assert.Null(result);
        Assert.Equal(0, area.Status.PendingCount);
    }

    [Fact]
    public void APrepareBudgetTimeoutYieldsNullWithoutThrowingAndStagesNothing()
    {
        var handler = new Handler { DelayPrepareIndefinitely = true };
        using RedirectSafeHttpClient transport = RedirectSafeHttpClient.CreateForTests(handler);
        ScreenshotDeliverySettings settings = Settings(prepareBudget: TimeSpan.FromMilliseconds(30));
        var client = new KeboolaFilesClient(Bundle(), transport, settings);
        var area = new ScreenshotStagingArea(settings);
        var preparer = new ScreenshotDeliveryPreparer(client, area, settings, () => { }, CancellationToken.None);

        string? result = preparer.Prepare(Descriptor());

        Assert.Null(result);
        Assert.Equal(0, area.Status.PendingCount);
    }

    [Fact]
    public void AShutdownTokenAlreadyCancelledReturnsNullImmediatelyWithoutCallingPrepare()
    {
        var handler = new Handler();
        using RedirectSafeHttpClient transport = RedirectSafeHttpClient.CreateForTests(handler);
        ScreenshotDeliverySettings settings = Settings();
        var client = new KeboolaFilesClient(Bundle(), transport, settings);
        var area = new ScreenshotStagingArea(settings);
        using var shutdown = new CancellationTokenSource();
        shutdown.Cancel();
        var preparer = new ScreenshotDeliveryPreparer(client, area, settings, () => { }, shutdown.Token);

        string? result = preparer.Prepare(Descriptor());

        Assert.Null(result);
        Assert.Equal(0, area.Status.PendingCount);
        Assert.Empty(handler.Requests);
    }

    [Fact]
    public void ASuccessfulPrepareStagesTheBytesNudgesTheSchedulerAndReturnsTheFilesId()
    {
        var handler = new Handler();
        using RedirectSafeHttpClient transport = RedirectSafeHttpClient.CreateForTests(handler);
        ScreenshotDeliverySettings settings = Settings();
        var client = new KeboolaFilesClient(Bundle(), transport, settings);
        var area = new ScreenshotStagingArea(settings);
        int nudges = 0;
        var preparer = new ScreenshotDeliveryPreparer(client, area, settings, () => nudges++, CancellationToken.None);
        byte[] bytes = ScreenshotBytes.TinyJpeg;
        ArtifactDeliveryDescriptor descriptor = Descriptor(bytes: bytes);

        string? result = preparer.Prepare(descriptor);

        Assert.Equal("77", result);
        Assert.Equal(1, area.Status.PendingCount);
        Assert.Equal(1, nudges);
        Assert.True(area.TryReadBytes(descriptor.ArtifactId, out byte[] staged));
        Assert.Equal(bytes, staged);
    }

    [Fact]
    public void APrepareSucceedingButStagingRefusedByTheSizeBoundReturnsNull()
    {
        var handler = new Handler();
        using RedirectSafeHttpClient transport = RedirectSafeHttpClient.CreateForTests(handler);
        ScreenshotDeliverySettings clientSettings = Settings();
        var client = new KeboolaFilesClient(Bundle(), transport, clientSettings);
        // The staging area's own ceiling is smaller than the bytes this descriptor carries, so
        // Stage() must refuse it even though prepare itself succeeded.
        var area = new ScreenshotStagingArea(Settings(byteCeiling: 1));
        var preparer = new ScreenshotDeliveryPreparer(client, area, clientSettings, () => { }, CancellationToken.None);

        string? result = preparer.Prepare(Descriptor(bytes: ScreenshotBytes.TinyJpeg));

        Assert.Null(result);
        Assert.Equal(0, area.Status.PendingCount);
    }

    [Fact]
    public void APrepareCallThatThrowsFromTheTransportNeverThrowsOutOfPrepareAndStagesNothing()
    {
        var handler = new Handler { ThrowFromSend = new InvalidOperationException("synthetic transport failure") };
        using RedirectSafeHttpClient transport = RedirectSafeHttpClient.CreateForTests(handler);
        ScreenshotDeliverySettings settings = Settings();
        var client = new KeboolaFilesClient(Bundle(), transport, settings);
        var area = new ScreenshotStagingArea(settings);
        var preparer = new ScreenshotDeliveryPreparer(client, area, settings, () => { }, CancellationToken.None);

        string? result = null;
        Exception? thrown = Record.Exception(() => result = preparer.Prepare(Descriptor()));

        Assert.Null(thrown);
        Assert.Null(result);
        Assert.Equal(0, area.Status.PendingCount);
    }

    /// <summary>
    /// Defect C (#74 review): an expired Storage credential must stop new prepares. The GCS upload
    /// itself uses the short-lived federation bearer from the prepare response, not this Storage
    /// token, so only the prepare path needs this check -- the worker does not.
    /// </summary>
    [Fact]
    public void AnExpiredCredentialYieldsNullAndStagesNothing()
    {
        var handler = new Handler();
        using RedirectSafeHttpClient transport = RedirectSafeHttpClient.CreateForTests(handler);
        ScreenshotDeliverySettings settings = Settings();
        var client = new KeboolaFilesClient(Bundle(), transport, settings);
        var area = new ScreenshotStagingArea(settings);
        var expiresAt = new DateTimeOffset(2020, 1, 1, 0, 0, 0, TimeSpan.Zero);
        var clock = new MutableClock(expiresAt); // At-or-after expiry counts as expired.
        var preparer = new ScreenshotDeliveryPreparer(
            client, area, settings, () => { }, CancellationToken.None, expiresAt, clock.Now);

        string? result = preparer.Prepare(Descriptor());

        Assert.Null(result);
        Assert.Equal(0, area.Status.PendingCount);
        Assert.Empty(handler.Requests);
    }

    [Fact]
    public void ACredentialStillBeforeItsExpiryStillPreparesSuccessfully()
    {
        var handler = new Handler();
        using RedirectSafeHttpClient transport = RedirectSafeHttpClient.CreateForTests(handler);
        ScreenshotDeliverySettings settings = Settings();
        var client = new KeboolaFilesClient(Bundle(), transport, settings);
        var area = new ScreenshotStagingArea(settings);
        var expiresAt = new DateTimeOffset(2099, 1, 1, 0, 0, 0, TimeSpan.Zero);
        var clock = new MutableClock(expiresAt - TimeSpan.FromSeconds(1));
        var preparer = new ScreenshotDeliveryPreparer(
            client, area, settings, () => { }, CancellationToken.None, expiresAt, clock.Now);

        string? result = preparer.Prepare(Descriptor());

        Assert.Equal("77", result);
        Assert.Equal(1, area.Status.PendingCount);
    }

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            try { Directory.Delete(root, recursive: true); }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
        }
    }

    private ScreenshotDeliverySettings Settings(TimeSpan? prepareBudget = null, long? byteCeiling = null) => new()
    {
        StagingDirectory = root,
        PrepareBudget = prepareBudget ?? TimeSpan.FromSeconds(3),
        StagingByteCeiling = byteCeiling ?? 256L * 1024 * 1024,
    };

    private static ArtifactDeliveryDescriptor Descriptor(
        string kind = ScreenshotEvidenceV1.Kind,
        string artifactId = "art-preparer",
        byte[]? bytes = null)
    {
        byte[] payload = bytes ?? ScreenshotBytes.TinyJpeg;
        return new ArtifactDeliveryDescriptor(
            archiveId: "a",
            captureId: "c",
            sessionId: "s",
            artifactId: artifactId,
            kind: kind,
            mediaType: "image/jpeg",
            sha256: Convert.ToHexString(SHA256.HashData(payload)).ToLowerInvariant(),
            byteLength: payload.Length,
            bytes: payload);
    }

    private static DeviceBundle Bundle() => DeviceBundleParser.ParseMvp(
        """
        {"kind":"jazz-device-bundle","enrollmentProfile":"mvp","deviceId":"d","companyId":"c","areaId":"a","projectId":"1","stackURL":"https://connection.keboola.com","archiveIngestURL":"https://example.invalid/api/archive-ingests","token":"123-abcdefghijklmnop","tokenId":"t","expiresAt":"2099-01-01T00:00:00Z","componentAccess":[],"tokenBucketScope":"none"}
        """,
        DateTimeOffset.UtcNow);

    private sealed class Handler : HttpMessageHandler
    {
        public string Prepare { get; set; } =
            "{\"id\":77,\"provider\":\"gcp\",\"gcsUploadParams\":{\"bucket\":\"bucket\",\"key\":\"prefix/object.png\",\"access_token\":\"fake-federation\"}}";
        public HttpStatusCode PrepareStatus { get; set; } = HttpStatusCode.OK;
        public bool DelayPrepareIndefinitely { get; set; }
        public Exception? ThrowFromSend { get; set; }

        public List<HttpRequestMessage> Requests { get; } = [];

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage r, CancellationToken ct)
        {
            Requests.Add(r);
            if (ThrowFromSend is { } exception)
            {
                throw exception;
            }

            if (DelayPrepareIndefinitely)
            {
                await Task.Delay(Timeout.InfiniteTimeSpan, ct).ConfigureAwait(false);
            }

            return new HttpResponseMessage(PrepareStatus) { Content = new StringContent(Prepare) };
        }
    }

    private sealed class MutableClock
    {
        private DateTimeOffset _now;

        public MutableClock(DateTimeOffset start) => _now = start;

        public DateTimeOffset Now() => _now;

        public void Advance(TimeSpan by) => _now += by;
    }
}
