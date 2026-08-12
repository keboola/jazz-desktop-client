using JazzCaptureCore.Delivery;
using JazzCaptureCoreTests.Support;

namespace JazzCaptureCoreTests;

/// <summary>
/// What survives a crash, and what must never happen twice.
/// </summary>
/// <remarks>
/// <para>
/// A crash is simulated by doing exactly what a crash does: committing a step to disk and then
/// throwing away every object that knew about it, so the next line runs against a queue rebuilt from
/// the directory alone. Nothing here mocks the durability layer.
/// </para>
/// <para>
/// The fake transport separates two things that are easy to conflate. "The client made the request
/// twice" is expected after a crash and is not a fault. "The archive was delivered twice" is a
/// duplicate object on the server, and is the thing that must never happen; the fake counts stored
/// objects rather than calls, so the assertions can tell them apart.
/// </para>
/// </remarks>
public sealed class ArchiveDeliveryCoordinatorTests : IDisposable
{
    private readonly DeliveryWorkspace _workspace = new();
    private readonly FakeArchiveDeliveryTransport _transport = new();

    public void Dispose() => _workspace.Dispose();

    [Fact]
    public async Task AConfirmedArchiveIsDeliveredAndAcknowledgedOnce()
    {
        ConfirmedArchive archive = _workspace.Confirm();

        ArchiveDeliveryRecord? delivered = await Coordinator().RunNextAsync();

        Assert.NotNull(delivered);
        Assert.Equal(DeliveryLifecycle.Acked, delivered.State);
        Assert.Equal(1, delivered.Attempt);
        Assert.Single(_transport.Requests);
        Assert.Single(_transport.Stored);

        ArchiveDeliveryRecord reloaded = _workspace.OpenQueue().Require(archive.ArchiveId);
        Assert.Equal(DeliveryLifecycle.Acked, reloaded.State);
        Assert.Equal("rcpt-" + reloaded.DeliveryId, reloaded.ReceiptId);
    }

    [Fact]
    public async Task ARelaunchMidFlightResendsTheSameBytes()
    {
        ConfirmedArchive archive = _workspace.Confirm();
        byte[] confirmed = File.ReadAllBytes(archive.PackagePath);

        // Attempt committed, process gone: the queue below is built from the directory alone.
        ArchiveDeliveryRecord interrupted = _workspace.OpenQueue().BeginAttempt(archive.ArchiveId);
        Assert.Equal(DeliveryLifecycle.InFlight, interrupted.State);

        ArchiveDeliveryRecord resumed = await Coordinator().RunAsync(archive.ArchiveId);

        Assert.Equal(DeliveryLifecycle.Acked, resumed.State);
        Assert.Equal(interrupted.DeliveryId, resumed.DeliveryId);

        RecordedDelivery sent = Assert.Single(_transport.Requests);
        Assert.Equal(interrupted.DeliveryId, sent.DeliveryId);
        Assert.Equal(interrupted.RawSha256, sent.ObservedSha256);
        Assert.Equal(interrupted.RawSha256, sent.DeclaredSha256);
        Assert.Equal(interrupted.ByteLength, sent.ObservedByteLength);
        Assert.Equal(confirmed, sent.Bytes);
    }

    [Fact]
    public async Task EveryRetryCarriesTheSameBytesAsTheFirstAttempt()
    {
        ConfirmedArchive archive = _workspace.Confirm();
        var failures = 0;
        _transport.Respond = _ => failures++ < 2 ? ArchiveDeliveryOutcome.Retryable("ARCHIVE_BUSY") : null;

        for (var pass = 0; pass < 3; pass++)
        {
            // Each pass is its own coordinator over its own queue object: three relaunches, not one
            // loop with everything still in memory.
            await Coordinator().RunAsync(archive.ArchiveId);
            _workspace.QueueClock.Advance(TimeSpan.FromMinutes(10));
        }

        Assert.Equal(3, _transport.Requests.Count);
        Assert.Single(_transport.Requests.Select(request => request.ObservedSha256).Distinct());
        Assert.Single(_transport.Requests.Select(request => request.DeliveryId).Distinct());
        Assert.Equal(new[] { 1, 2, 3 }, _transport.Requests.Select(request => request.Attempt));
        Assert.Equal(
            DeliveryLifecycle.Acked,
            _workspace.OpenQueue().Require(archive.ArchiveId).State);
        Assert.Single(_transport.Stored);
    }

