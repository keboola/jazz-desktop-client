using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using JazzCaptureCore.Delivery;
using JazzCaptureCore.Enrollment;

namespace JazzCapture;

/// <summary>Strict legacy Storage Files prepare/GCP upload transport. Credentials remain in managed
/// memory for the client/request lifetime only and are never persisted or logged.</summary>
public sealed class KeboolaFilesClient : IScreenshotFilesTransport
{
    private const int LookupPageSize = 100;
    private const int LookupPageLimit = 10;
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
        if (!IsScreenshotMediaType(record.MediaType)
            || record.ScreenshotId is null
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

            if (prepared.Id <= 0)
            {
                return FilesUploadResult.Quarantined;
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
                "Bearer " + prepared.Gcs.AccessToken)
                || !request.Headers.TryAddWithoutValidation(
                    "x-goog-meta-jazz-sha256",
                    record.Sha256))
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
            // Prepare may already have allocated a Files record. Shutdown still propagates
            // promptly, but make one bounded, independent cleanup attempt so cancellation does
            // not knowingly leave a remote allocation behind.
            if (prepared is { Id: > 0 })
            {
                await BestEffortDeleteAfterCancellationAsync(prepared.Id).ConfigureAwait(false);
            }
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

    private static bool IsScreenshotMediaType(string? mediaType) =>
        !string.IsNullOrWhiteSpace(mediaType)
        && MediaTypeHeaderValue.TryParse(mediaType, out MediaTypeHeaderValue? parsed)
        && parsed.MediaType is { } parsedType
        && parsed.Parameters.Count == 0
        && parsedType.StartsWith("image/", StringComparison.OrdinalIgnoreCase)
        && parsedType.Length > "image/".Length;

