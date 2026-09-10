using JazzCapture;
using JazzCaptureCore;
using JazzCaptureCore.Delivery;

namespace JazzCaptureHostTests;

public sealed class ScreenshotDeliveryWorkerTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));

    [Fact]
    public async Task RemoteBindingSurvivesOtlpFailureWithoutReupload()
    {
        byte[] bytes = [1];
        var queue = new ArtifactDeliveryQueue(root);
        var descriptor = new ArtifactDeliveryDescriptor("a", "c", "art", "art", "image/jpeg", Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes)).ToLowerInvariant(), 1, bytes);
        var eventValue = new ActivityEvent { SessionId = "s", EventId = "e", Timestamp = "2026-01-01T00:00:00Z", EventType = "click", Url = "x", ScreenshotId = "art" };
        var context = new SessionContext("s", new string('a', 32), new string('b', 16), eventValue.Timestamp, null, "u", "h", null, null);
        queue.EnqueueScreenshot(descriptor, eventValue, context);
        var files = new FakeFiles(); var failed = new FakeStream(StreamDeliveryStatus.Unreachable); var statuses = new List<ScreenshotDeliveryPresentation>();
        await Assert.ThrowsAsync<Exception>(() => new ScreenshotDeliveryWorker(queue, statuses.Add).DrainOnceAsync(files, failed, CancellationToken.None));
        Assert.Contains(statuses, x => x.State == ScreenshotDeliveryStatus.Retrying && x.PendingCount > 0);
        Assert.DoesNotContain(statuses, x => x.State == ScreenshotDeliveryStatus.Streaming);
        byte[] persisted = queue.ReadOtlpBytes(Assert.Single(queue.Pending()));
        var succeeded = new FakeStream(StreamDeliveryStatus.Streaming);
        var final = new List<ScreenshotDeliveryPresentation>(); await new ScreenshotDeliveryWorker(new ArtifactDeliveryQueue(root), final.Add).DrainOnceAsync(files, succeeded, CancellationToken.None);
        Assert.Equal(1, files.Uploads); Assert.Equal(persisted, succeeded.Bytes); Assert.Empty(queue.Pending()); Assert.Contains(final, x => x.State == ScreenshotDeliveryStatus.Streaming && x.PendingCount == 0);
    }

    public void Dispose() { if (Directory.Exists(root)) Directory.Delete(root, true); }
    private sealed class FakeFiles : IScreenshotFilesTransport
    {
        public int Uploads;
        public Task<(IReadOnlyList<long> Complete, IReadOnlyList<long> Dangling)> FindByArtifactAsync(string id, CancellationToken ct) => Task.FromResult<(IReadOnlyList<long>, IReadOnlyList<long>)>((Array.Empty<long>(), Array.Empty<long>()));
        public Task DeleteDanglingAsync(IEnumerable<long> ids, CancellationToken ct) => Task.CompletedTask;
        public Task<FilesUploadResult> UploadAsync(ArtifactDeliveryRecord r, byte[] b, CancellationToken ct) { Uploads++; return Task.FromResult(FilesUploadResult.Uploaded(7)); }
    }
    private sealed class FakeStream(StreamDeliveryStatus result) : IScreenshotStreamTransport
    { public byte[]? Bytes; public Task<StreamDeliveryStatus> SendExactAsync(byte[] body, CancellationToken ct) { Bytes = body; return Task.FromResult(result); } }
}
