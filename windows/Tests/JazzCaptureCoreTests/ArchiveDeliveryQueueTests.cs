using JazzCaptureCore.Delivery;
using JazzCaptureCore.Journal;
using JazzCaptureCoreTests.Support;

namespace JazzCaptureCoreTests;

/// <summary>
/// The durability, identity and idempotence rules of the archive delivery queue.
/// </summary>
/// <remarks>
/// Every test here reconstructs the queue from disk rather than reusing an instance, because the
/// only guarantee worth having is the one that survives the process. An assertion made against an
/// object that never left memory would prove nothing about a relaunch.
/// </remarks>
public sealed class ArchiveDeliveryQueueTests : IDisposable
{
    private readonly DeliveryWorkspace _workspace = new();

    public void Dispose() => _workspace.Dispose();

    [Fact]
    public void ConfirmingAnArchiveLeavesOneDurablePendingDelivery()
    {
        ConfirmedArchive archive = _workspace.Confirm();

        ArchiveDeliveryRecord record = _workspace.OpenQueue().Require(archive.ArchiveId);

        Assert.Equal(DeliveryLifecycle.Pending, record.State);
        Assert.Equal(0, record.Attempt);
        Assert.Equal(archive.ArchiveId, record.ArchiveId);
        Assert.Equal(archive.OriginId, record.OriginId);
        Assert.Equal(new[] { archive.CaptureId }, record.CaptureIds);
        Assert.Equal(archive.ContentDigest, record.ContentDigest);
        Assert.StartsWith("del-", record.DeliveryId, StringComparison.Ordinal);
        Assert.Equal(DeliveryTransports.JazzArchiveUpload, record.Transport);
        Assert.Null(record.ReceiptId);
        Assert.Null(record.ErrorCode);
        Assert.Null(record.NextAttemptAt);

        // The record describes the bytes the confirmation actually produced, not a claim about them.
        Assert.Equal(new FileInfo(archive.PackagePath).Length, record.ByteLength);
        Assert.Equal(
            JazzCaptureCore.Archive.JazzArchiveContainer.Sha256File(archive.PackagePath),
            record.RawSha256);
    }

    [Fact]
    public void TheDeliveryIdentityAndTheBytesSurviveARelaunch()
    {
        ConfirmedArchive archive = _workspace.Confirm();
        ArchiveDeliveryRecord before = _workspace.OpenQueue().Require(archive.ArchiveId);

        // A second queue object shares nothing with the first but the directory.
        ArchiveDeliveryRecord after = _workspace.OpenQueue().Require(archive.ArchiveId);

        Assert.Equal(before.DeliveryId, after.DeliveryId);
        Assert.Equal(before.RawSha256, after.RawSha256);
        Assert.Equal(before.ContentDigest, after.ContentDigest);
        Assert.Equal(before.ByteLength, after.ByteLength);
        Assert.Equal(before.QueuedAt, after.QueuedAt);
    }

    [Fact]
    public void ReQueueingTheSameConfirmedArchiveIsANoOp()
    {
        ConfirmedArchive archive = _workspace.Confirm();
        ArchiveDeliveryQueue queue = _workspace.OpenQueue();
        ArchiveDeliveryRecord first = queue.Require(archive.ArchiveId);

        ArchiveDeliveryRecord second = _workspace.OpenQueue().Enqueue(Descriptor(archive));

        Assert.Equal(first.DeliveryId, second.DeliveryId);
        Assert.Equal(first.QueuedAt, second.QueuedAt);
        Assert.Single(_workspace.OpenQueue().List().Records);
    }

    [Fact]
    public void ReQueueingAnAcknowledgedArchiveDoesNotReviveIt()
    {
        ConfirmedArchive archive = _workspace.Confirm();
        ArchiveDeliveryQueue queue = _workspace.OpenQueue();
        queue.BeginAttempt(archive.ArchiveId);
        queue.Acknowledge(archive.ArchiveId, "rcpt-1");

        ArchiveDeliveryRecord requeued = _workspace.OpenQueue().Enqueue(Descriptor(archive));

        Assert.Equal(DeliveryLifecycle.Acked, requeued.State);
        Assert.Equal("rcpt-1", requeued.ReceiptId);
        Assert.Empty(_workspace.OpenQueue().Runnable());
    }

