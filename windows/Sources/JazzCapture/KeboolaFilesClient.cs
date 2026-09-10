using System.IO;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using JazzCaptureCore.Delivery;
using JazzCaptureCore.Enrollment;

namespace JazzCapture;

/// <summary>Strict legacy Storage Files prepare/GCP upload transport. Credentials remain in managed
/// memory for the client/request lifetime only and are never persisted or logged.</summary>
public sealed class KeboolaFilesClient : IScreenshotFilesTransport
{
    private const long MaxResponseBytes = 64 * 1024;
    private readonly HttpClient _client;
    private readonly Uri _prepareEndpoint;
    private readonly string _token;

    public KeboolaFilesClient(DeviceBundle credential, HttpClient client)
    {
        string stack = credential?.NormalizedStackUrl
            ?? throw new ArgumentException("Invalid Storage routing.", nameof(credential));
        if (!DeviceBundleParser.IsValidStorageToken(credential.Token))
        {
            throw new ArgumentException("Invalid Storage credential.", nameof(credential));
        }

        _prepareEndpoint = new Uri(stack + "/v2/storage/files/prepare");
        _token = credential.Token;
        _client = client ?? throw new ArgumentNullException(nameof(client));
    }

    public async Task<FilesUploadResult> UploadAsync(
        ArtifactDeliveryRecord record,
        byte[] bytes,
        CancellationToken cancellationToken)
    {
        if (record.ScreenshotId is null
            || record.CanonicalEvent is not { SessionId: { Length: > 0 }, EventId: { Length: > 0 } }
            || record.Context?.SessionId != record.CanonicalEvent.SessionId
            || bytes.LongLength != record.ByteLength
            || !string.Equals(
                Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes))
                    .ToLowerInvariant(),
                record.Sha256,
                StringComparison.Ordinal))
        {
            return FilesUploadResult.Quarantined;
        }

        PreparedFile? prepared = null;
        try
        {
            prepared = await PrepareAsync(record, cancellationToken)
                .ConfigureAwait(false);
            if (prepared is null)
            {
                return FilesUploadResult.Retry;
            }

            if (prepared.Provider != "gcp" || prepared.Gcs is null)
            {
                return await DeleteAsync(prepared.Id, cancellationToken).ConfigureAwait(false)
                    ? FilesUploadResult.Quarantined : FilesUploadResult.Retry;
            }

            using var request = new HttpRequestMessage(HttpMethod.Put, GcsUri(prepared.Gcs))
            {
                Content = new ByteArrayContent(bytes),
            };
            request.Content.Headers.ContentType = new(record.MediaType);
            if (!request.Headers.TryAddWithoutValidation(
                "Authorization",
                "Bearer " + prepared.Gcs.AccessToken))
            {
                return await DeleteAsync(prepared.Id, cancellationToken).ConfigureAwait(false)
                    ? FilesUploadResult.Quarantined
                    : FilesUploadResult.Retry;
            }

            using HttpResponseMessage response = await _client.SendAsync(
                request,
                HttpCompletionOption.ResponseHeadersRead,
                cancellationToken).ConfigureAwait(false);
            if (response.IsSuccessStatusCode)
            {
                return FilesUploadResult.Uploaded(prepared.Id);
            }

            if (!await DeleteAsync(prepared.Id, cancellationToken).ConfigureAwait(false))
            {
                return FilesUploadResult.Retry;
            }
            // Federation credentials are intentionally short-lived. Authentication failures on
            // the signed upload are therefore transient after best-effort Files cleanup.
            return response.StatusCode is HttpStatusCode.BadRequest
                ? FilesUploadResult.Quarantined
                : FilesUploadResult.Retry;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            // Once Storage accepted prepare, every later construction or PUT failure must attempt
            // the same authenticated cleanup. The next pass can then safely reuse or reprepare.
            if (prepared is not null)
            {
                try
                {
                    _ = await DeleteAsync(prepared.Id, cancellationToken).ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                {
                    throw;
                }
                catch { }
            }
            return FilesUploadResult.Retry;
        }
    }

    /// <summary>Returns completed Files ids for one canonical artifact tag. The Storage API's tag
    /// query is broad, so all requested tags are checked again client-side before a HEAD probe.</summary>
    public async Task<ScreenshotFileLookupResult> FindByArtifactAsync(
        string artifactId,
        CancellationToken cancellationToken)
    {
        try
        {
            Uri endpoint = new(
                _prepareEndpoint.GetLeftPart(UriPartial.Authority)
                + "/v2/storage/files?tags[]="
                + Uri.EscapeDataString("artifact:" + artifactId));
            using var request = new HttpRequestMessage(HttpMethod.Get, endpoint);
            if (!request.Headers.TryAddWithoutValidation("X-StorageApi-Token", _token))
            {
                return ScreenshotFileLookupResult.Retry;
            }

            using HttpResponseMessage response = await _client.SendAsync(
                request,
                HttpCompletionOption.ResponseHeadersRead,
                cancellationToken).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode
                || response.Content.Headers.ContentLength is > MaxResponseBytes)
            {
                return ScreenshotFileLookupResult.Retry;
            }

            await using Stream stream = await response.Content
                .ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
            byte[] data = await ReadBoundedAsync(stream, cancellationToken).ConfigureAwait(false);
            var complete = new List<long>();
            var dangling = new List<long>();
            try
            {
                using JsonDocument document = JsonDocument.Parse(data);
                if (document.RootElement.ValueKind != JsonValueKind.Array)
                {
                    return ScreenshotFileLookupResult.Retry;
                }

                foreach (JsonElement file in document.RootElement.EnumerateArray())
                {
                    if (!HasScreenshotArtifactTags(file, artifactId))
                    {
                        continue;
                    }

                    if (!TryReadCandidate(file, out long id, out Uri? objectUri))
                    {
                        // A matching tag is an idempotency claim. Do not upload a second object
                        // while its existing Files record cannot be interpreted safely.
                        return ScreenshotFileLookupResult.Retry;
                    }

                    if (objectUri is null)
                    {
                        return ScreenshotFileLookupResult.Retry;
                    }

                    ObjectProbeOutcome probe = await ProbeObjectAsync(
                        objectUri,
                        cancellationToken).ConfigureAwait(false);
                    if (probe == ObjectProbeOutcome.Retry)
                    {
                        return ScreenshotFileLookupResult.Retry;
                    }

                    (probe == ObjectProbeOutcome.Complete ? complete : dangling).Add(id);
                }
            }
            finally
            {
                System.Security.Cryptography.CryptographicOperations.ZeroMemory(data);
            }

            return ScreenshotFileLookupResult.Ready(complete, dangling);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            return ScreenshotFileLookupResult.Retry;
        }
    }

    public async Task<bool> DeleteDanglingAsync(
        IEnumerable<long> ids,
        CancellationToken cancellationToken)
    {
        foreach (long id in ids)
        {
            if (!await DeleteAsync(id, cancellationToken).ConfigureAwait(false))
            {
                return false;
            }
        }

        return true;
    }

    private static bool HasScreenshotArtifactTags(JsonElement file, string artifactId)
    {
        if (!file.TryGetProperty("tags", out JsonElement tags)
            || tags.ValueKind != JsonValueKind.Array)
        {
            return false;
        }

        string[] values = tags.EnumerateArray()
            .Where(value => value.ValueKind == JsonValueKind.String)
            .Select(value => value.GetString()!)
            .ToArray();
        return values.Contains("screenshot", StringComparer.Ordinal)
            && values.Contains("artifact:" + artifactId, StringComparer.Ordinal);
    }

    private static bool TryReadCandidate(
        JsonElement file,
        out long id,
        out Uri? objectUri)
    {
        id = 0;
        objectUri = null;
        if (!file.TryGetProperty("id", out JsonElement idElement)
            || !idElement.TryGetInt64(out id)
            || id <= 0)
        {
            return false;
        }

        if (file.TryGetProperty("url", out JsonElement url)
            && url.ValueKind == JsonValueKind.String
            && TryStorageObjectUri(url.GetString(), out Uri parsed))
        {
            objectUri = parsed;
        }

        return true;
    }

    private static bool TryStorageObjectUri(string? value, out Uri uri)
    {
        if (Uri.TryCreate(value, UriKind.Absolute, out Uri? parsed)
            && parsed.Scheme == Uri.UriSchemeHttps
            && string.Equals(
                parsed.Host,
                "storage.googleapis.com",
                StringComparison.OrdinalIgnoreCase)
            && string.IsNullOrEmpty(parsed.UserInfo))
        {
            uri = parsed;
            return true;
        }

        uri = null!;
        return false;
    }

    private async Task<ObjectProbeOutcome> ProbeObjectAsync(
        Uri uri,
        CancellationToken cancellationToken)
    {
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Head, uri);
            using HttpResponseMessage response = await _client.SendAsync(
                request,
                HttpCompletionOption.ResponseHeadersRead,
                cancellationToken).ConfigureAwait(false);
            if (response.IsSuccessStatusCode)
            {
                return ObjectProbeOutcome.Complete;
            }

            return response.StatusCode == HttpStatusCode.NotFound
                ? ObjectProbeOutcome.Dangling
                : ObjectProbeOutcome.Retry;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            return ObjectProbeOutcome.Retry;
        }
    }

    private async Task<PreparedFile?> PrepareAsync(
        ArtifactDeliveryRecord record,
        CancellationToken cancellationToken)
    {
        var tags = new List<string>
        {
            "screenshot",
            "artifact:" + record.ArtifactId,
            "capture:" + record.CaptureId,
            "archive:" + record.ArchiveId,
        };
        tags.Add("session:" + record.CanonicalEvent!.SessionId);
        byte[] body = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new
        {
            name = record.ArtifactId,
            tags,
            isPermanent = true,
            federationToken = true,
        }));
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Post, _prepareEndpoint)
            {
                Content = new ByteArrayContent(body),
            };
            request.Content.Headers.ContentType = new("application/json");
            if (!request.Headers.TryAddWithoutValidation("X-StorageApi-Token", _token))
            {
                return null;
            }

            using HttpResponseMessage response = await _client.SendAsync(
                request,
                HttpCompletionOption.ResponseHeadersRead,
                cancellationToken).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode
                || response.Content.Headers.ContentLength is > MaxResponseBytes)
            {
                return null;
            }

            await using Stream stream = await response.Content
                .ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
            byte[] data = await ReadBoundedAsync(stream, cancellationToken).ConfigureAwait(false);
            try
            {
                using JsonDocument document = JsonDocument.Parse(data);
                JsonElement root = document.RootElement;
                if (!root.TryGetProperty("id", out JsonElement id)
                    || !id.TryGetInt64(out long numericId)
                    || numericId <= 0
                    || !root.TryGetProperty("provider", out JsonElement provider)
                    || provider.GetString() is not { } providerName)
                {
                    return null;
                }

                GcsUpload? gcs = TryReadGcs(root, out GcsUpload? parsed) ? parsed : null;
                return new PreparedFile(numericId, providerName, gcs);
            }
            finally
            {
                System.Security.Cryptography.CryptographicOperations.ZeroMemory(data);
            }
        }
        finally
        {
            System.Security.Cryptography.CryptographicOperations.ZeroMemory(body);
        }
    }

    private static bool TryReadGcs(JsonElement root, out GcsUpload? upload)
    {
        upload = null;
        if (!root.TryGetProperty("gcsUploadParams", out JsonElement gcs)
            || gcs.ValueKind != JsonValueKind.Object
            || !gcs.TryGetProperty("bucket", out JsonElement bucketElement)
            || !gcs.TryGetProperty("key", out JsonElement keyElement)
            || !gcs.TryGetProperty("access_token", out JsonElement accessElement)
            || bucketElement.GetString() is not { Length: > 0 } bucket
            || keyElement.GetString() is not { Length: > 0 } key
            || accessElement.GetString() is not { Length: > 0 } accessToken)
        {
            return false;
        }

        upload = new GcsUpload(bucket, key, accessToken);
        return true;
    }

    private async Task<bool> DeleteAsync(long id, CancellationToken cancellationToken)
    {
        try
        {
            Uri endpoint = new(
                _prepareEndpoint.GetLeftPart(UriPartial.Authority)
                + "/v2/storage/files/"
                + id.ToString(System.Globalization.CultureInfo.InvariantCulture));
            using var request = new HttpRequestMessage(HttpMethod.Delete, endpoint);
            if (!request.Headers.TryAddWithoutValidation("X-StorageApi-Token", _token))
            {
                return false;
            }

            using HttpResponseMessage response = await _client.SendAsync(
                request,
                HttpCompletionOption.ResponseHeadersRead,
                cancellationToken).ConfigureAwait(false);
            return response.IsSuccessStatusCode || response.StatusCode == HttpStatusCode.NotFound;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            return false;
        }
    }

    private static Uri GcsUri(GcsUpload upload)
    {
        string[] keySegments = upload.Key.Split('/');
        if (upload.Bucket.Any(char.IsWhiteSpace)
            || upload.Bucket.Contains('/')
            || upload.Bucket.Contains('\\')
            || upload.Key.StartsWith('/')
            || keySegments.Any(segment => segment is "." or ".."))
        {
            throw new InvalidDataException();
        }

        return new Uri(
            "https://storage.googleapis.com/"
            + Uri.EscapeDataString(upload.Bucket)
            + "/"
            + string.Join("/", keySegments.Select(Uri.EscapeDataString)));
    }

    private static async Task<byte[]> ReadBoundedAsync(
        Stream stream,
        CancellationToken cancellationToken)
    {
        using var output = new MemoryStream();
        byte[] buffer = new byte[8192];
        try
        {
            while (true)
            {
                int count = await stream.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
                if (count == 0)
                {
                    return output.ToArray();
                }

                if (output.Length + count > MaxResponseBytes)
                {
                    throw new InvalidDataException();
                }

                output.Write(buffer, 0, count);
            }
        }
        finally
        {
            System.Security.Cryptography.CryptographicOperations.ZeroMemory(buffer);
        }
    }

    private sealed record PreparedFile(long Id, string Provider, GcsUpload? Gcs);
    private sealed record GcsUpload(string Bucket, string Key, string AccessToken);

    private enum ObjectProbeOutcome
    {
        Complete,
        Dangling,
        Retry,
    }
}

public sealed record FilesUploadResult(long? RemoteFileId, FilesDeliveryOutcome Outcome)
{
    public static FilesUploadResult Uploaded(long id) =>
        new(id, FilesDeliveryOutcome.Acknowledged);

    public static FilesUploadResult Retry { get; } =
        new(null, FilesDeliveryOutcome.Retry);

    public static FilesUploadResult Quarantined { get; } =
        new(null, FilesDeliveryOutcome.Quarantined);
}

public enum FilesDeliveryOutcome
{
    Acknowledged,
    Retry,
    Quarantined,
}
