using System.Globalization;
using JazzCaptureCore.Archive;
using JazzCaptureCore.Delivery;

namespace JazzCapture;

/// <summary>
/// The capture-path half of prepare-early screenshot delivery: a
/// <c>Func&lt;ArtifactDeliveryDescriptor, string?&gt;</c> suitable for
/// <c>EngineConfig.ScreenshotDeliveryPreparer</c>.
/// </summary>
/// <remarks>
/// <para>
/// <see cref="Prepare"/> runs synchronously on the capture engine's own worker thread, inside the
/// engine's lock, so it can never itself be async -- but <see cref="KeboolaFilesClient.PrepareAsync"/>
/// is. <see cref="Prepare"/> bridges the two with a bounded synchronous wait rather than a bare
/// <c>.Result</c>/<c>.GetAwaiter().GetResult()</c>: the engine already catches whatever this method
/// throws (see <c>CaptureEngine.ObserveWithArtifact</c>'s <c>try { filesId = _screenshotDeliveryPreparer(...); } catch { }</c>),
/// but the documented contract is that this method returns, and a hung prepare must not hold up
/// every subsequent capture event.
/// </para>
/// <para>
/// The prepare is dispatched with <see cref="Task.Run(Func{Task})"/> rather than awaited or blocked
/// on in place. The calling thread is the capture coordinator's own worker thread, not a UI thread
/// with a <see cref="SynchronizationContext"/>, so a direct <c>.GetAwaiter().GetResult()</c> would
/// not deadlock here the way it classically can on a UI thread -- there is no captured context for a
/// continuation to marshal back onto. <see cref="Task.Run(Func{Task})"/> is still used, and preferred,
/// because it reads more defensibly regardless of that fact: it makes the "runs on an independent
/// thread pool thread, not inline on the caller" property explicit at the call site instead of
/// depending on an invariant (no synchronization context on this thread) that a future caller of
/// this class could silently break.
/// </para>
/// <para>
/// <see cref="KeboolaFilesClient.PrepareAsync"/> already applies
/// <see cref="ScreenshotDeliverySettings.PrepareBudget"/> internally through its own linked
/// <see cref="CancellationTokenSource"/> and is documented to return a
/// <see cref="ScreenshotPrepareOutcome.NoUsableTarget"/> rather than hang past that budget. The
/// bounded wait here therefore adds <see cref="ScreenshotDeliverySettings.PrepareWaitGrace"/> on
/// top of that budget -- enough for
/// the already-elapsed internal timeout to unwind and be observed synchronously -- rather than
/// re-imposing (and potentially racing) the same deadline a second time. If the task still has not
/// completed after budget-plus-grace, this method gives up and returns <see langword="null"/>
/// without blocking further, but not without acting on the abandoned call: its own per-call
/// cancellation (linked to, but distinct from, <see cref="_shutdown"/>) is cancelled at that point,
/// and the task is still given a fire-and-forget continuation -- now also responsible for
/// disposing that cancellation source once the task actually finishes -- so an eventual fault
/// cannot surface as an unobserved task exception and cancelling this one call does not tear down
/// every other in-flight use of <see cref="_shutdown"/>.
/// </para>
/// <para>
/// <b>Accepted limitation (#74 review, ninth pass): an unreachable endpoint still costs up to
/// <see cref="ScreenshotDeliverySettings.PrepareBudget"/> plus
/// <see cref="ScreenshotDeliverySettings.PrepareWaitGrace"/> on this call, and that cost is only
/// bounded per screenshot, not in aggregate.</b> <see cref="Prepare"/> is invoked from
/// <c>CaptureCoordinator</c>'s single reader over an unbounded channel, so a burst of
/// screenshot-bearing observations against a dead endpoint queues up behind one another and
/// delays later, non-screenshot events too. This never risks canonical capture -- the journal
/// record is already durable before <c>CaptureEngine.Append</c> ever calls this method -- only the
/// live projection's latency and the coordinator's queue depth degrade. A circuit breaker
/// (skipping prepares for a cooldown after repeated failures) was considered and deliberately not
/// added; see <c>windows/README.md</c>'s "Screenshot delivery" section for the full write-up of
/// this trade-off.
/// </para>
/// </remarks>
public sealed class ScreenshotDeliveryPreparer
{
    private readonly KeboolaFilesClient? _client;
    private readonly ScreenshotStagingArea _staging;
    private readonly ScreenshotDeliverySettings _settings;
    private readonly Action _nudge;
    private readonly CancellationToken _shutdown;
    private readonly DateTimeOffset _expiresAt;
    private readonly Func<DateTimeOffset> _clock;

