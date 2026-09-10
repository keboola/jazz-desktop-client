using JazzCaptureCore.Delivery;

namespace JazzCapture;

/// <summary>One bounded background pass. Capture never awaits it; every non-success leaves the
/// durable record intact for the next launch or nudge.</summary>
public sealed class ScreenshotDeliveryWorker
{
    private readonly ArtifactDeliveryQueue queue;
    private readonly Action<ScreenshotDeliveryPresentation>? status;
    public ScreenshotDeliveryWorker(ArtifactDeliveryQueue queue, Action<ScreenshotDeliveryPresentation>? status = null) { this.queue = queue; this.status = status; }
    public async Task DrainOnceAsync(IScreenshotFilesTransport files, IScreenshotStreamTransport stream, CancellationToken ct)
    {
        foreach (ArtifactDeliveryRecord item in queue.Pending())
        {
            status?.Invoke(new(ScreenshotDeliveryStatus.Uploading, queue.Pending().Count));
            try {
                ArtifactDeliveryRecord bound = item;
                if (bound.RemoteFileId is null) {
                    ScreenshotFileLookupResult found = await files.FindByArtifactAsync(bound.ArtifactId, ct).ConfigureAwait(false);
                    if (found.Outcome == ScreenshotFileLookupOutcome.Retry
                        || !await files.DeleteDanglingAsync(found.Dangling, ct).ConfigureAwait(false))
                        throw new ScreenshotDeliveryRetryException();
                    long? id = found.Complete.OrderBy(x => x).FirstOrDefault();
                    if (id is > 0) bound = queue.BindRemoteFile(bound, id.Value);
                    else { FilesUploadResult result = await files.UploadAsync(bound, queue.ReadBytes(bound), ct).ConfigureAwait(false); if (result.Outcome != FilesDeliveryOutcome.Acknowledged || result.RemoteFileId is null) continue; bound = queue.BindRemoteFile(bound, result.RemoteFileId.Value); }
                }
                if (await stream.SendExactAsync(queue.ReadOtlpBytes(bound), ct).ConfigureAwait(false) == StreamDeliveryStatus.Streaming) queue.Acknowledge(bound); else status?.Invoke(new(ScreenshotDeliveryStatus.Retrying, queue.Pending().Count));
            } catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; } catch { status?.Invoke(new(ScreenshotDeliveryStatus.Retrying, queue.Pending().Count)); }
        }
        int pending = queue.Pending().Count;
        if (pending == 0) { status?.Invoke(new(ScreenshotDeliveryStatus.Streaming, 0)); return; }
        status?.Invoke(new(ScreenshotDeliveryStatus.Retrying, pending));
        throw new ScreenshotDeliveryRetryException();
    }
}
public interface IScreenshotFilesTransport
{
    Task<ScreenshotFileLookupResult> FindByArtifactAsync(string id, CancellationToken ct);
    Task<bool> DeleteDanglingAsync(IEnumerable<long> ids, CancellationToken ct);
    Task<FilesUploadResult> UploadAsync(ArtifactDeliveryRecord r, byte[] b, CancellationToken ct);
}
public interface IScreenshotStreamTransport { Task<StreamDeliveryStatus> SendExactAsync(byte[] body, CancellationToken ct); }
public enum ScreenshotFileLookupOutcome { Ready, Retry }
public sealed record ScreenshotFileLookupResult(
    ScreenshotFileLookupOutcome Outcome,
    IReadOnlyList<long> Complete,
    IReadOnlyList<long> Dangling)
{
    public static ScreenshotFileLookupResult Retry { get; } =
        new(ScreenshotFileLookupOutcome.Retry, Array.Empty<long>(), Array.Empty<long>());
    public static ScreenshotFileLookupResult Ready(
        IReadOnlyList<long> complete,
        IReadOnlyList<long> dangling) =>
        new(ScreenshotFileLookupOutcome.Ready, complete, dangling);
}
public enum ScreenshotDeliveryStatus { Waiting, NotProvisioned, Uploading, Retrying, Streaming, Quarantined }
internal sealed class ScreenshotDeliveryRetryException : Exception { internal ScreenshotDeliveryRetryException() : base("Screenshot delivery retry pending.") { } }
public sealed record ScreenshotDeliveryPresentation(ScreenshotDeliveryStatus State, int PendingCount)
{ public string Describe() => State switch { ScreenshotDeliveryStatus.Uploading => "uploading " + PendingCount, ScreenshotDeliveryStatus.Retrying => "retrying " + PendingCount, ScreenshotDeliveryStatus.Streaming => PendingCount == 0 ? "up to date" : "waiting " + PendingCount, ScreenshotDeliveryStatus.NotProvisioned => "not provisioned", ScreenshotDeliveryStatus.Quarantined => "quarantined", _ => "waiting " + PendingCount }; }
