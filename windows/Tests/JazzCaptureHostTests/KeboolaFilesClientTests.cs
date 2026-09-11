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

    /// <summary>
    /// Regression coverage for Finding 2 (#74 review, ninth pass). The oversized-response, the
    /// malformed-response and the unusable-target (non-<c>gcp</c>/rejected <c>gcsUploadParams</c>)
    /// pre-emission cleanups used to issue their <c>DELETE</c> under <c>timeout.Token</c> -- the
    /// linked token enforcing <see cref="ScreenshotDeliverySettings.PrepareBudget"/> -- rather than
    /// the independently bounded <see cref="ScreenshotDeliverySettings.PrepareCleanupBudget"/>, so a
    /// slow endpoint could let the cleanup DELETE consume whatever was left of the far larger
    /// prepare budget instead of its own, much smaller, ceiling.
    /// </summary>
    /// <remarks>
    /// This cannot assert the exact <see cref="CancellationToken"/> instance a private method used
    /// (the fake handler only observes cancellation as "the call eventually threw or returned"), so
    /// instead it proves the *bound* changed: the DELETE never responds
    /// (<see cref="Handler.DelayDeleteIndefinitely"/>), <see cref="ScreenshotDeliverySettings.PrepareCleanupBudget"/>
    /// is set far shorter than <see cref="ScreenshotDeliverySettings.PrepareBudget"/>, and the whole
    /// <see cref="KeboolaFilesClient.PrepareAsync"/> call is timed. Before this fix, the DELETE was
    /// bound only by whatever remained of the linked prepare-budget token, so this call would have
    /// taken close to the full (generous) <c>PrepareBudget</c> to give up; after this fix, it must
    /// return close to the much shorter <c>PrepareCleanupBudget</c> instead, which this pins with a
    /// margin wide enough not to flake on a loaded CI machine while still being far short of
    /// <c>PrepareBudget</c>.
    /// </remarks>
    [Theory]
    [InlineData("{\"id\":77,\"padding\":\"REPLACED_WITH_OVERSIZED_PADDING\"}")] // oversized (line ~283)
    [InlineData("{\"id\":77,")] // malformed/truncated JSON (line ~299)
    [InlineData("{\"id\":77,\"provider\":\"s3\"}")] // unusable target: non-gcp (line ~323)
    public async Task PreEmissionCleanupDeletesRunUnderTheCleanupBudgetNotWhateverIsLeftOfThePrepareBudget(
        string response)
    {
        if (response.Contains("REPLACED_WITH_OVERSIZED_PADDING", StringComparison.Ordinal))
        {
            response = "{\"id\":77,\"padding\":\"" + new string('x', (64 * 1024) + 1) + "\"}";
        }

        // The two budgets are set far apart, and the assertion sits between them rather than close
        // to either. The earlier version used a 5s budget and a 2s threshold, which put the pass
        // mark within reach of a cold runner's one-off startup cost -- the HTTP stack, the timers
        // and the JIT for this path are all paid by whichever theory case happens to run first --
        // and it duly failed twice on CI at ~2.9s while the other cases in the same run passed. The
        // point of the test is not that the cleanup is fast, it is that the cleanup is *not* bound
        // by PrepareBudget, so the threshold only has to separate "gave up on its own budget" from
        // "ran to the prepare budget", and can be generous about everything else.
        TimeSpan prepareBudget = TimeSpan.FromSeconds(30);
        var h = new Handler { Prepare = response, DelayDeleteIndefinitely = true };
        using var transport = RedirectSafeHttpClient.CreateForTests(h);
        var client = new KeboolaFilesClient(
            Bundle(),
            transport,
            Settings(
                prepareBudget: prepareBudget,
                prepareCleanupBudget: TimeSpan.FromMilliseconds(50)));

        var stopwatch = System.Diagnostics.Stopwatch.StartNew();
        ScreenshotPrepareOutcome outcome = await client.PrepareAsync(Request([1]), CancellationToken.None);
        stopwatch.Stop();

        Assert.Null(outcome.Result);
        Assert.Equal(ScreenshotPrepareFailureKind.UnusableTarget, outcome.FailureKind);
        Assert.Contains(h.Requests, request => request.Method == HttpMethod.Delete);
        Assert.DoesNotContain(h.Requests, request => request.Method == HttpMethod.Put);

        TimeSpan threshold = prepareBudget / 3;
        Assert.True(
            stopwatch.Elapsed < threshold,
            $"Expected the cleanup DELETE to give up on its own 50ms PrepareCleanupBudget rather "
                + $"than running to the {prepareBudget} PrepareBudget; the call took "
                + $"{stopwatch.Elapsed}, past the {threshold} mark that separates the two.");
    }

    /// <summary>
    /// Regression coverage for Finding 1 (#74 review, tenth pass). The pre-emission branches above
    /// clean up and then call <c>cancellationToken.ThrowIfCancellationRequested</c>, so a caller
    /// that cancelled during the response read landed in <c>PrepareAsync</c>'s cancellation handler
    /// with the pending id still set -- and that handler issued the very same DELETE a second time.
    /// Against a stalled endpoint that doubled the bound the single cleanup is supposed to have
    /// (twice <see cref="ScreenshotDeliverySettings.PrepareCleanupBudget"/> rather than once). This
    /// counts the DELETEs rather than timing them, so it pins the duplicate itself rather than the
    /// delay it happens to cost. The oversized branch is covered by the timing theory above rather
    /// than here: its payload exceeds the read buffer this fake stream delivers in one go.
    /// </summary>
    [Theory]
    [InlineData("{\"id\":77,")] // malformed/truncated JSON
    [InlineData("{\"id\":77,\"provider\":\"s3\"}")] // unusable target: non-gcp
    public async Task CancellationRightAfterAPreEmissionCleanupDoesNotRepeatTheSameDelete(string response)
    {
        using var cancellation = new CancellationTokenSource();
        var h = new Handler { Prepare = response, CancelAfterPrepareIdKnown = cancellation.Cancel };
        using var transport = RedirectSafeHttpClient.CreateForTests(h);
        var client = new KeboolaFilesClient(Bundle(), transport, Settings());

        // The branch itself cleans up and then propagates the caller's cancellation, so the call
        // still throws exactly as it did before -- only the second, duplicate DELETE is gone.
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            client.PrepareAsync(Request([1]), cancellation.Token));

        var deleted = Assert.Single(h.Requests, request => request.Method == HttpMethod.Delete);
        Assert.Equal("/v2/storage/files/77", deleted.Path);
    }

    /// <summary>
    /// Regression coverage for Finding 1 (#74 review, twelfth pass). The bucket checks rejected
    /// separators, whitespace and control characters -- injection safety -- but accepted names GCS
    /// can never resolve, so the allocation looked usable, its Files id went out on an event, the
    /// bytes were staged, and the PUT then failed against a bucket that could not exist. Such a
    /// name must instead take the existing pre-emission path for a target this client can never
    /// upload to: the allocation deleted, <see cref="ScreenshotPrepareFailureKind.UnusableTarget"/>
    /// returned, and no id ever stamped on an event.
    /// </summary>
    [Theory]
    [InlineData("ab")] // shorter than the 3-character minimum
    [InlineData("Bucket")] // uppercase is not permitted
    [InlineData("buck?et")] // escaped by GcsUri rather than injected, but still unresolvable
    [InlineData("-bucket")] // must start with a letter or digit
    [InlineData("bucket-")] // must end with a letter or digit
    [InlineData("bucket..name")] // empty dot-separated component
    [InlineData("192.168.5.4")] // dotted-decimal IPv4 notation
    public async Task AMalformedGcsBucketNameIsAnUnusableTargetAndIsCleanedUpBeforeAnyEvent(string bucket)
    {
        var h = new Handler
        {
            Prepare = "{\"id\":77,\"provider\":\"gcp\",\"gcsUploadParams\":{\"bucket\":\""
                + bucket
                + "\",\"key\":\"prefix/object.png\",\"access_token\":\"fake-federation\"}}",
        };
        using var transport = RedirectSafeHttpClient.CreateForTests(h);
        var client = new KeboolaFilesClient(Bundle(), transport, Settings());

        ScreenshotPrepareOutcome outcome = await client.PrepareAsync(Request([1]), CancellationToken.None);

        Assert.Null(outcome.Result);
        Assert.Equal(ScreenshotPrepareFailureKind.UnusableTarget, outcome.FailureKind);
        var deleted = Assert.Single(h.Requests, request => request.Method == HttpMethod.Delete);
        Assert.Equal("/v2/storage/files/77", deleted.Path);
        Assert.DoesNotContain(h.Requests, request => request.Method == HttpMethod.Put);
    }

    /// <summary>
    /// The other half of the check above, and the more important one to pin: refusing a bucket
    /// Storage really did allocate would silently stop screenshot delivery altogether, which is far
    /// worse than the single dangling id the check exists to avoid. These are all legal GCS bucket
    /// names and must still produce a usable target.
    /// </summary>
    [Theory]
    [InlineData("abc")] // the 3-character minimum
    [InlineData("a-b_c.d")] // hyphens, underscores and dots are all permitted
    [InlineData("1bucket2")] // a digit at either edge is permitted
    [InlineData("my.bucket.example.com")] // dot-separated domain-named bucket
    [InlineData("kbc-eu-central-1-files-1234567890")] // the shape Keboola Storage actually returns
    [InlineData("aaaaaaaaaabbbbbbbbbbccccccccccddddddddddeeeeeeeeeeffffffffffggg")] // 63 characters
    public async Task ALegalGcsBucketNameIsStillAccepted(string bucket)
    {
        var h = new Handler
        {
            Prepare = "{\"id\":77,\"provider\":\"gcp\",\"gcsUploadParams\":{\"bucket\":\""
                + bucket
                + "\",\"key\":\"prefix/object.png\",\"access_token\":\"fake-federation\"}}",
        };
        using var transport = RedirectSafeHttpClient.CreateForTests(h);
        var client = new KeboolaFilesClient(Bundle(), transport, Settings());

        ScreenshotPrepareOutcome outcome = await client.PrepareAsync(Request([1]), CancellationToken.None);

        Assert.NotNull(outcome.Result);
        Assert.Equal(bucket, outcome.Result!.Bucket);
        Assert.Null(outcome.FailureKind);
        Assert.DoesNotContain(h.Requests, request => request.Method == HttpMethod.Delete);
    }

    /// <summary>
    /// The same class of problem as the bucket names above, on the object name: a key GCS can never
    /// accept -- one carrying a control character, or longer than the 1024-byte limit -- would have
    /// been staged and then failed at the PUT. Raised alongside Finding 1 (#74 review, twelfth
    /// pass) rather than by it.
    /// </summary>
    [Theory]
    [InlineData("prefix/\\u0001object.png")] // a control character in the object name
    [InlineData("LONG")] // 1025 characters, over the 1024-byte limit
    public async Task AnUnacceptableGcsObjectNameIsAnUnusableTargetToo(string keyJson)
    {
        if (keyJson == "LONG")
        {
            keyJson = new string('k', 1025);
        }

        var h = new Handler
        {
            Prepare = "{\"id\":77,\"provider\":\"gcp\",\"gcsUploadParams\":{\"bucket\":\"bucket\",\"key\":\""
                + keyJson
                + "\",\"access_token\":\"fake-federation\"}}",
        };
        using var transport = RedirectSafeHttpClient.CreateForTests(h);
        var client = new KeboolaFilesClient(Bundle(), transport, Settings());

        ScreenshotPrepareOutcome outcome = await client.PrepareAsync(Request([1]), CancellationToken.None);

        Assert.Null(outcome.Result);
        Assert.Equal(ScreenshotPrepareFailureKind.UnusableTarget, outcome.FailureKind);
        Assert.Single(h.Requests, request => request.Method == HttpMethod.Delete);
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

    /// <summary>
    /// Regression coverage for Finding 3 (#74 review). The test above,
    /// <see cref="CancellationAfterPrepareObtainsAnIdAttemptsBoundedCleanupThenPropagates"/>,
    /// cancels only after <c>ReadPreparedBoundedAsync</c> has already returned normally; this test
    /// cancels while a read is still in flight, after an earlier chunk has already delivered the
    /// id, so the reader itself throws instead of returning. The id must still make it to the
    /// cleanup path.
    /// </summary>
    [Fact]
    public async Task CancellationDuringResponseReadAfterIdObservedStillDeletesTheAllocation()
    {
        using var cancellation = new CancellationTokenSource();
        var h = new Handler();
        h.PrepareContentStreamFactory = () =>
            new CancelMidReadStream(Encoding.UTF8.GetBytes(h.Prepare), cancellation);
        using var transport = RedirectSafeHttpClient.CreateForTests(h);
        var client = new KeboolaFilesClient(Bundle(), transport, Settings());

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            client.PrepareAsync(Request([1]), cancellation.Token));

        var deleted = Assert.Single(h.Requests, request => request.Method == HttpMethod.Delete);
        Assert.Equal("/v2/storage/files/77", deleted.Path);
    }

    /// <summary>
    /// Regression coverage for Finding 2 (#74 review, third pass). The previous pass fixed caller
    /// cancellation mid-read (<see cref="CancellationDuringResponseReadAfterIdObservedStillDeletesTheAllocation"/>)
    /// but left its budget-expiry twin unguarded: the catch clause for the prepare budget itself
    /// elapsing returned a transient failure without ever consulting <c>acceptedIdPendingCleanup</c>,
    /// so an id observed moments before the budget elapsed mid-read leaked permanently. This uses a
    /// very short prepare budget and a stream that delivers the id on its first read, then blocks on
    /// the exact linked token the budget timeout cancels -- so the second read throws
    /// <see cref="OperationCanceledException"/> because the budget elapsed, not because the caller
    /// cancelled, and is deterministic because the interleaving point is that token firing, not a
    /// race against a real clock.
    /// </summary>
    [Fact]
    public async Task PrepareBudgetExpiryDuringResponseReadAfterIdObservedDeletesTheAllocation()
    {
        var h = new Handler();
        h.PrepareContentStreamFactory = () =>
            new IdObservedThenBudgetExpiresDuringReadStream(Encoding.UTF8.GetBytes(h.Prepare));
        using var transport = RedirectSafeHttpClient.CreateForTests(h);
        var client = new KeboolaFilesClient(
            Bundle(), transport, Settings(prepareBudget: TimeSpan.FromMilliseconds(30)));

        ScreenshotPrepareOutcome outcome = await client.PrepareAsync(Request([1]), CancellationToken.None);

        Assert.Null(outcome.Result);
        Assert.Equal(ScreenshotPrepareFailureKind.TransientFailure, outcome.FailureKind);
        var deleted = Assert.Single(h.Requests, request => request.Method == HttpMethod.Delete);
        Assert.Equal("/v2/storage/files/77", deleted.Path);
        Assert.DoesNotContain(h.Requests, request => request.Method == HttpMethod.Put);
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

    /// <summary>
    /// Regression coverage for Finding 4 (#74 review): the pre-return check used to examine only
    /// the caller's own token, so a budget that elapsed strictly after the response body had
    /// already been fully read could still be reported as a successful prepare. The response here
    /// arrives whole, but only after a delay long enough for the (very short) prepare budget to
    /// have already elapsed by the time it does.
    /// </summary>
    [Fact]
    public async Task PrepareBudgetElapsedAfterBodyReadYieldsNoUsableTargetAndDeletesTheAllocation()
    {
        var h = new Handler();
        h.PrepareContentStreamFactory = () =>
            new SlowThenExhaustedStream(Encoding.UTF8.GetBytes(h.Prepare), TimeSpan.FromMilliseconds(60));
        using var transport = RedirectSafeHttpClient.CreateForTests(h);
        var client = new KeboolaFilesClient(
            Bundle(), transport, Settings(prepareBudget: TimeSpan.FromMilliseconds(15)));

        ScreenshotPrepareOutcome outcome = await client.PrepareAsync(Request([1]), CancellationToken.None);

        Assert.Null(outcome.Result);
        Assert.Equal(ScreenshotPrepareFailureKind.TransientFailure, outcome.FailureKind);
        var deleted = Assert.Single(h.Requests, request => request.Method == HttpMethod.Delete);
        Assert.Equal("/v2/storage/files/77", deleted.Path);
        Assert.DoesNotContain(h.Requests, request => request.Method == HttpMethod.Put);
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

    /// <summary>
    /// Regression coverage for Finding 1 (#74 review, fourteenth pass): the wrapped
    /// <see cref="HttpClient"/> kept its built-in 100-second timeout, a second deadline appearing in
    /// no setting and no document, which would silently cut short any configured
    /// <see cref="ScreenshotDeliverySettings.PrepareBudget"/> or
    /// <see cref="ScreenshotDeliverySettings.UploadCallBudget"/> above 100 seconds --
    /// durations <c>Validate</c> accepts and reports as valid. Both factories must leave the
    /// per-operation cancellation tokens as the sole bound, so this covers each of them rather than
    /// only the one the rest of this suite happens to use.
    /// </summary>
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void RedirectSafeHttpClientLeavesTheConfiguredBudgetsAsTheOnlyDeadline(bool production)
    {
        using var handler = new HttpClientHandler { AllowAutoRedirect = false };
        using RedirectSafeHttpClient client = production
            ? RedirectSafeHttpClient.CreateProduction()
            : RedirectSafeHttpClient.CreateForTests(handler);

        FieldInfo field = typeof(RedirectSafeHttpClient).GetField(
            "_client",
            BindingFlags.Instance | BindingFlags.NonPublic)
            ?? throw new InvalidOperationException("RedirectSafeHttpClient no longer has a _client field.");
        var wrapped = (HttpClient)field.GetValue(client)!;

        Assert.Equal(Timeout.InfiniteTimeSpan, wrapped.Timeout);
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

    /// <summary>Delivers a payload containing a top-level <c>id</c> on the first read, then, on
    /// the second read, cancels <paramref name="cancelOnSecondRead"/> and throws using the token
    /// <see cref="KeboolaFilesClient.PrepareAsync"/> itself passed in -- simulating a real stream
    /// whose in-flight read is interrupted by cancellation, as opposed to
    /// <see cref="CancelDuringReadStream"/>, which merely signals end-of-stream after the caller's
    /// token has already been cancelled. This is what exercises Finding 3 (#74 review): the id
    /// must survive the reader throwing, not just the reader returning normally after
    /// cancellation.</summary>
    private sealed class CancelMidReadStream : Stream
    {
        private readonly byte[] _payload;
        private readonly CancellationTokenSource _cancelOnSecondRead;
        private bool _delivered;

        public CancelMidReadStream(byte[] payload, CancellationTokenSource cancelOnSecondRead)
        {
            _payload = payload;
            _cancelOnSecondRead = cancelOnSecondRead;
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

            _cancelOnSecondRead.Cancel();
            cancellationToken.ThrowIfCancellationRequested();
            return ValueTask.FromResult(0);
        }
    }

    /// <summary>Delivers the full payload on its first read, but only after a real (short) delay
    /// that deliberately does not observe the passed cancellation token -- simulating bytes
    /// already in flight on the wire when the prepare budget elapses, which a real network stream
    /// would not necessarily surface as a cancelled read. This is what exercises Finding 4 (#74
    /// review): a budget that elapses strictly after the body has been fully read must still
    /// yield no usable target.</summary>
    private sealed class SlowThenExhaustedStream : Stream
    {
        private readonly byte[] _payload;
        private readonly TimeSpan _delay;
        private bool _delivered;

        public SlowThenExhaustedStream(byte[] payload, TimeSpan delay)
        {
            _payload = payload;
            _delay = delay;
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

        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            if (!_delivered)
            {
                _delivered = true;
                await Task.Delay(_delay).ConfigureAwait(false);
                _payload.CopyTo(buffer);
                return _payload.Length;
            }

            return 0;
        }
    }

    /// <summary>Delivers a payload containing a top-level <c>id</c> on the first read, then, on the
    /// second read, waits on the very token <see cref="KeboolaFilesClient.PrepareAsync"/>'s own
    /// linked prepare-budget timeout will cancel -- simulating bytes already in flight on the wire
    /// when the budget elapses mid-read. Unlike <see cref="SlowThenExhaustedStream"/> (which never
    /// observes the token and lets <c>PrepareAsync</c>'s own post-read check discover an
    /// already-elapsed budget) this makes the read itself throw <see cref="OperationCanceledException"/>
    /// from the budget's own <see cref="CancellationTokenSource"/> firing -- exercising Finding 2
    /// (#74 review, third pass): the id must survive that throw, not just a caller cancelling or a
    /// budget noticed only after a full read completed normally.</summary>
    private sealed class IdObservedThenBudgetExpiresDuringReadStream : Stream
    {
        private readonly byte[] _payload;
        private bool _delivered;

        public IdObservedThenBudgetExpiresDuringReadStream(byte[] payload) => _payload = payload;

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

        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            if (!_delivered)
            {
                _delivered = true;
                _payload.CopyTo(buffer);
                return _payload.Length;
            }

            // Waits on the caller's own token -- PrepareAsync's linked prepare-budget timeout --
            // rather than a fixed delay, so this fires exactly when the budget elapses instead of
            // racing a real clock against it.
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken).ConfigureAwait(false);
            return 0;
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
        public bool DelayDeleteIndefinitely { get; set; }
        public Func<Stream>? PrepareContentStreamFactory { get; set; }

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
                if (DelayDeleteIndefinitely)
                {
                    await Task.Delay(Timeout.InfiniteTimeSpan, ct).ConfigureAwait(false);
                }
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

            if (PrepareContentStreamFactory is { } factory)
            {
                return new HttpResponseMessage(PrepareStatus) { Content = new StreamContent(factory()) };
            }

            return new HttpResponseMessage(PrepareStatus) { Content = new StringContent(Prepare) };
        }
    }
}
