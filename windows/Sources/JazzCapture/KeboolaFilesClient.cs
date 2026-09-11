using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using JazzCaptureCore.Enrollment;

namespace JazzCapture;

/// <summary>
/// One artifact's screenshot identity as the capture path knows it, before a Files allocation
/// exists for it.
/// </summary>
/// <remarks>
/// <see cref="ScreenshotDeliveryPreparer.Prepare"/> builds one of these from an
/// <c>ArtifactDeliveryDescriptor</c> on the capture path for every screenshot prepare. This type
/// intentionally still has no dependency on that descriptor, the journal, or the staging area --
/// that isolation is what keeps this transport testable on its own, independent of the capture
/// path that happens to construct it today.
/// </remarks>
public sealed record ScreenshotFilesRequest(
    string ArchiveId,
    string CaptureId,
    string SessionId,
    string ArtifactId,
    string MediaType,
    string Sha256,
    long ByteLength);

/// <summary>
/// The upload target a successful <see cref="KeboolaFilesClient.PrepareAsync"/> produced: a Files
/// id plus the short-lived GCS federation parameters needed to PUT to it later.
/// </summary>
/// <remarks>
/// <see cref="AccessToken"/> is a short-lived secret and must never reach a log, an exception
/// message, or the default record <c>ToString()</c>. <see cref="ToString"/> is overridden for the
/// same reason and in the same way as <c>DeviceBundle.ToString()</c>
/// (<c>windows/Sources/JazzCaptureCore/Enrollment/DeviceBundle.cs</c>): overriding
/// <c>ToString()</c> alone is sufficient, because a record's compiler-generated <c>ToString()</c>
/// is the only caller of its compiler-generated <c>PrintMembers</c> partial.
/// </remarks>
public sealed record ScreenshotPrepareResult(
    long FilesId,
    string Bucket,
    string Key,
    string AccessToken)
{
    /// <summary>Fixed, non-secret shape. Deliberately omits <see cref="AccessToken"/>.</summary>
    public override string ToString() =>
        string.Format(
            CultureInfo.InvariantCulture,
            "ScreenshotPrepareResult({0}, {1}, {2})",
            FilesId,
            Bucket,
            Key);
}

/// <summary>Operator-safe reason <see cref="KeboolaFilesClient.PrepareAsync"/> produced no usable
/// upload target. Never used to drive a retry on the capture path -- issue #73 accepts the
/// inconsistency of a failed prepare rather than retrying it -- this exists purely so a caller
/// (eventually the tray) can distinguish these cases for diagnostics.</summary>
public enum ScreenshotPrepareFailureKind
{
    /// <summary>The request failed local validation; no network call was made.</summary>
    InvalidRequest,

    /// <summary>Prepare succeeded but produced an allocation this client can never upload to (a
    /// non-<c>gcp</c> provider, or <c>gcsUploadParams</c> that failed validation), or the response
    /// could not be interpreted at all. Any Files id recovered from such a response has already
    /// been sent a best-effort delete.</summary>
    UnusableTarget,

    /// <summary>Storage refused the request in a way retrying the same request would not fix
    /// (<c>400</c>/<c>422</c>).</summary>
    PermanentRejection,

    /// <summary>Everything else: other HTTP statuses, a transport failure, or the prepare budget
    /// elapsing before a response arrived.</summary>
    TransientFailure,
}

/// <summary>
/// The result of a prepare attempt: either a usable <see cref="ScreenshotPrepareResult"/> to
/// stage, or a <see cref="ScreenshotPrepareFailureKind"/> explaining why there is nothing to
/// stage. The private constructor and the two factory methods below are the only way to produce
/// one, so a caller can never observe a result that is both non-null and paired with a failure
/// reason.
/// </summary>
public sealed class ScreenshotPrepareOutcome
{
    private ScreenshotPrepareOutcome(
        ScreenshotPrepareResult? result,
        ScreenshotPrepareFailureKind? failureKind)
    {
        Result = result;
        FailureKind = failureKind;
    }

