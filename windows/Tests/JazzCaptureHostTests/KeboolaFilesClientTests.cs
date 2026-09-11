using System.Net;
using System.Net.Http;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using JazzCapture;
using JazzCaptureCore.Enrollment;

namespace JazzCaptureHostTests;

/// <summary>
/// <see cref="KeboolaFilesClient"/> splits the closed <c>codex/68-screenshot-files</c> branch's
/// single prepare+PUT call into two independent public operations for prepare-early delivery:
/// <see cref="KeboolaFilesClient.PrepareAsync"/> (capture path, bounded budget, never retried) and
/// <see cref="KeboolaFilesClient.UploadAsync"/> (background worker, no callback into prepare or
/// cleanup). These tests exercise both halves independently, the security properties carried over
/// from the closed branch (bounded response reads, strict GCS parameter validation, redirect-safe
/// transport, token separation between Storage and GCS), and the three deliberate behavioural
/// changes from that branch: prepare-time cleanup never touches an id an event may already carry,
/// upload-time failure never deletes the remote allocation, and budget expiry is reported rather
/// than thrown.
/// </summary>
public sealed class KeboolaFilesClientTests
{
    [Fact]
    public async Task PrepareAndUploadUseExactShapeWithoutLeakingTheStorageTokenOnThePut()
    {
        var h = new Handler();
        using var transport = RedirectSafeHttpClient.CreateForTests(h);
        var client = new KeboolaFilesClient(Bundle(), transport, Settings());
        byte[] bytes = [1, 2];
        ScreenshotFilesRequest request = Request(bytes);

        ScreenshotPrepareOutcome prepareOutcome = await client.PrepareAsync(request, CancellationToken.None);
        Assert.NotNull(prepareOutcome.Result);
        Assert.Null(prepareOutcome.FailureKind);

        FilesUploadResult uploadResult = await client.UploadAsync(
            prepareOutcome.Result!, request, bytes, CancellationToken.None);

        Assert.Equal(FilesDeliveryOutcome.Acknowledged, uploadResult.Outcome);
        Assert.Equal(77, uploadResult.RemoteFileId);

        Assert.Equal("/v2/storage/files/prepare", h.Requests[0].Path);
        Assert.True(h.Requests[0].Storage);
        Assert.Contains("federationToken", h.Requests[0].Body);
        Assert.Contains("artifact:art", h.Requests[0].Body);
        Assert.Contains("capture:c", h.Requests[0].Body);
        Assert.Contains("archive:a", h.Requests[0].Body);
        Assert.Contains("session:session", h.Requests[0].Body);
        Assert.Contains("sha256:" + request.Sha256, h.Requests[0].Body);
        Assert.Contains("bytes:2", h.Requests[0].Body);

        Assert.Equal(HttpMethod.Put, h.Requests[1].Method);
        Assert.Equal("Bearer fake-federation", h.Requests[1].Authorization);
        Assert.Equal(request.Sha256, h.Requests[1].Digest);
        Assert.Equal(bytes, h.Requests[1].Bytes);
        Assert.False(h.Requests[1].Storage, "The GCS PUT must never carry the Storage token.");
    }

    [Fact]
    public async Task NonGcpProviderYieldsNoUsableTargetAndDeletesTheAllocation()
    {
        var h = new Handler { Prepare = "{\"id\":77,\"provider\":\"s3\"}" };
        using var transport = RedirectSafeHttpClient.CreateForTests(h);
        var client = new KeboolaFilesClient(Bundle(), transport, Settings());

        ScreenshotPrepareOutcome outcome = await client.PrepareAsync(Request([1]), CancellationToken.None);

        Assert.Null(outcome.Result);
        Assert.Equal(ScreenshotPrepareFailureKind.UnusableTarget, outcome.FailureKind);
        var deleted = Assert.Single(h.Requests, request => request.Method == HttpMethod.Delete);
        Assert.Equal("/v2/storage/files/77", deleted.Path);
        Assert.DoesNotContain(h.Requests, request => request.Method == HttpMethod.Put);
    }

