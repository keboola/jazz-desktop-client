using System.Globalization;

namespace JazzCapture;

/// <summary>
/// Tray-facing state for narration clip delivery -- the fourth, independently visible delivery line
/// (issue #84, §2.8), beside <c>Delivery:</c>, <c>Streaming:</c> and <c>Screenshots:</c>. Vocabulary
/// modelled directly on <see cref="EventDeliveryPresentation"/>.
/// </summary>
public enum NarrationDeliveryPresentationState
{
    /// <summary>No bundle, no Storage credential, or an expired one.</summary>
    NotProvisioned,

    /// <summary>Nothing staged, nothing abandoned this process.</summary>
    UpToDate,

    /// <summary>At least one clip is staged and none has yet failed an upload attempt.</summary>
    Uploading,

    /// <summary>At least one clip is staged and at least one is waiting out a retry backoff.</summary>
    Retrying,

    /// <summary>
    /// Sticky tally of every clip evicted, refused, terminally dropped, or found unparsable at
    /// adoption -- every way a pair can leave the spool without becoming a delivered row. Survives
    /// the spool draining back to empty, for the same reason
    /// <see cref="EventDeliveryPresentationState.Abandoned"/>'s own remarks give: once the queue
    /// drains, <c>up to date</c> would misreport a degraded outcome as a clean one.
    /// </summary>
    Abandoned,

    /// <summary>The spool could not be constructed. A null narration spool means clips are recorded
    /// and never leave -- the exact condition issue #84 exists to make impossible to hide, the same
    /// reasoning <see cref="EventDeliveryPresentationState.Unavailable"/>'s own remarks give.</summary>
    Unavailable,
}

/// <summary>
/// Non-secret rendering of narration delivery for the tray's "Narration:" line.
/// </summary>
public readonly record struct NarrationDeliveryPresentation(NarrationDeliveryPresentationState State, int Count)
{
    /// <summary>Safe state text only: never a credential, endpoint, or file path. Never prefixed with
    /// <c>!</c> -- a missing credential and a bounded eviction are both policy, not a fault, exactly as
    /// #53 scope 5 and slice 1's own tray states already establish.</summary>
    public string Describe() => State switch
    {
        NarrationDeliveryPresentationState.NotProvisioned => "not provisioned",
        NarrationDeliveryPresentationState.Uploading => "uploading " + Count.ToString(CultureInfo.InvariantCulture),
        NarrationDeliveryPresentationState.Retrying => "retrying " + Count.ToString(CultureInfo.InvariantCulture),
        NarrationDeliveryPresentationState.Abandoned =>
            Count.ToString(CultureInfo.InvariantCulture) + " undelivered",
        NarrationDeliveryPresentationState.Unavailable => "spool unavailable; narration not delivered",
        _ => "up to date",
    };
}

/// <summary>
/// Aggregates the spool's live pending count and retry state with the delivery worker's outcome
/// events, over the life of the process, into one <see cref="NarrationDeliveryPresentation"/> for the
/// tray. Structurally identical to <see cref="EventDeliveryPresentationTracker"/>.
/// </summary>
public sealed class NarrationDeliveryPresentationTracker
{
    private readonly object _gate = new();
    private int _abandonedCount;

    /// <summary>Folds one drain-pass outcome into the running abandoned tally.</summary>
    public void OnOutcome(NarrationDeliveryOutcomeEvent outcome)
    {
        lock (_gate)
        {
            switch (outcome.Outcome)
            {
                case NarrationDeliveryOutcome.Dropped:
                case NarrationDeliveryOutcome.VerificationFailed:
                case NarrationDeliveryOutcome.Evicted:
                case NarrationDeliveryOutcome.Refused:
                    _abandonedCount++;
                    break;

                case NarrationDeliveryOutcome.Acknowledged:
                case NarrationDeliveryOutcome.Retrying:
                default:
                    break;
            }
        }
    }

    /// <summary>
    /// Resolves the current presentation. <paramref name="provisioned"/> reflects whether a usable,
    /// unexpired Storage credential currently exists; <paramref name="pendingCount"/> is the spool's
    /// live <see cref="NarrationSpoolStatus.PendingCount"/>; <paramref name="anyRetrying"/> is
    /// <see cref="NarrationSpool.AnyRetrying"/>.
    /// </summary>
    /// <remarks>
    /// <b>An abandoned tally is never hidden behind <c>NotProvisioned</c></b> -- the identical fix
    /// <see cref="EventDeliveryPresentationTracker.Resolve"/>'s own remarks describe. An unprovisioned
    /// machine is exactly where narration recorded before a device bundle ever arrives keeps
    /// accumulating, evicting and refusing regardless (#53 scope 4), so this must never mask a
    /// nonzero tally behind the reason nothing is currently uploading.
    /// </remarks>
    public NarrationDeliveryPresentation Resolve(bool provisioned, int pendingCount, bool anyRetrying)
    {
        lock (_gate)
        {
            if (!provisioned)
            {
                // NotProvisioned still carries pendingCount, not 0 (review finding): Describe()
                // never prints it for this state, so this changes nothing about what the line says
                // -- but TrayHost's own "Available" expression keys on
                // NarrationDeliveryPresentation.Count > 0 to keep the line visible when narration is
                // off yet clips staged before that toggle remain pending (#84 plan §2.8's own
                // "Count > 0" clause). Reporting 0 here unconditionally silently hid exactly the
                // clips that clause exists to keep visible, whenever the machine also happened to be
                // unprovisioned -- discarding real state for a value nothing ever displays.
                return _abandonedCount > 0
                    ? new NarrationDeliveryPresentation(NarrationDeliveryPresentationState.Abandoned, _abandonedCount)
                    : new NarrationDeliveryPresentation(NarrationDeliveryPresentationState.NotProvisioned, pendingCount);
            }

            if (pendingCount > 0)
            {
                return new NarrationDeliveryPresentation(
                    anyRetrying ? NarrationDeliveryPresentationState.Retrying : NarrationDeliveryPresentationState.Uploading,
                    pendingCount);
            }

            return _abandonedCount > 0
                ? new NarrationDeliveryPresentation(NarrationDeliveryPresentationState.Abandoned, _abandonedCount)
                : new NarrationDeliveryPresentation(NarrationDeliveryPresentationState.UpToDate, 0);
        }
    }
}
