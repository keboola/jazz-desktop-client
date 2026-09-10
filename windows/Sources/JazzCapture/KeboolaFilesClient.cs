using System.Net;
using System.Net.Http;
using System.IO;
using System.Text;
using System.Text.Json;
using JazzCaptureCore.Delivery;
using JazzCaptureCore.Enrollment;

namespace JazzCapture;

/// <summary>Strict legacy Storage Files prepare/GCP upload transport. Secrets live only in request memory.</summary>
public sealed class KeboolaFilesClient : IScreenshotFilesTransport
{
    private const long Max = 64 * 1024;
    private readonly HttpClient client; private readonly Uri prepare; private readonly string token;
    public KeboolaFilesClient(DeviceBundle credential, HttpClient client)
    {
        string stack = credential?.NormalizedStackUrl ?? throw new ArgumentException("Invalid Storage routing.", nameof(credential));
        if (!DeviceBundleParser.IsValidStorageToken(credential.Token)) throw new ArgumentException("Invalid Storage credential.", nameof(credential));
        prepare = new Uri(stack + "/v2/storage/files/prepare"); token = credential.Token; this.client = client ?? throw new ArgumentNullException(nameof(client));
    }
    public async Task<FilesUploadResult> UploadAsync(ArtifactDeliveryRecord record, byte[] bytes, CancellationToken ct)
    {
        if (record.ScreenshotId is null || bytes.LongLength != record.ByteLength) return FilesUploadResult.Quarantined;
        try {
            Prepared? p = await PrepareAsync(record, ct).ConfigureAwait(false); if (p is null) return FilesUploadResult.Retry;
            if (p.Provider != "gcp" || p.Gcs is null) { await DeleteAsync(p.Id, ct).ConfigureAwait(false); return FilesUploadResult.Quarantined; }
            using var put = new HttpRequestMessage(HttpMethod.Put, GcsUri(p.Gcs)) { Content = new ByteArrayContent(bytes) };
            put.Content.Headers.ContentType = new(record.MediaType);
            if (!put.Headers.TryAddWithoutValidation("Authorization", "Bearer " + p.Gcs.AccessToken)) return FilesUploadResult.Quarantined;
            using HttpResponseMessage r = await client.SendAsync(put, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false);
            if (r.IsSuccessStatusCode) return FilesUploadResult.Uploaded(p.Id);
            await DeleteAsync(p.Id, ct).ConfigureAwait(false);
            return r.StatusCode is HttpStatusCode.BadRequest or HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden ? FilesUploadResult.Quarantined : FilesUploadResult.Retry;
        } catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; } catch { return FilesUploadResult.Retry; }
    }
    /// <summary>Returns completed Files ids for one canonical artifact tag. The Storage API's tag
    /// query is broad, so all requested tags are checked again client-side before a HEAD probe.</summary>
    public async Task<(IReadOnlyList<long> Complete, IReadOnlyList<long> Dangling)> FindByArtifactAsync(string artifactId, CancellationToken ct)
    {
        try {
            Uri uri = new(prepare.GetLeftPart(UriPartial.Authority) + "/v2/storage/files?tags[]=" + Uri.EscapeDataString("artifact:" + artifactId));
            using var q = new HttpRequestMessage(HttpMethod.Get, uri); q.Headers.TryAddWithoutValidation("X-StorageApi-Token", token);
            using HttpResponseMessage r = await client.SendAsync(q, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false);
            if (!r.IsSuccessStatusCode || r.Content.Headers.ContentLength is > Max) return (Array.Empty<long>(), Array.Empty<long>());
            await using Stream s = await r.Content.ReadAsStreamAsync(ct).ConfigureAwait(false); using JsonDocument d = JsonDocument.Parse(await BoundedAsync(s, ct).ConfigureAwait(false));
            var good = new List<long>(); var bad = new List<long>();
            if (d.RootElement.ValueKind != JsonValueKind.Array) return (good, bad);
            foreach (JsonElement f in d.RootElement.EnumerateArray()) {
                if (!f.TryGetProperty("id", out var id) || !id.TryGetInt64(out long n) || n <= 0 || !f.TryGetProperty("tags", out var tags) || tags.ValueKind != JsonValueKind.Array || !tags.EnumerateArray().Any(x => x.GetString() == "artifact:" + artifactId)) continue;
                if (f.TryGetProperty("url", out var url) && Uri.TryCreate(url.GetString(), UriKind.Absolute, out Uri? u) && await ObjectExistsAsync(u, ct).ConfigureAwait(false)) good.Add(n); else bad.Add(n);
            }
            return (good, bad);
        } catch { return (Array.Empty<long>(), Array.Empty<long>()); }
    }
    public async Task DeleteDanglingAsync(IEnumerable<long> ids, CancellationToken ct) { foreach (long id in ids) await DeleteAsync(id, ct).ConfigureAwait(false); }
    private async Task<bool> ObjectExistsAsync(Uri uri, CancellationToken ct) { try { using var q = new HttpRequestMessage(HttpMethod.Head, uri); using HttpResponseMessage r = await client.SendAsync(q, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false); return r.IsSuccessStatusCode; } catch { return false; } }
    private async Task<Prepared?> PrepareAsync(ArtifactDeliveryRecord record, CancellationToken ct)
    {
        byte[] body = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new { name = record.ArtifactId, tags = new[] { "screenshot", "artifact:" + record.ArtifactId }, isPermanent = true, federationToken = true }));
        try {
            using var q = new HttpRequestMessage(HttpMethod.Post, prepare) { Content = new ByteArrayContent(body) }; q.Content.Headers.ContentType = new("application/json");
            if (!q.Headers.TryAddWithoutValidation("X-StorageApi-Token", token)) return null;
            using HttpResponseMessage r = await client.SendAsync(q, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false);
            if (!r.IsSuccessStatusCode || r.Content.Headers.ContentLength is > Max) return null;
            await using Stream s = await r.Content.ReadAsStreamAsync(ct).ConfigureAwait(false); byte[] data = await BoundedAsync(s, ct).ConfigureAwait(false);
            using JsonDocument d = JsonDocument.Parse(data); JsonElement x = d.RootElement;
            if (!x.TryGetProperty("id", out var id) || !id.TryGetInt64(out long n) || n <= 0 || !x.TryGetProperty("provider", out var provider) || provider.GetString() is not { } kind) return null;
            Gcs? gcs = null;
            if (x.TryGetProperty("gcsUploadParams", out var g) && g.ValueKind == JsonValueKind.Object && g.TryGetProperty("bucket", out var b) && g.TryGetProperty("key", out var k) && g.TryGetProperty("accessToken", out var a) && b.GetString() is { Length: > 0 } bucket && k.GetString() is { Length: > 0 } key && a.GetString() is { Length: > 0 } access) gcs = new(bucket, key, access);
            return new(n, kind, gcs);
        } finally { System.Security.Cryptography.CryptographicOperations.ZeroMemory(body); }
    }
    private async Task DeleteAsync(long id, CancellationToken ct) { try { using var q = new HttpRequestMessage(HttpMethod.Delete, new Uri(prepare, "../" + id.ToString(System.Globalization.CultureInfo.InvariantCulture))); q.Headers.TryAddWithoutValidation("X-StorageApi-Token", token); using var _ = await client.SendAsync(q, ct).ConfigureAwait(false); } catch { } }
    private static Uri GcsUri(Gcs g) { if (g.Bucket.Any(char.IsWhiteSpace) || g.Key.StartsWith('/') || g.Key.Contains("..", StringComparison.Ordinal)) throw new InvalidDataException(); return new Uri("https://storage.googleapis.com/" + Uri.EscapeDataString(g.Bucket) + "/" + string.Join("/", g.Key.Split('/').Select(Uri.EscapeDataString))); }
    private static async Task<byte[]> BoundedAsync(Stream s, CancellationToken ct) { using var o = new MemoryStream(); byte[] b = new byte[8192]; while (true) { int n = await s.ReadAsync(b, ct).ConfigureAwait(false); if (n == 0) return o.ToArray(); if (o.Length + n > Max) throw new InvalidDataException(); o.Write(b, 0, n); } }
    private sealed record Prepared(long Id, string Provider, Gcs? Gcs); private sealed record Gcs(string Bucket, string Key, string AccessToken);
}
public sealed record FilesUploadResult(long? RemoteFileId, FilesDeliveryOutcome Outcome) { public static FilesUploadResult Uploaded(long id) => new(id, FilesDeliveryOutcome.Acknowledged); public static FilesUploadResult Retry { get; } = new(null, FilesDeliveryOutcome.Retry); public static FilesUploadResult Quarantined { get; } = new(null, FilesDeliveryOutcome.Quarantined); }
public enum FilesDeliveryOutcome { Acknowledged, Retry, Quarantined }