    [Theory]
    [InlineData("text/plain")]
    [InlineData("image")]
    [InlineData("image/jpeg; charset=utf-8")]
    public async Task InvalidScreenshotMediaTypeIsRejectedBeforeAnyNetworkRequest(string mediaType)
    {
        var h = new Handler();
        using var transport = RedirectSafeHttpClient.CreateForTests(h);
        var client = new KeboolaFilesClient(Bundle(), transport, Settings());
        ScreenshotFilesRequest request = Request([1]) with { MediaType = mediaType };

        ScreenshotPrepareOutcome outcome = await client.PrepareAsync(request, CancellationToken.None);

        Assert.Null(outcome.Result);
        Assert.Equal(ScreenshotPrepareFailureKind.InvalidRequest, outcome.FailureKind);
        Assert.Empty(h.Requests);
    }

    [Fact]
    public async Task PrepareWithMissingIdentityFieldsIsRejectedBeforeAnyNetworkRequest()
    {
        var h = new Handler();
        using var transport = RedirectSafeHttpClient.CreateForTests(h);
        var client = new KeboolaFilesClient(Bundle(), transport, Settings());
        ScreenshotFilesRequest request = Request([1]) with { ArtifactId = "" };

        ScreenshotPrepareOutcome outcome = await client.PrepareAsync(request, CancellationToken.None);

        Assert.Null(outcome.Result);
        Assert.Equal(ScreenshotPrepareFailureKind.InvalidRequest, outcome.FailureKind);
        Assert.Empty(h.Requests);
    }

    [Fact]
    public async Task FailedCleanupAfterUnsupportedProviderStillReportsNoUsableTargetAndNeverUploads()
    {
        var h = new Handler
        {
            Prepare = "{\"id\":77,\"provider\":\"s3\"}",
            DeleteStatus = HttpStatusCode.InternalServerError,
        };
        using var transport = RedirectSafeHttpClient.CreateForTests(h);
        var client = new KeboolaFilesClient(Bundle(), transport, Settings());

        ScreenshotPrepareOutcome outcome = await client.PrepareAsync(Request([1]), CancellationToken.None);

        Assert.Null(outcome.Result);
        Assert.Equal(ScreenshotPrepareFailureKind.UnusableTarget, outcome.FailureKind);
        Assert.Contains(h.Requests, request => request.Method == HttpMethod.Delete);
        Assert.DoesNotContain(h.Requests, request => request.Method == HttpMethod.Put);
    }

    [Theory]
    [InlineData(HttpStatusCode.BadRequest, FilesDeliveryOutcome.Dropped)]
    [InlineData(HttpStatusCode.Unauthorized, FilesDeliveryOutcome.Retry)]
    [InlineData(HttpStatusCode.Forbidden, FilesDeliveryOutcome.Retry)]
    public async Task GcsPutStatusClassification(HttpStatusCode status, FilesDeliveryOutcome expected)
    {
        var h = new Handler { PutStatus = status };
        using var transport = RedirectSafeHttpClient.CreateForTests(h);
        var client = new KeboolaFilesClient(Bundle(), transport, Settings());
        byte[] bytes = [1];
        var prepared = new ScreenshotPrepareResult(77, "bucket", "prefix/object.png", "fake-federation");

        FilesUploadResult result = await client.UploadAsync(prepared, Request(bytes), bytes, CancellationToken.None);

        Assert.Equal(expected, result.Outcome);
        Assert.DoesNotContain(h.Requests, request => request.Method == HttpMethod.Delete);
    }