    [Fact]
    public async Task ACrashBetweenTheIntentAndTheRequestLosesNothingAndDeliversOnce()
    {
        ConfirmedArchive archive = _workspace.Confirm();

        // The intent is durable; the request never happened.
        _workspace.OpenQueue().BeginAttempt(archive.ArchiveId);
        Assert.Empty(_transport.Requests);
        Assert.Empty(_transport.Stored);

        ArchiveDeliveryRecord recovered = await Coordinator().RunAsync(archive.ArchiveId);

        Assert.Equal(DeliveryLifecycle.Acked, recovered.State);
        Assert.Single(_transport.Stored);
        Assert.Equal(0, _transport.RepeatedOperations);
    }

    [Fact]
    public async Task ACrashBetweenTheRequestAndTheAcknowledgementDeliversOnce()
    {
        ConfirmedArchive archive = _workspace.Confirm();

        // The bytes reach the far end, and the process dies before the receipt is committed. The
        // queue's honest position afterwards is "in flight, outcome unknown".
        ArchiveDeliveryQueue crashing = _workspace.OpenQueue();
        ArchiveDeliveryRecord attempting = crashing.BeginAttempt(archive.ArchiveId);
        ArchiveDeliveryOutcome lost = _transport.DeliverWithoutRecordingTheOutcome(crashing, attempting);
        Assert.Equal(ArchiveDeliveryOutcomeKind.Acknowledged, lost.Kind);
        Assert.Equal(
            DeliveryLifecycle.InFlight,
            _workspace.OpenQueue().Require(archive.ArchiveId).State);

        ArchiveDeliveryRecord recovered = await Coordinator().RunAsync(archive.ArchiveId);

        Assert.Equal(DeliveryLifecycle.Acked, recovered.State);

        // The client asked twice, which is unavoidable; the server holds one object and issued one
        // receipt, which is the part that matters.
        Assert.Equal(2, _transport.Requests.Count);
        Assert.Equal(1, _transport.RepeatedOperations);
        Assert.Single(_transport.Stored);
        Assert.Equal(lost.ReceiptId, recovered.ReceiptId);
        Assert.Single(_transport.Requests.Select(request => request.DeliveryId).Distinct());
    }

    [Fact]
    public async Task AnAcknowledgedDeliveryIsNeverSentAgain()
    {
        ConfirmedArchive archive = _workspace.Confirm();
        await Coordinator().RunNextAsync();
        Assert.Single(_transport.Requests);

        _workspace.QueueClock.Advance(TimeSpan.FromDays(7));
        Assert.Null(await Coordinator().RunNextAsync());
        Assert.Empty(await Coordinator().DrainAsync());
        ArchiveDeliveryRecord unchanged = await Coordinator().RunAsync(archive.ArchiveId);

        Assert.Equal(DeliveryLifecycle.Acked, unchanged.State);
        Assert.Single(_transport.Requests);
        Assert.Single(_transport.Stored);
    }

    [Fact]
    public async Task ACorruptPackageFailsAloneWhileItsNeighboursDeliver()
    {
        ConfirmedArchive first = _workspace.Confirm();
        ConfirmedArchive damaged = _workspace.Confirm();
        ConfirmedArchive last = _workspace.Confirm();
        DeliveryWorkspace.DamagePackage(damaged.PackagePath);

        IReadOnlyList<ArchiveDeliveryPassFailure> failures = await Coordinator().DrainAsync();

        Assert.Empty(failures);
        ArchiveDeliveryQueue queue = _workspace.OpenQueue();
        Assert.Equal(DeliveryLifecycle.Acked, queue.Require(first.ArchiveId).State);
        Assert.Equal(DeliveryLifecycle.Acked, queue.Require(last.ArchiveId).State);

        ArchiveDeliveryRecord stopped = queue.Require(damaged.ArchiveId);
        Assert.Equal(DeliveryLifecycle.PermanentFailure, stopped.State);
        Assert.Equal(DeliveryErrorCodes.LocalIntegrityConflict, stopped.ErrorCode);

        // The damaged package was never handed to the transport, and the healthy two were.
        Assert.Equal(2, _transport.Requests.Count);
        Assert.DoesNotContain(damaged.ArchiveId, _transport.Requests.Select(request => request.ArchiveId));
    }