    /// <summary>The prepared upload target, or <see langword="null"/> when nothing was staged.</summary>
    public ScreenshotPrepareResult? Result { get; }

    /// <summary>Why nothing was staged, or <see langword="null"/> on success.</summary>
    public ScreenshotPrepareFailureKind? FailureKind { get; }

    public static ScreenshotPrepareOutcome Prepared(ScreenshotPrepareResult result) =>
        new(result ?? throw new ArgumentNullException(nameof(result)), null);

    public static ScreenshotPrepareOutcome NoUsableTarget(ScreenshotPrepareFailureKind reason) =>
        new(null, reason);
}

/// <summary>Outcome of a background-uploader GCS PUT.</summary>
public enum FilesDeliveryOutcome
{
    /// <summary>The bytes reached GCS. <see cref="FilesUploadResult.RemoteFileId"/> carries the
    /// Files id.</summary>
    Acknowledged,

    /// <summary>Worth another attempt later -- a transient GCS failure, an expired federation
    /// credential, or the upload call budget elapsing.</summary>
    Retry,

    /// <summary>Never call <see cref="KeboolaFilesClient.UploadAsync"/> again for this artifact.
    /// The caller must drop the staged blob; the Files id from prepare is intentionally left
    /// dangling rather than deleted (issue #73's accepted terminal-failure behaviour).</summary>
    Dropped,
}

/// <summary>Result of a background-uploader GCS PUT.</summary>
public sealed record FilesUploadResult(long? RemoteFileId, FilesDeliveryOutcome Outcome)
{
    public static FilesUploadResult Acknowledged(long id) =>
        new(id, FilesDeliveryOutcome.Acknowledged);

    public static FilesUploadResult Retry { get; } =
        new(null, FilesDeliveryOutcome.Retry);

    public static FilesUploadResult Dropped { get; } =
        new(null, FilesDeliveryOutcome.Dropped);
}

/// <summary>
/// Keboola Storage Files transport for prepare-early screenshot delivery. Credentials remain in
/// managed memory for the client/request lifetime only and are never persisted or logged.
/// </summary>
/// <remarks>
/// <para>
/// This is a deliberate two-operation split of the strong-consistency client built on the closed
/// <c>codex/68-screenshot-files</c> branch (PR #70, commit <c>0570fce</c>), whose single
/// <c>UploadAsync</c> did prepare and the GCS PUT in one call. Prepare-early requires them
/// separated: <see cref="PrepareAsync"/> runs on the capture path under a bounded budget and
/// stamps a Files id on the emitted event; <see cref="UploadAsync"/> runs later, on a background
/// worker, against the staged bytes.
/// </para>
/// <para>
/// <see cref="PrepareAsync"/> never issues the remote delete for a Files allocation that a later
/// <see cref="UploadAsync"/> could still use -- by the time <see cref="UploadAsync"/> runs, the
/// event carrying that Files id has already been emitted, so deleting the remote record out from
/// under it would be worse than leaving it dangling. The only allocations <see cref="PrepareAsync"/>
/// deletes are ones no event has gone out with yet: a target this client can never upload to (a
/// non-<c>gcp</c> provider, or invalid <c>gcsUploadParams</c>), a prepare abandoned by caller
/// cancellation, or one whose budget elapsed after the response was already read.
/// <see cref="CleanupUnusedAllocationAsync"/> extends that same pre-emission window to a caller
/// outside this class: <see cref="ScreenshotDeliveryPreparer.Prepare"/>, when its own local
/// staging area refuses an otherwise-successful prepare.
/// </para>
/// </remarks>
public sealed class KeboolaFilesClient
{
    private const long MaxResponseBytes = 64 * 1024;

    private readonly RedirectSafeHttpClient _client;
    private readonly Uri _prepareEndpoint;
    private readonly string _token;
    private readonly ScreenshotDeliverySettings _settings;

