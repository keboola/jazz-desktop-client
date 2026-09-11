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

/// <summary>
/// Wraps the delegate that actually pushes a <see cref="ScreenshotDeliveryPresentation"/> to the
/// tray (ordinarily <c>TrayHost.SetScreenshotDeliveryStatus</c>), adding a coalescing path for a
/// caller that only wants to push when the projected presentation has actually changed.
/// </summary>
/// <remarks>
/// <para>
/// <b>Why this exists (Finding 2, #74 review, second pass).</b> <c>App.PrepareScreenshotDelivery</c>
/// runs on the capture path and calls <see cref="PushIfChanged"/> after every declined prepare, so
/// the live <see cref="ScreenshotDeliveryPreparer.IsUsable"/> check is reflected as soon as a
/// credential lapses instead of only on the next successful stage. A screenshot-bearing observation
/// can happen once per click, so once a credential lapses mid-session every subsequent click would
/// otherwise re-push an identical "not provisioned" line for as long as the session stays
/// unprovisioned. <see cref="PushIfChanged"/> exists to coalesce exactly that: it still marshals a
/// tray refresh (<c>TrayHost.SetScreenshotDeliveryStatus</c>'s own non-blocking <c>BeginInvoke</c>)
/// on the first decline that changes anything, and on every one after that, but not on a repeat of
/// the same presentation.
/// </para>
/// <para>
/// <b>One baseline, never stale.</b> Every other call site that already refreshes the tray
/// unconditionally today -- a credential refresh, a successful stage, a drain outcome -- keeps doing
/// so through <see cref="Push"/>, because those are driven by a real state transition already, not a
/// per-click hot path, so there is nothing worth coalescing there. Both methods record whatever they
/// pushed as the same single baseline, so <see cref="PushIfChanged"/> is always compared against the
/// most recent presentation regardless of which method last pushed it -- there is no separate,
/// independently-updated cache to go stale. This is also what guarantees the first decline after any
/// change always pushes: that change, whoever caused it, already moved the one baseline this type
/// owns.
/// </para>
/// <para>
/// Thread safety: a single lock guards the baseline; the wrapped delegate runs outside the lock so a
/// slow or misbehaving delegate can never block a concurrent caller (the same reasoning
/// <see cref="ScreenshotDeliveryPresentationTracker"/> itself documents).
/// </para>
/// <para>
/// <b>Delivery order (Finding 3, #74 review, third pass).</b> Running the wrapped delegate outside
/// the lock is necessary -- <c>TrayHost.SetScreenshotDeliveryStatus</c> marshals through
/// <c>TrayHost.Marshal</c>, which runs its action <i>inline</i> when already on the UI dispatcher
/// thread, and the capture path takes this same lock on a declined prepare (via
/// <see cref="PushIfChanged"/>), so holding the lock across that callback could let a UI refresh
/// block capture. The previous shape of this type recorded the baseline under the lock and then
/// called <see cref="_push"/> unconditionally, with no coordination between two concurrent callers'
/// own calls to the delegate -- so an older presentation's call could run after a newer
/// presentation's call already had, and once that happened <see cref="PushIfChanged"/> would then
/// suppress every later call that merely repeated what the (correct) baseline already said, leaving
/// the tray showing the stale value indefinitely -- worse than the churn the coalescing was added to
/// avoid, since the tray is the only diagnostic this codebase has.
/// </para>
/// <para>
/// <b>Fix: a single-delivery trampoline, not a race check.</b> Both methods hand their presentation
/// to <see cref="Deliver"/>, which records it into one shared "next thing to send" slot
/// (<see cref="_pendingDelivery"/>) under <see cref="_gate"/>. At most one thread is ever actually
/// calling <see cref="_push"/> at a time: the first caller to find no delivery already running
/// becomes that thread and loops in <see cref="DrainDeliveryQueue"/>, each iteration atomically
/// taking whatever currently sits in the slot -- which may have been overwritten several times while
/// the previous <see cref="_push"/> call was in flight -- and calling <see cref="_push"/> with it,
/// until the slot is empty. Every other concurrent caller only ever overwrites the slot and returns
/// immediately; it never calls <see cref="_push"/> itself and is never blocked waiting for one to
/// run. This is stronger than recording a sequence number and then checking it before calling out
/// regardless: there is no window between "confirm this is still the newest" and "actually deliver
/// it" for a still-newer call to slip through, because delivery itself is serialized rather than
/// merely ordered by a check made moments before an unsynchronized call. The newest presentation
/// recorded is therefore always the last one delivered, and nothing older is ever delivered after it.
/// </para>
/// </remarks>
public sealed class ScreenshotDeliveryStatusPublisher
{
    private readonly Action<ScreenshotDeliveryPresentation> _push;
    private readonly object _gate = new();
    private ScreenshotDeliveryPresentation? _lastPushed;
    private ScreenshotDeliveryPresentation? _pendingDelivery;
    private bool _delivering;

