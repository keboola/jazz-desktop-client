using System.Globalization;

namespace JazzCapture;

/// <summary>
/// Tray-facing state for screenshot delivery. Distinct from <see cref="ScreenshotDeliveryOutcome"/>
/// (the outcome of one drain attempt for one screenshot) and from <see cref="StreamDeliveryStatus"/>
/// (the unrelated OTLP "Streaming:" tray line) -- issue #73 requires capture and screenshot delivery
/// to remain separate, visible tray states.
/// </summary>
/// <remarks>
/// This is an adaptation, not a port, of the closed <c>codex/68-screenshot-files</c> branch's own
/// <c>ScreenshotDeliveryStatus</c>/<c>ScreenshotDeliveryPresentation</c>. That branch's
/// <c>Quarantined</c> value named a durable quarantine state this design does not have -- there is
/// no durable spool here, so nothing is ever quarantined. In its place this design adds
/// <see cref="Abandoned"/>: prepare-early's own accepted terminal-failure outcome (see
/// <see cref="KeboolaFilesClient"/>'s remarks and <see cref="ScreenshotDeliveryOutcome.Dropped"/>)
/// leaves a Files id dangling on an event that has already gone out. This codebase has no logging
/// framework, so the tray is the only place that degradation can ever surface, and the wording below
/// is deliberately honest about it rather than folding it into "up to date".
/// </remarks>
public enum ScreenshotDeliveryPresentationState
{
    /// <summary>No usable Storage credential exists right now, so nothing can be prepared.</summary>
    NotProvisioned,

    /// <summary>Nothing is staged and nothing has ever been abandoned this session.</summary>
    UpToDate,

    /// <summary>At least one screenshot is staged and has not yet failed an upload attempt.</summary>
    Uploading,

    /// <summary>At least one staged screenshot has failed at least one upload attempt and is
    /// waiting on its retry backoff.</summary>
    Retrying,

    /// <summary>
    /// One or more screenshots were dropped after either GCS or this client's own attempt budget
    /// refused any further retry (see <see cref="ScreenshotDeliveryOutcome.Dropped"/>), failed the
    /// staging area's own re-verification on read-back (see
    /// <see cref="ScreenshotDeliveryOutcome.VerificationFailed"/>), or were evicted by the staging
    /// area's byte or age bound before ever being attempted (see
    /// <see cref="ScreenshotDeliveryOutcome.Evicted"/>). Either way the event carrying the
    /// screenshot's Files id has already been emitted, so that id is now permanently dangling -- the
    /// upload will never happen. This state stays visible even after the queue drains back to empty,
    /// because "up to date" would otherwise misreport a degraded outcome as a clean one.
    /// </summary>
    Abandoned,
}

/// <summary>
/// Non-secret rendering of screenshot delivery for the tray's "Screenshots:" line. <see cref="Count"/>
/// means something different per <see cref="State"/> (a pending count, or an abandoned count),
/// exactly as the closed branch's own presentation type used one count field for every state.
/// </summary>
public readonly record struct ScreenshotDeliveryPresentation(ScreenshotDeliveryPresentationState State, int Count)
{
    /// <summary>
    /// Safe state text only: never a credential, endpoint, bucket, key, access token, URL, or file
    /// path. Callers still owe this to <c>Truncate</c> before it reaches the tray, per every other
    /// line in <c>TrayHost.RefreshStatus</c>.
    /// </summary>
    public string Describe() => State switch
    {
        ScreenshotDeliveryPresentationState.NotProvisioned => "not provisioned",
        ScreenshotDeliveryPresentationState.Uploading => "uploading " + Count.ToString(CultureInfo.InvariantCulture),
        ScreenshotDeliveryPresentationState.Retrying => "retrying " + Count.ToString(CultureInfo.InvariantCulture),
        ScreenshotDeliveryPresentationState.Abandoned =>
            Count.ToString(CultureInfo.InvariantCulture) + " undelivered",
        _ => Count == 0 ? "up to date" : "waiting " + Count.ToString(CultureInfo.InvariantCulture),
    };
}

