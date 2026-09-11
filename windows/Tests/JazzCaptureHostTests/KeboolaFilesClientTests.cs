using System.Net;
using System.Text;
using JazzCapture;
using JazzCaptureCore.Delivery;
using JazzCaptureCore.Enrollment;

namespace JazzCaptureHostTests;

public sealed class KeboolaFilesClientTests
{
    [Fact]
    public async Task PrepareAndGcsPutUseExactLegacyShapeWithoutLeakingSecrets()
    {
        var h = new Handler(); using var http = new HttpClient(h);
        byte[] bytes = [1, 2]; var record = new ArtifactDeliveryRecord("a", "c", "art-1", "art-1", "image/jpeg", Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes)).ToLowerInvariant(), 2)
        {
            CanonicalEvent = new JazzCaptureCore.ActivityEvent { SessionId = "session-1", EventId = "event-1" },
            Context = new JazzCaptureCore.SessionContext("session-1", new string('a', 32), new string('b', 16), "2026-01-01T00:00:00Z", null, "u", "h", null, null),
        };
        FilesUploadResult result = await new KeboolaFilesClient(Bundle(), http).UploadAsync(record, bytes, CancellationToken.None);
        Assert.Equal(FilesDeliveryOutcome.Acknowledged, result.Outcome); Assert.Equal(77, result.RemoteFileId);
        Assert.Equal("/v2/storage/files/prepare", h.Requests[0].Path); Assert.True(h.Requests[0].Storage); Assert.Contains("federationToken", h.Requests[0].Body); Assert.Contains("artifact:art-1", h.Requests[0].Body); Assert.Contains("capture:c", h.Requests[0].Body); Assert.Contains("archive:a", h.Requests[0].Body); Assert.Contains("session:session-1", h.Requests[0].Body);
        Assert.Contains("sha256:" + record.Sha256, h.Requests[0].Body); Assert.Contains("bytes:2", h.Requests[0].Body);
        Assert.Equal(HttpMethod.Put, h.Requests[1].Method); Assert.Equal("Bearer fake-federation", h.Requests[1].Authorization); Assert.Equal(record.Sha256, h.Requests[1].Digest); Assert.Equal(bytes, h.Requests[1].Bytes);
        Assert.DoesNotContain("123-abcdefghijklmnop", result.ToString());
    }
    [Fact]
    public async Task UnsupportedOrMalformedPrepareIsSafeAndDoesNotUpload()
    {
        var h = new Handler { Prepare = "{\"id\":77,\"provider\":\"s3\"}" }; using var http = new HttpClient(h); byte[] bytes = [1];
        FilesUploadResult result = await new KeboolaFilesClient(Bundle(), http).UploadAsync(Record(bytes), bytes, CancellationToken.None);
        Assert.Equal(FilesDeliveryOutcome.Quarantined, result.Outcome); Assert.DoesNotContain(h.Requests, x => x.Method == HttpMethod.Put);
    }

    [Theory]
    [InlineData("text/plain")]
    [InlineData("image")]
    [InlineData("image/jpeg; charset=utf-8")]
    public async Task InvalidScreenshotMediaTypeIsQuarantinedBeforeAnyNetworkRequest(string mediaType)
    {
        var h = new Handler();
        using var http = new HttpClient(h);
        byte[] bytes = [1];

        FilesUploadResult result = await new KeboolaFilesClient(Bundle(), http).UploadAsync(
            Record(bytes) with { MediaType = mediaType }, bytes, CancellationToken.None);

        Assert.Equal(FilesDeliveryOutcome.Quarantined, result.Outcome);
        Assert.Empty(h.Requests);
    }
    [Fact]
    public async Task FailedCleanupAfterUnsupportedProviderRemainsRetryable()
    {
        var h = new Handler { Prepare = "{\"id\":77,\"provider\":\"s3\"}", DeleteStatus = HttpStatusCode.InternalServerError }; using var http = new HttpClient(h); byte[] bytes = [1];
        FilesUploadResult result = await new KeboolaFilesClient(Bundle(), http).UploadAsync(Record(bytes),bytes,CancellationToken.None);
        Assert.Equal(FilesDeliveryOutcome.Retry,result.Outcome); Assert.DoesNotContain(h.Requests,x=>x.Method==HttpMethod.Put); Assert.Contains(h.Requests,x=>x.Method==HttpMethod.Delete);
    }
    [Fact]
    public async Task FailedCleanupAfterUploadFailureRemainsRetryable()
    {
        var h = new Handler { PutStatus = HttpStatusCode.InternalServerError, DeleteStatus = HttpStatusCode.InternalServerError }; using var http = new HttpClient(h); byte[] bytes = [1];
        FilesUploadResult result = await new KeboolaFilesClient(Bundle(), http).UploadAsync(Record(bytes),bytes,CancellationToken.None);
        Assert.Equal(FilesDeliveryOutcome.Retry,result.Outcome); Assert.Contains(h.Requests,x=>x.Method==HttpMethod.Delete);
    }

    [Theory]
    [InlineData(HttpStatusCode.BadRequest, FilesDeliveryOutcome.Quarantined)]
    [InlineData(HttpStatusCode.Unauthorized, FilesDeliveryOutcome.Retry)]
    [InlineData(HttpStatusCode.Forbidden, FilesDeliveryOutcome.Retry)]
    public async Task GcsAuthorizationFailuresRemainRetryable(
        HttpStatusCode status,
        FilesDeliveryOutcome expected)
    {
        var h = new Handler { PutStatus = status }; using var http = new HttpClient(h); byte[] bytes = [1];
        FilesUploadResult result = await new KeboolaFilesClient(Bundle(), http)
            .UploadAsync(Record(bytes), bytes, CancellationToken.None);
        Assert.Equal(expected, result.Outcome);
    }

    [Fact]
    public async Task LookupRequiresBothTagsAndOnlyTreatsNotFoundAsDangling()
    {
        ArtifactDeliveryRecord record = Record([1]);
        var h = new Handler
        {
            List = $$"""
                [
                  {"id":40,"tags":["artifact:art"],"url":"https://storage.googleapis.com/bucket/missing-kind"},
                  {"id":41,"tags":["screenshot","artifact:other"],"url":"https://storage.googleapis.com/bucket/wrong-artifact"},
                  {"id":42,"tags":["screenshot","artifact:art","archive:a","capture:c","session:session","sha256:{{record.Sha256}}","bytes:1"],"url":"https://storage.googleapis.com/bucket/complete"}
                ]
                """
        };
        using var http = new HttpClient(h);

        ScreenshotFileLookupResult result = await new KeboolaFilesClient(Bundle(), http)
            .FindByArtifactAsync(record, CancellationToken.None);

        Assert.Equal(ScreenshotFileLookupOutcome.Ready, result.Outcome);
        Assert.Equal(new long[] { 42 }, result.Complete);
        Assert.Empty(result.Dangling);
        Assert.Single(h.Requests, request => request.Method == HttpMethod.Head);
        Assert.True(Assert.Single(h.Requests, request => request.Method == HttpMethod.Get).Storage);
        Assert.Contains("limit=100", h.LastQuery, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ServerErrorDuringObjectProbeRetriesWithoutDeleting()
    {
        ArtifactDeliveryRecord record = Record([1]);
        var h = new Handler
        {
            List = $$"""[{"id":42,"tags":["screenshot","artifact:art","archive:a","capture:c","session:session","sha256:{{record.Sha256}}","bytes:1"],"url":"https://storage.googleapis.com/bucket/object"}]""",
            HeadStatus = HttpStatusCode.InternalServerError,
        };
        using var http = new HttpClient(h);

        ScreenshotFileLookupResult result = await new KeboolaFilesClient(Bundle(), http)
            .FindByArtifactAsync(record, CancellationToken.None);

        Assert.Equal(ScreenshotFileLookupOutcome.Retry, result.Outcome);
        Assert.DoesNotContain(h.Requests, request => request.Method is { Method: "DELETE" } or { Method: "POST" });
    }

    [Fact]
    public async Task MalformedMatchingFileIdRetriesWithoutProbing()
    {
        ArtifactDeliveryRecord record = Record([1]);
        var h = new Handler
        {
            List = $$"""[{"id":"not-a-number","tags":["screenshot","artifact:art","archive:a","capture:c","session:session","sha256:{{record.Sha256}}","bytes:1"]}]""",
        };
        using var http = new HttpClient(h);

        ScreenshotFileLookupResult result = await new KeboolaFilesClient(Bundle(), http)
            .FindByArtifactAsync(record, CancellationToken.None);

        Assert.Equal(ScreenshotFileLookupOutcome.Retry, result.Outcome);
        Assert.DoesNotContain(h.Requests, request => request.Method == HttpMethod.Head);
    }

    [Fact]
    public async Task NotFoundObjectIsDeletedBeforeItCanBeReprepared()
    {
        ArtifactDeliveryRecord record = Record([1]);
        var h = new Handler
        {
            List = $$"""[{"id":42,"tags":["screenshot","artifact:art","archive:a","capture:c","session:session","sha256:{{record.Sha256}}","bytes:1"],"url":"https://storage.googleapis.com/bucket/object"}]""",
            HeadStatus = HttpStatusCode.NotFound,
        };
        using var http = new HttpClient(h);
        var client = new KeboolaFilesClient(Bundle(), http);

        ScreenshotFileLookupResult result = await client.FindByArtifactAsync(record, CancellationToken.None);
        Assert.Equal(new long[] { 42 }, result.Dangling);
        Assert.True(await client.DeleteDanglingAsync(result.Dangling, CancellationToken.None));

        var deleted = Assert.Single(h.Requests, request => request.Method == HttpMethod.Delete);
        Assert.Equal("/v2/storage/files/42", deleted.Path);
        Assert.True(deleted.Storage);
    }

    [Fact]
    public async Task MatchingAllocationWithoutSafeObjectUrlIsReturnedForCleanup()
    {
        ArtifactDeliveryRecord record = Record([1]);
        var h = new Handler
        {
            List = $$"""[{"id":42,"tags":["screenshot","artifact:art","archive:a","capture:c","session:session","sha256:{{record.Sha256}}","bytes:1"]}]""",
        };
        using var http = new HttpClient(h);

        ScreenshotFileLookupResult result = await new KeboolaFilesClient(Bundle(), http)
            .FindByArtifactAsync(record, CancellationToken.None);

        Assert.Equal(ScreenshotFileLookupOutcome.Ready, result.Outcome);
        Assert.Empty(result.Complete);
        Assert.Equal(new long[] { 42 }, result.Dangling);
        Assert.DoesNotContain(h.Requests, request => request.Method == HttpMethod.Head);
    }

    [Fact]
    public async Task CancellationAfterPrepareAttemptsBoundedCleanupThenPropagates()
    {
        using var cancellation = new CancellationTokenSource();
        var h = new Handler { CancelPut = cancellation.Cancel };
        using var http = new HttpClient(h);

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            new KeboolaFilesClient(Bundle(), http).UploadAsync(Record([1]), [1], cancellation.Token));

        Assert.Contains(h.Requests, request => request.Method == HttpMethod.Put);
        Assert.Contains(h.Requests, request => request.Method == HttpMethod.Delete
            && request.Path == "/v2/storage/files/77");
    }

    [Fact]
    public async Task MatchingArtifactWithoutImmutableIdentityRetriesWithoutProbe()
    {
        var h = new Handler
        {
            List = """[{"id":42,"tags":["screenshot","artifact:art"],"url":"https://storage.googleapis.com/bucket/object"}]""",
        };
        using var http = new HttpClient(h);

        ScreenshotFileLookupResult result = await new KeboolaFilesClient(Bundle(), http)
            .FindByArtifactAsync(Record([1]), CancellationToken.None);

        Assert.Equal(ScreenshotFileLookupOutcome.Retry, result.Outcome);
        Assert.DoesNotContain(h.Requests, request => request.Method == HttpMethod.Head);
    }

    [Fact]
    public async Task ConflictingImmutableIdentityIsQuarantinedWithoutProbe()
    {
        var h = new Handler
        {
            List = """[{"id":42,"tags":["screenshot","artifact:art","archive:a","capture:c","session:session","sha256:0000000000000000000000000000000000000000000000000000000000000000","bytes:1"],"url":"https://storage.googleapis.com/bucket/object"}]""",
        };
        using var http = new HttpClient(h);

        ScreenshotFileLookupResult result = await new KeboolaFilesClient(Bundle(), http)
            .FindByArtifactAsync(Record([1]), CancellationToken.None);

        Assert.Equal(ScreenshotFileLookupOutcome.Quarantined, result.Outcome);
        Assert.DoesNotContain(h.Requests, request => request.Method == HttpMethod.Head);
    }

    [Fact]
    public async Task MultipleArtifactTagsAreQuarantinedWithoutProbe()
    {
        ArtifactDeliveryRecord record = Record([1]);
        var h = new Handler
        {
            List = $$"""[{"id":42,"tags":["screenshot","artifact:art","artifact:other","archive:a","capture:c","session:session","sha256:{{record.Sha256}}","bytes:1"],"url":"https://storage.googleapis.com/bucket/object"}]""",
        };
        using var http = new HttpClient(h);

        ScreenshotFileLookupResult result = await new KeboolaFilesClient(Bundle(), http)
            .FindByArtifactAsync(record, CancellationToken.None);

        Assert.Equal(ScreenshotFileLookupOutcome.Quarantined, result.Outcome);
        Assert.DoesNotContain(h.Requests, request => request.Method == HttpMethod.Head);
    }

    [Theory]
    [InlineData("archive:other")]
    [InlineData("capture:other")]
    [InlineData("session:other")]
    public async Task ConflictingTraceIdentityIsQuarantinedWithoutProbe(string conflictingTag)
    {
        ArtifactDeliveryRecord record = Record([1]);
        string[] tags =
        [
            "screenshot", "artifact:art", "archive:a", "capture:c", "session:session",
            "sha256:" + record.Sha256, "bytes:1",
        ];
        string prefix = conflictingTag[..(conflictingTag.IndexOf(':') + 1)];
        tags = tags.Select(tag => tag.StartsWith(prefix, StringComparison.Ordinal)
            ? conflictingTag : tag).ToArray();
        var h = new Handler
        {
            List = "[{\"id\":42,\"tags\":[" + string.Join(',', tags.Select(tag => "\"" + tag + "\""))
                + "],\"url\":\"https://storage.googleapis.com/bucket/object\"}]",
        };
        using var http = new HttpClient(h);

        ScreenshotFileLookupResult result = await new KeboolaFilesClient(Bundle(), http)
            .FindByArtifactAsync(record, CancellationToken.None);

        Assert.Equal(ScreenshotFileLookupOutcome.Quarantined, result.Outcome);
        Assert.DoesNotContain(h.Requests, request => request.Method == HttpMethod.Head);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task RemoteObjectMustMatchExactLengthAndDigest(bool mismatchLength)
    {
        ArtifactDeliveryRecord record = Record([1]);
        var h = new Handler
        {
            List = $$"""[{"id":42,"tags":["screenshot","artifact:art","archive:a","capture:c","session:session","sha256:{{record.Sha256}}","bytes:1"],"url":"https://storage.googleapis.com/bucket/object"}]""",
            HeadLength = mismatchLength ? 2 : 1,
            HeadDigest = mismatchLength ? record.Sha256 : new string('0', 64),
        };
        using var http = new HttpClient(h);

        ScreenshotFileLookupResult result = await new KeboolaFilesClient(Bundle(), http)
            .FindByArtifactAsync(record, CancellationToken.None);

        Assert.Equal(ScreenshotFileLookupOutcome.Quarantined, result.Outcome);
        Assert.Empty(result.Complete);
    }

    [Fact]
    public async Task MalformedAndOversizedPrepareResponsesNeverReachObjectStorage()
    {
        foreach (string response in new[]
        {
            "{",
            "{\"id\":77,\"provider\":\"gcp\",\"gcsUploadParams\":{}}",
            new string('x', (64 * 1024) + 1),
        })
        {
            var h = new Handler { Prepare = response };
            using var http = new HttpClient(h);
            byte[] bytes = [1];
            var record = new ArtifactDeliveryRecord(
                "a", "c", "art", "art", "image/jpeg",
                Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes)).ToLowerInvariant(),
                bytes.Length);

            FilesUploadResult result = await new KeboolaFilesClient(Bundle(), http)
                .UploadAsync(record, bytes, CancellationToken.None);

            Assert.Contains(result.Outcome, new[]
            {
                FilesDeliveryOutcome.Retry,
                FilesDeliveryOutcome.Quarantined,
            });
            Assert.DoesNotContain(h.Requests, request => request.Method == HttpMethod.Put);
        }
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task AcceptedIdInIncompletePrepareIsDeletedWithoutUploading(bool oversized)
    {
        string response = oversized
            ? "{\"id\":77,\"padding\":\"" + new string('x', (64 * 1024) + 1) + "\"}"
            : "{\"id\":77,";
        var h = new Handler { Prepare = response };
        using var http = new HttpClient(h);

        FilesUploadResult result = await new KeboolaFilesClient(Bundle(), http)
            .UploadAsync(Record([1]), [1], CancellationToken.None);

        Assert.Equal(FilesDeliveryOutcome.Quarantined, result.Outcome);
        var deleted = Assert.Single(h.Requests, request => request.Method == HttpMethod.Delete);
        Assert.Equal("/v2/storage/files/77", deleted.Path);
        Assert.DoesNotContain(h.Requests, request => request.Method == HttpMethod.Put);
    }

    [Fact]
    public async Task OversizedPrepareWithoutIdIsRecoveredByNextTaggedLookup()
    {
        ArtifactDeliveryRecord record = Record([1]);
        var h = new Handler
        {
            Prepare = "{\"padding\":\"" + new string('x', (64 * 1024) + 1) + "\"}",
        };
        using var http = new HttpClient(h);
        var client = new KeboolaFilesClient(Bundle(), http);

        Assert.Equal(FilesDeliveryOutcome.Retry,
            (await client.UploadAsync(record, [1], CancellationToken.None)).Outcome);

        h.List = $$"""[{"id":77,"tags":["screenshot","artifact:art","archive:a","capture:c","session:session","sha256:{{record.Sha256}}","bytes:1"]}]""";
        ScreenshotFileLookupResult recovered = await client.FindByArtifactAsync(record, CancellationToken.None);

        Assert.Equal(ScreenshotFileLookupOutcome.Ready, recovered.Outcome);
        Assert.Equal(new long[] { 77 }, recovered.Dangling);
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
    public async Task InvalidPreparedFieldsRetainRemoteIdForCleanup(string response)
    {
        var h = new Handler { Prepare = response };
        using var http = new HttpClient(h);
        byte[] bytes = [1];

        FilesUploadResult result = await new KeboolaFilesClient(Bundle(), http)
            .UploadAsync(Record(bytes), bytes, CancellationToken.None);

        Assert.Equal(FilesDeliveryOutcome.Quarantined, result.Outcome);
        var deleted = Assert.Single(h.Requests, request => request.Method == HttpMethod.Delete);
        Assert.Equal("/v2/storage/files/77", deleted.Path);
        Assert.DoesNotContain(h.Requests, request => request.Method == HttpMethod.Put);
    }

    [Fact]
    public async Task MalformedAndOversizedListsRetryWithoutProbingOrDeleting()
    {
        foreach (string response in new[] { "{", new string('x', (64 * 1024) + 1) })
        {
            var h = new Handler { List = response };
            using var http = new HttpClient(h);

            ScreenshotFileLookupResult result = await new KeboolaFilesClient(Bundle(), http)
                .FindByArtifactAsync(Record([1]), CancellationToken.None);

            Assert.Equal(ScreenshotFileLookupOutcome.Retry, result.Outcome);
            Assert.DoesNotContain(h.Requests, request =>
                request.Method == HttpMethod.Head || request.Method == HttpMethod.Delete);
        }
    }

    [Fact]
    public async Task FullLookupPageWithoutConclusiveCandidateRetriesWithoutPrepare()
    {
        string list = "[" + string.Join(',', Enumerable.Range(1, 100)
            .Select(id => "{\"id\":" + id + ",\"tags\":[\"unrelated\"]}")) + "]";
        var h = new Handler { List = list };
        using var http = new HttpClient(h);

        ScreenshotFileLookupResult result = await new KeboolaFilesClient(Bundle(), http)
            .FindByArtifactAsync(Record([1]), CancellationToken.None);

        Assert.Equal(ScreenshotFileLookupOutcome.Retry, result.Outcome);
        Assert.Contains("limit=100", h.LastQuery, StringComparison.Ordinal);
        Assert.Equal(10, h.Queries.Count);
        Assert.Contains("offset=900", h.LastQuery, StringComparison.Ordinal);
        Assert.DoesNotContain(h.Requests, request => request.Method == HttpMethod.Post);
    }

    [Fact]
    public async Task FullLookupPageWithVerifiedCompleteCandidateIsConclusive()
    {
        ArtifactDeliveryRecord record = Record([1]);
        string unrelated = string.Join(',', Enumerable.Range(1, 99)
            .Select(id => "{\"id\":" + id + ",\"tags\":[\"unrelated\"]}"));
        var h = new Handler
        {
            ListsByOffset = new()
            {
                [0] = "[" + unrelated + ",{\"id\":777,\"tags\":[\"screenshot\",\"artifact:art\",\"archive:a\",\"capture:c\",\"session:session\",\"sha256:" + record.Sha256 + "\",\"bytes:1\"],\"url\":\"https://storage.googleapis.com/bucket/object\"}]",
                [100] = "[]",
            },
        };
        using var http = new HttpClient(h);

        ScreenshotFileLookupResult result = await new KeboolaFilesClient(Bundle(), http)
            .FindByArtifactAsync(record, CancellationToken.None);

        Assert.Equal(ScreenshotFileLookupOutcome.Ready, result.Outcome);
        Assert.Equal(new long[] { 777 }, result.Complete);
        Assert.Equal(2, h.Queries.Count);
        Assert.Contains("offset=0", h.Queries[0], StringComparison.Ordinal);
        Assert.Contains("offset=100", h.Queries[1], StringComparison.Ordinal);
    }

    [Fact]
    public async Task MatchingFileOnSecondLookupPageIsCorrelated()
    {
        ArtifactDeliveryRecord record = Record([1]);
        string first = "[" + string.Join(',', Enumerable.Range(1, 100)
            .Select(id => "{\"id\":" + id + ",\"tags\":[\"unrelated\"]}")) + "]";
        string second = "[{\"id\":777,\"tags\":[\"screenshot\",\"artifact:art\",\"archive:a\",\"capture:c\",\"session:session\",\"sha256:"
            + record.Sha256 + "\",\"bytes:1\"],\"url\":\"https://storage.googleapis.com/bucket/object\"}]";
        var h = new Handler { ListsByOffset = new() { [0] = first, [100] = second } };
        using var http = new HttpClient(h);

        ScreenshotFileLookupResult result = await new KeboolaFilesClient(Bundle(), http)
            .FindByArtifactAsync(record, CancellationToken.None);

        Assert.Equal(ScreenshotFileLookupOutcome.Ready, result.Outcome);
        Assert.Equal(new long[] { 777 }, result.Complete);
        Assert.Equal(2, h.Queries.Count);
    }

    [Fact]
    public async Task CallerCancellationPropagatesWithoutASecondRequest()
    {
        var h = new Handler();
        using var http = new HttpClient(h);
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            new KeboolaFilesClient(Bundle(), http)
                .FindByArtifactAsync(Record([1]), cancellation.Token));
        Assert.Single(h.Requests);
        Assert.Equal(HttpMethod.Get, h.Requests[0].Method);
    }

    [Theory]
    [InlineData(HttpStatusCode.BadRequest, FilesDeliveryOutcome.Quarantined)]
    [InlineData(HttpStatusCode.UnprocessableEntity, FilesDeliveryOutcome.Quarantined)]
    [InlineData(HttpStatusCode.Unauthorized, FilesDeliveryOutcome.Retry)]
    [InlineData(HttpStatusCode.Forbidden, FilesDeliveryOutcome.Retry)]
    [InlineData(HttpStatusCode.RequestTimeout, FilesDeliveryOutcome.Retry)]
    [InlineData(HttpStatusCode.TooManyRequests, FilesDeliveryOutcome.Retry)]
    [InlineData(HttpStatusCode.InternalServerError, FilesDeliveryOutcome.Retry)]
    public async Task PrepareFailureClassifiesPermanentAndTransientResponses(HttpStatusCode status, FilesDeliveryOutcome expected)
    {
        var h = new Handler { PrepareStatus = status }; using var http = new HttpClient(h);
        FilesUploadResult result = await new KeboolaFilesClient(Bundle(), http).UploadAsync(Record([1]), [1], CancellationToken.None);
        Assert.Equal(expected, result.Outcome);
        Assert.DoesNotContain(h.Requests, request => request.Method is { Method: "PUT" } or { Method: "DELETE" });
    }
    private static DeviceBundle Bundle() => DeviceBundleParser.ParseMvp("""{"kind":"jazz-device-bundle","enrollmentProfile":"mvp","deviceId":"d","companyId":"c","areaId":"a","projectId":"1","stackURL":"https://connection.keboola.com","archiveIngestURL":"https://example.invalid/api/archive-ingests","token":"123-abcdefghijklmnop","tokenId":"t","expiresAt":"2099-01-01T00:00:00Z","componentAccess":[],"tokenBucketScope":"none"}""", DateTimeOffset.UtcNow);
    private static ArtifactDeliveryRecord Record(byte[] bytes) => new(
        "a", "c", "art", "art", "image/jpeg",
        Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes)).ToLowerInvariant(), bytes.Length)
    {
        CanonicalEvent = new JazzCaptureCore.ActivityEvent { SessionId = "session", EventId = "event" },
        Context = new JazzCaptureCore.SessionContext("session", new string('a', 32), new string('b', 16), "2026-01-01T00:00:00Z", null, "u", "h", null, null),
    };
    private sealed class Handler : HttpMessageHandler
    {
        public string Prepare { get; set; } = "{\"id\":77,\"provider\":\"gcp\",\"gcsUploadParams\":{\"bucket\":\"bucket\",\"key\":\"prefix/object.png\",\"access_token\":\"fake-federation\"}}";
        public string List { get; set; } = "[]";
        public Dictionary<int, string>? ListsByOffset { get; set; }
        public HttpStatusCode HeadStatus { get; set; } = HttpStatusCode.OK;
        public HttpStatusCode DeleteStatus { get; set; } = HttpStatusCode.NoContent;
        public HttpStatusCode PutStatus { get; set; } = HttpStatusCode.OK;
        public HttpStatusCode PrepareStatus { get; set; } = HttpStatusCode.OK;
        public Action? CancelPut { get; set; }
        public long HeadLength { get; set; } = 1;
        public string? HeadDigest { get; set; } = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData([1])).ToLowerInvariant();
        public string? LastQuery { get; private set; }
        public List<string> Queries { get; } = [];
        public List<(HttpMethod Method, string Path, bool Storage, string? Authorization, string? Digest, string Body, byte[] Bytes)> Requests { get; } = [];
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage r, CancellationToken ct)
        {
            byte[] b = r.Content is null ? [] : await r.Content.ReadAsByteArrayAsync(ct);
            string? digest = r.Headers.TryGetValues("x-goog-meta-jazz-sha256", out IEnumerable<string>? values) ? values.SingleOrDefault() : null;
            Requests.Add((r.Method, r.RequestUri!.AbsolutePath, r.Headers.Contains("X-StorageApi-Token"), r.Headers.Authorization?.ToString(), digest, Encoding.UTF8.GetString(b), b));
            if (r.Method == HttpMethod.Get)
            {
                LastQuery = r.RequestUri.Query;
                Queries.Add(LastQuery);
                int offset = LastQuery.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries)
                    .Select(part => part.Split('=', 2))
                    .Where(parts => parts.Length == 2 && parts[0] == "offset")
                    .Select(parts => int.TryParse(parts[1], out int value) ? value : 0)
                    .SingleOrDefault();
                string list = ListsByOffset is not null && ListsByOffset.TryGetValue(offset, out string? page)
                    ? page
                    : List;
                return new(HttpStatusCode.OK) { Content = new StringContent(list) };
            }
            if (r.Method == HttpMethod.Head)
            {
                var response = new HttpResponseMessage(HeadStatus)
                {
                    Content = new ByteArrayContent(new byte[HeadLength]),
                };
                if (HeadDigest is not null) response.Headers.TryAddWithoutValidation("x-goog-meta-jazz-sha256", HeadDigest);
                return response;
            }
            if (r.Method == HttpMethod.Delete) return new(DeleteStatus);
            if (r.Method == HttpMethod.Put)
            {
                CancelPut?.Invoke();
                ct.ThrowIfCancellationRequested();
                return new(PutStatus);
            }
            return new(r.Method == HttpMethod.Post ? PrepareStatus : HttpStatusCode.OK) { Content = new StringContent(r.Method == HttpMethod.Post ? Prepare : "") };
        }
    }
}
