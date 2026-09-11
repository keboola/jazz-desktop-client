using JazzCaptureCore.Delivery;
using System.IO;

namespace JazzCapture;

/// <summary>One bounded background pass. Capture never awaits it; every non-success leaves the
/// durable record intact for the next launch or nudge.</summary>
public sealed class ScreenshotDeliveryWorker
{
    private readonly ArtifactDeliveryQueue queue;
    private readonly Action<ScreenshotDeliveryPresentation>? status;
    private readonly Func<ArtifactDeliveryRecord, bool>? isEligible;

    public ScreenshotDeliveryWorker(
        ArtifactDeliveryQueue queue,
        Action<ScreenshotDeliveryPresentation>? status = null,
        Func<ArtifactDeliveryRecord, bool>? isEligible = null)
    {
        this.queue = queue;
        this.status = status;
        this.isEligible = isEligible;
    }

    public async Task DrainOnceAsync(
        IScreenshotFilesTransport files,
        IScreenshotStreamTransport stream,
        CancellationToken ct)
    {
        bool quarantined = false;
        bool terminalAttention = false;
        bool transientRetry = false;
        IReadOnlyList<ArtifactDeliveryRecord> items;
        int pending;
        try
        {
            items = queue.Pending();
            pending = queue.PendingFileCount;
        }
        catch
        {
            status?.Invoke(new(ScreenshotDeliveryStatus.Quarantined, 0));
            throw new ScreenshotDeliveryRetryException();
        }
        foreach (ArtifactDeliveryRecord item in items)
        {
            if (isEligible?.Invoke(item) == false)
            {
                // A journal-owned admission retry has not yet made this record eligible for
                // transport. Leave it untouched, but continue with independent healthy records.
                transientRetry = true;
                continue;
            }
            if (item.Quarantined)
            {
                quarantined = true;
                terminalAttention = true;
                continue;
            }
            status?.Invoke(new(ScreenshotDeliveryStatus.Uploading, pending));
            try
            {
                ArtifactDeliveryRecord bound = item;
                // Every path, including a durably persisted remote Files binding, must prove the
                // original exact bytes before emitting OTLP or acknowledging local evidence.
                byte[] exactBytes = ReadExactBytesOrIntegrityFailure(bound);
                if (bound.RemoteFileId is null)
                {
                    // Validate the retained local evidence before trusting any Files reuse or
                    // creating another remote binding. A complete remote object never authorizes
                    // delivery of an event whose exact local bytes are missing or changed.
                    ScreenshotFileLookupResult found = await files.FindByArtifactAsync(
                        bound,
                        ct).ConfigureAwait(false);
                    if (found.Outcome == ScreenshotFileLookupOutcome.Quarantined)
                    {
                        queue.MarkQuarantined(bound);
                        quarantined = true;
                        terminalAttention = true;
                        continue;
                    }
                    if (found.Outcome == ScreenshotFileLookupOutcome.Retry)
                    {
                        throw new ScreenshotDeliveryRetryException();
                    }

                    long? id = found.Complete.OrderBy(value => value).FirstOrDefault();
                    bool cleanedDangling = await files.DeleteDanglingAsync(
                        found.Dangling,
                        ct).ConfigureAwait(false);
                    if (!cleanedDangling)
                    {
                        throw new ScreenshotDeliveryRetryException();
                    }
                    if (id is > 0)
                    {
                        bound = BindRemoteRetryably(bound, id.Value);
                    }
                    else
                    {
                        FilesUploadResult result = await files.UploadAsync(
                            bound,
                            exactBytes,
                            ct).ConfigureAwait(false);
                        if (result.Outcome != FilesDeliveryOutcome.Acknowledged
                            || result.RemoteFileId is null)
                        {
                            if (result.Outcome == FilesDeliveryOutcome.Quarantined)
                            {
                                queue.MarkQuarantined(bound);
                                quarantined = true;
                                terminalAttention = true;
                                continue;
                            }
                            throw new ScreenshotDeliveryRetryException();
                        }

                        bound = BindRemoteRetryably(bound, result.RemoteFileId.Value);
                    }
                }

                if (await stream.SendExactAsync(
                        ReadExactOtlpOrIntegrityFailure(bound),
                        ct).ConfigureAwait(false)
                    == StreamDeliveryStatus.Streaming)
                {
                    try
                    {
                        queue.Acknowledge(bound);
                    }
                    catch (Exception exception) when (exception is IOException
                        or UnauthorizedAccessException)
                    {
                        throw new ScreenshotDeliveryRetryException();
                    }
                    pending--;
                }
                else
                {
                    throw new ScreenshotDeliveryRetryException();
                }
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                throw;
            }
            catch (ScreenshotDeliveryRetryException)
            {
                // The transport could not establish a safe result. Keep the item retryable.
                transientRetry = true;
                break;
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                // Local ACL/filesystem races are recoverable; never turn them into terminal
                // quarantine merely because they escaped a queue read.
                transientRetry = true;
                break;
            }
            catch
            {
                // Production transports convert network failures to retry outcomes. Anything that
                // still escapes here is a deterministic local queue/integrity failure.
                try { queue.MarkQuarantined(item); }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
                {
                    transientRetry = true;
                    break;
                }
                quarantined = true;
                terminalAttention = true;
            }
        }

        try
        {
            pending = queue.PendingFileCount;
        }
        catch
        {
            status?.Invoke(new(ScreenshotDeliveryStatus.Quarantined, 0));
            throw new ScreenshotDeliveryRetryException();
        }
        try
        {
            terminalAttention |= queue.UnreadableFileCount > 0 || queue.OrphanFileCount > 0;
            quarantined |= terminalAttention;
        }
        catch
        {
            quarantined = true;
            terminalAttention = true;
        }
        if (pending == 0 && !terminalAttention)
        {
            status?.Invoke(new(ScreenshotDeliveryStatus.Streaming, 0));
            return;
        }
        status?.Invoke(new(
            quarantined ? ScreenshotDeliveryStatus.Quarantined : ScreenshotDeliveryStatus.Retrying,
            pending));
        if (terminalAttention && !transientRetry) return;
        throw new ScreenshotDeliveryRetryException();
    }