    [Fact]
    public void TheSameArchiveIdentityWithDifferentBytesFailsClosedAndStopsTheDelivery()
    {
        ConfirmedArchive archive = _workspace.Confirm();
        DeliveryWorkspace.DamagePackage(archive.PackagePath);

        ArchiveDeliveryException failure = Assert.Throws<ArchiveDeliveryException>(
            () => _workspace.OpenQueue().Enqueue(Descriptor(archive)));

        Assert.Equal(ArchiveDeliveryErrorKind.Collision, failure.Kind);

        ArchiveDeliveryRecord record = _workspace.OpenQueue().Require(archive.ArchiveId);
        Assert.Equal(DeliveryLifecycle.PermanentFailure, record.State);
        Assert.Equal(DeliveryErrorCodes.ArchiveIdCollision, record.ErrorCode);
    }

    [Fact]
    public void AnAcknowledgedDeliveryIsNotRebound_WhenItsIdentityIsPresentedWithOtherBytes()
    {
        ConfirmedArchive archive = _workspace.Confirm();
        ArchiveDeliveryQueue queue = _workspace.OpenQueue();
        queue.BeginAttempt(archive.ArchiveId);
        queue.Acknowledge(archive.ArchiveId, "rcpt-1");
        DeliveryWorkspace.DamagePackage(archive.PackagePath);

        Assert.Throws<ArchiveDeliveryException>(() => _workspace.OpenQueue().Enqueue(Descriptor(archive)));

        // The acknowledgement is a statement about bytes the server already holds; the collision is
        // the caller's problem, not a reason to unsay it.
        ArchiveDeliveryRecord record = _workspace.OpenQueue().Require(archive.ArchiveId);
        Assert.Equal(DeliveryLifecycle.Acked, record.State);
        Assert.Equal("rcpt-1", record.ReceiptId);
    }

    [Fact]
    public void ListingDoesNotHashPackagesAndSoDoesNotNoticeADamagedOne()
    {
        ConfirmedArchive healthy = _workspace.Confirm();
        ConfirmedArchive damaged = _workspace.Confirm();
        DeliveryWorkspace.DamagePackage(damaged.PackagePath);

        IReadOnlyList<ArchiveDeliveryRecord> records = _workspace.OpenQueue().List().Records;

        Assert.Equal(2, records.Count);
        Assert.Contains(records, record => record.ArchiveId == healthy.ArchiveId);
        Assert.Contains(records, record => record.ArchiveId == damaged.ArchiveId);

        // The fingerprint gate is where the damage is caught, and it catches only the damaged one.
        _workspace.OpenQueue().VerifiedPackagePath(healthy.ArchiveId);
        ArchiveDeliveryException failure = Assert.Throws<ArchiveDeliveryException>(
            () => _workspace.OpenQueue().VerifiedPackagePath(damaged.ArchiveId));
        Assert.Equal(ArchiveDeliveryErrorKind.PackageChanged, failure.Kind);
    }

    [Fact]
    public void ADamagedRecordIsReportedWithoutHidingTheDeliveriesBesideIt()
    {
        ConfirmedArchive healthy = _workspace.Confirm();
        ConfirmedArchive broken = _workspace.Confirm();
        File.WriteAllText(RecordPath(broken.ArchiveId), "{\"schemaVersion\":1,");

        ArchiveDeliveryListing listing = _workspace.OpenQueue().List();

        Assert.Equal(healthy.ArchiveId, Assert.Single(listing.Records).ArchiveId);
        Assert.Equal(broken.ArchiveId, Assert.Single(listing.Unreadable));
    }

