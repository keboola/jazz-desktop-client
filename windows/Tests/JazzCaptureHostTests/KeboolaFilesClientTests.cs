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
    private static DeviceBundle Bundle() => DeviceBundleParser.ParseMvp("""{"kind":"jazz-device-bundle","enrollmentProfile":"mvp","deviceId":"d","companyId":"c","areaId":"a","projectId":"1","stackURL":"https://connection.keboola.com","archiveIngestURL":"https://example.invalid/api/archive-ingests","token":"123-abcdefghijklmnop","tokenId":"t","expiresAt":"2099-01-01T00:00:00Z","componentAccess":[],"tokenBucketScope":"none"}""", DateTimeOffset.UtcNow);
    private sealed class Handler : HttpMessageHandler
    {
        public string Prepare { get; set; } = "{\"id\":77,\"provider\":\"gcp\",\"gcsUploadParams\":{\"bucket\":\"bucket\",\"key\":\"prefix/object.png\",\"accessToken\":\"fake-federation\"}}";
        public List<(HttpMethod Method,string Path,bool Storage,string? Authorization,string Body,byte[] Bytes)> Requests { get; } = [];
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage r, CancellationToken ct) { byte[] b = r.Content is null ? [] : await r.Content.ReadAsByteArrayAsync(ct); Requests.Add((r.Method,r.RequestUri!.AbsolutePath,r.Headers.Contains("X-StorageApi-Token"),r.Headers.Authorization?.ToString(),Encoding.UTF8.GetString(b),b)); return new(HttpStatusCode.OK) { Content = new StringContent(r.Method == HttpMethod.Post ? Prepare : "") }; }
    }
}