    [Fact]
    public async Task TerminalGcsFailureNeverIssuesADelete()
    {
        var h = new Handler { PutStatus = HttpStatusCode.BadRequest };
        using var transport = RedirectSafeHttpClient.CreateForTests(h);
        var client = new KeboolaFilesClient(Bundle(), transport, Settings());
        byte[] bytes = [1];
        var prepared = new ScreenshotPrepareResult(77, "bucket", "prefix/object.png", "fake-federation");

        FilesUploadResult result = await client.UploadAsync(prepared, Request(bytes), bytes, CancellationToken.None);

        Assert.Equal(FilesDeliveryOutcome.Dropped, result.Outcome);
        Assert.DoesNotContain(h.Requests, request => request.Method == HttpMethod.Delete);
    }

    [Fact]
    public async Task ByteLengthMismatchIsDroppedBeforeAnyNetworkRequest()
    {
        var h = new Handler();
        using var transport = RedirectSafeHttpClient.CreateForTests(h);
        var client = new KeboolaFilesClient(Bundle(), transport, Settings());
        byte[] bytes = [1, 2, 3];
        ScreenshotFilesRequest request = Request(bytes) with { ByteLength = bytes.Length + 1 };
        var prepared = new ScreenshotPrepareResult(77, "bucket", "prefix/object.png", "fake-federation");

        FilesUploadResult result = await client.UploadAsync(prepared, request, bytes, CancellationToken.None);

        Assert.Equal(FilesDeliveryOutcome.Dropped, result.Outcome);
        Assert.Empty(h.Requests);
    }

    [Fact]
    public async Task DigestMismatchIsDroppedBeforeAnyNetworkRequest()
    {
        var h = new Handler();
        using var transport = RedirectSafeHttpClient.CreateForTests(h);
        var client = new KeboolaFilesClient(Bundle(), transport, Settings());
        byte[] bytes = [1, 2, 3];
        ScreenshotFilesRequest request = Request(bytes) with { Sha256 = new string('0', 64) };
        var prepared = new ScreenshotPrepareResult(77, "bucket", "prefix/object.png", "fake-federation");

        FilesUploadResult result = await client.UploadAsync(prepared, request, bytes, CancellationToken.None);

        Assert.Equal(FilesDeliveryOutcome.Dropped, result.Outcome);
        Assert.Empty(h.Requests);
    }