    [Fact]
    public void ARecordFiledUnderAnotherArchiveIdIsRefused()
    {
        ConfirmedArchive first = _workspace.Confirm();
        ConfirmedArchive second = _workspace.Confirm();
        File.Copy(RecordPath(first.ArchiveId), RecordPath(second.ArchiveId), overwrite: true);

        ArchiveDeliveryListing listing = _workspace.OpenQueue().List();

        Assert.Equal(second.ArchiveId, Assert.Single(listing.Unreadable));
        Assert.Throws<ArchiveDeliveryException>(() => _workspace.OpenQueue().Find(second.ArchiveId));
    }

    [Fact]
    public void AnAttemptIsCommittedBeforeItCanBeMade()
    {
        ConfirmedArchive archive = _workspace.Confirm();

        ArchiveDeliveryRecord attempting = _workspace.OpenQueue().BeginAttempt(archive.ArchiveId);

        // Reloaded from disk: the attempt is on the record before any request could have been made.
        ArchiveDeliveryRecord reloaded = _workspace.OpenQueue().Require(archive.ArchiveId);
        Assert.Equal(DeliveryLifecycle.InFlight, reloaded.State);
        Assert.Equal(1, reloaded.Attempt);
        Assert.Equal(attempting.DeliveryId, reloaded.DeliveryId);
        Assert.True(reloaded.IsRunnable(_workspace.QueueClock.Read()));
    }

    [Fact]
    public void ResumingAnInFlightDeliveryKeepsItsDurableIdentity()
    {
        ConfirmedArchive archive = _workspace.Confirm();
        ArchiveDeliveryRecord first = _workspace.OpenQueue().BeginAttempt(archive.ArchiveId);

        ArchiveDeliveryRecord resumed = _workspace.OpenQueue().BeginAttempt(archive.ArchiveId);

        Assert.Equal(first.DeliveryId, resumed.DeliveryId);
        Assert.Equal(2, resumed.Attempt);
        Assert.Equal(first.RawSha256, resumed.RawSha256);
    }

    [Fact]
    public void AcknowledgingTwiceWithTheSameReceiptIsANoOp()
    {
        ConfirmedArchive archive = _workspace.Confirm();
        ArchiveDeliveryQueue queue = _workspace.OpenQueue();
        queue.BeginAttempt(archive.ArchiveId);
        ArchiveDeliveryRecord first = queue.Acknowledge(archive.ArchiveId, "rcpt-1");

        ArchiveDeliveryRecord second = _workspace.OpenQueue().Acknowledge(archive.ArchiveId, "rcpt-1");

        Assert.Equal(first.UpdatedAt, second.UpdatedAt);
        Assert.Equal(DeliveryLifecycle.Acked, second.State);
    }

    [Fact]
    public void ASecondReceiptForAnAcknowledgedDeliveryIsRefused()
    {
        ConfirmedArchive archive = _workspace.Confirm();
        ArchiveDeliveryQueue queue = _workspace.OpenQueue();
        queue.BeginAttempt(archive.ArchiveId);
        queue.Acknowledge(archive.ArchiveId, "rcpt-1");

        ArchiveDeliveryException failure = Assert.Throws<ArchiveDeliveryException>(
            () => _workspace.OpenQueue().Acknowledge(archive.ArchiveId, "rcpt-2"));

        Assert.Equal(ArchiveDeliveryErrorKind.Conflict, failure.Kind);
    }

    [Fact]
    public void AnAcknowledgedDeliveryAdmitsNoFurtherTransition()
    {
        ConfirmedArchive archive = _workspace.Confirm();
        ArchiveDeliveryQueue queue = _workspace.OpenQueue();
        queue.BeginAttempt(archive.ArchiveId);
        queue.Acknowledge(archive.ArchiveId, "rcpt-1");

        Assert.Throws<ArchiveDeliveryException>(() => _workspace.OpenQueue().BeginAttempt(archive.ArchiveId));
        Assert.Throws<ArchiveDeliveryException>(
            () => _workspace.OpenQueue().MarkRetryable(archive.ArchiveId, "ARCHIVE_LATE"));
        Assert.Throws<ArchiveDeliveryException>(
            () => _workspace.OpenQueue().MarkPermanentFailure(archive.ArchiveId, "ARCHIVE_LATE"));
        Assert.Empty(_workspace.OpenQueue().Runnable());
    }

