using JazzCaptureCore.Delivery;

namespace JazzCapture;

/// <summary>One bounded background pass. Capture never awaits it; every non-success leaves the
/// durable record intact for the next launch or nudge.</summary>
public sealed class ScreenshotDeliveryWorker
{
    private readonly ArtifactDeliveryQueue queue;
    public ScreenshotDeliveryWorker(ArtifactDeliveryQueue queue) => this.queue = queue;
    public async Task DrainOnceAsync(KeboolaFilesClient files, MvpStreamSender stream, CancellationToken ct)
    {
        foreach (ArtifactDeliveryRecord item in queue.Pending())
        {
            try {
                ArtifactDeliveryRecord bound = item;
                if (bound.RemoteFileId is null) {
                    var found = await files.FindByArtifactAsync(bound.ArtifactId, ct).ConfigureAwait(false);
                    await files.DeleteDanglingAsync(found.Dangling, ct).ConfigureAwait(false);
                    long? id = found.Complete.OrderBy(x => x).FirstOrDefault();
                    if (id is > 0) bound = queue.BindRemoteFile(bound, id.Value);
                    else { FilesUploadResult result = await files.UploadAsync(bound, queue.ReadBytes(bound), ct).ConfigureAwait(false); if (result.Outcome != FilesDeliveryOutcome.Acknowledged || result.RemoteFileId is null) continue; bound = queue.BindRemoteFile(bound, result.RemoteFileId.Value); }
                }
                if (await stream.SendExactAsync(queue.ReadOtlpBytes(bound), ct).ConfigureAwait(false) == StreamDeliveryStatus.Streaming) queue.Acknowledge(bound);
            } catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; } catch { /* retain item and continue with the next one */ }
        }
    }
}
