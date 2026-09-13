using JazzCaptureCore;
using JazzCaptureCore.Delivery;

namespace JazzCapture;

/// <summary>
/// The capture-path half of upload-then-emit narration delivery: takes durable custody of a sealed
/// clip's bytes and everything needed to rebuild its event later, so <see cref="CaptureEngine"/> can
/// withhold the event from the ordinary delivery observer until an upload returns a Files id.
/// </summary>
/// <remarks>
/// <para>
/// <b>None of <see cref="ScreenshotDeliveryPreparer"/>'s bounded-wait machinery applies here, and
/// that is deliberate.</b> <see cref="ScreenshotDeliveryPreparer.Prepare"/> makes a real network call
/// on the capture path -- hence its <c>PrepareBudget</c>/<c>PrepareWaitGrace</c>/bounded
/// <see cref="Task.Wait(TimeSpan)"/> machinery. <see cref="TryTakeCustody"/> makes <b>no network call
/// at all</b>: it writes two files (through <see cref="NarrationSpool.Stage"/>) and returns. There is
/// nothing here to bound with a timeout, because there is no I/O whose latency depends on a remote
/// endpoint -- only a synchronous local write, whose cost (up to
/// <see cref="NarrationDeliverySettings.MaximumClipBytes"/>, inside the capture engine's own lock) is
/// accepted and documented in <c>windows/README.md</c>, not something a budget could meaningfully
/// bound anyway.
/// </para>
/// <para>
/// <b>Never throws, never blocks on the network, and reads the descriptor's bytes exactly once</b>
/// (issue #84, R1 and R14): <see cref="ArtifactDeliveryDescriptor.BytesSpan"/> is read a single time
/// and handed straight through to <see cref="NarrationSpool.Stage"/>, which itself never copies it --
/// see that type's own remarks. This class owns no "throwaway array" to zero, because there never is
/// one: the descriptor's own array is never touched or zeroed here, only read.
/// </para>
/// <para>
/// Every failure path -- no spool (it could not be constructed), a shutdown already in progress, a
/// spool refusal (the clip alone exceeds a bound, or nothing fits), or an unexpected exception from
/// any of those -- returns <see langword="false"/> and stages nothing. <see cref="CaptureEngine"/>'s
/// own remarks on <c>EngineConfig.NarrationDeliveryHandler</c> state the consequence: the engine
/// never drops an event nobody took, so a declined custody still emits the event through the
/// ordinary observer, with no <c>audio_file_id</c> -- exactly as if no handler were configured at
/// all. A spool-level refusal (the one case with real bytes to account for) is already counted by
/// <see cref="NarrationSpool"/>'s own pending-refusals list, drained and reported by
/// <see cref="NarrationDeliveryWorker"/> exactly like any other loss; a null spool instead renders
/// the distinct <c>Unavailable</c> tray state (see <see cref="NarrationDeliveryPresentation"/>), so
/// nothing here needs its own separate accounting for that case.
/// </para>
/// </remarks>
public sealed class NarrationDeliveryStager
{
    private readonly NarrationSpool? _spool;
    private readonly Action _nudge;
    private readonly CancellationToken _shutdown;
    private readonly Func<DateTimeOffset> _clock;

    /// <param name="spool">
    /// The durable pair spool, or <see langword="null"/> when it could not be constructed at
    /// startup. <see cref="TryTakeCustody"/> returns <see langword="false"/> immediately in that
    /// case -- see this type's own remarks on why that renders as the distinct <c>Unavailable</c>
    /// state rather than being folded into a refusal count.
    /// </param>
    /// <param name="nudge">
    /// Wakes the background upload worker after a successful stage (ordinarily
    /// <see cref="DeliveryDrainScheduler.Nudge"/>). Invoked best-effort.
    /// </param>
    /// <param name="shutdown">
    /// Checked up front so a shutdown in progress declines custody immediately rather than writing a
    /// clip the process is about to exit anyway -- harmless either way, since the pair is durable,
    /// but there is no reason to pay the write cost during shutdown.
    /// </param>
    /// <param name="clock">Defaults to <see cref="DateTimeOffset.UtcNow"/>; tests supply a fixed or
    /// mutable clock instead, matching every other host type's own clock-injection pattern.</param>
    public NarrationDeliveryStager(
        NarrationSpool? spool,
        Action nudge,
        CancellationToken shutdown,
        Func<DateTimeOffset>? clock = null)
    {
        _spool = spool;
        _nudge = nudge ?? throw new ArgumentNullException(nameof(nudge));
        _shutdown = shutdown;
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
    }

    /// <summary>
    /// Matches the shape <see cref="TrayHost"/>'s own <c>TakeNarrationCustody</c> adapter calls after
    /// building a <see cref="SessionContext"/>. Never throws.
    /// </summary>
    /// <param name="descriptor">The sealed clip's post-durability projection.</param>
    /// <param name="activityEvent">
    /// The narration event as the engine projected it -- <em>before</em> the engine's own
    /// <c>AudioFileId = null</c> rewrite, so this carries the journal artifact id, which is discarded
    /// here (never staged; the Files <c>artifact:</c> tag is built from <paramref name="descriptor"/>'s
    /// own <c>ArtifactId</c> instead) rather than ever reaching the sidecar as a value that could be
    /// mistaken for a Files id.
    /// </param>
    /// <param name="context">The session context, built by the caller from state this class does not
    /// itself have access to (the in-memory trace/span ids and the frozen host settings).</param>
    /// <returns>
    /// <see langword="true"/> only when the pair was durably staged. <see langword="false"/> for a
    /// null spool, a shutdown already in progress, a spool refusal, or any unexpected exception.
    /// </returns>
    public bool TryTakeCustody(ArtifactDeliveryDescriptor descriptor, ActivityEvent activityEvent, SessionContext context)
    {
        try
        {
            NarrationSpool? spool = _spool;
            if (spool is null
                || descriptor is null
                || activityEvent is null
                || context is null
                || _shutdown.IsCancellationRequested)
            {
                return false;
            }

            var pending = new PendingNarration(
                SessionId: descriptor.SessionId,
                ArchiveId: descriptor.ArchiveId,
                CaptureId: descriptor.CaptureId,
                ArtifactId: descriptor.ArtifactId,
                EventId: activityEvent.EventId,
                Sequence: activityEvent.Sequence ?? 0,
                Timestamp: activityEvent.Timestamp,
                LabelId: activityEvent.LabelId,
                Label: activityEvent.Label,
                MediaType: descriptor.MediaType,
                Sha256: descriptor.Sha256,
                ByteLength: descriptor.ByteLength,
                StagedAt: Timestamps.IsoMillisUtc(_clock()),
                TraceId: context.TraceId,
                SpanId: context.SpanId,
                SessionStartedAt: context.StartedAt,
                User: context.User,
                InstanceName: context.InstanceName,
                ServiceName: context.ServiceName,
                FilesId: null);

            if (spool.Stage(pending, descriptor.BytesSpan) != NarrationSpoolAdmission.Staged)
            {
                return false;
            }

            try
            {
                _nudge();
            }
            catch
            {
                // A failure to wake the background worker must not undo a successful stage: the
                // next nudge (the next closed label, or the scheduler's own retry loop) still finds
                // this pair.
            }

            return true;
        }
        catch
        {
            return false;
        }
    }
}
