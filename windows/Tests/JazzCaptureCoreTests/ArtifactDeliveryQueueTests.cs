using JazzCaptureCore.Delivery;
using JazzCaptureCore;

namespace JazzCaptureCoreTests;

public sealed class ArtifactDeliveryQueueTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), "jazz-artifact-queue-" + Guid.NewGuid().ToString("N"));

    [Fact]
    public void ExactBytesAndCanonicalScreenshotIdentitySurviveRelaunch()
    {
        byte[] bytes = [1, 2, 3, 4, 5];
        var descriptor = new ArtifactDeliveryDescriptor("arc-1", "cap-1", "art-1", "art-1", "image/jpeg", "74f81fe167d99b4c", bytes.Length, bytes);
        // Use the actual digest rather than trusting a caller-supplied one.
        descriptor = descriptor with { Sha256 = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes)).ToLowerInvariant() };
        ArtifactDeliveryRecord record = new ArtifactDeliveryQueue(root).Enqueue(descriptor);
        bytes[0] = 99;
        var reopened = new ArtifactDeliveryQueue(root);
        ArtifactDeliveryRecord pending = Assert.Single(reopened.Pending());
        Assert.Equal(record.ArtifactId, pending.ScreenshotId);
        Assert.Equal(new byte[] { 1, 2, 3, 4, 5 }, reopened.ReadBytes(pending));
    }

    [Fact]
    public void FailedWorkIsRetainedUntilAcknowledged()
    {
        byte[] bytes = [1];
        var descriptor = new ArtifactDeliveryDescriptor("arc", "cap", "art", "art", "image/jpeg", Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes)).ToLowerInvariant(), 1, bytes);
        var queue = new ArtifactDeliveryQueue(root);
        ArtifactDeliveryRecord record = queue.Enqueue(descriptor);
        Assert.Single(queue.Pending());
        queue.Acknowledge(record);
        Assert.Empty(queue.Pending());
    }

    [Fact]
    public void RemoteBindingPersistsExactOtlpCopyWithoutMutatingCanonicalEvent()
    {
        byte[] bytes = [8, 9];
        var descriptor = new ArtifactDeliveryDescriptor("arc", "cap", "art", "art", "image/jpeg", Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes)).ToLowerInvariant(), 2, bytes);
        var original = new ActivityEvent { SessionId = "ses", EventId = "evt", Timestamp = "2026-01-01T00:00:00.000Z", EventType = "click", Url = "app://x", ScreenshotId = "art" };
        var context = new SessionContext("ses", "00000000000000000000000000000000", "0000000000000000", "2026-01-01T00:00:00.000Z", null, "u", "h", null, null);
        var queue = new ArtifactDeliveryQueue(root);
        ArtifactDeliveryRecord bound = queue.BindRemoteFile(queue.EnqueueScreenshot(descriptor, original, context), 42);
        Assert.Equal("art", bound.CanonicalEvent!.ScreenshotId);
        Assert.Equal(42, bound.RemoteFileId);
        byte[] exact = queue.ReadOtlpBytes(bound);
        Assert.Equal(exact, new ArtifactDeliveryQueue(root).ReadOtlpBytes(Assert.Single(new ArtifactDeliveryQueue(root).Pending())));
        Assert.Contains("42", System.Text.Encoding.UTF8.GetString(exact));
    }

    public void Dispose() { if (Directory.Exists(root)) Directory.Delete(root, true); }
}