    [Fact]
    public void APermanentFailureStopsAndIsNeverRunnableAgain()
    {
        ConfirmedArchive archive = _workspace.Confirm();
        ArchiveDeliveryQueue queue = _workspace.OpenQueue();
        queue.BeginAttempt(archive.ArchiveId);
        queue.MarkPermanentFailure(archive.ArchiveId, "ARCHIVE_REJECTED");

        _workspace.QueueClock.Advance(TimeSpan.FromDays(30));

        ArchiveDeliveryRecord record = _workspace.OpenQueue().Require(archive.ArchiveId);
        Assert.Equal(DeliveryLifecycle.PermanentFailure, record.State);
        Assert.Null(record.NextAttemptAt);
        Assert.Empty(_workspace.OpenQueue().Runnable());
        Assert.Throws<ArchiveDeliveryException>(() => _workspace.OpenQueue().BeginAttempt(archive.ArchiveId));
    }

    [Fact]
    public void ARetryableFailureCommitsABoundedWatermarkThatSurvivesARelaunch()
    {
        ConfirmedArchive archive = _workspace.Confirm();
        ArchiveDeliveryQueue queue = _workspace.OpenQueue();
        queue.BeginAttempt(archive.ArchiveId);

        ArchiveDeliveryRecord failed = queue.MarkRetryable(archive.ArchiveId, "ARCHIVE_UNAVAILABLE");

        Assert.Equal(DeliveryLifecycle.Failed, failed.State);
        Assert.Equal("ARCHIVE_UNAVAILABLE", failed.ErrorCode);
        DateTimeOffset due = Assert.IsType<DateTimeOffset>(
            JazzCaptureCore.Timestamps.TryParseRfc3339(failed.NextAttemptAt));
        Assert.InRange(
            due - _workspace.QueueClock.Read(),
            TimeSpan.FromMilliseconds(1),
            TimeSpan.FromMilliseconds(ArchiveDeliveryRetryPolicy.MaximumDelayMilliseconds));

        // Before the watermark nothing runs; the schedule is on disk, not in the object that set it.
        Assert.Empty(_workspace.OpenQueue().Runnable());
        Assert.Equal(failed.NextAttemptAt, _workspace.OpenQueue().Require(archive.ArchiveId).NextAttemptAt);

        _workspace.QueueClock.Now = due;
        Assert.Equal(archive.ArchiveId, Assert.Single(_workspace.OpenQueue().Runnable()).ArchiveId);
    }

    [Fact]
    public void AServerSuppliedRetryInstantOverridesTheClientPolicy()
    {
        ConfirmedArchive archive = _workspace.Confirm();
        ArchiveDeliveryQueue queue = _workspace.OpenQueue();
        queue.BeginAttempt(archive.ArchiveId);
        DateTimeOffset serverChoice = _workspace.QueueClock.Read().AddHours(4);

        ArchiveDeliveryRecord failed = queue.MarkRetryable(archive.ArchiveId, "ARCHIVE_BUSY", serverChoice);

        Assert.Equal(JazzCaptureCore.Timestamps.IsoMillisUtc(serverChoice), failed.NextAttemptAt);
        _workspace.QueueClock.Advance(TimeSpan.FromHours(3));
        Assert.Empty(_workspace.OpenQueue().Runnable());
        _workspace.QueueClock.Advance(TimeSpan.FromHours(2));
        Assert.Single(_workspace.OpenQueue().Runnable());
    }