    /// <summary>Returns completed Files ids for one canonical artifact tag. The Storage API's tag
    /// query is broad, so all requested tags are checked again client-side before a HEAD probe.</summary>
    public async Task<ScreenshotFileLookupResult> FindByArtifactAsync(
        ArtifactDeliveryRecord record,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(record);
        try
        {
            var complete = new HashSet<long>();
            var dangling = new HashSet<long>();
            for (int page = 0; page < LookupPageLimit; page++)
            {
                Uri endpoint = new(
                    _prepareEndpoint.GetLeftPart(UriPartial.Authority)
                    + "/v2/storage/files?tags[]="
                    + Uri.EscapeDataString("artifact:" + record.ArtifactId)
                    + "&limit=" + LookupPageSize
                    + "&offset=" + (page * LookupPageSize));
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
                try
                {
                    using JsonDocument document = JsonDocument.Parse(data);
                    if (document.RootElement.ValueKind != JsonValueKind.Array)
                    {
                        return ScreenshotFileLookupResult.Retry;
                    }

                    foreach (JsonElement file in document.RootElement.EnumerateArray())
                    {
                        CandidateIdentity identity = ClassifyCandidateIdentity(file, record);
                        if (identity == CandidateIdentity.NotCandidate) continue;
                        if (identity == CandidateIdentity.Mismatch)
                            return ScreenshotFileLookupResult.Quarantined;
                        if (identity == CandidateIdentity.Unverifiable)
                            return ScreenshotFileLookupResult.Retry;

                        if (!TryReadCandidate(file, out long id, out Uri? objectUri))
                        {
                            // A matching tag is an idempotency claim. Do not upload a second
                            // object while its Files record cannot be interpreted safely.
                            return ScreenshotFileLookupResult.Retry;
                        }
                        if (objectUri is null)
                        {
                            // The matching immutable tags and a positive id prove this is an
                            // allocation owned by this record, but without a safe GCS URL it
                            // cannot be probed or reused. Return it as cleanup debt; the worker
                            // deletes it before any prepare/upload can happen.
                            dangling.Add(id);
                            continue;
                        }

                        ObjectProbeOutcome probe = await ProbeObjectAsync(
                            objectUri,
                            record,
                            cancellationToken).ConfigureAwait(false);
                        if (probe == ObjectProbeOutcome.Retry)
                            return ScreenshotFileLookupResult.Retry;
                        if (probe == ObjectProbeOutcome.Mismatch)
                            return ScreenshotFileLookupResult.Quarantined;

                        (probe == ObjectProbeOutcome.Complete ? complete : dangling).Add(id);
                    }

                    if (document.RootElement.GetArrayLength() < LookupPageSize)
                    {
                        return ScreenshotFileLookupResult.Ready(
                            complete.OrderBy(value => value).ToArray(),
                            dangling.OrderBy(value => value).ToArray());
                    }
                }
                finally
                {
                    System.Security.Cryptography.CryptographicOperations.ZeroMemory(data);
                }
            }

            // Bounded exhaustion is intentionally fail-closed: a full final page cannot prove
            // that a matching object is absent on a later page, so never prepare a duplicate.
            return ScreenshotFileLookupResult.Retry;
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

    private static CandidateIdentity ClassifyCandidateIdentity(
        JsonElement file,
        ArtifactDeliveryRecord record)
    {
        if (!file.TryGetProperty("tags", out JsonElement tags)
            || tags.ValueKind != JsonValueKind.Array)
        {
            return CandidateIdentity.NotCandidate;
        }

        string[] values = tags.EnumerateArray()
            .Where(value => value.ValueKind == JsonValueKind.String)
            .Select(value => value.GetString()!)
            .ToArray();
        if (!values.Contains("screenshot", StringComparer.Ordinal)
            || !values.Contains("artifact:" + record.ArtifactId, StringComparer.Ordinal))
        {
            return CandidateIdentity.NotCandidate;
        }
        if (values.Count(value => value.StartsWith("artifact:", StringComparison.Ordinal)) != 1)
        {
            // A broad Storage tag query can return a record for several artifacts. It cannot be
            // safely bound to this immutable screenshot, even if our tag is among them.
            return CandidateIdentity.Mismatch;
        }

        if (record.CanonicalEvent?.SessionId is not { Length: > 0 } sessionId)
        {
            return CandidateIdentity.Unverifiable;
        }

        string[] immutableTags =
        [
            "archive:" + record.ArchiveId,
            "capture:" + record.CaptureId,
            "session:" + sessionId,
        ];
        foreach (string expected in immutableTags)
        {
            int separator = expected.IndexOf(':');
            string prefix = expected[..(separator + 1)];
            string[] taggedValues = values.Where(value => value.StartsWith(prefix, StringComparison.Ordinal)).ToArray();
            if (taggedValues.Length == 0)
            {
                return CandidateIdentity.Unverifiable;
            }
            if (taggedValues.Length != 1 || !string.Equals(taggedValues[0], expected, StringComparison.Ordinal))
            {
                return CandidateIdentity.Mismatch;
            }
        }

        string[] digests = values
            .Where(value => value.StartsWith("sha256:", StringComparison.Ordinal))
            .ToArray();
        string[] lengths = values
            .Where(value => value.StartsWith("bytes:", StringComparison.Ordinal))
            .ToArray();
        if (digests.Length != 1 || lengths.Length != 1)
        {
            return CandidateIdentity.Unverifiable;
        }

        return digests[0] == "sha256:" + record.Sha256
            && lengths[0] == "bytes:" + record.ByteLength.ToString(
                System.Globalization.CultureInfo.InvariantCulture)
                ? CandidateIdentity.Match
                : CandidateIdentity.Mismatch;
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
        ArtifactDeliveryRecord record,
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
                bool digestMatches = response.Headers.TryGetValues(
                        "x-goog-meta-jazz-sha256",
                        out IEnumerable<string>? digestValues)
                    && digestValues.Count() == 1
                    && string.Equals(
                        digestValues.Single(),
                        record.Sha256,
                        StringComparison.Ordinal);
                return response.Content.Headers.ContentLength == record.ByteLength
                    && digestMatches
                        ? ObjectProbeOutcome.Complete
                        : ObjectProbeOutcome.Mismatch;
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
        tags.Add("sha256:" + record.Sha256);
        tags.Add("bytes:" + record.ByteLength.ToString(
            System.Globalization.CultureInfo.InvariantCulture));
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
            if (!response.IsSuccessStatusCode)
            {
                return response.StatusCode is HttpStatusCode.BadRequest
                    or HttpStatusCode.UnprocessableEntity
                    ? new PreparedFile(0, string.Empty, null)
                    : null;
            }

            await using Stream stream = await response.Content
                .ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
            (byte[] data, long acceptedId, bool oversized) = await ReadPreparedBoundedAsync(
                stream, cancellationToken).ConfigureAwait(false);
            try
            {
                if (oversized)
                {
                    // When the bounded prefix has no top-level id, retain no response bytes or
                    // guessed identifier. The durable record's unique immutable Files tags are
                    // queried before every later prepare, so a subsequently visible allocation
                    // is classified as cleanup debt rather than duplicated.
                    return acceptedId > 0
                        ? new PreparedFile(acceptedId, string.Empty, null)
                        : null;
                }
                JsonDocument document;
                try { document = JsonDocument.Parse(data); }
                catch (JsonException) when (acceptedId > 0)
                {
                    // Storage may have allocated an id before a malformed/truncated response.
                    // Preserve that bounded numeric id so UploadAsync can delete it safely.
                    return new PreparedFile(acceptedId, string.Empty, null);
                }
                using (document)
                {
                JsonElement root = document.RootElement;
                if (!root.TryGetProperty("id", out JsonElement id)
                    || !id.TryGetInt64(out long numericId)
                    || numericId <= 0)
                {
                    return null;
                }

                string providerName = root.TryGetProperty("provider", out JsonElement provider)
                    && provider.ValueKind == JsonValueKind.String
                        ? provider.GetString() ?? string.Empty
                        : string.Empty;
                GcsUpload? gcs = TryReadGcs(root, out GcsUpload? parsed) ? parsed : null;
                return new PreparedFile(numericId, providerName, gcs);
                }
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

    private static long TryExtractPreparedId(byte[] data)
    {
        long id = 0;
        try
        {
            var reader = new Utf8JsonReader(data, isFinalBlock: false, state: default);
            while (reader.Read())
            {
                if (reader.TokenType == JsonTokenType.PropertyName
                    && reader.CurrentDepth == 1
                    && reader.ValueTextEquals("id")
                    && reader.Read()
                    && reader.TokenType == JsonTokenType.Number
                    && reader.TryGetInt64(out long parsed)
                    && parsed > 0)
                {
                    id = parsed;
                    break;
                }
            }
        }
        catch (JsonException) { }
        return id;
    }

    private static async Task<(byte[] Data, long AcceptedId, bool Oversized)> ReadPreparedBoundedAsync(
        Stream stream, CancellationToken cancellationToken)
    {
        using var output = new MemoryStream();
        byte[] buffer = new byte[8192];
        long id = 0;
        try
        {
            while (true)
            {
                int count = await stream.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
                if (count == 0) return (output.ToArray(), id, false);
                int writable = (int)Math.Min(count, MaxResponseBytes - output.Length);
                if (writable > 0)
                {
                    output.Write(buffer, 0, writable);
                    if (id == 0) id = TryExtractPreparedId(output.GetBuffer().AsSpan(0, (int)output.Length).ToArray());
                }
                if (writable != count) return (output.ToArray(), id, true);
            }
        }
        finally { System.Security.Cryptography.CryptographicOperations.ZeroMemory(buffer); }
    }

    private static bool TryReadGcs(JsonElement root, out GcsUpload? upload)
    {
        upload = null;
        if (!root.TryGetProperty("gcsUploadParams", out JsonElement gcs)
            || gcs.ValueKind != JsonValueKind.Object
            || !gcs.TryGetProperty("bucket", out JsonElement bucketElement)
            || !gcs.TryGetProperty("key", out JsonElement keyElement)
            || !gcs.TryGetProperty("access_token", out JsonElement accessElement)
            || bucketElement.ValueKind != JsonValueKind.String
            || keyElement.ValueKind != JsonValueKind.String
            || accessElement.ValueKind != JsonValueKind.String
            || bucketElement.GetString() is not { Length: > 0 } bucket
            || bucket is "." or ".."
            || keyElement.GetString() is not { Length: > 0 } key
            || accessElement.GetString() is not { Length: > 0 } accessToken)
        {
            return false;
        }

        if (bucket.Any(character => char.IsWhiteSpace(character) || char.IsControl(character))
            || bucket.Contains("/", StringComparison.Ordinal)
            || bucket.Contains("\\", StringComparison.Ordinal)
            || key.StartsWith("/", StringComparison.Ordinal)
            || key.Split('/').Any(segment => segment is "." or "..")
            || accessToken.Any(character => char.IsWhiteSpace(character) || char.IsControl(character)))
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

    private async Task BestEffortDeleteAfterCancellationAsync(long id)
    {
        using var cleanup = new CancellationTokenSource(TimeSpan.FromSeconds(2));
        try { _ = await DeleteAsync(id, cleanup.Token).ConfigureAwait(false); }
        catch { /* Cancellation must not leak cleanup diagnostics or delay shutdown indefinitely. */ }
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
        Mismatch,
    }

    private enum CandidateIdentity
    {
        NotCandidate,
        Match,
        Unverifiable,
        Mismatch,
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