    public ScreenshotDeliveryStatusPublisher(Action<ScreenshotDeliveryPresentation> push)
    {
        _push = push ?? throw new ArgumentNullException(nameof(push));
    }

    /// <summary>Pushes unconditionally and records <paramref name="presentation"/> as the new
    /// baseline for any later <see cref="PushIfChanged"/> call.</summary>
    public void Push(ScreenshotDeliveryPresentation presentation) => Deliver(presentation, force: true);

    /// <summary>
    /// Pushes only when <paramref name="presentation"/> differs from the baseline -- the last
    /// presentation pushed by this method or by <see cref="Push"/>, whichever ran most recently. The
    /// very first call on a fresh publisher always pushes, since there is no baseline yet.
    /// </summary>
    public void PushIfChanged(ScreenshotDeliveryPresentation presentation) => Deliver(presentation, force: false);

    /// <summary>
    /// Records <paramref name="presentation"/> as both the change-detection baseline and the next
    /// value <see cref="DrainDeliveryQueue"/> will send, then either starts that drain (if nothing is
    /// currently delivering) or leaves it to whichever call is already running one -- see this
    /// type's own remarks for why that is what keeps delivery in order without ever blocking a
    /// concurrent caller on <see cref="_push"/>.
    /// </summary>
    private void Deliver(ScreenshotDeliveryPresentation presentation, bool force)
    {
        lock (_gate)
        {
            if (!force && _lastPushed is { } last && last.Equals(presentation))
            {
                return;
            }

            _lastPushed = presentation;
            _pendingDelivery = presentation;
            if (_delivering)
            {
                // Someone else's DrainDeliveryQueue loop owns delivery right now and will pick up
                // this (newer) value on its next iteration; piling on here would let two threads
                // call _push concurrently and reintroduce the exact reordering this type exists to
                // prevent.
                return;
            }

            _delivering = true;
        }

        DrainDeliveryQueue();
    }