    public KeboolaFilesClient(
        DeviceBundle credential,
        RedirectSafeHttpClient client,
        ScreenshotDeliverySettings settings)
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
        _settings = settings ?? throw new ArgumentNullException(nameof(settings));
    }

    /// <summary>
    /// Runs <c>POST /v2/storage/files/prepare</c> under <see cref="ScreenshotDeliverySettings.PrepareBudget"/>.
    /// Never throws for the caller's own <paramref name="cancellationToken"/> being merely slow --
    /// only genuine caller cancellation propagates as <see cref="OperationCanceledException"/>; a
    /// budget expiry, an HTTP failure, or a malformed response all come back as
    /// <see cref="ScreenshotPrepareOutcome.NoUsableTarget"/>. The capture path must not retry
    /// either way -- issue #73 accepts a failed prepare as emitting the event with no screenshot
    /// id -- so this method does not build any retry loop of its own.
    /// </summary>
    public async Task<ScreenshotPrepareOutcome> PrepareAsync(
        ScreenshotFilesRequest request,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (!HasValidIdentity(request) || !IsScreenshotMediaType(request.MediaType))
        {
            return ScreenshotPrepareOutcome.NoUsableTarget(ScreenshotPrepareFailureKind.InvalidRequest);
        }

        var tags = new List<string>
        {
            "screenshot",
            "artifact:" + request.ArtifactId,
            "capture:" + request.CaptureId,
            "archive:" + request.ArchiveId,
            "session:" + request.SessionId,
            "sha256:" + request.Sha256,
            "bytes:" + request.ByteLength.ToString(CultureInfo.InvariantCulture),
        };
        byte[] body = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new
        {
            name = request.ArtifactId,
            tags,
            isPermanent = true,
            federationToken = true,
        }));

        long acceptedIdPendingCleanup = 0;

        // Finding 1 (#74 review, tenth pass): every cleanup in this method goes through here, and
        // here clears the pending id before attempting the DELETE. Without that, the three branches
        // below that clean up and then call cancellationToken.ThrowIfCancellationRequested land in
        // the cancellation handler at the bottom with acceptedIdPendingCleanup still set, and it
        // repeats the same DELETE -- so a caller cancelling against a stalled endpoint blocks for
        // twice PrepareCleanupBudget, against this method's single-bounded-cleanup contract.
        // Clearing first, rather than after, also means a cleanup that somehow threw could not be
        // retried either; BestEffortCleanupAsync is documented never to throw, and this keeps the
        // "at most one cleanup per prepare call" bound true regardless.
        async Task CleanupOnceAsync(long id)
        {
            acceptedIdPendingCleanup = 0;
            await BestEffortCleanupAsync(id).ConfigureAwait(false);
        }

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(_settings.PrepareBudget);
        try
        {
            using var httpRequest = new HttpRequestMessage(HttpMethod.Post, _prepareEndpoint)
            {
                Content = new ByteArrayContent(body),
            };
            httpRequest.Content.Headers.ContentType = new("application/json");
            if (!httpRequest.Headers.TryAddWithoutValidation("X-StorageApi-Token", _token))
            {
                return ScreenshotPrepareOutcome.NoUsableTarget(ScreenshotPrepareFailureKind.UnusableTarget);
            }

            using HttpResponseMessage response = await _client.SendAsync(
                httpRequest,
                HttpCompletionOption.ResponseHeadersRead,
                timeout.Token).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                // The capture path never retries a failed prepare either way; this
                // classification exists only so a caller (eventually the tray) can tell the two
                // apart for diagnostics.
                return ScreenshotPrepareOutcome.NoUsableTarget(
                    response.StatusCode is HttpStatusCode.BadRequest or HttpStatusCode.UnprocessableEntity
                        ? ScreenshotPrepareFailureKind.PermanentRejection
                        : ScreenshotPrepareFailureKind.TransientFailure);
            }

            await using Stream stream = await response.Content
                .ReadAsStreamAsync(timeout.Token).ConfigureAwait(false);
            (byte[] data, long acceptedId, bool oversized) = await ReadPreparedBoundedAsync(
                stream,
                id => acceptedIdPendingCleanup = id,
                timeout.Token).ConfigureAwait(false);
            acceptedIdPendingCleanup = acceptedId;
            try
            {
                if (oversized)
                {
                    // When the bounded prefix has no top-level id, retain no response bytes or
                    // guessed identifier. Without the closed branch's tag-lookup path (dropped:
                    // there is nothing left here to reconcile against), an oversized prepare
                    // response whose id cannot be recovered leaks a Files allocation permanently.
                    // That is accepted -- it costs storage, not correctness.
                    if (acceptedId > 0)
                    {
                        // Finding 2 (#74 review, ninth pass): bound this cleanup by its own
                        // PrepareCleanupBudget rather than timeout.Token, whose remaining life is
                        // just whatever is left of PrepareBudget -- a stalled DELETE here must not
                        // be able to consume the prepare call's own budget. See
                        // BestEffortCleanupAsync's own remarks.
                        await CleanupOnceAsync(acceptedId).ConfigureAwait(false);

                        // BestEffortCleanupAsync never observes cancellationToken (it always runs
                        // to completion or its own budget, and never throws), so genuine caller
                        // cancellation arriving during that cleanup call would otherwise go
                        // unnoticed here. Check it explicitly so it still propagates exactly as it
                        // did when this cleanup ran under the linked (and therefore caller-token-
                        // sensitive) timeout.Token.
                        cancellationToken.ThrowIfCancellationRequested();
                    }
                    return ScreenshotPrepareOutcome.NoUsableTarget(ScreenshotPrepareFailureKind.UnusableTarget);
                }

                JsonDocument document;
                try
                {
                    document = JsonDocument.Parse(data);
                }
                catch (JsonException)
                {
                    // Storage may have allocated an id before a malformed/truncated response.
                    // Recover that bounded numeric id, if any, so it can be cleaned up.
                    if (acceptedId > 0)
                    {
                        // Finding 2 (#74 review, ninth pass): see the identical comment above --
                        // this cleanup must run under its own PrepareCleanupBudget, not whatever
                        // remains of timeout.Token/PrepareBudget.
                        await CleanupOnceAsync(acceptedId).ConfigureAwait(false);
                        cancellationToken.ThrowIfCancellationRequested();
                    }
                    return ScreenshotPrepareOutcome.NoUsableTarget(ScreenshotPrepareFailureKind.UnusableTarget);
                }

                using (document)
                {
                    JsonElement root = document.RootElement;
                    if (!root.TryGetProperty("id", out JsonElement idElement)
                        || !idElement.TryGetInt64(out long numericId)
                        || numericId <= 0)
                    {
                        return ScreenshotPrepareOutcome.NoUsableTarget(ScreenshotPrepareFailureKind.UnusableTarget);
                    }

                    string providerName = root.TryGetProperty("provider", out JsonElement provider)
                        && provider.ValueKind == JsonValueKind.String
                            ? provider.GetString() ?? string.Empty
                            : string.Empty;
                    bool hasGcs = TryReadGcs(root, out GcsUpload? gcs) && gcs is not null;
                    if (providerName != "gcp" || !hasGcs)
                    {
                        // A target this client can never upload to. No event has been emitted
                        // with this id yet, so it is safe -- and correct -- to delete it here.
                        // Finding 2 (#74 review, ninth pass): bound by PrepareCleanupBudget, not
                        // timeout.Token -- see the identical comment further up this method.
                        await CleanupOnceAsync(numericId).ConfigureAwait(false);
                        cancellationToken.ThrowIfCancellationRequested();
                        return ScreenshotPrepareOutcome.NoUsableTarget(ScreenshotPrepareFailureKind.UnusableTarget);
                    }

                    // The caller may have already given up, or the prepare budget may already
                    // have elapsed, by the time a usable target is known. Check the linked token
                    // -- which reflects both -- rather than only the caller's own token, so
                    // neither race can silently hand back a target that has already run out its
                    // budget or that the caller will never stage (Finding 4, #74 review).
                    if (timeout.IsCancellationRequested)
                    {
                        // Genuine caller cancellation still propagates exactly as before: this
                        // throws using the caller's own token, and the outer catch below does
                        // its own bounded cleanup using acceptedIdPendingCleanup, which by now
                        // already holds numericId.
                        cancellationToken.ThrowIfCancellationRequested();

                        // Only the prepare budget itself elapsed; the caller has not given up.
                        // No event has been emitted with this id yet, so clean it up here rather
                        // than returning a target whose budget has already expired.
                        await CleanupOnceAsync(numericId).ConfigureAwait(false);
                        return ScreenshotPrepareOutcome.NoUsableTarget(ScreenshotPrepareFailureKind.TransientFailure);
                    }

                    return ScreenshotPrepareOutcome.Prepared(
                        new ScreenshotPrepareResult(numericId, gcs!.Bucket, gcs.Key, gcs.AccessToken));
                }
            }
            finally
            {
                CryptographicOperations.ZeroMemory(data);
            }
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            // The prepare budget elapsed, not the caller. This must never surface as an
            // exception on the capture path. The budget can elapse while a read of the response
            // stream is still in flight -- after ReadPreparedBoundedAsync's onIdFound callback has
            // already observed a positive id (see its own remarks on why that callback runs before
            // this method could ever see a return value) but before this method reaches its own
            // in-band check of timeout.IsCancellationRequested a few lines above. That id has not
            // been emitted on any event yet, so it must be cleaned up here exactly like every other
            // pre-emission path on this method (Finding 2, #74 review, third pass) rather than
            // leaked -- best-effort and independently bounded by PrepareCleanupBudget so a dead
            // endpoint cannot extend the capture path's own budget expiry.
            if (acceptedIdPendingCleanup > 0)
            {
                await CleanupOnceAsync(acceptedIdPendingCleanup).ConfigureAwait(false);
            }

            return ScreenshotPrepareOutcome.NoUsableTarget(ScreenshotPrepareFailureKind.TransientFailure);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            // Prepare may already have allocated a Files record. The capture path still needs
            // cancellation to propagate promptly, but make one bounded, independent cleanup
            // attempt first so cancellation does not knowingly leave a remote allocation behind.
            if (acceptedIdPendingCleanup > 0)
            {
                await CleanupOnceAsync(acceptedIdPendingCleanup).ConfigureAwait(false);
            }
            throw;
        }
        catch (HttpRequestException)
        {
            return ScreenshotPrepareOutcome.NoUsableTarget(ScreenshotPrepareFailureKind.TransientFailure);
        }
        catch (IOException)
        {
            return ScreenshotPrepareOutcome.NoUsableTarget(ScreenshotPrepareFailureKind.TransientFailure);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(body);
        }
    }

    /// <summary>
    /// PUTs <paramref name="bytes"/> to the GCS object <paramref name="prepared"/> names, using
    /// the federation bearer prepare returned. Runs on the background uploader, not the capture
    /// path.
    /// </summary>
    /// <remarks>
    /// Deliberately never calls <c>DeleteAsync</c>. By the time this runs, the event carrying
    /// <paramref name="prepared"/>'s Files id has already been emitted through the ordinary
    /// observer -- deleting the remote record here would invalidate an id already recorded
    /// elsewhere. On terminal failure the caller drops the staged blob and the Files id is left
    /// dangling; that is issue #73's accepted terminal-failure behaviour, and it is also why the
    /// dangling-object cleanup machinery from the closed branch is not reintroduced here.
    /// </remarks>
    public async Task<FilesUploadResult> UploadAsync(
        ScreenshotPrepareResult prepared,
        ScreenshotFilesRequest request,
        byte[] bytes,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(prepared);
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(bytes);

        if (!IsScreenshotMediaType(request.MediaType)
            || bytes.LongLength != request.ByteLength
            || !string.Equals(
                Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant(),
                request.Sha256,
                StringComparison.Ordinal))
        {
            // A local defect: the staged bytes no longer match the journal's own record of them.
            // Retrying an identical PUT cannot fix this, and no network call is worth making.
            return FilesUploadResult.Dropped;
        }

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(_settings.UploadCallBudget);
        try
        {
            using var httpRequest = new HttpRequestMessage(
                HttpMethod.Put,
                GcsUri(new GcsUpload(prepared.Bucket, prepared.Key, prepared.AccessToken)))
            {
                Content = new ByteArrayContent(bytes),
            };
            httpRequest.Content.Headers.ContentType = new(request.MediaType);
            // Deliberately no X-StorageApi-Token here: this is a GCS request authenticated by the
            // short-lived federation bearer, and the two credentials must never mix on one call.
            if (!httpRequest.Headers.TryAddWithoutValidation(
                    "Authorization", "Bearer " + prepared.AccessToken)
                || !httpRequest.Headers.TryAddWithoutValidation(
                    "x-goog-meta-jazz-sha256", request.Sha256))
            {
                return FilesUploadResult.Retry;
            }

            using HttpResponseMessage response = await _client.SendAsync(
                httpRequest,
                HttpCompletionOption.ResponseHeadersRead,
                timeout.Token).ConfigureAwait(false);
            if (response.IsSuccessStatusCode)
            {
                return FilesUploadResult.Acknowledged(prepared.FilesId);
            }

            // The malformed-request case is the only one retrying identical bytes cannot fix.
            // Everything else -- including 401/403, since the federation credential is
            // short-lived and expiry is the likely cause -- is worth another attempt later.
            return response.StatusCode == HttpStatusCode.BadRequest
                ? FilesUploadResult.Dropped
                : FilesUploadResult.Retry;
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            // The upload call budget elapsed, not the caller: retryable, not an exception.
            return FilesUploadResult.Retry;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (HttpRequestException)
        {
            return FilesUploadResult.Retry;
        }
        catch (IOException)
        {
            return FilesUploadResult.Retry;
        }
    }

    private static bool IsValidSha256(string? value) =>
        value is { Length: 64 }
        && value.All(character => character is >= '0' and <= '9' or >= 'a' and <= 'f');

    private static bool HasValidIdentity(ScreenshotFilesRequest request) =>
        !string.IsNullOrEmpty(request.ArchiveId)
        && !string.IsNullOrEmpty(request.CaptureId)
        && !string.IsNullOrEmpty(request.SessionId)
        && !string.IsNullOrEmpty(request.ArtifactId)
        && IsValidSha256(request.Sha256)
        && request.ByteLength > 0;

    private static bool IsScreenshotMediaType(string? mediaType) =>
        !string.IsNullOrWhiteSpace(mediaType)
        && MediaTypeHeaderValue.TryParse(mediaType, out MediaTypeHeaderValue? parsed)
        && parsed.MediaType is { } parsedType
        && parsed.Parameters.Count == 0
        && parsedType.StartsWith("image/", StringComparison.OrdinalIgnoreCase)
        && parsedType.Length > "image/".Length;

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

    /// <summary>
    /// Reads the prepare response body up to <see cref="MaxResponseBytes"/>, extracting a
    /// top-level numeric <c>id</c> as soon as one is visible even if the response later turns out
    /// to be truncated or oversized.
    /// </summary>
    /// <param name="onIdFound">
    /// Invoked once, synchronously, the moment a positive top-level <c>id</c> is first found --
    /// in addition to this method's own <c>AcceptedId</c> return value, not instead of it. This
    /// exists so the id survives an exception from a later <see cref="Stream.ReadAsync(Memory{byte},CancellationToken)"/>
    /// call in this same loop (e.g. cancellation interrupting the response stream after the id
    /// bytes have already been delivered): the return value is lost when this method throws
    /// instead of returning, but the callback has already run by then (Finding 3, #74 review).
    /// </param>
    /// <remarks>
    /// This re-scans the entire accumulated prefix with <see cref="TryExtractPreparedId"/> after
    /// every 8&#160;KiB chunk until an id is found, which is O(n&#178;) in the number of chunks
    /// read so far. That is bounded by <see cref="MaxResponseBytes"/> (64&#160;KiB, i.e. at most 8
    /// chunks) and therefore harmless, if non-obvious -- ported as-is from the closed branch.
    /// </remarks>
    private static async Task<(byte[] Data, long AcceptedId, bool Oversized)> ReadPreparedBoundedAsync(
        Stream stream, Action<long> onIdFound, CancellationToken cancellationToken)
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
                    if (id == 0)
                    {
                        id = TryExtractPreparedId(output.GetBuffer().AsSpan(0, (int)output.Length).ToArray());
                        if (id > 0) onIdFound(id);
                    }
                }
                if (writable != count) return (output.ToArray(), id, true);
            }
        }
        finally { CryptographicOperations.ZeroMemory(buffer); }
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
            || !IsPlausibleGcsBucketName(bucket)
            || key.StartsWith("/", StringComparison.Ordinal)
            || key.Split('/').Any(segment => segment is "." or "..")
            || key.Any(char.IsControl)
            || Encoding.UTF8.GetByteCount(key) > MaxGcsObjectNameBytes
            || accessToken.Any(character => char.IsWhiteSpace(character) || char.IsControl(character)))
        {
            return false;
        }

        upload = new GcsUpload(bucket, key, accessToken);
        return true;
    }

    /// <summary>GCS object names are at most 1024 bytes of UTF-8.</summary>
    private const int MaxGcsObjectNameBytes = 1024;

    /// <summary>
    /// Whether <paramref name="bucket"/> could name a real GCS bucket, by the structural half of
    /// Google's bucket-naming rules: 3-63 characters, or up to 222 for a dot-separated
    /// domain-named bucket with each component 1-63; lowercase letters, digits, hyphens,
    /// underscores and dots only; starting and ending with a letter or digit; and not written as a
    /// dotted-decimal IPv4 address.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>Why (Finding 1, #74 review, twelfth pass).</b> The checks above this one are about
    /// injection safety -- no separators, no whitespace, no control characters -- and a name can
    /// pass all of them while still being one GCS can never resolve (uppercase, a single character,
    /// a <c>?</c>). <see cref="GcsUri"/> escapes such a name rather than being confused by it, so
    /// this is not a security hole; the cost is that the allocation looked usable, its Files id was
    /// stamped on an emitted event and the bytes were staged, and the PUT then failed against a
    /// bucket that could not exist. Rejecting the name here instead routes it into the
    /// already-existing pre-emission path for "a target this client can never upload to", which
    /// deletes the allocation and returns
    /// <see cref="ScreenshotPrepareFailureKind.UnusableTarget"/> before any event carries it --
    /// turning a dangling <c>screenshot_id</c> into a clean refusal.
    /// </para>
    /// <para>
    /// <b>What is deliberately not checked.</b> GCS also refuses a name beginning with
    /// <c>goog</c>, and names containing <c>google</c> or a close misspelling of it. Those are not
    /// structural rules, and erring the other way -- refusing a bucket Storage really did allocate
    /// -- would silently stop screenshot delivery altogether, which is far worse than the single
    /// dangling id this check exists to avoid. A name only those rules would reject therefore still
    /// reaches the upload and still ends as a dangling id, exactly as it does today. That asymmetry
    /// is the point: this method only ever converts a would-be dangling id into a clean
    /// pre-emission cleanup, never the reverse.
    /// </para>
    /// </remarks>
    private static bool IsPlausibleGcsBucketName(string bucket)
    {
        const int MaxComponent = 63;
        const int MaxDotted = 222;

        if (bucket.Length < 3 || bucket.Length > MaxDotted)
        {
            return false;
        }

        string[] components = bucket.Split('.');
        if (components.Length == 1 && bucket.Length > MaxComponent)
        {
            return false;
        }

        foreach (char character in bucket)
        {
            if (!char.IsAsciiLetterLower(character)
                && !char.IsAsciiDigit(character)
                && character is not ('-' or '_' or '.'))
            {
                return false;
            }
        }

        if (!IsBucketEdgeCharacter(bucket[0]) || !IsBucketEdgeCharacter(bucket[^1]))
        {
            return false;
        }

        foreach (string component in components)
        {
            if (component.Length is 0 or > MaxComponent)
            {
                return false;
            }
        }

        // Dotted-decimal IPv4 notation is refused by GCS. Shaped explicitly rather than through
        // IPAddress.TryParse, whose tolerance of shorthand and non-decimal forms has changed
        // between .NET versions -- this is a naming rule about the literal text, not an attempt to
        // parse an address.
        bool looksLikeIpv4 = components.Length == 4
            && components.All(component =>
                component.Length is > 0 and <= 3 && component.All(char.IsAsciiDigit));
        return !looksLikeIpv4;
    }

    private static bool IsBucketEdgeCharacter(char character) =>
        char.IsAsciiLetterLower(character) || char.IsAsciiDigit(character);

    /// <summary>
    /// Best-effort <c>DELETE /v2/storage/files/{id}</c>. Its only legitimate callers are within
    /// <see cref="PrepareAsync"/>: a Files id that no event has been emitted with yet, either
    /// because it is a target this client can never upload to, or because the capture path was
    /// cancelled mid-prepare. <see cref="UploadAsync"/> must never call this.
    /// </summary>
    private async Task<bool> DeleteAsync(long id, CancellationToken cancellationToken)
    {
        try
        {
            Uri endpoint = new(
                _prepareEndpoint.GetLeftPart(UriPartial.Authority)
                + "/v2/storage/files/"
                + id.ToString(CultureInfo.InvariantCulture));
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

    /// <summary>
    /// Bounded, best-effort <see cref="DeleteAsync"/> for a Files allocation no event will ever
    /// carry: caller cancellation mid-<see cref="PrepareAsync"/>, or the prepare budget elapsing
    /// after the response was already fully read. Always runs against a fresh
    /// <see cref="ScreenshotDeliverySettings.PrepareCleanupBudget"/> window rather than whatever
    /// token led here -- that token may itself already be cancelled or expired -- and never
    /// throws.
    /// </summary>
    private async Task BestEffortCleanupAsync(long id)
    {
        using var cleanup = new CancellationTokenSource(_settings.PrepareCleanupBudget);
        try { _ = await DeleteAsync(id, cleanup.Token).ConfigureAwait(false); }
        catch { /* Best-effort: this costs storage, not correctness, and must never throw. */ }
    }

    /// <summary>
    /// Deletes a Files allocation that <see cref="PrepareAsync"/> produced but that its caller
    /// will never use -- e.g. <see cref="ScreenshotDeliveryPreparer.Prepare"/> obtained a usable
    /// target but the local staging area then refused or failed to admit the bytes. The ONLY
    /// legitimate window for calling this is before the event carrying <paramref name="id"/> has
    /// been emitted: once an event has gone out with this id, deleting the remote record out from
    /// under it would be worse than leaving it dangling (see this class's own remarks, and why
    /// <see cref="UploadAsync"/> never calls <see cref="DeleteAsync"/>). Bounded by
    /// <see cref="ScreenshotDeliverySettings.PrepareCleanupBudget"/> and never throws.
    /// </summary>
    internal Task CleanupUnusedAllocationAsync(long id) => BestEffortCleanupAsync(id);

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

    private sealed record GcsUpload(string Bucket, string Key, string AccessToken);
}
