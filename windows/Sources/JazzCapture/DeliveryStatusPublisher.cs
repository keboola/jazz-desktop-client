namespace JazzCapture;

/// <summary>
/// Wraps the delegate that actually pushes a tray delivery presentation (ordinarily
/// <c>TrayHost.SetScreenshotDeliveryStatus</c> or <c>TrayHost.SetStreamingStatus</c>), adding a
/// coalescing path for a caller that only wants to push when the projected presentation has actually
/// changed.
/// </summary>
/// <remarks>
/// <para>
/// <b>Generalised from <c>ScreenshotDeliveryStatusPublisher</c> (issue #48, §2.6).</b> That type took
/// five review passes to get right and is otherwise untouched here: every remark below is ported
/// verbatim, with <c>ScreenshotDeliveryPresentation</c> replaced by the type parameter
/// <typeparamref name="T"/>. <c>ScreenshotDeliveryPresentation</c> is a <c>readonly record struct</c>
/// and already satisfies the <c>struct, IEquatable&lt;T&gt;</c> constraint, and so is
/// <see cref="EventDeliveryPresentation"/> -- both types compile a C# record struct's automatic
/// <see cref="IEquatable{T}"/> implementation, so this generalisation changes no behaviour for either
/// caller. <c>ScreenshotDeliveryPresentationTests</c> stays green with only construction/type-name
/// lines changed, per the plan's acceptance bar for this refactor.
/// </para>
/// <para>
/// <b>Why this exists (Finding 2, #74 review, second pass).</b> <c>App.PrepareScreenshotDelivery</c>
/// runs on the capture path and calls <see cref="PushIfChanged"/> after every declined prepare, so
/// the live <c>ScreenshotDeliveryPreparer.IsUsable</c> check is reflected as soon as a credential
/// lapses instead of only on the next successful stage. A screenshot-bearing observation can happen
/// once per click, so once a credential lapses mid-session every subsequent click would otherwise
/// re-push an identical "not provisioned" line for as long as the session stays unprovisioned.
/// <see cref="PushIfChanged"/> exists to coalesce exactly that: it still marshals a tray refresh on
/// the first decline that changes anything, and on every one after that, but not on a repeat of the
/// same presentation.
/// </para>
/// <para>
/// <b>One baseline, never stale.</b> Every other call site that already refreshes the tray
/// unconditionally today -- a credential refresh, a successful stage or spool, a drain outcome --
/// keeps doing so through <see cref="Push"/>, because those are driven by a real state transition
/// already, not a per-click hot path, so there is nothing worth coalescing there. Both methods record
/// whatever they pushed as the same single baseline, so <see cref="PushIfChanged"/> is always
/// compared against the most recent presentation regardless of which method last pushed it -- there
/// is no separate, independently-updated cache to go stale. This is also what guarantees the first
/// decline after any change always pushes: that change, whoever caused it, already moved the one
/// baseline this type owns.
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
public sealed class DeliveryStatusPublisher<T>
    where T : struct, IEquatable<T>
{
    private readonly Action<T> _push;
    private readonly object _gate = new();
    private T? _lastPushed;
    private T? _pendingDelivery;
    private bool _delivering;

    public DeliveryStatusPublisher(Action<T> push)
    {
        _push = push ?? throw new ArgumentNullException(nameof(push));
    }

    /// <summary>Pushes unconditionally and records <paramref name="presentation"/> as the new
    /// baseline for any later <see cref="PushIfChanged"/> call.</summary>
    public void Push(T presentation) => Deliver(presentation, force: true);

    /// <summary>
    /// Pushes only when <paramref name="presentation"/> differs from the baseline -- the last
    /// presentation pushed by this method or by <see cref="Push"/>, whichever ran most recently. The
    /// very first call on a fresh publisher always pushes, since there is no baseline yet.
    /// </summary>
    public void PushIfChanged(T presentation) => Deliver(presentation, force: false);

    /// <summary>
    /// Records <paramref name="presentation"/> as both the change-detection baseline and the next
    /// value <see cref="DrainDeliveryQueue"/> will send, then either starts that drain (if nothing is
    /// currently delivering) or leaves it to whichever call is already running one -- see this
    /// type's own remarks for why that is what keeps delivery in order without ever blocking a
    /// concurrent caller on <see cref="_push"/>.
    /// </summary>
    private void Deliver(T presentation, bool force)
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
    /// this codebase invokes off the capture and delivery paths -- so one throwing call is swallowed
    /// here the same way, rather than being allowed to propagate out of the loop. An uncaught throw
    /// here would do two kinds of damage at once: it would abandon whatever presentation was about
    /// to be sent (silently, since there is no logging framework to record it), and -- far worse --
    /// it would skip the <c>finally</c> below, leaving <see cref="_delivering"/> stuck
    /// <see langword="true"/> forever. Every subsequent <see cref="Deliver"/> call would then see
    /// delivery already "in progress", overwrite <see cref="_pendingDelivery"/>, and return without
    /// ever starting a new loop -- permanently freezing the tray line this publisher owns at
    /// whatever it last happened to show. The <c>try</c>/<c>finally</c> around the whole loop (not
    /// just a <c>catch</c> around the call) also covers an unexpected throw from anywhere else in
    /// the loop body, not only from <see cref="_push"/> itself.
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
                T next;
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
