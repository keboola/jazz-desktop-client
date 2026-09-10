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
                  {"id":42,"tags":["screenshot","artifact:art","sha256:{{record.Sha256}}","bytes:1"],"url":"https://storage.googleapis.com/bucket/complete"}
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
    }

    [Fact]
    public async Task ServerErrorDuringObjectProbeRetriesWithoutDeleting()
    {
        ArtifactDeliveryRecord record = Record([1]);
        var h = new Handler
        {
            List = $$"""[{"id":42,"tags":["screenshot","artifact:art","sha256:{{record.Sha256}}","bytes:1"],"url":"https://storage.googleapis.com/bucket/object"}]""",
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
            List = $$"""[{"id":"not-a-number","tags":["screenshot","artifact:art","sha256:{{record.Sha256}}","bytes:1"]}]""",
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
            List = $$"""[{"id":42,"tags":["screenshot","artifact:art","sha256:{{record.Sha256}}","bytes:1"],"url":"https://storage.googleapis.com/bucket/object"}]""",
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
            List = """[{"id":42,"tags":["screenshot","artifact:art","sha256:0000000000000000000000000000000000000000000000000000000000000000","bytes:1"],"url":"https://storage.googleapis.com/bucket/object"}]""",
        };
        using var http = new HttpClient(h);

        ScreenshotFileLookupResult result = await new KeboolaFilesClient(Bundle(), http)
            .FindByArtifactAsync(Record([1]), CancellationToken.None);

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
            List = $$"""[{"id":42,"tags":["screenshot","artifact:art","sha256:{{record.Sha256}}","bytes:1"],"url":"https://storage.googleapis.com/bucket/object"}]""",
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
        public HttpStatusCode HeadStatus { get; set; } = HttpStatusCode.OK;
        public HttpStatusCode DeleteStatus { get; set; } = HttpStatusCode.NoContent;
        public HttpStatusCode PutStatus { get; set; } = HttpStatusCode.OK;
        public long HeadLength { get; set; } = 1;
        public string? HeadDigest { get; set; } = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData([1])).ToLowerInvariant();
        public List<(HttpMethod Method, string Path, bool Storage, string? Authorization, string? Digest, string Body, byte[] Bytes)> Requests { get; } = [];
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage r, CancellationToken ct)
        {
            byte[] b = r.Content is null ? [] : await r.Content.ReadAsByteArrayAsync(ct);
            string? digest = r.Headers.TryGetValues("x-goog-meta-jazz-sha256", out IEnumerable<string>? values) ? values.SingleOrDefault() : null;
            Requests.Add((r.Method, r.RequestUri!.AbsolutePath, r.Headers.Contains("X-StorageApi-Token"), r.Headers.Authorization?.ToString(), digest, Encoding.UTF8.GetString(b), b));
            if (r.Method == HttpMethod.Get) return new(HttpStatusCode.OK) { Content = new StringContent(List) };
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
            if (r.Method == HttpMethod.Put) return new(PutStatus);
            return new(HttpStatusCode.OK) { Content = new StringContent(r.Method == HttpMethod.Post ? Prepare : "") };
        }
    }
}