    /// <param name="client">
    /// The Files transport, or <see langword="null"/> when no usable delivery credential exists
    /// (e.g. the device is not enrolled). <see cref="Prepare"/> returns <see langword="null"/>
    /// immediately in that case.
    /// </param>
    /// <param name="staging">Where a successful prepare's bytes and GCS parameters are staged.</param>
    /// <param name="settings">The operational bounds, including <see cref="ScreenshotDeliverySettings.PrepareBudget"/>.</param>
    /// <param name="nudge">
    /// Wakes the background uploader after a successful stage (ordinarily
    /// <see cref="DeliveryDrainScheduler.Nudge"/>). Invoked best-effort; an exception from it
    /// is swallowed the same way every other side effect on this path is.
    /// </param>
    /// <param name="shutdown">
    /// Observed before and during the prepare call. Checked up front so a shutdown in progress
    /// returns <see langword="null"/> immediately instead of burning the prepare budget on a call
    /// whose result no one will act on, and passed through to
    /// <see cref="KeboolaFilesClient.PrepareAsync"/> so an in-flight call unwinds promptly too.
    /// </param>
    /// <param name="expiresAt">
    /// The Storage credential's own expiry (the same value <c>App.RefreshScreenshotDelivery</c>
    /// already parsed to decide whether <paramref name="client"/> should exist at all). Defaults to
    /// <see cref="DateTimeOffset.MaxValue"/> -- "never expires" -- so a caller that has no
    /// expiry to give (every existing test) sees no behavioural change.
    /// <see cref="KeboolaFilesClient"/> does not retain the <see cref="DeviceBundle"/> it was built
    /// from, so this is the only place that expiry can be held once the client is constructed; see
    /// this type's own remarks and <see cref="Prepare"/> for why it is re-checked here rather than
    /// on a timer.
    /// </param>
    /// <param name="clock">
    /// Defaults to <see cref="DateTimeOffset.UtcNow"/>, matching
    /// <see cref="ScreenshotStagingArea"/>'s own clock-injection pattern; tests supply a fixed or
    /// mutable clock instead.
    /// </param>
    public ScreenshotDeliveryPreparer(
        KeboolaFilesClient? client,
        ScreenshotStagingArea staging,
        ScreenshotDeliverySettings settings,
        Action nudge,
        CancellationToken shutdown,
        DateTimeOffset? expiresAt = null,
        Func<DateTimeOffset>? clock = null)
    {
        _client = client;
        _staging = staging ?? throw new ArgumentNullException(nameof(staging));
        _settings = settings ?? throw new ArgumentNullException(nameof(settings));
        _nudge = nudge ?? throw new ArgumentNullException(nameof(nudge));
        _shutdown = shutdown;
        _expiresAt = expiresAt ?? DateTimeOffset.MaxValue;
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
    }

    /// <summary>
    /// Whether this preparer currently has both a client and an unexpired credential -- the same
    /// check <see cref="Prepare"/> itself performs before doing any work, exposed read-only so a
    /// caller (the tray, via <c>App.PushScreenshotDeliveryStatus</c>) can render "provisioned"
    /// without caching a snapshot that goes stale the moment the credential's clock runs out. No
    /// I/O: this only compares two values already held in memory, so it is safe to call as often as
    /// the tray likes and never needs a polling timer.
    /// </summary>
    public bool IsUsable => _client is not null && _clock() < _expiresAt;

    /// <summary>
    /// Matches <c>EngineConfig.ScreenshotDeliveryPreparer</c>'s
    /// <c>Func&lt;ArtifactDeliveryDescriptor, string?&gt;</c> shape. Never throws: every failure
    /// path -- no credential, an expired credential, an invalid descriptor, a prepare failure, a
    /// budget timeout, a staging refusal, or an unexpected exception from any of those -- returns
    /// <see langword="null"/> and stages nothing.
    /// </summary>
    public string? Prepare(ArtifactDeliveryDescriptor descriptor)
    {
        try
        {
            if (_client is null
                || descriptor is null
                || !string.Equals(descriptor.Kind, ScreenshotEvidenceV1.Kind, StringComparison.Ordinal)
                || _shutdown.IsCancellationRequested
                // The Storage token backing _client is short-lived and there is no periodic
                // refresh anywhere in the process (issue #73/#74 forbid a polling timer); checking
                // it here, against the live clock, at the point of use is what lets an expired
                // credential stop new prepares on the very next screenshot without one. Already
                // staged bytes are unaffected: the GCS upload uses the short-lived federation
                // bearer from the prepare response, not this Storage token, so an expired Storage
                // credential only ever breaks new prepares.
                || _clock() >= _expiresAt)
            {
                return null;
            }

            var request = new ScreenshotFilesRequest(
                descriptor.ArchiveId,
                descriptor.CaptureId,
                descriptor.SessionId,
                descriptor.ArtifactId,
                descriptor.MediaType,
                descriptor.Sha256,
                descriptor.ByteLength);

            ScreenshotPrepareOutcome? outcome = RunPrepareBounded(request);
            if (outcome is not { Result: { } prepared })
            {
                return null;
            }

            // Only report the id if staging actually admitted the bytes: an id whose bytes were
            // refused by the size bound would be a dangling reference we could have avoided for
            // free by simply not stamping it. No event has been emitted yet either way, so a
            // refusal or a staging failure here must clean up the allocation prepare just
            // created rather than leak it (Finding 1, #74 review).
            ScreenshotStageResult staged;
            try
            {
                staged = _staging.Stage(prepared, request, descriptor.Bytes);
            }
            catch
            {
                CleanupUnusedAllocationBestEffort(prepared.FilesId);
                return null;
            }

            if (staged != ScreenshotStageResult.Staged)
            {
                CleanupUnusedAllocationBestEffort(prepared.FilesId);
                return null;
            }

            try
            {
                _nudge();
            }
            catch
            {
                // A failure to wake the background uploader must not undo a successful stage or
                // prevent the Files id from being stamped -- the next nudge (the next screenshot,
                // or the scheduler's own retry loop) will still pick this entry up.
            }

            return prepared.FilesId.ToString(CultureInfo.InvariantCulture);
        }
        catch
        {
            return null;
        }
    }