    [Fact]
    public async Task APermanentFailureStopsRatherThanSpinning()
    {
        ConfirmedArchive archive = _workspace.Confirm();
        _transport.Respond = _ => ArchiveDeliveryOutcome.Permanent("ARCHIVE_REJECTED");

        await Coordinator().RunAsync(archive.ArchiveId);

        for (var pass = 0; pass < 5; pass++)
        {
            _workspace.QueueClock.Advance(TimeSpan.FromDays(1));
            Assert.Null(await Coordinator().RunNextAsync());
            Assert.Empty(await Coordinator().DrainAsync());
        }

        ArchiveDeliveryRecord record = _workspace.OpenQueue().Require(archive.ArchiveId);
        Assert.Equal(DeliveryLifecycle.PermanentFailure, record.State);
        Assert.Equal("ARCHIVE_REJECTED", record.ErrorCode);
        Assert.Null(record.NextAttemptAt);
        Assert.Single(_transport.Requests);
    }

    [Fact]
    public async Task ARetryableFailureBacksOffWithinTheBoundAndThenRuns()
    {
        ConfirmedArchive archive = _workspace.Confirm();
        _transport.Respond = _ => ArchiveDeliveryOutcome.Retryable("ARCHIVE_BUSY");
        var delays = new List<TimeSpan>();

        for (var attempt = 1; attempt <= 6; attempt++)
        {
            DateTimeOffset before = _workspace.QueueClock.Read();
            ArchiveDeliveryRecord failed = await Coordinator().RunAsync(archive.ArchiveId);

            Assert.Equal(DeliveryLifecycle.Failed, failed.State);
            Assert.Equal(attempt, failed.Attempt);
            DateTimeOffset due = Assert.IsType<DateTimeOffset>(
                JazzCaptureCore.Timestamps.TryParseRfc3339(failed.NextAttemptAt));
            delays.Add(due - before);

            // Nothing runs before the watermark, however many passes ask.
            Assert.Null(await Coordinator().RunNextAsync());
            _workspace.QueueClock.Now = due;
        }

        Assert.Equal(6, _transport.Requests.Count);
        Assert.All(delays, delay => Assert.InRange(
            delay,
            TimeSpan.FromMilliseconds(1),
            TimeSpan.FromMilliseconds(ArchiveDeliveryRetryPolicy.MaximumDelayMilliseconds)));

        // Bounded, and growing until it hits the bound.
        Assert.True(delays[3] > delays[0]);
    }

    [Fact]
    public async Task AServerSuppliedRetryInstantIsHonoured()
    {
        ConfirmedArchive archive = _workspace.Confirm();
        DateTimeOffset serverChoice = _workspace.QueueClock.Read().AddHours(6);
        _transport.Respond = _ => ArchiveDeliveryOutcome.Retryable("ARCHIVE_BUSY", serverChoice);

        ArchiveDeliveryRecord failed = await Coordinator().RunAsync(archive.ArchiveId);

        Assert.Equal(JazzCaptureCore.Timestamps.IsoMillisUtc(serverChoice), failed.NextAttemptAt);
        _workspace.QueueClock.Advance(TimeSpan.FromHours(5));
        Assert.Null(await Coordinator().RunNextAsync());
        _workspace.QueueClock.Advance(TimeSpan.FromHours(2));
        Assert.NotNull(await Coordinator().RunNextAsync());
    }

    [Fact]
    public async Task ATransportFaultIsRetryableAndKeepsTheBytes()
    {
        ConfirmedArchive archive = _workspace.Confirm();
        _transport.Fault = _ => new HttpRequestException("the network is not there");

        ArchiveDeliveryRecord failed = await Coordinator().RunAsync(archive.ArchiveId);

        Assert.Equal(DeliveryLifecycle.Failed, failed.State);
        Assert.Equal(DeliveryErrorCodes.DeliveryUnavailable, failed.ErrorCode);
        Assert.True(File.Exists(archive.PackagePath));

        _transport.Fault = null;
        _workspace.QueueClock.Advance(TimeSpan.FromMinutes(10));
        ArchiveDeliveryRecord delivered = await Coordinator().RunAsync(archive.ArchiveId);
        Assert.Equal(DeliveryLifecycle.Acked, delivered.State);
    }

