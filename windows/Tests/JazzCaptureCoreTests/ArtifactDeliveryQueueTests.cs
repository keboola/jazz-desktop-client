using JazzCaptureCore.Delivery;

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

    public void Dispose() { if (Directory.Exists(root)) Directory.Delete(root, true); }
}