    [Fact]
    public void EnqueueingWithNoPackageOnDiskIsRefused()
    {
        ConfirmedArchive archive = _workspace.Confirm();
        File.Delete(RecordPath(archive.ArchiveId));
        File.Delete(archive.PackagePath);

        ArchiveDeliveryException failure = Assert.Throws<ArchiveDeliveryException>(
            () => _workspace.OpenQueue().Enqueue(Descriptor(archive)));

        Assert.Equal(ArchiveDeliveryErrorKind.PackageMissing, failure.Kind);
    }

    [Fact]
    public void AMissingPackageIsDistinguishedFromAChangedOne()
    {
        ConfirmedArchive archive = _workspace.Confirm();
        File.Delete(archive.PackagePath);

        ArchiveDeliveryException failure = Assert.Throws<ArchiveDeliveryException>(
            () => _workspace.OpenQueue().VerifiedPackagePath(archive.ArchiveId));

        Assert.Equal(ArchiveDeliveryErrorKind.PackageMissing, failure.Kind);
    }

    [Fact]
    public void AnArchiveIdentityThatCouldEscapeTheQueueRootIsRefused()
    {
        ArchiveDeliveryQueue queue = _workspace.OpenQueue();

        foreach (string candidate in new[] { "..", "ar-../../etc", "ar-not-a-uuid", "archive" })
        {
            Assert.Throws<ArchiveDeliveryException>(() => queue.PackagePath(candidate));
        }
    }

    [Fact]
    public void AQueueWithNoRecordsIsEmptyRatherThanAFailure()
    {
        ArchiveDeliveryListing listing = new ArchiveDeliveryQueue(
            Path.Combine(_workspace.Root, "never-used")).List();

        Assert.Empty(listing.Records);
        Assert.Empty(listing.Unreadable);
    }

    [Fact]
    public void ListingIsOrderedByQueueTimeThenIdentity()
    {
        ConfirmedArchive first = _workspace.Confirm();
        ConfirmedArchive second = _workspace.Confirm();

        IReadOnlyList<ArchiveDeliveryRecord> records = _workspace.OpenQueue().List().Records;

        Assert.Equal(2, records.Count);
        Assert.True(string.CompareOrdinal(records[0].QueuedAt, records[1].QueuedAt) <= 0);
        Assert.Contains(first.ArchiveId, records.Select(record => record.ArchiveId));
        Assert.Contains(second.ArchiveId, records.Select(record => record.ArchiveId));
    }

    [Fact]
    public void ARecordWrittenByTheQueueIsCanonicalLineFeedTerminatedUtf8()
    {
        ConfirmedArchive archive = _workspace.Confirm();

        byte[] bytes = File.ReadAllBytes(RecordPath(archive.ArchiveId));

        Assert.NotEqual(0xEF, bytes[0]);
        Assert.DoesNotContain((byte)'\r', bytes);
        Assert.Equal((byte)'\n', bytes[^1]);
    }

    [Fact]
    public void NoTemporaryFileIsLeftBehindByACommit()
    {
        ConfirmedArchive archive = _workspace.Confirm();
        _workspace.OpenQueue().BeginAttempt(archive.ArchiveId);

        string records = Path.Combine(_workspace.QueueDirectory, ArchiveDeliveryQueue.RecordsDirectoryName);
        Assert.Empty(Directory.GetFiles(records, "*" + Durability.TemporaryFileSuffix));
    }

    private string RecordPath(string archiveId) => Path.Combine(
        _workspace.QueueDirectory,
        ArchiveDeliveryQueue.RecordsDirectoryName,
        archiveId + ArchiveDeliveryQueue.RecordExtension);

    private static ArchiveDeliveryDescriptor Descriptor(ConfirmedArchive archive) => new()
    {
        ArchiveId = archive.ArchiveId,
        OriginId = archive.OriginId,
        CaptureIds = new[] { archive.CaptureId },
        ContentDigest = archive.ContentDigest,
        ArchiveDirectory = archive.ArchiveDirectory,
    };
}