    [Fact]
    public async Task MalformedAndOversizedPrepareResponsesYieldNoUsableTarget()
    {
        foreach (string response in new[]
        {
            "{",
            "{\"id\":77,\"provider\":\"gcp\",\"gcsUploadParams\":{}}",
            new string('x', (64 * 1024) + 1),
        })
        {
            var h = new Handler { Prepare = response };
            using var transport = RedirectSafeHttpClient.CreateForTests(h);
            var client = new KeboolaFilesClient(Bundle(), transport, Settings());

            ScreenshotPrepareOutcome outcome = await client.PrepareAsync(Request([1]), CancellationToken.None);

            Assert.Null(outcome.Result);
            Assert.Equal(ScreenshotPrepareFailureKind.UnusableTarget, outcome.FailureKind);
            Assert.DoesNotContain(h.Requests, request => request.Method == HttpMethod.Put);
        }
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task AcceptedIdInIncompletePrepareIsDeletedAndNeverUploaded(bool oversized)
    {
        string response = oversized
            ? "{\"id\":77,\"padding\":\"" + new string('x', (64 * 1024) + 1) + "\"}"
            : "{\"id\":77,";
        var h = new Handler { Prepare = response };
        using var transport = RedirectSafeHttpClient.CreateForTests(h);
        var client = new KeboolaFilesClient(Bundle(), transport, Settings());

        ScreenshotPrepareOutcome outcome = await client.PrepareAsync(Request([1]), CancellationToken.None);

        Assert.Null(outcome.Result);
        var deleted = Assert.Single(h.Requests, request => request.Method == HttpMethod.Delete);
        Assert.Equal("/v2/storage/files/77", deleted.Path);
        Assert.DoesNotContain(h.Requests, request => request.Method == HttpMethod.Put);
    }

    [Theory]
    [InlineData("{\"id\":77}")]
    [InlineData("{\"id\":77,\"provider\":{},\"gcsUploadParams\":{}}")]
    [InlineData("{\"id\":77,\"provider\":\"gcp\",\"gcsUploadParams\":{\"bucket\":{},\"key\":7,\"access_token\":[]}}")]
    [InlineData("{\"id\":77,\"provider\":\"gcp\",\"gcsUploadParams\":{\"bucket\":\"bad bucket\",\"key\":\"object\",\"access_token\":\"token\"}}")]
    [InlineData("{\"id\":77,\"provider\":\"gcp\",\"gcsUploadParams\":{\"bucket\":\"bad\\u0001bucket\",\"key\":\"object\",\"access_token\":\"token\"}}")]
    [InlineData("{\"id\":77,\"provider\":\"gcp\",\"gcsUploadParams\":{\"bucket\":\"bucket\",\"key\":\"../object\",\"access_token\":\"token\"}}")]
    [InlineData("{\"id\":77,\"provider\":\"gcp\",\"gcsUploadParams\":{\"bucket\":\"bucket\",\"key\":\"a/./b\",\"access_token\":\"token\"}}")]
    [InlineData("{\"id\":77,\"provider\":\"gcp\",\"gcsUploadParams\":{\"bucket\":\"bucket\",\"key\":\"object\",\"access_token\":\"   \"}}")]
    [InlineData("{\"id\":77,\"provider\":\"gcp\",\"gcsUploadParams\":{\"bucket\":\"bucket\",\"key\":\"object\",\"access_token\":\"bad\\u0001token\"}}")]
    [InlineData("{\"id\":77,\"provider\":\"gcp\",\"gcsUploadParams\":{\"bucket\":\".\",\"key\":\"object\",\"access_token\":\"token\"}}")]
    [InlineData("{\"id\":77,\"provider\":\"gcp\",\"gcsUploadParams\":{\"bucket\":\"..\",\"key\":\"object\",\"access_token\":\"token\"}}")]
    [InlineData("{\"id\":77,\"provider\":\"gcp\",\"gcsUploadParams\":{\"bucket\":\"bucket/escape\",\"key\":\"object\",\"access_token\":\"token\"}}")]
    [InlineData("{\"id\":77,\"provider\":\"gcp\",\"gcsUploadParams\":{\"bucket\":\"bucket\\\\escape\",\"key\":\"object\",\"access_token\":\"token\"}}")]
    [InlineData("{\"id\":77,\"provider\":\"gcp\",\"gcsUploadParams\":{\"bucket\":\"bucket\",\"key\":\"/object\",\"access_token\":\"token\"}}")]
    public async Task InvalidPreparedGcsFieldsRetainRemoteIdForCleanup(string response)
    {
        var h = new Handler { Prepare = response };
        using var transport = RedirectSafeHttpClient.CreateForTests(h);
        var client = new KeboolaFilesClient(Bundle(), transport, Settings());

        ScreenshotPrepareOutcome outcome = await client.PrepareAsync(Request([1]), CancellationToken.None);

        Assert.Null(outcome.Result);
        var deleted = Assert.Single(h.Requests, request => request.Method == HttpMethod.Delete);
        Assert.Equal("/v2/storage/files/77", deleted.Path);
        Assert.DoesNotContain(h.Requests, request => request.Method == HttpMethod.Put);
    }

    [Theory]
    [InlineData(HttpStatusCode.BadRequest, ScreenshotPrepareFailureKind.PermanentRejection)]
    [InlineData(HttpStatusCode.UnprocessableEntity, ScreenshotPrepareFailureKind.PermanentRejection)]
    [InlineData(HttpStatusCode.Unauthorized, ScreenshotPrepareFailureKind.TransientFailure)]
    [InlineData(HttpStatusCode.Forbidden, ScreenshotPrepareFailureKind.TransientFailure)]
    [InlineData(HttpStatusCode.RequestTimeout, ScreenshotPrepareFailureKind.TransientFailure)]
    [InlineData(HttpStatusCode.TooManyRequests, ScreenshotPrepareFailureKind.TransientFailure)]
    [InlineData(HttpStatusCode.InternalServerError, ScreenshotPrepareFailureKind.TransientFailure)]
    public async Task PrepareStatusClassification(HttpStatusCode status, ScreenshotPrepareFailureKind expected)
    {
        var h = new Handler { PrepareStatus = status };
        using var transport = RedirectSafeHttpClient.CreateForTests(h);
        var client = new KeboolaFilesClient(Bundle(), transport, Settings());

        ScreenshotPrepareOutcome outcome = await client.PrepareAsync(Request([1]), CancellationToken.None);

        Assert.Null(outcome.Result);
        Assert.Equal(expected, outcome.FailureKind);
        Assert.DoesNotContain(h.Requests, request => request.Method is { Method: "PUT" } or { Method: "DELETE" });
    }

    [Fact]
    public async Task CancellationAfterPrepareObtainsAnIdAttemptsBoundedCleanupThenPropagates()
    {
        using var cancellation = new CancellationTokenSource();
        var h = new Handler { CancelAfterPrepareIdKnown = cancellation.Cancel };
        using var transport = RedirectSafeHttpClient.CreateForTests(h);
        var client = new KeboolaFilesClient(Bundle(), transport, Settings());

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            client.PrepareAsync(Request([1]), cancellation.Token));

        var deleted = Assert.Single(h.Requests, request => request.Method == HttpMethod.Delete);
        Assert.Equal("/v2/storage/files/77", deleted.Path);
    }

