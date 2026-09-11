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
/// without blocking further; the abandoned task is still given a fire-and-forget continuation so an
/// eventual fault cannot surface as an unobserved task exception.
/// </para>
/// </remarks>
public sealed class ScreenshotDeliveryPreparer
{
    private readonly KeboolaFilesClient? _client;
    private readonly ScreenshotStagingArea _staging;
    private readonly ScreenshotDeliverySettings _settings;
    private readonly Action _nudge;
    private readonly CancellationToken _shutdown;

    /// <param name="client">
    /// The Files transport, or <see langword="null"/> when no usable delivery credential exists
    /// (e.g. the device is not enrolled). <see cref="Prepare"/> returns <see langword="null"/>
    /// immediately in that case.
    /// </param>
    /// <param name="staging">Where a successful prepare's bytes and GCS parameters are staged.</param>
    /// <param name="settings">The operational bounds, including <see cref="ScreenshotDeliverySettings.PrepareBudget"/>.</param>
    /// <param name="nudge">
    /// Wakes the background uploader after a successful stage (ordinarily
    /// <see cref="ScreenshotDeliveryScheduler.Nudge"/>). Invoked best-effort; an exception from it
    /// is swallowed the same way every other side effect on this path is.
    /// </param>
    /// <param name="shutdown">
    /// Observed before and during the prepare call. Checked up front so a shutdown in progress
    /// returns <see langword="null"/> immediately instead of burning the prepare budget on a call
    /// whose result no one will act on, and passed through to
    /// <see cref="KeboolaFilesClient.PrepareAsync"/> so an in-flight call unwinds promptly too.
    /// </param>
    public ScreenshotDeliveryPreparer(
        KeboolaFilesClient? client,
        ScreenshotStagingArea staging,
        ScreenshotDeliverySettings settings,
        Action nudge,
        CancellationToken shutdown)
    {
        _client = client;
        _staging = staging ?? throw new ArgumentNullException(nameof(staging));
        _settings = settings ?? throw new ArgumentNullException(nameof(settings));
        _nudge = nudge ?? throw new ArgumentNullException(nameof(nudge));
        _shutdown = shutdown;
    }

    /// <summary>
    /// Matches <c>EngineConfig.ScreenshotDeliveryPreparer</c>'s
    /// <c>Func&lt;ArtifactDeliveryDescriptor, string?&gt;</c> shape. Never throws: every failure
    /// path -- no credential, an invalid descriptor, a prepare failure, a budget timeout, a staging
    /// refusal, or an unexpected exception from any of those -- returns <see langword="null"/> and
    /// stages nothing.
    /// </summary>
    public string? Prepare(ArtifactDeliveryDescriptor descriptor)
    {
        try
        {
            if (_client is null
                || descriptor is null
                || !string.Equals(descriptor.Kind, ScreenshotEvidenceV1.Kind, StringComparison.Ordinal)
                || _shutdown.IsCancellationRequested)
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
            // free by simply not stamping it.
            ScreenshotStageResult staged = _staging.Stage(prepared, request, descriptor.Bytes);
            if (staged != ScreenshotStageResult.Staged)
            {
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
        Task<ScreenshotPrepareOutcome> task = Task.Run(
            () => _client!.PrepareAsync(request, _shutdown),
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
            // throw, except for genuine caller cancellation. Either way, nothing usable came back.
            ObserveFaultBestEffort(task);
            return null;
        }

        if (!completed)
        {
            // Gave up waiting; do not let a later fault on the abandoned task become an unobserved
            // task exception.
            ObserveFaultBestEffort(task);
            return null;
        }

        return task.Status == TaskStatus.RanToCompletion ? task.Result : null;
    }

    private static void ObserveFaultBestEffort(Task task) =>
        task.ContinueWith(
            static completed => { _ = completed.Exception; },
            TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously);
}
