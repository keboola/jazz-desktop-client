using System.Text.Json.Nodes;
using JazzCaptureCore;
using JazzCaptureCore.Archive;
using JazzCaptureCore.Delivery;
using JazzCaptureCore.Json;
using JazzCaptureCoreTests.Support;

namespace JazzCaptureCoreTests;

/// <summary>
/// The review decision and the delivery queue, joined: confirmation queues exactly one delivery and
/// rejection queues none at all.
/// </summary>
public sealed class CaptureEngineDeliveryTests : IDisposable
{
    private readonly DeliveryWorkspace _workspace = new();

    public void Dispose() => _workspace.Dispose();

    [Fact]
    public void ConfirmingAnArchiveQueuesExactlyOneDelivery()
    {
        ConfirmedArchive archive = _workspace.Confirm();

        ArchiveDeliveryListing listing = _workspace.OpenQueue().List();

        Assert.Empty(listing.Unreadable);
        ArchiveDeliveryRecord record = Assert.Single(listing.Records);
        Assert.Equal(archive.ArchiveId, record.ArchiveId);
        Assert.Equal(DeliveryLifecycle.Pending, record.State);
        Assert.True(File.Exists(archive.PackagePath));
    }

    [Fact]
    public void RejectingAnArchiveQueuesNothing()
    {
        // Asserted against the queue rather than against a return value: the promise is that no
        // upload intent exists anywhere, not that one method happened to hand nothing back.
        CaptureEngine engine = _workspace.Reject("contains a customer password");

        ArchiveDeliveryListing listing = _workspace.OpenQueue().List();

        Assert.Equal(EngineState.Rejected, engine.State);
        Assert.Empty(listing.Records);
        Assert.Empty(listing.Unreadable);
        Assert.Null(_workspace.OpenQueue().Find(engine.Identity.ArchiveId));
        Assert.Null(engine.ArchiveDirectory);
        Assert.Empty(_workspace.OpenQueue().Runnable());
        Assert.False(File.Exists(_workspace.OpenQueue().PackagePath(engine.Identity.ArchiveId)));
    }

    [Fact]
    public void ARejectionLeavesNoQueueStateBesideAConfirmedDelivery()
    {
        ConfirmedArchive confirmed = _workspace.Confirm();
        CaptureEngine rejected = _workspace.Reject("wrong window");

        ArchiveDeliveryRecord record = Assert.Single(_workspace.OpenQueue().List().Records);

        Assert.Equal(confirmed.ArchiveId, record.ArchiveId);
        Assert.Null(_workspace.OpenQueue().Find(rejected.Identity.ArchiveId));
    }

    [Fact]
    public void ConfirmingTwiceStillQueuesExactlyOneDelivery()
    {
        ConfirmedArchive archive = _workspace.Confirm();
        ArchiveDeliveryRecord first = _workspace.OpenQueue().Require(archive.ArchiveId);
        byte[] bytes = File.ReadAllBytes(archive.PackagePath);

        CaptureEngine engine = ReopenAndConfirmAgain(archive);

        Assert.Equal(EngineState.Confirmed, engine.State);
        ArchiveDeliveryRecord second = Assert.Single(_workspace.OpenQueue().List().Records);
        Assert.Equal(first.DeliveryId, second.DeliveryId);
        Assert.Equal(first.QueuedAt, second.QueuedAt);
        Assert.Equal(bytes, File.ReadAllBytes(archive.PackagePath));
    }

    [Fact]
    public void AnAcknowledgedDeliveryIsNotRevivedByAnotherConfirmation()
    {
        ConfirmedArchive archive = _workspace.Confirm();
        ArchiveDeliveryQueue queue = _workspace.OpenQueue();
        queue.BeginAttempt(archive.ArchiveId);
        queue.Acknowledge(archive.ArchiveId, "rcpt-1");

        ReopenAndConfirmAgain(archive);

        ArchiveDeliveryRecord record = Assert.Single(_workspace.OpenQueue().List().Records);
        Assert.Equal(DeliveryLifecycle.Acked, record.State);
        Assert.Empty(_workspace.OpenQueue().Runnable());
    }

    [Fact]
    public void TheQueuedDeliveryRestatesTheManifestRatherThanTheEngine()
    {
        ConfirmedArchive archive = _workspace.Confirm();
        JsonObject manifest = (JsonObject)JsonStrictParser.Parse(
            File.ReadAllBytes(Path.Combine(archive.ArchiveDirectory, "manifest.json")))!;

        ArchiveDeliveryRecord record = _workspace.OpenQueue().Require(archive.ArchiveId);

        Assert.Equal((string?)manifest["archiveId"], record.ArchiveId);
        Assert.Equal((string?)manifest["originId"], record.OriginId);
        Assert.Equal((string?)manifest["contentDigest"], record.ContentDigest);
        Assert.Equal((long?)manifest["formatVersion"], record.FormatVersion);
        Assert.Equal((long?)manifest["revision"], record.Revision);

        // And the logical digest is genuinely the manifest's own: the digest of the manifest with
        // contentDigest removed, exactly as the archive contract defines it.
        var withoutDigest = (JsonObject)manifest.DeepClone();
        withoutDigest.Remove("contentDigest");
        Assert.Equal(JsonCanonicalizer.Sha256Hex(withoutDigest), record.ContentDigest);
    }

    [Fact]
    public void TheQueuedPackageIsTheContainerTheArchiveDirectoryProduces()
    {
        ConfirmedArchive archive = _workspace.Confirm();
        ArchiveDeliveryRecord record = _workspace.OpenQueue().Require(archive.ArchiveId);

        string independent = Path.Combine(_workspace.Root, "independent.jazz-archive");
        JazzArchiveContainer.Export(archive.ArchiveDirectory, independent);

        Assert.Equal(JazzArchiveContainer.Sha256File(independent), record.RawSha256);
        Assert.Equal(new FileInfo(independent).Length, record.ByteLength);
        Assert.Equal(File.ReadAllBytes(independent), File.ReadAllBytes(archive.PackagePath));
    }

    [Fact]
    public void TheDeliveryStateLandsInTheArchivesNeverExportedSyncSubtree()
    {
        ConfirmedArchive archive = _workspace.Confirm();

        string syncPath = ArchiveDeliverySyncLog.PathFor(archive.ArchiveDirectory);

        Assert.True(File.Exists(syncPath));
        Assert.Equal(
            _workspace.OpenQueue().Require(archive.ArchiveId).DeliveryId,
            Assert.Single(ArchiveDeliverySyncLog.Read(archive.ArchiveDirectory)).DeliveryId);
    }

    [Fact]
    public void TwoConfirmedCapturesQueueTwoIndependentDeliveries()
    {
        ConfirmedArchive first = _workspace.Confirm();
        ConfirmedArchive second = _workspace.Confirm();

        IReadOnlyList<ArchiveDeliveryRecord> records = _workspace.OpenQueue().List().Records;

        Assert.Equal(2, records.Count);
        Assert.Equal(2, records.Select(record => record.DeliveryId).Distinct().Count());
        Assert.Equal(2, records.Select(record => record.RawSha256).Distinct().Count());
        Assert.NotEqual(first.ArchiveId, second.ArchiveId);
    }

    /// <summary>
    /// Confirms the same reviewed archive a second time, as a user does after a hand-off appears to
    /// have failed, and checks the package path did not move.
    /// </summary>
    private CaptureEngine ReopenAndConfirmAgain(ConfirmedArchive archive)
    {
        Assert.Equal(archive.PackagePath, archive.Engine.ConfirmAndExport(_workspace.QueueDirectory));
        return archive.Engine;
    }
}