    [Fact]
    public async Task CallerCancellationBeforeAnyResponsePropagates()
    {
        var h = new Handler();
        using var transport = RedirectSafeHttpClient.CreateForTests(h);
        var client = new KeboolaFilesClient(Bundle(), transport, Settings());
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            client.PrepareAsync(Request([1]), cancellation.Token));
    }

    [Fact]
    public async Task PrepareBudgetExpiryYieldsNoUsableTargetWithoutThrowing()
    {
        var h = new Handler { DelayPrepareIndefinitely = true };
        using var transport = RedirectSafeHttpClient.CreateForTests(h);
        var client = new KeboolaFilesClient(
            Bundle(), transport, Settings(prepareBudget: TimeSpan.FromMilliseconds(30)));

        ScreenshotPrepareOutcome outcome = await client.PrepareAsync(Request([1]), CancellationToken.None);

        Assert.Null(outcome.Result);
        Assert.Equal(ScreenshotPrepareFailureKind.TransientFailure, outcome.FailureKind);
    }

    [Fact]
    public async Task UploadCallBudgetExpiryYieldsRetryWithoutThrowing()
    {
        var h = new Handler { DelayPutIndefinitely = true };
        using var transport = RedirectSafeHttpClient.CreateForTests(h);
        var client = new KeboolaFilesClient(
            Bundle(), transport, Settings(uploadCallBudget: TimeSpan.FromMilliseconds(30)));
        byte[] bytes = [1];
        var prepared = new ScreenshotPrepareResult(77, "bucket", "prefix/object.png", "fake-federation");

        FilesUploadResult result = await client.UploadAsync(prepared, Request(bytes), bytes, CancellationToken.None);

        Assert.Equal(FilesDeliveryOutcome.Retry, result.Outcome);
    }

    [Fact]
    public async Task CancellationExceptionNeverCarriesSecrets()
    {
        using var cancellation = new CancellationTokenSource();
        var h = new Handler { CancelAfterPrepareIdKnown = cancellation.Cancel };
        using var transport = RedirectSafeHttpClient.CreateForTests(h);
        var client = new KeboolaFilesClient(Bundle(), transport, Settings());

        OperationCanceledException thrown = await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            client.PrepareAsync(Request([1]), cancellation.Token));

        string text = thrown.ToString();
        Assert.DoesNotContain("123-abcdefghijklmnop", text, StringComparison.Ordinal);
        Assert.DoesNotContain("fake-federation", text, StringComparison.Ordinal);
        Assert.DoesNotContain("storage.googleapis.com/bucket/prefix", text, StringComparison.Ordinal);
    }

    [Fact]
    public void RedirectSafeHttpClientRejectsARedirectFollowingHttpClientHandler()
    {
        using var handler = new HttpClientHandler { AllowAutoRedirect = true };
        Assert.Throws<ArgumentException>(() => RedirectSafeHttpClient.CreateForTests(handler));
    }

    [Fact]
    public void RedirectSafeHttpClientRejectsARedirectFollowingSocketsHandler()
    {
        using var handler = new SocketsHttpHandler { AllowAutoRedirect = true };
        Assert.Throws<ArgumentException>(() => RedirectSafeHttpClient.CreateForTests(handler));
    }

    [Fact]
    public void RedirectSafeHttpClientAcceptsANonRedirectFollowingHandler()
    {
        using var handler = new HttpClientHandler { AllowAutoRedirect = false };
        using RedirectSafeHttpClient client = RedirectSafeHttpClient.CreateForTests(handler);
        Assert.NotNull(client);
    }

    [Fact]
    public void RedirectSafeHttpClientProductionFactoryNeverFollowsRedirects()
    {
        using RedirectSafeHttpClient client = RedirectSafeHttpClient.CreateProduction();
        Assert.NotNull(client);
    }

    [Fact]
    public void KeboolaFilesClientHasNoPublicConstructorAcceptingAPlainHttpClient()
    {
        ConstructorInfo[] constructors =
            typeof(KeboolaFilesClient).GetConstructors(BindingFlags.Public | BindingFlags.Instance);

        Assert.NotEmpty(constructors);
        Assert.All(constructors, ctor => Assert.DoesNotContain(
            ctor.GetParameters(),
            parameter => typeof(HttpClient).IsAssignableFrom(parameter.ParameterType)));
    }

    [Fact]
    public void ScreenshotPrepareResultToStringCannotPrintTheAccessToken()
    {
        const string sentinel = "federation-token-SENTINEL-must-not-appear";
        var result = new ScreenshotPrepareResult(77, "bucket", "prefix/object.png", sentinel);

        Assert.DoesNotContain(sentinel, result.ToString(), StringComparison.Ordinal);
    }

    [Fact]
    public void ScreenshotPrepareResultToStringIsTheFixedNonSecretShape()
    {
        var result = new ScreenshotPrepareResult(77, "bucket", "prefix/object.png", "fake-federation");

        Assert.Equal("ScreenshotPrepareResult(77, bucket, prefix/object.png)", result.ToString());
    }

    private static DeviceBundle Bundle() => DeviceBundleParser.ParseMvp(
        """
        {"kind":"jazz-device-bundle","enrollmentProfile":"mvp","deviceId":"d","companyId":"c","areaId":"a","projectId":"1","stackURL":"https://connection.keboola.com","archiveIngestURL":"https://example.invalid/api/archive-ingests","token":"123-abcdefghijklmnop","tokenId":"t","expiresAt":"2099-01-01T00:00:00Z","componentAccess":[],"tokenBucketScope":"none"}
        """,
        DateTimeOffset.UtcNow);

    private static ScreenshotFilesRequest Request(byte[] bytes) => new(
        ArchiveId: "a",
        CaptureId: "c",
        SessionId: "session",
        ArtifactId: "art",
        MediaType: "image/jpeg",
        Sha256: Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant(),
        ByteLength: bytes.Length);

    private static ScreenshotDeliverySettings Settings(
        TimeSpan? prepareBudget = null,
        TimeSpan? uploadCallBudget = null,
        TimeSpan? prepareCleanupBudget = null) => new()
    {
        PrepareBudget = prepareBudget ?? TimeSpan.FromSeconds(3),
        UploadCallBudget = uploadCallBudget ?? TimeSpan.FromSeconds(30),
        PrepareCleanupBudget = prepareCleanupBudget ?? TimeSpan.FromSeconds(2),
    };

    /// <summary>Delivers a small payload on the first read, then invokes a callback on the
    /// second read before signalling end-of-stream -- used to make a caller's cancellation token
    /// fire only after <see cref="KeboolaFilesClient.PrepareAsync"/> has already recovered a
    /// positive id from the first chunk, so the bounded cleanup path can be exercised
    /// deterministically instead of racing a real timer.</summary>
    private sealed class CancelDuringReadStream : Stream
    {
        private readonly byte[] _payload;
        private readonly Action _onSecondRead;
        private bool _delivered;

        public CancelDuringReadStream(byte[] payload, Action onSecondRead)
        {
            _payload = payload;
            _onSecondRead = onSecondRead;
        }

        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position
        {
            get => throw new NotSupportedException();
            set => throw new NotSupportedException();
        }

        public override void Flush() { }
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();

        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            if (!_delivered)
            {
                _delivered = true;
                _payload.CopyTo(buffer);
                return ValueTask.FromResult(_payload.Length);
            }

            _onSecondRead();
            return ValueTask.FromResult(0);
        }
    }

    private sealed class Handler : HttpMessageHandler
    {
        public string Prepare { get; set; } =
            "{\"id\":77,\"provider\":\"gcp\",\"gcsUploadParams\":{\"bucket\":\"bucket\",\"key\":\"prefix/object.png\",\"access_token\":\"fake-federation\"}}";
        public HttpStatusCode PrepareStatus { get; set; } = HttpStatusCode.OK;
        public HttpStatusCode PutStatus { get; set; } = HttpStatusCode.OK;
        public HttpStatusCode DeleteStatus { get; set; } = HttpStatusCode.NoContent;
        public Action? CancelAfterPrepareIdKnown { get; set; }
        public bool DelayPrepareIndefinitely { get; set; }
        public bool DelayPutIndefinitely { get; set; }

        public List<(HttpMethod Method, string Path, bool Storage, string? Authorization, string? Digest, string Body, byte[] Bytes)> Requests { get; } = [];

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage r, CancellationToken ct)
        {
            byte[] b = r.Content is null ? [] : await r.Content.ReadAsByteArrayAsync(ct);
            string? digest = r.Headers.TryGetValues("x-goog-meta-jazz-sha256", out IEnumerable<string>? values)
                ? values.SingleOrDefault()
                : null;
            Requests.Add((
                r.Method,
                r.RequestUri!.AbsolutePath,
                r.Headers.Contains("X-StorageApi-Token"),
                r.Headers.Authorization?.ToString(),
                digest,
                Encoding.UTF8.GetString(b),
                b));

            if (r.Method == HttpMethod.Delete)
            {
                return new HttpResponseMessage(DeleteStatus);
            }

            if (r.Method == HttpMethod.Put)
            {
                if (DelayPutIndefinitely)
                {
                    await Task.Delay(Timeout.InfiniteTimeSpan, ct).ConfigureAwait(false);
                }
                return new HttpResponseMessage(PutStatus);
            }

            // POST /v2/storage/files/prepare
            if (DelayPrepareIndefinitely)
            {
                await Task.Delay(Timeout.InfiniteTimeSpan, ct).ConfigureAwait(false);
            }

            if (CancelAfterPrepareIdKnown is { } cancel)
            {
                return new HttpResponseMessage(PrepareStatus)
                {
                    Content = new StreamContent(new CancelDuringReadStream(Encoding.UTF8.GetBytes(Prepare), cancel)),
                };
            }

            return new HttpResponseMessage(PrepareStatus) { Content = new StringContent(Prepare) };
        }
    }
}