    [Fact]
    public async Task AMissingPackageWaitsRatherThanStops()
    {
        ConfirmedArchive archive = _workspace.Confirm();
        byte[] bytes = File.ReadAllBytes(archive.PackagePath);
        File.Delete(archive.PackagePath);

        ArchiveDeliveryRecord waiting = await Coordinator().RunAsync(archive.ArchiveId);

        Assert.Equal(DeliveryLifecycle.Failed, waiting.State);
        Assert.Equal(DeliveryErrorCodes.PackageMissing, waiting.ErrorCode);
        Assert.Empty(_transport.Requests);

        // A package that comes back is delivered; the failure never became terminal.
        File.WriteAllBytes(archive.PackagePath, bytes);
        _workspace.QueueClock.Advance(TimeSpan.FromMinutes(10));
        Assert.Equal(DeliveryLifecycle.Acked, (await Coordinator().RunAsync(archive.ArchiveId)).State);
    }

    [Fact]
    public async Task APackageAnotherProcessHasLockedWaitsRatherThanStops()
    {
        ConfirmedArchive archive = _workspace.Confirm();

        ArchiveDeliveryRecord waiting;
        using (new FileStream(archive.PackagePath, FileMode.Open, FileAccess.Read, FileShare.None))
        {
            waiting = await Coordinator().RunAsync(archive.ArchiveId);
        }

        // Unreadable right now is not the same as wrong, and only the second is terminal.
        Assert.Equal(DeliveryLifecycle.Failed, waiting.State);
        Assert.Equal(DeliveryErrorCodes.PackageUnreadable, waiting.ErrorCode);
        Assert.Empty(_transport.Requests);

        _workspace.QueueClock.Advance(TimeSpan.FromMinutes(10));
        Assert.Equal(DeliveryLifecycle.Acked, (await Coordinator().RunAsync(archive.ArchiveId)).State);
    }

    [Fact]
    public async Task CancellationEndsThePassWithoutRecordingAFailure()
    {
        ConfirmedArchive archive = _workspace.Confirm();
        using var cancellation = new CancellationTokenSource();
        _transport.Fault = _ =>
        {
            cancellation.Cancel();
            return new OperationCanceledException(cancellation.Token);
        };

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => Coordinator().DrainAsync(cancellation.Token));

        // The delivery stays in flight, which is exactly what it is: the outcome is unknown.
        ArchiveDeliveryRecord record = _workspace.OpenQueue().Require(archive.ArchiveId);
        Assert.Equal(DeliveryLifecycle.InFlight, record.State);
        Assert.Null(record.ErrorCode);
    }

    [Fact]
    public async Task ADrainReportsAFailureItCannotRecordAgainstTheDelivery()
    {
        ConfirmedArchive healthy = _workspace.Confirm();
        ConfirmedArchive vanishing = _workspace.Confirm();

        // The record disappears between the listing and the attempt, which the coordinator can only
        // report — there is nowhere left to write the outcome.
        _transport.Respond = request =>
        {
            if (request.ArchiveId == healthy.ArchiveId)
            {
                File.Delete(Path.Combine(
                    _workspace.QueueDirectory,
                    ArchiveDeliveryQueue.RecordsDirectoryName,
                    vanishing.ArchiveId + ArchiveDeliveryQueue.RecordExtension));
            }

            return null;
        };

        IReadOnlyList<ArchiveDeliveryPassFailure> failures = await Coordinator().DrainAsync();

        Assert.Equal(DeliveryLifecycle.Acked, _workspace.OpenQueue().Require(healthy.ArchiveId).State);
        Assert.Equal(vanishing.ArchiveId, Assert.Single(failures).ArchiveId);
    }

    [Fact]
    public async Task AnEmptyQueueIsNotAnError()
    {
        Assert.Null(await Coordinator().RunNextAsync());
        Assert.Empty(await Coordinator().DrainAsync());
        Assert.Empty(_transport.Requests);
    }

    [Fact]
    public async Task RunningAnUnknownArchiveIsRefused()
    {
        ArchiveDeliveryException failure = await Assert.ThrowsAsync<ArchiveDeliveryException>(
            () => Coordinator().RunAsync("ar-0197f0c0-1c00-7a11-b000-0000000000ff"));

        Assert.Equal(ArchiveDeliveryErrorKind.Missing, failure.Kind);
    }

    private ArchiveDeliveryCoordinator Coordinator() =>
        new(_workspace.OpenQueue(), _transport, _workspace.QueueClock.Read);
}
