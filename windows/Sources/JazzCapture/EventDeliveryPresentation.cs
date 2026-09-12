using System.Globalization;

namespace JazzCapture;

/// <summary>
/// Tray-facing state for OTLP event delivery, replacing the old two-valued <c>StreamDeliveryStatus</c>
/// (<c>Waiting</c>/<c>Backpressure</c>/<c>NotProvisioned</c>/<c>Streaming</c>/<c>Unreachable</c>).
/// Distinct from <see cref="ScreenshotDeliveryPresentationState"/> (the unrelated "Screenshots:" tray
/// line) -- capture, screenshot delivery and event delivery are three separate, independently visible
/// tray states (#53 scope 5).
/// </summary>
/// <remarks>
/// <para>
/// The new vocabulary makes a distinction the old two-state rendering could not: *no credential* vs
/// *endpoint refusing* vs *data actually lost*. None of these states carries the <c>!</c> prefix
/// <c>TrayHost</c> reserves for a real fault (a hotkey re-arm, an unhandled capture error) -- a
/// missing credential and a bounded eviction are both policy, not a defect, per #53 scope 5 and the
/// "Decisions on the plan's open questions" comment on issue #48.
/// </para>
/// </remarks>
public enum EventDeliveryPresentationState
{
    /// <summary>No bundle, no <c>streamEndpoint</c>, or an expired credential.</summary>
    NotProvisioned,

    /// <summary>Nothing spooled, nothing abandoned this session.</summary>
    UpToDate,

    /// <summary>At least one event is spooled and none has yet failed a send attempt.</summary>
    Sending,

    /// <summary>At least one event is spooled and at least one is waiting out a retry backoff.</summary>
    Retrying,

    /// <summary>
    /// Sticky session tally of every event evicted, refused, or terminally dropped. Survives the
    /// spool draining back to empty -- exactly the reason
    /// <see cref="ScreenshotDeliveryPresentationState.Abandoned"/> gives for its own stickiness --
    /// because for events this is a stronger statement than for screenshots: captured activity will
    /// never reach Keboola, not merely a dangling reference an artifact-tolerant reader can drop.
    /// </summary>
    Abandoned,

    /// <summary>
    /// The spool could not be constructed. Deliberately distinguishable, unlike its screenshot
    /// counterpart (<c>App.xaml.cs</c>'s own remarks on why a missing staging area renders
    /// identically to a missing credential): a null event spool means events are produced and
    /// discarded, the exact condition issue #48 exists to make impossible to hide.
    /// </summary>
    Unavailable,
}

/// <summary>
/// Non-secret rendering of event delivery for the tray's "Streaming:" line. <see cref="Count"/> means
/// something different per <see cref="State"/> (a pending count, or an abandoned count), exactly as
/// <see cref="ScreenshotDeliveryPresentation"/>'s own <c>Count</c> does.
/// </summary>
public readonly record struct EventDeliveryPresentation(EventDeliveryPresentationState State, int Count)
{
    /// <summary>
    /// Safe state text only: never a credential, endpoint, or file path. Callers still owe this to
    /// <c>Truncate</c> before it reaches the tray, per every other line in
    /// <c>TrayHost.RefreshStatus</c>. Deliberately never prefixed with <c>!</c> -- see this type's own
    /// remarks.
    /// </summary>
    public string Describe() => State switch
    {
        EventDeliveryPresentationState.NotProvisioned => "not provisioned",
        EventDeliveryPresentationState.Sending => "sending " + Count.ToString(CultureInfo.InvariantCulture),
        EventDeliveryPresentationState.Retrying => "retrying " + Count.ToString(CultureInfo.InvariantCulture),
        EventDeliveryPresentationState.Abandoned =>
            Count.ToString(CultureInfo.InvariantCulture) + " undelivered",
        EventDeliveryPresentationState.Unavailable => "spool unavailable; events not delivered",
        _ => "up to date",
    };
}