/// <summary>
/// Aggregates the staging area's live pending count with the delivery worker's outcome events, over
/// the life of the process, into one <see cref="ScreenshotDeliveryPresentation"/> for the tray.
/// </summary>
/// <remarks>
/// <para>
/// Nothing here is durable, matching <see cref="ScreenshotStagingArea"/>'s own non-durable design:
/// the abandoned count is a session-lifetime tally, not a persisted ledger, and resets to zero on
/// the next process launch exactly as the staging area itself is wiped at launch. That is an
/// accepted consequence of issue #73's design, not an oversight -- there is nowhere durable this
/// count could live without reintroducing the spool this design deliberately does not have.
/// </para>
/// <para>
/// Thread safety: <see cref="OnOutcome"/> is called from <see cref="ScreenshotDeliveryWorker"/>'s
/// background drain task; <see cref="Resolve"/> is called from wherever the host pushes a tray
/// update (ordinarily the UI thread, via the host's own dispatcher marshalling). Both are guarded by
/// one lock; neither does any I/O, so contention is never a concern.
/// </para>
/// <para>
/// <b>Per-artifact retrying state.</b> <see cref="_retryingIds"/> tracks which staged artifacts are
/// currently waiting out a retry backoff, rather than one boolean shared across every artifact. A
/// single flag would let an <see cref="ScreenshotDeliveryOutcome.Acknowledged"/> (or any other
/// terminal outcome) for one artifact clear the "retrying" impression left by a different artifact
/// that is still backing off, which would render "Uploading" while a screenshot is, in fact, stuck
/// retrying. The set cannot grow without bound: every id enters it only via
/// <see cref="ScreenshotDeliveryOutcome.Retrying"/>, and every id that can ever be reported at all
/// (retrying or otherwise) belongs to one entry in the bounded <see cref="ScreenshotStagingArea"/>,
/// which guarantees that entry eventually reaches exactly one terminal outcome --
/// <see cref="ScreenshotDeliveryOutcome.Acknowledged"/>, <see cref="ScreenshotDeliveryOutcome.Dropped"/>,
/// <see cref="ScreenshotDeliveryOutcome.VerificationFailed"/>, or
/// <see cref="ScreenshotDeliveryOutcome.Evicted"/> -- and every one of those removes the id here.
/// </para>
/// </remarks>
public sealed class ScreenshotDeliveryPresentationTracker
{
    private readonly object _gate = new();
    private readonly HashSet<string> _retryingIds = new(StringComparer.Ordinal);
    private int _abandonedCount;

    /// <summary>Folds one drain-pass outcome into the running tally.</summary>
    public void OnOutcome(ScreenshotDeliveryOutcomeEvent outcome)
    {
        lock (_gate)
        {
            switch (outcome.Outcome)
            {
                case ScreenshotDeliveryOutcome.Retrying:
                    _retryingIds.Add(outcome.ArtifactId);
                    break;

                case ScreenshotDeliveryOutcome.Dropped:
                case ScreenshotDeliveryOutcome.VerificationFailed:
                case ScreenshotDeliveryOutcome.Evicted:
                    // Terminal per issue #73's accepted design: the Files id from prepare is left
                    // dangling. Count it permanently rather than letting a later empty queue read
                    // as "up to date".
                    _retryingIds.Remove(outcome.ArtifactId);
                    _abandonedCount++;
                    break;

                case ScreenshotDeliveryOutcome.Acknowledged:
                default:
                    _retryingIds.Remove(outcome.ArtifactId);
                    break;
            }
        }
    }

    /// <summary>
    /// Resolves the current presentation. <paramref name="provisioned"/> reflects whether a Files
    /// client currently exists (a usable, unexpired Storage credential); <paramref name="pendingCount"/>
    /// is the staging area's live <see cref="ScreenshotStagingStatus.PendingCount"/>. Active pending
    /// work always outranks a stale abandoned count -- a screenshot dropped an hour ago must not
    /// hide that new screenshots are uploading fine right now -- but an abandoned count survives the
    /// queue draining back to empty, per this type's own remarks.
    /// </summary>
    public ScreenshotDeliveryPresentation Resolve(bool provisioned, int pendingCount)
    {
        lock (_gate)
        {
            if (!provisioned)
            {
                return new ScreenshotDeliveryPresentation(ScreenshotDeliveryPresentationState.NotProvisioned, 0);
            }

            if (pendingCount > 0)
            {
                return new ScreenshotDeliveryPresentation(
                    _retryingIds.Count > 0
                        ? ScreenshotDeliveryPresentationState.Retrying
                        : ScreenshotDeliveryPresentationState.Uploading,
                    pendingCount);
            }

            return _abandonedCount > 0
                ? new ScreenshotDeliveryPresentation(ScreenshotDeliveryPresentationState.Abandoned, _abandonedCount)
                : new ScreenshotDeliveryPresentation(ScreenshotDeliveryPresentationState.UpToDate, 0);
        }
    }
}
