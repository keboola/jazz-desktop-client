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
        var queue = new ArtifactDeliveryQueue(root);
        ActivityEvent activity = Event("event");
        ArtifactDeliveryRecord record = queue.EnqueueScreenshot(
            Descriptor("art", bytes), activity, Context(activity));
        Assert.Single(queue.Pending());
        queue.Acknowledge(queue.BindRemoteFile(record, 42));
        Assert.Empty(queue.Pending());
    }

    [Fact]
    public void UnreadableMetadataIsCountedWithoutHidingHealthyItems()
    {
        Directory.CreateDirectory(root);
        File.WriteAllText(Path.Combine(root, "broken.json"), "not-json");
        var queue = new ArtifactDeliveryQueue(root);
        Assert.Equal(1, queue.UnreadableFileCount);
        Assert.Empty(queue.Pending());
    }

    [Fact]
    public void RemoteBindingPersistsExactOtlpCopyWithoutMutatingCanonicalEvent()
    {
        byte[] bytes = [8, 9];
        var descriptor = new ArtifactDeliveryDescriptor("arc", "cap", "art", "art", "image/jpeg", Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes)).ToLowerInvariant(), 2, bytes);
        var original = new ActivityEvent { SessionId = "ses", EventId = "evt", Timestamp = "2026-01-01T00:00:00.000Z", EventType = "click", Url = "app://x" };
        var context = new SessionContext("ses", "00000000000000000000000000000000", "0000000000000000", "2026-01-01T00:00:00.000Z", null, "u", "h", null, null);
        var queue = new ArtifactDeliveryQueue(root);
        ArtifactDeliveryRecord bound = queue.BindRemoteFile(queue.EnqueueScreenshot(descriptor, original, context), 42);
        Assert.Null(bound.CanonicalEvent!.ScreenshotId);
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
    public void RemoteBindingIsIdempotentAndCannotReplaceDurableIdentityOrProgress()
    {
        byte[] bytes = [8, 9];
        ActivityEvent activity = Event("event");
        var queue = new ArtifactDeliveryQueue(root);
        ArtifactDeliveryRecord admitted = queue.EnqueueScreenshot(
            Descriptor("art", bytes), activity, Context(activity));

        ArtifactDeliveryRecord bound = queue.BindRemoteFile(admitted, 42);

        Assert.Equal(bound, queue.BindRemoteFile(admitted, 42));
        Assert.Throws<InvalidOperationException>(() => queue.BindRemoteFile(admitted, 43));
        Assert.Throws<InvalidOperationException>(() => queue.BindRemoteFile(
            admitted with { CanonicalEvent = activity with { EventId = "different" } },
            42));
        Assert.Equal(bound, Assert.Single(queue.Pending()));
    }

    [Fact]
    public void RemoteBindingRejectsChangedDurableScreenshotBytes()
    {
        byte[] bytes = [8, 9];
        ActivityEvent activity = Event("event");
        var queue = new ArtifactDeliveryQueue(root);
        ArtifactDeliveryRecord admitted = queue.EnqueueScreenshot(
            Descriptor("art", bytes), activity, Context(activity));
        File.WriteAllBytes(Path.Combine(root, SpoolKey("art") + ".bin"), [0, 0]);

        Assert.Throws<InvalidOperationException>(() => queue.BindRemoteFile(admitted, 42));
        Assert.Empty(Directory.GetFiles(root, "*.otlp"));
        Assert.Single(queue.Pending());
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
        Assert.Null(firstVisibleMetadata!.CanonicalEvent!.ScreenshotId);
    }

    [Fact]
    public void ScreenshotAdmissionRequiresDescriptorToNameItsOwnArtifact()
    {
        byte[] bytes = [1];
        var descriptor = new ArtifactDeliveryDescriptor(
            "arc", "cap", "art", "different", "image/jpeg",
            Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes)).ToLowerInvariant(),
            bytes.Length, bytes);
        var activityEvent = new ActivityEvent
        {
            SessionId = "ses", EventId = "evt", Timestamp = "2026-01-01T00:00:00.000Z",
            EventType = "click", Url = "app://x",
        };
        var context = new SessionContext("ses", new string('a', 32), new string('b', 16),
            activityEvent.Timestamp, null, "user", "host", null, null);

        Assert.Throws<ArgumentException>(() =>
            new ArtifactDeliveryQueue(root).EnqueueScreenshot(descriptor, activityEvent, context));
    }

    [Fact]
    public void OrphanedExactBytesAreReconciledWithoutRewritingThem()
    {
        byte[] bytes = [7, 8, 9];
        var descriptor = Descriptor("art", bytes);
        Directory.CreateDirectory(root);
        string bytesPath = Path.Combine(root, SpoolKey("art") + ".bin");
        File.WriteAllBytes(bytesPath, bytes);
        var activity = Event("evt");
        var context = Context(activity);

        ArtifactDeliveryRecord record = new ArtifactDeliveryQueue(root)
            .EnqueueScreenshot(descriptor, activity, context);

        Assert.Equal(bytes, File.ReadAllBytes(bytesPath));
        ArtifactDeliveryRecord pending = Assert.Single(new ArtifactDeliveryQueue(root).Pending());
        Assert.Equal(record, pending);
        Assert.Equal(activity, pending.CanonicalEvent);
        Assert.Equal(context, pending.Context);
    }

    [Fact]
    public void OrphanedBytesWithDifferentDigestFailClosedAndRemain()
    {
        byte[] incoming = [1, 2];
        Directory.CreateDirectory(root);
        string bytesPath = Path.Combine(root, SpoolKey("art") + ".bin");
        File.WriteAllBytes(bytesPath, [9, 9]);
        var activity = Event("evt");

        Assert.Throws<InvalidOperationException>(() => new ArtifactDeliveryQueue(root)
            .EnqueueScreenshot(Descriptor("art", incoming), activity, Context(activity)));

        Assert.Equal(new byte[] { 9, 9 }, File.ReadAllBytes(bytesPath));
        Assert.Empty(Directory.GetFiles(root, "*.json"));
    }

    [Fact]
    public void ReplayWithChangedCanonicalAdmissionFailsClosedAndRetainsOriginal()
    {
        byte[] bytes = [1];
        var descriptor = Descriptor("art", bytes);
        var queue = new ArtifactDeliveryQueue(root);
        var original = Event("first");
        queue.EnqueueScreenshot(descriptor, original, Context(original));
        var conflicting = Event("second");

        Assert.Throws<InvalidOperationException>(() => queue.EnqueueScreenshot(
            descriptor, conflicting, Context(conflicting)));

        ArtifactDeliveryRecord pending = Assert.Single(queue.Pending());
        Assert.Equal("first", pending.CanonicalEvent!.EventId);
        Assert.Equal(bytes, queue.ReadBytes(pending));
    }

    [Fact]
    public void ReplayWithChangedSessionContextFailsClosed()
    {
        byte[] bytes = [1];
        var queue = new ArtifactDeliveryQueue(root);
        var activity = Event("event");
        queue.EnqueueScreenshot(Descriptor("art", bytes), activity, Context(activity));
        SessionContext conflicting = Context(activity) with { User = "other-user" };

        Assert.Throws<InvalidOperationException>(() => queue.EnqueueScreenshot(
            Descriptor("art", bytes), activity, conflicting));
        Assert.Single(queue.Pending());
    }

    [Fact]
    public void CompletionMarkerSurvivesCleanupFailureAndReopenDoesNotResendIt()
    {
        byte[] bytes = [1];
        var deletes = new List<string>();
        var queue = new ArtifactDeliveryQueue(root, deleteFile: path =>
        {
            deletes.Add(Path.GetExtension(path));
            if (Path.GetExtension(path) == ".bin") throw new IOException("simulated");
            File.Delete(path);
        });
        var activity = Event("event");
        ArtifactDeliveryRecord bound = queue.BindRemoteFile(
            queue.EnqueueScreenshot(Descriptor("art", bytes), activity, Context(activity)), 42);

        queue.Acknowledge(bound);
        Assert.Equal(new[] { ".bin" }, deletes);

        ArtifactDeliveryRecord marker = JsonSerializer.Deserialize<ArtifactDeliveryRecord>(
            File.ReadAllBytes(Assert.Single(Directory.GetFiles(root, "*.json"))))!;
        Assert.True(marker.Acknowledged);
        Assert.Empty(new ArtifactDeliveryQueue(root).Pending());
        Assert.Empty(Directory.GetFiles(root));
    }

    [Fact]
    public void UnknownPayloadOrphansAreRetainedAndCounted()
    {
        Directory.CreateDirectory(root);
        string bin = Path.Combine(root, "unknown.bin");
        string otlp = Path.Combine(root, "unknown.otlp");
        string temporary = Path.Combine(root, "unknown.bin.tmp");
        File.WriteAllBytes(bin, [1]); File.WriteAllBytes(otlp, [2]); File.WriteAllBytes(temporary, [3]);
        File.SetLastWriteTimeUtc(temporary, DateTime.UtcNow.AddHours(-1));
        var queue = new ArtifactDeliveryQueue(root);

        Assert.Equal(3, queue.OrphanFileCount);
        Assert.Equal(new byte[] { 1 }, File.ReadAllBytes(bin));
        Assert.Equal(new byte[] { 2 }, File.ReadAllBytes(otlp));
        Assert.Equal(new byte[] { 3 }, File.ReadAllBytes(temporary));
    }

    [Fact]
    public void ActiveAtomicPublishTemporaryIsRetainedWithoutFalseAttention()
    {
        Directory.CreateDirectory(root);
        string temporary = Path.Combine(root, "unknown.bin.in-flight.tmp");
        File.WriteAllBytes(temporary, [3]);

        Assert.Equal(0, new ArtifactDeliveryQueue(root).OrphanFileCount);
        Assert.Equal(new byte[] { 3 }, File.ReadAllBytes(temporary));
    }

    [Fact]
    public void RenamedMetadataIsUnreadableAttentionAndNeverDuplicatesPendingWork()
    {
        byte[] bytes = [1];
        var queue = new ArtifactDeliveryQueue(root);
        var activity = Event("event");
        queue.EnqueueScreenshot(Descriptor("art", bytes), activity, Context(activity));
        string canonical = Assert.Single(Directory.GetFiles(root, "*.json"));
        string copied = Path.Combine(root, "renamed.json");
        File.Copy(canonical, copied);

        Assert.Single(queue.Pending());
        Assert.Equal(1, queue.UnreadableFileCount);
        Assert.True(File.Exists(copied));
    }

    [Fact]
    public void UnboundScreenshotCannotBeAcknowledged()
    {
        byte[] bytes = [1];
        var queue = new ArtifactDeliveryQueue(root);
        var activity = Event("event");
        ArtifactDeliveryRecord record = queue.EnqueueScreenshot(
            Descriptor("art", bytes), activity, Context(activity));

        Assert.Throws<InvalidOperationException>(() => queue.Acknowledge(record));
        Assert.Single(queue.Pending());
        Assert.Equal(bytes, queue.ReadBytes(record));
    }

    [Fact]
    public void AcknowledgementCannotChangeCanonicalAdmissionIdentity()
    {
        byte[] bytes = [1];
        var queue = new ArtifactDeliveryQueue(root);
        ActivityEvent activity = Event("event");
        ArtifactDeliveryRecord bound = queue.BindRemoteFile(queue.EnqueueScreenshot(
            Descriptor("art", bytes), activity, Context(activity)), 42);

        Assert.Throws<InvalidOperationException>(() => queue.Acknowledge(
            bound with { CanonicalEvent = activity with { EventId = "different" } }));
        Assert.Single(queue.Pending());
        Assert.Equal(bytes, queue.ReadBytes(bound));
        Assert.NotEmpty(queue.ReadOtlpBytes(bound));
    }

    [Fact]
    public void QuarantinePersistsUntilExplicitMatchingRequeue()
    {
        byte[] bytes = [1];
        var activity = Event("event");
        var queue = new ArtifactDeliveryQueue(root);
        ArtifactDeliveryRecord record = queue.EnqueueScreenshot(Descriptor("art", bytes), activity, Context(activity));
        queue.MarkQuarantined(record);
        ArtifactDeliveryRecord quarantined = Assert.Single(new ArtifactDeliveryQueue(root).Pending());
        Assert.True(quarantined.Quarantined);
        Assert.True(queue.EnqueueScreenshot(Descriptor("art", bytes), activity, Context(activity)).Quarantined);
        Assert.Throws<InvalidOperationException>(() => queue.RequeueQuarantined(
            quarantined with { CanonicalEvent = activity with { EventId = "wrong" } }));

        queue.RequeueQuarantined(quarantined);
        Assert.False(Assert.Single(new ArtifactDeliveryQueue(root).Pending()).Quarantined);
        Assert.Throws<InvalidOperationException>(() => queue.RequeueQuarantined(record));
    }

    [Fact]
    public void AcknowledgedMarkerIsNotReadmittedWhenPayloadCleanupIsIncomplete()
    {
        byte[] bytes = [1];
        var activity = Event("event");
        var queue = new ArtifactDeliveryQueue(root, deleteFile: _ => throw new IOException());
        ArtifactDeliveryRecord bound = queue.BindRemoteFile(
            queue.EnqueueScreenshot(Descriptor("art", bytes), activity, Context(activity)), 42);
        queue.Acknowledge(bound);
        File.Delete(Assert.Single(Directory.GetFiles(root, "*.bin")));
        File.Delete(Assert.Single(Directory.GetFiles(root, "*.otlp")));

        ArtifactDeliveryRecord completed = queue.EnqueueScreenshot(Descriptor("art", bytes), activity, Context(activity));
        Assert.True(completed.Acknowledged);
        Assert.NotEmpty(Directory.GetFiles(root, "*.json"));
    }

    [Fact]
    public void RootProtectionIsReappliedAfterDirectoryRecreation()
    {
        int protections = 0;
        var queue = new ArtifactDeliveryQueue(
            root,
            protectDirectory: path =>
            {
                Assert.Equal(Path.GetFullPath(root), path);
                protections++;
            });
        ActivityEvent first = Event("first");
        queue.EnqueueScreenshot(Descriptor("first", [1]), first, Context(first));
        int afterFirstAdmission = protections;
        Directory.Delete(root, true);
        ActivityEvent second = Event("second");

        queue.EnqueueScreenshot(Descriptor("second", [2]), second, Context(second));

        Assert.True(protections > afterFirstAdmission);
        Assert.Single(queue.Pending());
    }

    [Fact]
    public void RedirectedRootIsRejectedWithoutWritingThroughIt()
    {
        string external = Path.Combine(
            Path.GetTempPath(),
            "jazz-artifact-external-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(external);
        try
        {
            try
            {
                Directory.CreateSymbolicLink(root, external);
            }
            catch (Exception exception) when (exception is UnauthorizedAccessException
                or PlatformNotSupportedException
                or IOException)
            {
                return;
            }

            ActivityEvent activity = Event("event");
            Assert.Throws<InvalidOperationException>(() => new ArtifactDeliveryQueue(root)
                .EnqueueScreenshot(Descriptor("art", [1]), activity, Context(activity)));
            Assert.Empty(Directory.EnumerateFileSystemEntries(external));
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root);
            if (Directory.Exists(external)) Directory.Delete(external, true);
        }
    }

    [Fact]
    public void RedirectedRootAncestorIsRejectedWithoutWritingThroughIt()
    {
        string parent = Path.Combine(
            Path.GetTempPath(),
            "jazz-artifact-parent-" + Guid.NewGuid().ToString("N"));
        string external = Path.Combine(
            Path.GetTempPath(),
            "jazz-artifact-external-" + Guid.NewGuid().ToString("N"));
        string redirected = Path.Combine(parent, "redirected");
        Directory.CreateDirectory(parent);
        Directory.CreateDirectory(external);
        try
        {
            try
            {
                Directory.CreateSymbolicLink(redirected, external);
            }
            catch (Exception exception) when (exception is UnauthorizedAccessException
                or PlatformNotSupportedException
                or IOException)
            {
                return;
            }

            string nestedRoot = Path.Combine(redirected, "screenshots");
            ActivityEvent activity = Event("event");
            Assert.Throws<InvalidOperationException>(() => new ArtifactDeliveryQueue(nestedRoot)
                .EnqueueScreenshot(Descriptor("art", [1]), activity, Context(activity)));
            Assert.Empty(Directory.EnumerateFileSystemEntries(external));
        }
        finally
        {
            if (Directory.Exists(redirected)) Directory.Delete(redirected);
            if (Directory.Exists(parent)) Directory.Delete(parent, true);
            if (Directory.Exists(external)) Directory.Delete(external, true);
        }
    }

    [Fact]
    public void RedirectedMetadataIsRetainedAsUnreadableAndNeverFollowed()
    {
        byte[] bytes = [1];
        ActivityEvent activity = Event("event");
        var queue = new ArtifactDeliveryQueue(root);
        ArtifactDeliveryRecord record = queue.EnqueueScreenshot(
            Descriptor("art", bytes), activity, Context(activity));
        string metadataPath = Assert.Single(Directory.GetFiles(root, "*.json"));
        string external = Path.Combine(
            Path.GetTempPath(),
            "jazz-artifact-metadata-" + Guid.NewGuid().ToString("N") + ".json");
        File.Move(metadataPath, external);
        try
        {
            try
            {
                File.CreateSymbolicLink(metadataPath, external);
            }
            catch (Exception exception) when (exception is UnauthorizedAccessException
                or PlatformNotSupportedException
                or IOException)
            {
                File.Move(external, metadataPath);
                return;
            }

            byte[] unchanged = File.ReadAllBytes(external);
            Assert.Empty(queue.Pending());
            Assert.Equal(1, queue.UnreadableFileCount);
            Assert.Throws<InvalidOperationException>(() => queue.BindRemoteFile(record, 1));
            Assert.Equal(unchanged, File.ReadAllBytes(external));
        }
        finally
        {
            if (File.Exists(metadataPath)) File.Delete(metadataPath);
            if (File.Exists(external)) File.Delete(external);
        }
    }

    private static ArtifactDeliveryDescriptor Descriptor(string artifactId, byte[] bytes) => new(
        "arc", "cap", artifactId, artifactId, "image/jpeg",
        Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes)).ToLowerInvariant(),
        bytes.Length, bytes);

    private static ActivityEvent Event(string eventId) => new()
    {
        SessionId = "ses", EventId = eventId, Timestamp = "2026-01-01T00:00:00.000Z",
        EventType = "click", Url = "app://x",
    };

    private static SessionContext Context(ActivityEvent activity) => new(
        "ses", new string('a', 32), new string('b', 16), activity.Timestamp,
        null, "user", "host", null, null);

    private static string SpoolKey(string artifactId) => Convert.ToHexString(
        System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(artifactId)))
        .ToLowerInvariant();

    public void Dispose() { if (Directory.Exists(root)) Directory.Delete(root, true); }
}
