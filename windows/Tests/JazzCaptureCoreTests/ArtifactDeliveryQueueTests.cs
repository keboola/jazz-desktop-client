using JazzCaptureCore.Delivery;
using JazzCaptureCore;
using System.Text.Json;

namespace JazzCaptureCoreTests;

public sealed class ArtifactDeliveryQueueTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), "jazz-artifact-queue-" + Guid.NewGuid().ToString("N"));

    [Fact]
    public void ExactBytesAndCanonicalScreenshotIdentitySurviveRelaunch()
    {
        byte[] bytes = [1, 2, 3, 4, 5];
        var descriptor = new ArtifactDeliveryDescriptor(
            "arc-1",
            "cap-1",
            "art-1",
            "art-1",
            "image/jpeg",
            Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes))
                .ToLowerInvariant(),
            bytes.Length,
            bytes);
        bytes[0] = 99;
        ArtifactDeliveryRecord record = new ArtifactDeliveryQueue(root).Enqueue(descriptor);
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
        using JsonDocument document = JsonDocument.Parse(exact);
        JsonElement attributes = document.RootElement
            .GetProperty("resourceLogs")[0]
            .GetProperty("scopeLogs")[0]
            .GetProperty("logRecords")[0]
            .GetProperty("attributes");
        JsonElement screenshot = attributes.EnumerateArray().Single(
            attribute => attribute.GetProperty("key").GetString() == "screenshot_id");
        Assert.Equal("42", screenshot.GetProperty("value").GetProperty("stringValue").GetString());
    }

    [Fact]
    public void ScreenshotMetadataIsCompleteWhenItFirstBecomesVisible()
    {
        byte[] bytes = [1, 2, 3];
        var descriptor = new ArtifactDeliveryDescriptor(
            "arc",
            "cap",
            "art",
            "art",
            "image/jpeg",
            Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes)).ToLowerInvariant(),
            bytes.Length,
            bytes);
        var activityEvent = new ActivityEvent
        {
            SessionId = "ses",
            EventId = "evt",
            Timestamp = "2026-01-01T00:00:00.000Z",
            EventType = "click",
            Url = "app://x",
            ScreenshotId = "art",
        };
        var context = new SessionContext(
            "ses",
            new string('a', 32),
            new string('b', 16),
            activityEvent.Timestamp,
            null,
            "user",
            "host",
            null,
            null);
        ArtifactDeliveryRecord? firstVisibleMetadata = null;
        var queue = new ArtifactDeliveryQueue(root, path =>
        {
            if (Path.GetExtension(path) == ".json")
            {
                firstVisibleMetadata = JsonSerializer.Deserialize<ArtifactDeliveryRecord>(
                    File.ReadAllBytes(path));
            }
        });

        queue.EnqueueScreenshot(descriptor, activityEvent, context);

        Assert.NotNull(firstVisibleMetadata?.CanonicalEvent);
        Assert.NotNull(firstVisibleMetadata?.Context);
        Assert.Equal("art", firstVisibleMetadata!.CanonicalEvent!.ScreenshotId);
    }

    public void Dispose() { if (Directory.Exists(root)) Directory.Delete(root, true); }
}