    /// <summary>
    /// Runs on whichever caller's thread won the right to deliver (see <see cref="Deliver"/>).
    /// Repeatedly takes the current pending value and calls <see cref="_push"/> with it -- entirely
    /// outside <see cref="_gate"/>, so a slow or misbehaving delegate can never block a concurrent
    /// caller -- until nothing new has arrived since the last send, at which point it relinquishes
    /// delivery. Because taking the pending value and checking for more work both happen under the
    /// same lock, no update can arrive in the gap between "nothing left to send" and "stop
    /// delivering" without either being seen by this loop or starting a new loop of its own.
    /// </summary>
    /// <remarks>
    /// <para>
    /// The thread that wins delivery can be the capture path's own -- it reaches here through
    /// <see cref="PushIfChanged"/> on a declined prepare -- so this loop must stay cheap, and it
    /// does: one iteration is one <see cref="_push"/>, which marshals to the tray with
    /// <c>BeginInvoke</c> and returns without waiting for the UI. Iterating again requires a
    /// genuinely different presentation to have arrived meanwhile, and those are paced by real
    /// delivery outcomes rather than by this loop, so capture cannot be held here.
    /// </para>
    /// <para>
    /// <b>A throwing sink must not wedge delivery (Finding 1, #74 review, fourth pass).</b>
    /// <see cref="_push"/> is caller-supplied and best-effort, exactly like every other observer
    /// this codebase invokes off the capture and delivery paths (see
    /// <c>ScreenshotDeliveryWorker.Report</c>, <c>CaptureEngine</c>'s own delivery-observer call,
    /// and <c>MvpStreamDispatcher.SafeStatus</c>) -- so one throwing call is swallowed here the same
    /// way, rather than being allowed to propagate out of the loop. An uncaught throw here would do
    /// two kinds of damage at once: it would abandon whatever presentation was about to be sent
    /// (silently, since there is no logging framework to record it), and -- far worse -- it would
    /// skip the <c>finally</c> below, leaving <see cref="_delivering"/> stuck <see langword="true"/>
    /// forever. Every subsequent <see cref="Deliver"/> call would then see delivery already "in
    /// progress", overwrite <see cref="_pendingDelivery"/>, and return without ever starting a new
    /// loop -- permanently freezing the tray's "Screenshots:" line, the one diagnostic this codebase
    /// has, at whatever it last happened to show. The <c>try</c>/<c>finally</c> around the whole loop
    /// (not just a <c>catch</c> around the call) also covers an unexpected throw from anywhere else
    /// in the loop body, not only from <see cref="_push"/> itself.
    /// </para>
    /// <para>
    /// <b>The flag must still be cleared exactly once, atomically with the empty check.</b> The
    /// normal exit path clears <see cref="_delivering"/> in the very same <see cref="_gate"/>
    /// acquisition that observes <see cref="_pendingDelivery"/> is empty -- that pairing is what the
    /// class-level remarks mean by "no update can arrive in the gap" -- and records
    /// <c>clearedDelivering</c> so the outer <c>finally</c> knows not to repeat it. If the outer
    /// <c>finally</c> cleared the flag again on its own, unpaired lock acquisition, a concurrent
    /// <see cref="Deliver"/> call that had already observed <see cref="_delivering"/> still
    /// <see langword="true"/> (and so only queued into <see cref="_pendingDelivery"/> and started no
    /// loop of its own, trusting this one to pick it up) could have that queued value stranded: this
    /// loop already returned, and the <c>finally</c>'s redundant clear would race with -- and could
    /// stomp on -- a second loop a still-later caller starts believing delivery was free. Only an
    /// unexpected throw that skips the normal exit leaves <c>clearedDelivering</c> false, which is
    /// exactly when the outer <c>finally</c> needs to act.
    /// </para>
    /// <para>
    /// <b>A failed delivery must not be recorded as delivered (Finding 1, #74 review, fifth pass).</b>
    /// Before this fix, <see cref="Deliver"/> set <see cref="_lastPushed"/> to the new baseline
    /// before <see cref="_push"/> ever ran, so a throw from <see cref="_push"/> below still left that
    /// value recorded as the last thing the tray received. If nothing newer arrived in the meantime,
    /// a later <see cref="PushIfChanged"/> call for that same presentation would then be suppressed
    /// as "no change" even though the sink never actually got it -- the state that failed to reach
    /// the tray could never be retried, and with no logging framework it would simply vanish. On a
    /// caught throw this loop now clears <see cref="_lastPushed"/> back to <see langword="null"/>,
    /// but only when it still equals the value that just failed <i>and</i>
    /// <see cref="_pendingDelivery"/> is empty: a newer value already queued (as it can be here,
    /// since <see cref="_push"/> runs outside the lock and a concurrent -- or, as in this loop's own
    /// reentrant case, a same-thread -- caller can queue one while it is in flight) will deliver on
    /// this same loop's next iteration and set its own baseline, so clearing here as well would only
    /// throw that baseline away too. The check-and-clear happens under <see cref="_gate"/>, matching
    /// every other read or write of <see cref="_lastPushed"/> and <see cref="_pendingDelivery"/> in
    /// this type; <see cref="_push"/> itself is still never called with the lock held.
    /// </para>
    /// </remarks>
    private void DrainDeliveryQueue()
    {
        bool clearedDelivering = false;
        try
        {
            while (true)
            {
                ScreenshotDeliveryPresentation next;
                lock (_gate)
                {
                    if (_pendingDelivery is not { } value)
                    {
                        _delivering = false;
                        clearedDelivering = true;
                        return;
                    }

                    next = value;
                    _pendingDelivery = null;
                }

                try
                {
                    _push(next);
                }
                catch
                {
                    // Best-effort, matching every other observer invoked off the capture/delivery
                    // paths (see the remarks above): a misbehaving sink must not stop later values
                    // from being delivered. But delivery genuinely failed, so the baseline must not
                    // keep claiming it succeeded (Finding 1, #74 review, fifth pass): clear it back
                    // to unset when it still names the value that just failed and nothing newer has
                    // been queued since, so an identical later PushIfChanged is not suppressed as
                    // "no change". A newer value already queued gets its own baseline when this same
                    // loop delivers it next, so leave the baseline alone in that case.
                    lock (_gate)
                    {
                        if (_pendingDelivery is null && _lastPushed is { } lastPushed && lastPushed.Equals(next))
                        {
                            _lastPushed = null;
                        }
                    }
                }
            }
        }
        finally
        {
            if (!clearedDelivering)
            {
                lock (_gate)
                {
                    _delivering = false;
                }
            }
        }
    }
}
