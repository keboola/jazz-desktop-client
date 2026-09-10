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
        byte[] bytes = [1, 2]; var record = new ArtifactDeliveryRecord("a", "c", "art-1", "art-1", "image/jpeg", Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes)).ToLowerInvariant(), 2);
        FilesUploadResult result = await new KeboolaFilesClient(Bundle(), http).UploadAsync(record, bytes, CancellationToken.None);
        Assert.Equal(FilesDeliveryOutcome.Acknowledged, result.Outcome); Assert.Equal(77, result.RemoteFileId);
        Assert.Equal("/v2/storage/files/prepare", h.Requests[0].Path); Assert.True(h.Requests[0].Storage); Assert.Contains("federationToken", h.Requests[0].Body); Assert.Contains("artifact:art-1", h.Requests[0].Body);
        Assert.Equal(HttpMethod.Put, h.Requests[1].Method); Assert.Equal("Bearer fake-federation", h.Requests[1].Authorization); Assert.Equal(bytes, h.Requests[1].Bytes);
        Assert.DoesNotContain("123-abcdefghijklmnop", result.ToString());
    }
    [Fact]
    public async Task UnsupportedOrMalformedPrepareIsSafeAndDoesNotUpload()
    {
        var h = new Handler { Prepare = "{\"id\":77,\"provider\":\"s3\"}" }; using var http = new HttpClient(h); byte[] bytes = [1];
        FilesUploadResult result = await new KeboolaFilesClient(Bundle(), http).UploadAsync(new("a", "c", "art", "art", "image/jpeg", Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes)).ToLowerInvariant(), 1), bytes, CancellationToken.None);
        Assert.Equal(FilesDeliveryOutcome.Quarantined, result.Outcome); Assert.DoesNotContain(h.Requests, x => x.Method == HttpMethod.Put);
    }

    [Fact]
    public async Task LookupRequiresBothTagsAndOnlyTreatsNotFoundAsDangling()
    {
        var h = new Handler
        {
            List = """
                [
                  {"id":40,"tags":["artifact:art"],"url":"https://storage.googleapis.com/bucket/missing-kind"},
                  {"id":41,"tags":["screenshot","artifact:other"],"url":"https://storage.googleapis.com/bucket/wrong-artifact"},
                  {"id":42,"tags":["screenshot","artifact:art"],"url":"https://storage.googleapis.com/bucket/complete"}
                ]
                """
        };
        using var http = new HttpClient(h);

        ScreenshotFileLookupResult result = await new KeboolaFilesClient(Bundle(), http)
            .FindByArtifactAsync("art", CancellationToken.None);

        Assert.Equal(ScreenshotFileLookupOutcome.Ready, result.Outcome);
        Assert.Equal(new long[] { 42 }, result.Complete);
        Assert.Empty(result.Dangling);
        Assert.Single(h.Requests, request => request.Method == HttpMethod.Head);
        Assert.True(Assert.Single(h.Requests, request => request.Method == HttpMethod.Get).Storage);
    }

    [Fact]
    public async Task ServerErrorDuringObjectProbeRetriesWithoutDeleting()
    {
        var h = new Handler
        {
            List = """[{"id":42,"tags":["screenshot","artifact:art"],"url":"https://storage.googleapis.com/bucket/object"}]""",
            HeadStatus = HttpStatusCode.InternalServerError,
        };
        using var http = new HttpClient(h);

        ScreenshotFileLookupResult result = await new KeboolaFilesClient(Bundle(), http)
            .FindByArtifactAsync("art", CancellationToken.None);

        Assert.Equal(ScreenshotFileLookupOutcome.Retry, result.Outcome);
        Assert.DoesNotContain(h.Requests, request => request.Method is { Method: "DELETE" } or { Method: "POST" });
    }

    [Fact]
    public async Task NotFoundObjectIsDeletedBeforeItCanBeReprepared()
    {
        var h = new Handler
        {
            List = """[{"id":42,"tags":["screenshot","artifact:art"],"url":"https://storage.googleapis.com/bucket/object"}]""",
            HeadStatus = HttpStatusCode.NotFound,
        };
        using var http = new HttpClient(h);
        var client = new KeboolaFilesClient(Bundle(), http);

        ScreenshotFileLookupResult result = await client.FindByArtifactAsync("art", CancellationToken.None);
        Assert.Equal(new long[] { 42 }, result.Dangling);
        Assert.True(await client.DeleteDanglingAsync(result.Dangling, CancellationToken.None));

        var deleted = Assert.Single(h.Requests, request => request.Method == HttpMethod.Delete);
        Assert.Equal("/v2/storage/files/42", deleted.Path);
        Assert.True(deleted.Storage);
    }
    private static DeviceBundle Bundle() => DeviceBundleParser.ParseMvp("""{"kind":"jazz-device-bundle","enrollmentProfile":"mvp","deviceId":"d","companyId":"c","areaId":"a","projectId":"1","stackURL":"https://connection.keboola.com","archiveIngestURL":"https://example.invalid/api/archive-ingests","token":"123-abcdefghijklmnop","tokenId":"t","expiresAt":"2099-01-01T00:00:00Z","componentAccess":[],"tokenBucketScope":"none"}""", DateTimeOffset.UtcNow);
    private sealed class Handler : HttpMessageHandler
    {
        public string Prepare { get; set; } = "{\"id\":77,\"provider\":\"gcp\",\"gcsUploadParams\":{\"bucket\":\"bucket\",\"key\":\"prefix/object.png\",\"access_token\":\"fake-federation\"}}";
        public string List { get; set; } = "[]";
        public HttpStatusCode HeadStatus { get; set; } = HttpStatusCode.OK;
        public HttpStatusCode DeleteStatus { get; set; } = HttpStatusCode.NoContent;
        public List<(HttpMethod Method,string Path,bool Storage,string? Authorization,string Body,byte[] Bytes)> Requests { get; } = [];
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage r, CancellationToken ct)
        {
            byte[] b = r.Content is null ? [] : await r.Content.ReadAsByteArrayAsync(ct);
            Requests.Add((r.Method, r.RequestUri!.AbsolutePath, r.Headers.Contains("X-StorageApi-Token"), r.Headers.Authorization?.ToString(), Encoding.UTF8.GetString(b), b));
            if (r.Method == HttpMethod.Get) return new(HttpStatusCode.OK) { Content = new StringContent(List) };
            if (r.Method == HttpMethod.Head) return new(HeadStatus);
            if (r.Method == HttpMethod.Delete) return new(DeleteStatus);
            return new(HttpStatusCode.OK) { Content = new StringContent(r.Method == HttpMethod.Post ? Prepare : "") };
        }
    }
}
