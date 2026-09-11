using JazzCapture;
using JazzCaptureCore;
using JazzCaptureCore.Delivery;

namespace JazzCaptureHostTests;

public sealed class ScreenshotDeliveryWorkerTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));

    [Fact]
    public async Task CompleteTaggedFileIsReusedWithoutUpload()
    {
        byte[] bytes = [2]; var queue = new ArtifactDeliveryQueue(root); var descriptor = new ArtifactDeliveryDescriptor("a", "c", "art", "art", "image/jpeg", Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes)).ToLowerInvariant(), 1, bytes);
        var original = new ActivityEvent { SessionId = "s", EventId = "e", Timestamp = "2026-01-01T00:00:00Z", EventType = "click", Url = "x", ScreenshotId = "art" };
        queue.EnqueueScreenshot(descriptor, original, new SessionContext("s", new string('a', 32), new string('b', 16), original.Timestamp, null, "u", "h", null, null));
        var files = new FakeFiles { Complete = [42] }; var stream = new FakeStream(StreamDeliveryStatus.Streaming);
        await new ScreenshotDeliveryWorker(queue).DrainOnceAsync(files, stream, CancellationToken.None);
        Assert.Equal(0, files.Uploads); Assert.Equal("art", original.ScreenshotId); Assert.Contains("42", System.Text.Encoding.UTF8.GetString(stream.Bytes!)); Assert.Empty(queue.Pending());
    }

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
        Exception retry = await Assert.ThrowsAnyAsync<Exception>(() => new ScreenshotDeliveryWorker(queue, statuses.Add).DrainOnceAsync(files, failed, CancellationToken.None)); Assert.Equal("Screenshot delivery retry pending.", retry.Message);
        Assert.Contains(statuses, x => x.State == ScreenshotDeliveryStatus.Retrying && x.PendingCount > 0);
        Assert.DoesNotContain(statuses, x => x.State == ScreenshotDeliveryStatus.Streaming);
        byte[] persisted = queue.ReadOtlpBytes(Assert.Single(queue.Pending()));
        var succeeded = new FakeStream(StreamDeliveryStatus.Streaming);
        var final = new List<ScreenshotDeliveryPresentation>(); await new ScreenshotDeliveryWorker(new ArtifactDeliveryQueue(root), final.Add).DrainOnceAsync(files, succeeded, CancellationToken.None);
        Assert.Equal(1, files.Uploads); Assert.Equal(persisted, succeeded.Bytes); Assert.Empty(queue.Pending()); Assert.Contains(final, x => x.State == ScreenshotDeliveryStatus.Streaming && x.PendingCount == 0);
    }

    [Fact]
    public async Task CleanupFailureAfterDurableAcknowledgementRetriesWithoutQuarantineOrReplay()
    {
        var queue = new ArtifactDeliveryQueue(
            root,
            deleteFile: _ => throw new IOException("simulated cleanup interruption"));
        Add(queue, "one");
        var statuses = new List<ScreenshotDeliveryPresentation>();

        await Assert.ThrowsAsync<ScreenshotDeliveryRetryException>(() =>
            new ScreenshotDeliveryWorker(queue, statuses.Add).DrainOnceAsync(
                new FakeFiles(),
                new FakeStream(StreamDeliveryStatus.Streaming),
                CancellationToken.None));

        ArtifactDeliveryRecord marker = System.Text.Json.JsonSerializer
            .Deserialize<ArtifactDeliveryRecord>(File.ReadAllBytes(
                Assert.Single(Directory.GetFiles(root, "*.json"))))!;
        Assert.True(marker.Acknowledged);
        Assert.False(marker.Quarantined);
        Assert.Empty(queue.Pending());
        Assert.Contains(statuses, value => value.State == ScreenshotDeliveryStatus.Retrying);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task PersistedRemoteBindingNeverStreamsInvalidLocalBytes(bool change)
    {
        byte[] bytes = [1]; var queue = new ArtifactDeliveryQueue(root);
        var descriptor = new ArtifactDeliveryDescriptor("a", "c", "art", "art", "image/jpeg", Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes)).ToLowerInvariant(), 1, bytes);
        var activity = new ActivityEvent { SessionId = "s", EventId = "e", Timestamp = "2026-01-01T00:00:00Z", EventType = "click", Url = "x" };
        ArtifactDeliveryRecord bound = queue.BindRemoteFile(queue.EnqueueScreenshot(descriptor, activity,
            new SessionContext("s", new string('a', 32), new string('b', 16), activity.Timestamp, null, "u", "h", null, null)), 42);
        string bin = Assert.Single(Directory.GetFiles(root, "*.bin"));
        if (change) File.WriteAllBytes(bin, [9]); else File.Delete(bin);
        var files = new FakeFiles(); var stream = new FakeStream(StreamDeliveryStatus.Streaming);

        await new ScreenshotDeliveryWorker(queue).DrainOnceAsync(files, stream, CancellationToken.None);

        Assert.Equal(0, files.Lookups); Assert.Equal(0, files.Uploads); Assert.Null(stream.Bytes);
        Assert.True(Assert.Single(queue.Pending()).Quarantined);
    }

    [Fact]
    public async Task FailedDanglingDeleteRetainsWorkWithoutUploadOrStream()
    {
        byte[] bytes = [3];
        var queue = new ArtifactDeliveryQueue(root);
        var descriptor = new ArtifactDeliveryDescriptor(
            "a", "c", "art", "art", "image/jpeg",
            Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes)).ToLowerInvariant(),
            bytes.Length,
            bytes);
        var activityEvent = new ActivityEvent
        {
            SessionId = "s",
            EventId = "e",
            Timestamp = "2026-01-01T00:00:00Z",
            EventType = "click",
            Url = "x",
            ScreenshotId = "art",
        };
        queue.EnqueueScreenshot(
            descriptor,
            activityEvent,
            new SessionContext(
                "s", new string('a', 32), new string('b', 16), activityEvent.Timestamp,
                null, "u", "h", null, null));
        var files = new FakeFiles { Dangling = [41], DeleteSucceeds = false };
        var stream = new FakeStream(StreamDeliveryStatus.Streaming);

        await Assert.ThrowsAnyAsync<Exception>(() =>
            new ScreenshotDeliveryWorker(queue).DrainOnceAsync(
                files, stream, CancellationToken.None));

        Assert.Equal(0, files.Uploads);
        Assert.Equal(1, files.Deletes);
        Assert.Null(stream.Bytes);
        Assert.Single(queue.Pending());
    }

    [Fact]
    public async Task VerifiedCompleteFileRemainsRetryableWhenDuplicateCleanupFails()
    {
        var queue = new ArtifactDeliveryQueue(root); Add(queue, "one");
        var files = new FakeFiles
        {
            Complete = [42],
            Dangling = [41],
            DeleteSucceeds = false,
        };
        var stream = new FakeStream(StreamDeliveryStatus.Streaming);

        await Assert.ThrowsAsync<ScreenshotDeliveryRetryException>(() =>
            new ScreenshotDeliveryWorker(queue).DrainOnceAsync(
                files, stream, CancellationToken.None));

        Assert.Equal(1, files.Lookups); Assert.Equal(1, files.Deletes);
        Assert.Equal(0, files.Uploads); Assert.Null(stream.Bytes);
        Assert.Single(queue.Pending());
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task MissingOrChangedLocalBytesAreQuarantinedAndRetained(bool changeBytes)
    {
        byte[] bytes = [4, 5, 6];
        var queue = new ArtifactDeliveryQueue(root);
        var descriptor = new ArtifactDeliveryDescriptor(
            "a",
            "c",
            "art",
            "art",
            "image/jpeg",
            Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes)).ToLowerInvariant(),
            bytes.Length,
            bytes);
        var activityEvent = new ActivityEvent
        {
            SessionId = "s",
            EventId = "e",
            Timestamp = "2026-01-01T00:00:00Z",
            EventType = "click",
            Url = "x",
            ScreenshotId = "art",
        };
        queue.EnqueueScreenshot(
            descriptor,
            activityEvent,
            new SessionContext(
                "s",
                new string('a', 32),
                new string('b', 16),
                activityEvent.Timestamp,
                null,
                "u",
                "h",
                null,
                null));
        string bytesPath = Assert.Single(Directory.GetFiles(root, "*.bin"));
        if (changeBytes)
        {
            File.WriteAllBytes(bytesPath, [9, 9, 9]);
        }
        else
        {
            File.Delete(bytesPath);
        }
        var statuses = new List<ScreenshotDeliveryPresentation>();
        var files = new FakeFiles { Complete = [42] };
        var stream = new FakeStream(StreamDeliveryStatus.Streaming);

        await new ScreenshotDeliveryWorker(queue, statuses.Add).DrainOnceAsync(
            files,
            stream,
            CancellationToken.None);

        Assert.Contains(statuses, status => status.State == ScreenshotDeliveryStatus.Quarantined);
        Assert.True(Assert.Single(new ArtifactDeliveryQueue(root).Pending()).Quarantined);
        Assert.Equal(0, files.Uploads);
        Assert.Equal(0, files.Lookups);
        Assert.Null(stream.Bytes);
    }

    [Fact]
    public async Task OrphanOnlySpoolIsTerminalAttentionNotStreaming()
    {
        Directory.CreateDirectory(root);
        string orphan = Path.Combine(root, "unknown.bin");
        byte[] bytes = [7, 8, 9];
        File.WriteAllBytes(orphan, bytes);
        var statuses = new List<ScreenshotDeliveryPresentation>();
        var files = new FakeFiles();
        var stream = new FakeStream(StreamDeliveryStatus.Streaming);

        await new ScreenshotDeliveryWorker(new ArtifactDeliveryQueue(root), statuses.Add)
            .DrainOnceAsync(files, stream, CancellationToken.None);

        Assert.Contains(statuses, status => status.State == ScreenshotDeliveryStatus.Quarantined);
        Assert.DoesNotContain(statuses, status => status.State == ScreenshotDeliveryStatus.Streaming);
        Assert.Equal(0, files.Lookups);
        Assert.Null(stream.Bytes);
        Assert.Equal(bytes, File.ReadAllBytes(orphan));
    }

    [Fact]
    public async Task MalformedMetadataIsQuarantinedAndRetained()
    {
        Directory.CreateDirectory(root);
        string metadataPath = Path.Combine(root, "broken.json");
        File.WriteAllText(metadataPath, "not-json");
        var statuses = new List<ScreenshotDeliveryPresentation>();

        await new ScreenshotDeliveryWorker(queue: new ArtifactDeliveryQueue(root), statuses.Add)
            .DrainOnceAsync(
                new FakeFiles(),
                new FakeStream(StreamDeliveryStatus.Streaming),
                CancellationToken.None);

        Assert.Contains(statuses, status => status.State == ScreenshotDeliveryStatus.Quarantined);
        Assert.True(File.Exists(metadataPath));
    }

    [Fact]
    public async Task UploadRetryStopsBeforeSecondItem()
    {
        var queue = new ArtifactDeliveryQueue(root); Add(queue, "one"); Add(queue, "two");
        var files = new FakeFiles { UploadOutcome = FilesUploadResult.Retry };
        await Assert.ThrowsAnyAsync<Exception>(() => new ScreenshotDeliveryWorker(queue).DrainOnceAsync(files, new FakeStream(StreamDeliveryStatus.Streaming), CancellationToken.None));
        Assert.Equal(1, files.Uploads);
    }

    [Fact]
    public async Task LookupRetryStopsBeforeSecondItem()
    {
        var queue = new ArtifactDeliveryQueue(root); Add(queue, "one"); Add(queue, "two");
        var files = new FakeFiles { Lookup = ScreenshotFileLookupResult.Retry };
        await Assert.ThrowsAnyAsync<Exception>(() => new ScreenshotDeliveryWorker(queue).DrainOnceAsync(files, new FakeStream(StreamDeliveryStatus.Streaming), CancellationToken.None));
        Assert.Equal(1, files.Lookups); Assert.Equal(0, files.Uploads);
    }

    [Fact]
    public async Task RemoteIdentityMismatchIsDurablyQuarantinedWithoutUploadOrStream()
    {
        var queue = new ArtifactDeliveryQueue(root); Add(queue, "one");
        var files = new FakeFiles { Lookup = ScreenshotFileLookupResult.Quarantined };
        var stream = new FakeStream(StreamDeliveryStatus.Streaming);

        await new ScreenshotDeliveryWorker(queue).DrainOnceAsync(
            files, stream, CancellationToken.None);

        Assert.Equal(1, files.Lookups); Assert.Equal(0, files.Uploads);
        Assert.Null(stream.Bytes); Assert.True(Assert.Single(queue.Pending()).Quarantined);
    }

    [Fact]
    public async Task RemoteBindingPersistenceFailureRemainsRetryableWithoutOtlp()
    {
        var queue = new ArtifactDeliveryQueue(root); Add(queue, "one");
        string key = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(
            System.Text.Encoding.UTF8.GetBytes("one"))).ToLowerInvariant();
        Directory.CreateDirectory(Path.Combine(root, key + ".otlp"));
        var files = new FakeFiles { Complete = [42] };
        var stream = new FakeStream(StreamDeliveryStatus.Streaming);

        await Assert.ThrowsAsync<ScreenshotDeliveryRetryException>(() =>
            new ScreenshotDeliveryWorker(queue).DrainOnceAsync(
                files, stream, CancellationToken.None));

        Assert.Equal(1, files.Lookups); Assert.Equal(0, files.Uploads);
        Assert.Null(stream.Bytes); Assert.False(Assert.Single(queue.Pending()).Quarantined);
    }

    [Fact]
    public async Task UploadingStatusUsesOnePassSnapshotCount()
    {
        var queue = new ArtifactDeliveryQueue(root); Add(queue, "one"); Add(queue, "two");
        var statuses = new List<ScreenshotDeliveryPresentation>();

        await new ScreenshotDeliveryWorker(queue, statuses.Add).DrainOnceAsync(
            new FakeFiles(), new FakeStream(StreamDeliveryStatus.Streaming), CancellationToken.None);

        Assert.Equal(new[] { 2, 1 }, statuses
            .Where(status => status.State == ScreenshotDeliveryStatus.Uploading)
            .Select(status => status.PendingCount));
    }

    private static void Add(ArtifactDeliveryQueue queue, string id)
    {
        byte[] bytes = [1]; var descriptor = new ArtifactDeliveryDescriptor("a", "c", id, id, "image/jpeg", Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes)).ToLowerInvariant(), 1, bytes);
        var activity = new ActivityEvent { SessionId = "s", EventId = id, Timestamp = "2026-01-01T00:00:00Z", EventType = "click", Url = "x", ScreenshotId = id };
        queue.EnqueueScreenshot(descriptor, activity, new SessionContext("s", new string('a',32),new string('b',16),activity.Timestamp,null,"u","h",null,null));
    }

    public void Dispose() { if (Directory.Exists(root)) Directory.Delete(root, true); }
    private sealed class FakeFiles : IScreenshotFilesTransport
    {
        public int Uploads;
        public int Lookups;
        public int Deletes;
        public bool DeleteSucceeds { get; init; } = true;
        public IReadOnlyList<long> Complete { get; init; } = Array.Empty<long>();
        public IReadOnlyList<long> Dangling { get; init; } = Array.Empty<long>();
        public FilesUploadResult? UploadOutcome { get; init; }
        public ScreenshotFileLookupResult? Lookup { get; init; }
        public Task<ScreenshotFileLookupResult> FindByArtifactAsync(
            ArtifactDeliveryRecord record,
            CancellationToken ct)
        { Lookups++; return Task.FromResult(Lookup ?? ScreenshotFileLookupResult.Ready(Complete, Dangling)); }
        public Task<bool> DeleteDanglingAsync(IEnumerable<long> ids, CancellationToken ct)
        {
            Deletes += ids.Count();
            return Task.FromResult(DeleteSucceeds);
        }
        public Task<FilesUploadResult> UploadAsync(ArtifactDeliveryRecord r, byte[] b, CancellationToken ct) { Uploads++; return Task.FromResult(UploadOutcome ?? FilesUploadResult.Uploaded(7)); }
    }
    private sealed class FakeStream(StreamDeliveryStatus result) : IScreenshotStreamTransport
    { public byte[]? Bytes; public Task<StreamDeliveryStatus> SendExactAsync(byte[] body, CancellationToken ct) { Bytes = body; return Task.FromResult(result); } }
}