/// <summary>
/// Aggregates the spool's live pending count and retry state with the delivery worker's outcome
/// events, over the life of the process, into one <see cref="EventDeliveryPresentation"/> for the
/// tray.
/// </summary>
/// <remarks>
/// <para>
/// Unlike <see cref="ScreenshotDeliveryPresentationTracker"/>, this type does not need its own
/// per-key "currently retrying" set: <see cref="EventSpool.AnyRetrying"/> already answers that
/// question directly and cheaply from the spool's own live state (an entry's <c>Attempt</c> count),
/// so <see cref="Resolve"/> takes it as a parameter instead of reconstructing it from outcome events.
/// The only thing this type accumulates over the life of the process is the abandoned tally, which
/// -- unlike the spool's own live counts -- has no other durable home: it is a session-lifetime
/// count, not a persisted ledger, and resets to zero on the next process launch exactly as the
/// spool's own in-memory bookkeeping does (see <see cref="EventSpool"/>'s own remarks on what is and
/// is not durable).
/// </para>
/// <para>
/// Thread safety: <see cref="OnOutcome"/> is called from <see cref="EventDeliveryWorker"/>'s
/// background drain task; <see cref="Resolve"/> is called from wherever the host pushes a tray
/// update. Both are guarded by one lock; neither does any I/O.
/// </para>
/// </remarks>
public sealed class EventDeliveryPresentationTracker
{
    private readonly object _gate = new();
    private int _abandonedCount;

    /// <summary>Folds one drain-pass outcome into the running abandoned tally.</summary>
    public void OnOutcome(EventDeliveryOutcomeEvent outcome)
    {
        lock (_gate)
        {
            switch (outcome.Outcome)
            {
                case EventDeliveryOutcome.Dropped:
                case EventDeliveryOutcome.VerificationFailed:
                case EventDeliveryOutcome.Evicted:
                case EventDeliveryOutcome.Refused:
                    _abandonedCount++;
                    break;

                case EventDeliveryOutcome.Acknowledged:
                case EventDeliveryOutcome.Retrying:
                default:
                    break;
            }
        }
    }

    /// <summary>
    /// Resolves the current presentation. <paramref name="provisioned"/> reflects whether a usable,
    /// unexpired delivery target currently exists; <paramref name="pendingCount"/> is the spool's
    /// live <see cref="EventSpoolStatus.PendingCount"/>; <paramref name="anyRetrying"/> is
    /// <see cref="EventSpool.AnyRetrying"/>. Active pending work always outranks a stale abandoned
    /// count while provisioned, but an abandoned count survives the spool draining back to empty,
    /// per this type's own remarks.
    /// </summary>
    /// <remarks>
    /// <b>An abandoned tally is never hidden behind <c>NotProvisioned</c> (fix for a defect found in
    /// review, otherwise real).</b> Unlike screenshot delivery -- where nothing is ever staged
    /// without a credential, so <c>NotProvisioned</c> always correctly implies nothing has been lost
    /// -- an unprovisioned machine is exactly the *ordinary* case the amended 32 MiB / 48 hour bounds
    /// exist for (see the "Decisions on the plan's open questions" comment on issue #48): capture
    /// starts before a device bundle ever arrives, and the spool evicts and refuses on the capture
    /// path the whole time regardless. If this method returned <c>NotProvisioned</c> unconditionally
    /// whenever <paramref name="provisioned"/> is <see langword="false"/>, exactly as the screenshot
    /// precedent does, a machine that has never been provisioned could never render <c>N
    /// undelivered</c> at all -- the sticky tally that is supposed to be what makes this loss visible
    /// would be permanently masked by the very state describing why nothing is being sent.
    /// </remarks>
    public EventDeliveryPresentation Resolve(bool provisioned, int pendingCount, bool anyRetrying)
    {
        lock (_gate)
        {
            if (!provisioned)
            {
                return _abandonedCount > 0
                    ? new EventDeliveryPresentation(EventDeliveryPresentationState.Abandoned, _abandonedCount)
                    : new EventDeliveryPresentation(EventDeliveryPresentationState.NotProvisioned, 0);
            }

            if (pendingCount > 0)
            {
                return new EventDeliveryPresentation(
                    anyRetrying ? EventDeliveryPresentationState.Retrying : EventDeliveryPresentationState.Sending,
                    pendingCount);
            }

            return _abandonedCount > 0
                ? new EventDeliveryPresentation(EventDeliveryPresentationState.Abandoned, _abandonedCount)
                : new EventDeliveryPresentation(EventDeliveryPresentationState.UpToDate, 0);
        }
    }
}