    private ScreenshotPrepareOutcome? RunPrepareBounded(ScreenshotFilesRequest request)
    {
        // A dedicated, per-call cancellation linked to _shutdown -- not _shutdown alone -- so this
        // specific call can be cancelled the moment this method gives up waiting on it, without
        // tearing down every other in-flight use of _shutdown (Finding 2, #74 review). Disposed
        // once the task backing this call has actually finished; see the branches below.
        var prepareCancellation = CancellationTokenSource.CreateLinkedTokenSource(_shutdown);
        Task<ScreenshotPrepareOutcome> task = Task.Run(
            () => _client!.PrepareAsync(request, prepareCancellation.Token),
            CancellationToken.None);

        TimeSpan waitBound = _settings.PrepareBudget + _settings.PrepareWaitGrace;
        bool completed;
        try
        {
            completed = task.Wait(waitBound);
        }
        catch (AggregateException)
        {
            // PrepareAsync's own contract is to report failure as a NoUsableTarget outcome, not to
            // throw, except for genuine caller cancellation. Either way, nothing usable came back,
            // and Wait only throws once the task itself has already finished (Faulted/Canceled),
            // so the linked source can be disposed synchronously here.
            prepareCancellation.Dispose();
            return null;
        }

        if (!completed)
        {
            // Gave up waiting. Cancel the still-running call: its only cancellation token used to
            // be _shutdown alone, which meant a thread-pool delay or a non-cooperative transport
            // could still allocate a Files id long after this method had already returned null,
            // with nothing staged and nothing cleaned up (Finding 2, #74 review). The task may
            // well still be running after Cancel() returns -- PrepareAsync's own cancellation
            // handling is itself asynchronous -- so the linked source must not be disposed here;
            // it is disposed from the same fire-and-forget continuation that already exists to
            // observe an eventual fault, once the task actually completes.
            //
            // A narrow race remains even so: if the abandoned task's cancellation check loses to
            // its own completion by a hair, it can still finish successfully and produce an
            // allocation nobody will ever stage or use. Chasing that with a second, detached
            // cleanup path is more machinery than the race is worth and risks outliving shutdown
            // itself; it is accepted as-is rather than built around.
            prepareCancellation.Cancel();
            ObserveFaultAndDispose(task, prepareCancellation);
            return null;
        }

        // The task has already finished (Wait returned true); safe to dispose synchronously.
        prepareCancellation.Dispose();
        return task.Status == TaskStatus.RanToCompletion ? task.Result : null;
    }

    private static void ObserveFaultAndDispose(Task task, CancellationTokenSource linkedCancellation) =>
        task.ContinueWith(
            completed =>
            {
                _ = completed.Exception; // never let this become an unobserved task exception
                linkedCancellation.Dispose();
            },
            TaskContinuationOptions.ExecuteSynchronously);

    /// <summary>
    /// One bounded, best-effort attempt to delete a Files allocation that <see cref="Prepare"/>
    /// obtained but will never use -- see
    /// <see cref="KeboolaFilesClient.CleanupUnusedAllocationAsync"/> for why this window (before
    /// the event carrying the id has been emitted) is the only legitimate time to do so. Swallows
    /// everything: a failed or slow cleanup must not throw out of <see cref="Prepare"/> or hold it
    /// up past its own budget, since it costs storage, not correctness.
    /// </summary>
    private void CleanupUnusedAllocationBestEffort(long filesId)
    {
        try
        {
            _client!.CleanupUnusedAllocationAsync(filesId).Wait(_settings.PrepareCleanupBudget);
        }
        catch
        {
            // Best-effort; see the summary above.
        }
    }
}