    private ArtifactDeliveryRecord BindRemoteRetryably(ArtifactDeliveryRecord record, long remoteFileId)
    {
        try { return queue.BindRemoteFile(record, remoteFileId); }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            throw new ScreenshotDeliveryRetryException();
        }
    }

    private byte[] ReadExactBytesOrIntegrityFailure(ArtifactDeliveryRecord record)
    {
        try { return queue.ReadBytes(record); }
        catch (Exception exception) when (exception is FileNotFoundException
            or DirectoryNotFoundException)
        {
            throw new InvalidOperationException("Durable screenshot bytes are unavailable.", exception);
        }
    }

    private byte[] ReadExactOtlpOrIntegrityFailure(ArtifactDeliveryRecord record)
    {
        try { return queue.ReadOtlpBytes(record); }
        catch (Exception exception) when (exception is FileNotFoundException
            or DirectoryNotFoundException)
        {
            throw new InvalidOperationException("Durable screenshot OTLP bytes are unavailable.", exception);
        }
    }
}

public interface IScreenshotFilesTransport
{
    Task<ScreenshotFileLookupResult> FindByArtifactAsync(
        ArtifactDeliveryRecord record,
        CancellationToken ct);
    Task<bool> DeleteDanglingAsync(IEnumerable<long> ids, CancellationToken ct);
    Task<FilesUploadResult> UploadAsync(
        ArtifactDeliveryRecord record,
        byte[] bytes,
        CancellationToken ct);
}

public interface IScreenshotStreamTransport
{
    Task<StreamDeliveryStatus> SendExactAsync(byte[] body, CancellationToken ct);
}

public enum ScreenshotFileLookupOutcome
{
    Ready,
    Retry,
    Quarantined,
}

public sealed record ScreenshotFileLookupResult(
    ScreenshotFileLookupOutcome Outcome,
    IReadOnlyList<long> Complete,
    IReadOnlyList<long> Dangling)
{
    public static ScreenshotFileLookupResult Retry { get; } =
        new(ScreenshotFileLookupOutcome.Retry, Array.Empty<long>(), Array.Empty<long>());

    public static ScreenshotFileLookupResult Quarantined { get; } =
        new(ScreenshotFileLookupOutcome.Quarantined, Array.Empty<long>(), Array.Empty<long>());

    public static ScreenshotFileLookupResult Ready(
        IReadOnlyList<long> complete,
        IReadOnlyList<long> dangling) =>
        new(ScreenshotFileLookupOutcome.Ready, complete, dangling);
}

public enum ScreenshotDeliveryStatus
{
    Waiting,
    NotProvisioned,
    Uploading,
    Retrying,
    Streaming,
    Quarantined,
}

internal sealed class ScreenshotDeliveryRetryException : Exception
{
    internal ScreenshotDeliveryRetryException()
        : base("Screenshot delivery retry pending.")
    {
    }
}

public sealed record ScreenshotDeliveryPresentation(
    ScreenshotDeliveryStatus State,
    int PendingCount)
{
    public string Describe() => State switch
    {
        ScreenshotDeliveryStatus.Uploading => "uploading " + PendingCount,
        ScreenshotDeliveryStatus.Retrying => "retrying " + PendingCount,
        ScreenshotDeliveryStatus.Streaming => PendingCount == 0
            ? "up to date"
            : "waiting " + PendingCount,
        ScreenshotDeliveryStatus.NotProvisioned => "not provisioned",
        ScreenshotDeliveryStatus.Quarantined => "quarantined",
        _ => "waiting " + PendingCount,
    };
}
