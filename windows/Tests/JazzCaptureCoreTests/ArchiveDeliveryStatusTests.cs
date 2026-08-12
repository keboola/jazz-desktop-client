using JazzCaptureCore.Delivery;
using JazzCaptureCoreTests.Support;

namespace JazzCaptureCoreTests;

/// <summary>
/// The one line the notification area shows about delivery.
/// </summary>
/// <remarks>
/// The wording is pinned here rather than in the tray host so it can be checked on any machine, and
/// so a change to it has to be deliberate.
/// </remarks>
public sealed class ArchiveDeliveryStatusTests : IDisposable
{
    private readonly DeliveryWorkspace _workspace = new();

    public void Dispose() => _workspace.Dispose();

    [Fact]
    public void AnEmptyQueueReadsAsIdle()
    {
        ArchiveDeliveryStatus status = ArchiveDeliveryStatus.From(_workspace.OpenQueue());

        Assert.Equal(0, status.QueueDepth);
        Assert.Null(status.LastErrorCode);
        Assert.Equal(ArchiveDeliveryStatus.IdleText, status.Describe());
    }

    [Fact]
    public void QueueDepthCountsWhatHasNotLeftTheMachine()
    {
        ConfirmedArchive pending = _workspace.Confirm();
        ConfirmedArchive inFlight = _workspace.Confirm();
        ConfirmedArchive delivered = _workspace.Confirm();

        _workspace.OpenQueue().BeginAttempt(inFlight.ArchiveId);
        ArchiveDeliveryQueue queue = _workspace.OpenQueue();
        queue.BeginAttempt(delivered.ArchiveId);
        queue.Acknowledge(delivered.ArchiveId, "rcpt-1");

        ArchiveDeliveryStatus status = ArchiveDeliveryStatus.From(_workspace.OpenQueue());

        Assert.Equal(1, status.Pending);
        Assert.Equal(1, status.InFlight);
        Assert.Equal(1, status.Acked);
        Assert.Equal(2, status.QueueDepth);
        Assert.Equal("Delivery: 2 queued", status.Describe());
        Assert.NotEqual(pending.ArchiveId, delivered.ArchiveId);
    }

    [Fact]
    public void TheLastErrorIsShownBesideTheDepth()
    {
        ConfirmedArchive waiting = _workspace.Confirm();
        _workspace.Confirm();
        ArchiveDeliveryQueue queue = _workspace.OpenQueue();
        queue.BeginAttempt(waiting.ArchiveId);
        queue.MarkRetryable(waiting.ArchiveId, "ARCHIVE_BUSY");

        ArchiveDeliveryStatus status = ArchiveDeliveryStatus.From(_workspace.OpenQueue());

        Assert.Equal("ARCHIVE_BUSY", status.LastErrorCode);
        Assert.Equal("Delivery: 2 queued - last error ARCHIVE_BUSY", status.Describe());
    }

    [Fact]
    public void AStoppedDeliveryIsVisibleEvenThoughItIsNotWaiting()
    {
        ConfirmedArchive stopped = _workspace.Confirm();
        ArchiveDeliveryQueue queue = _workspace.OpenQueue();
        queue.BeginAttempt(stopped.ArchiveId);
        queue.MarkPermanentFailure(stopped.ArchiveId, "ARCHIVE_REJECTED");

        ArchiveDeliveryStatus status = ArchiveDeliveryStatus.From(_workspace.OpenQueue());

        // Nothing is waiting, so a depth-only line would say "idle" about an archive that will never
        // be delivered.
        Assert.Equal(0, status.QueueDepth);
        Assert.Equal(1, status.PermanentlyFailed);
        Assert.Equal("Delivery: 1 stopped - last error ARCHIVE_REJECTED", status.Describe());
    }

    [Fact]
    public void AnUnreadableRecordIsCountedRatherThanSwallowed()
    {
        ConfirmedArchive healthy = _workspace.Confirm();
        ConfirmedArchive broken = _workspace.Confirm();
        File.WriteAllText(
            Path.Combine(
                _workspace.QueueDirectory,
                ArchiveDeliveryQueue.RecordsDirectoryName,
                broken.ArchiveId + ArchiveDeliveryQueue.RecordExtension),
            "not json");

        ArchiveDeliveryStatus status = ArchiveDeliveryStatus.From(_workspace.OpenQueue());

        Assert.Equal(1, status.Pending);
        Assert.Equal(1, status.Unreadable);
        Assert.Equal("Delivery: 1 queued, 1 unreadable", status.Describe());
        Assert.NotEqual(healthy.ArchiveId, broken.ArchiveId);
    }

    [Fact]
    public void AnErrorFromAnEarlierDeliveryDoesNotOutrankTheLatest()
    {
        ConfirmedArchive first = _workspace.Confirm();
        ConfirmedArchive second = _workspace.Confirm();

        ArchiveDeliveryQueue queue = _workspace.OpenQueue();
        queue.BeginAttempt(first.ArchiveId);
        queue.MarkRetryable(first.ArchiveId, "ARCHIVE_FIRST");
        _workspace.QueueClock.Advance(TimeSpan.FromMinutes(1));
        queue = _workspace.OpenQueue();
        queue.BeginAttempt(second.ArchiveId);
        queue.MarkRetryable(second.ArchiveId, "ARCHIVE_SECOND");

        Assert.Equal("ARCHIVE_SECOND", ArchiveDeliveryStatus.From(_workspace.OpenQueue()).LastErrorCode);
    }

    [Fact]
    public void AnAcknowledgedQueueReadsAsIdleAgain()
    {
        ConfirmedArchive archive = _workspace.Confirm();
        ArchiveDeliveryQueue queue = _workspace.OpenQueue();
        queue.BeginAttempt(archive.ArchiveId);
        queue.Acknowledge(archive.ArchiveId, "rcpt-1");

        ArchiveDeliveryStatus status = ArchiveDeliveryStatus.From(_workspace.OpenQueue());

        Assert.Equal(1, status.Acked);
        Assert.Equal(ArchiveDeliveryStatus.IdleText, status.Describe());
    }
}
