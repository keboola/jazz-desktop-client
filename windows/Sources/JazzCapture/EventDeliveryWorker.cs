using System.Security.Cryptography;

namespace JazzCapture;

/// <summary>
/// Outcome of one attempt to move a spooled event, reported through <see cref="EventDeliveryWorker"/>'s
/// status callback. This codebase has no logging framework, so this and
/// <see cref="EventDeliveryOutcomeEvent"/> are the only diagnostic surface for a lost or delayed
/// event -- every value here is safe to display and can never carry a bucket, key, or access token;
/// here the one sensitive value in this whole path is the stream endpoint's capability URL, which
/// never reaches this enum, a spool key, or the tray (see <see cref="EventSpool"/>'s own remarks).
/// </summary>
public enum EventDeliveryOutcome
{
    /// <summary>The bytes reached the sink; the spooled entry was removed.</summary>
    Acknowledged,

    /// <summary>Send failed in a retryable way; the entry stays spooled for a later attempt with no
    /// attempt budget (see <see cref="EventSpool"/>'s own remarks on why an event differs from a
    /// screenshot here).</summary>
    Retrying,

    /// <summary>Terminal: the sink classified the response 400 or 422 (<see cref="EventSendOutcome.Dropped"/>).
    /// The spooled entry was removed and counted abandoned.</summary>
    Dropped,

    /// <summary>The bytes read back from the spool failed length/digest verification against their
    /// own file name. The entry was already removed by the spool itself.</summary>
    VerificationFailed,

    /// <summary>Terminal: the spool evicted this entry -- by the byte ceiling or by age -- before it
    /// was ever attempted.</summary>
    Evicted,

    /// <summary>Terminal: the spool refused to admit this event in the first place (the body alone
    /// exceeded a bound, debt left no room, a redirected path was rejected, or the write itself
    /// failed). Unlike a screenshot refusal, this is always counted -- see <see cref="EventSpool"/>'s
    /// own remarks.</summary>
    Refused,
}

/// <summary>Non-secret projection of one drain-pass outcome, for a tray or diagnostics surface.
/// Carries only a spool key and an outcome -- see <see cref="EventDeliveryOutcome"/>'s own remarks on
/// why that is always safe to log or display.</summary>
public readonly record struct EventDeliveryOutcomeEvent(string Key, EventDeliveryOutcome Outcome);

/// <summary>
/// One bounded drain pass over <see cref="EventSpool"/>: reads each due entry's bytes back
/// (re-verifying them against the digest in their own file name), attempts the classified
/// <c>/v1/logs</c> POST through the injected <c>deliver</c> delegate (ordinarily backed by
/// <see cref="MvpStreamSender.SendBodyAsync"/>), and applies the no-attempt-budget retry policy this
/// issue's plan settles on for an event.
/// </summary>
/// <remarks>
/// <para>
/// Modelled on <see cref="ScreenshotDeliveryWorker"/>, with one behavioural difference required by
/// per-session FIFO (§2.4 of the #48 plan): unlike <see cref="ScreenshotDeliveryWorker"/>, which
/// carries on past every failed entry regardless of order, this type stops attempting further
/// entries for a given session as soon as one of that session's entries comes back
/// <see cref="EventDeliveryOutcome.Retrying"/> -- so a later event is never delivered ahead of an
/// earlier one of the same session that is still being retried -- while still moving on to attempt
/// entries belonging to other sessions in the same pass. A terminal outcome (
/// <see cref="EventDeliveryOutcome.Dropped"/>, <see cref="EventDeliveryOutcome.VerificationFailed"/>)
/// does not halt its session: the entry is gone, so there is nothing left to deliver out of order.
/// </para>
/// <para>
/// <b>Exactly one terminal outcome per event, for the same reason <see cref="ScreenshotDeliveryWorker"/>
/// documents.</b> <see cref="EventSpool.Drain"/> hands out a snapshot under its own lock, but this
/// type then processes each handle outside it -- the capture path's own <see cref="EventSpool.Spool"/>
/// can run concurrently and could otherwise evict the very entry a call here is about to attempt.
/// <see cref="DrainOnceAsync"/> closes that exactly as <see cref="ScreenshotDeliveryWorker"/> does:
/// leasing the one entry it is actively attempting for the span of that attempt, and skipping an
/// entry entirely when the lease itself reports it lost that narrower race.
/// </para>
/// <para>
/// Never throws for one entry's own failure -- a transport exception, a verification failure, or a
/// classified drop all leave the rest of the pass unaffected. Only genuine cancellation of the
/// supplied <see cref="CancellationToken"/> propagates.
/// </para>
/// <para>
/// <b>An <see cref="EventSendOutcome.Unauthorized"/> response parks this whole worker instance, not
/// just one session (deliberate correction to the #48 plan's §2.5 -- see that outcome's own
/// remarks).</b> Unlike an ordinary <see cref="EventSendOutcome.Retry"/>, a 401/403 means the
/// credential itself, not this one entry, is the problem: <see cref="_targetKnownRevoked"/> makes
/// every remaining entry in the current pass, and every entry in every later pass, stop short of
/// ever calling <c>deliver</c> again -- for as long as this exact worker instance lives. The only
/// way sending resumes is a fresh worker instance: <c>App.RefreshDeliveryTarget</c> constructs one
/// whenever the *effective* delivery target actually changes (a different endpoint or expiry, not
/// merely a re-read of the same still-current bundle -- see its own remarks on why rebuilding on
/// every call would have let a persistently revoked credential get re-probed on every retryable
/// provisioning check), which only happens on an actual provisioning change, satisfying issue #48's
/// "revocation/expiry stops networking without deleting evidence" acceptance criterion without
/// deleting or evicting a single spooled entry differently.
/// </para>
/// </remarks>
public sealed class EventDeliveryWorker
{
    private readonly Func<bool> _isTargetUsable;
    private readonly Func<ReadOnlyMemory<byte>, CancellationToken, Task<EventSendOutcome>> _deliver;
    private readonly EventSpool _spool;
    private readonly Action<EventDeliveryOutcomeEvent>? _onOutcome;

    // Set for the remaining lifetime of this worker instance the moment any send comes back
    // EventSendOutcome.Unauthorized (see that member's own remarks: a deliberate correction of the
    // #48 plan's §2.5). Deliberately not reset by anything this type does itself: the only way
    // sending resumes is App.RefreshDeliveryTarget discarding this instance for a freshly
    // constructed one -- which it does only when the effective delivery target actually changes,
    // not on every call (a review finding: rebuilding unconditionally would reset this flag on every
    // retryable provisioning check even when the stored bundle is unchanged, letting a persistently
    // revoked credential get re-probed on a timer instead of staying parked) -- which only happens
    // on an actual provisioning change -- exactly the existing seam #48's acceptance criterion
    // ("revocation/expiry stops networking without deleting evidence") asks this to use.
    private volatile bool _targetKnownRevoked;

    /// <param name="isTargetUsable">
    /// Whether a usable delivery target exists right now -- ordinarily a live re-check of
    /// <c>App</c>'s current delivery target and its expiry, ephemeral and re-evaluated on every
    /// <see cref="DrainOnceAsync"/> call rather than cached from when this worker was constructed.
    /// Checked after this pass's bookkeeping (age eviction, pending-list draining) but before any
    /// leasing, read-back, or send is attempted, so a revoked or expired credential stops the
    /// *networking* half of the pass outright (see <see cref="DrainOnceAsync"/>'s own remarks) --
    /// the acceptance criterion that revocation/expiry stops networking without deleting evidence --
    /// without also silencing the bookkeeping half.
    /// </param>
    /// <param name="deliver">
    /// Sends one body and classifies the outcome -- ordinarily <c>App.DeliverCapturedEventAsync</c>,
    /// which re-reads the current delivery target and its expiry fresh on every call (the "Volatile.Read
    /// + expiry re-check" the #48 plan requires) rather than a target snapshotted once when this
    /// worker was constructed. This is deliberately a delegate and not a bound <see cref="MvpStreamSender"/>:
    /// unlike screenshot delivery, an event's credential expiring must stop networking outright (see
    /// <see cref="EventSpool"/>'s own remarks and the #48 plan's acceptance criteria), so the check
    /// has to be live on every send, not merely current as of the last time a worker was rebuilt. This
    /// is deliberately a second, per-item check on top of <paramref name="isTargetUsable"/>'s
    /// once-per-pass one: a long pass over many due entries can outlast a credential's remaining
    /// life, and this is what stops mid-pass rather than only at the next pass's boundary.
    /// </param>
    public EventDeliveryWorker(
        Func<bool> isTargetUsable,
        Func<ReadOnlyMemory<byte>, CancellationToken, Task<EventSendOutcome>> deliver,
        EventSpool spool,
        Action<EventDeliveryOutcomeEvent>? onOutcome = null)
    {
        _isTargetUsable = isTargetUsable ?? throw new ArgumentNullException(nameof(isTargetUsable));
        _deliver = deliver ?? throw new ArgumentNullException(nameof(deliver));
        _spool = spool ?? throw new ArgumentNullException(nameof(spool));
        _onOutcome = onOutcome;
    }

    /// <summary>
    /// Drains every currently-due spooled entry once, per-session FIFO (see this type's own
    /// remarks). Also reports any byte-ceiling/age evictions and any refusals
    /// <see cref="EventSpool"/> has accumulated since the previous pass, on the same footing as a
    /// send's own terminal outcome.
    /// </summary>
    /// <returns>
    /// <see cref="EventSpool.TimeUntilNextDue"/>, read after this pass's own
    /// <see cref="EventSpool.RecordRetry"/> calls -- so it reflects any backoff just scheduled --
    /// rather than before them. <see langword="null"/> means nothing is spooled, or that no usable
    /// target currently exists (see <paramref name="isTargetUsable"/> on the constructor) -- the
    /// latter parks the *send* loop without ever leasing, reading back, or attempting to deliver a
    /// single spooled body, so a revoked or expired credential stops networking outright.
    /// </returns>
    /// <remarks>
    /// <b>Bookkeeping runs regardless of whether a usable target exists (fix for a defect found in
    /// review, otherwise real).</b> <see cref="EventSpool.Spool"/> evicts and refuses entries on the
    /// capture path independent of whether anything can currently be sent -- an unprovisioned
    /// machine is the *ordinary* case the spool's bounds are sized for, per
    /// <see cref="EventDeliverySettings"/>'s own remarks -- so age-based eviction and the two
    /// pending-list drains below must never be skipped just because <paramref name="isTargetUsable"/>
    /// (the constructor parameter) says no target exists right now. Skipping them would mean every
    /// loss on a never-provisioned machine accumulates forever in <see cref="EventSpool"/>'s two
    /// pending lists with nothing ever draining them, and the tray's abandoned tally would never
    /// move -- exactly the silent loss this issue exists to make visible. Only the networking half
    /// below (leasing, reading a body back, and calling <c>deliver</c>) is gated on
    /// <paramref name="isTargetUsable"/>.
    /// </remarks>
    public async Task<TimeSpan?> DrainOnceAsync(CancellationToken cancellationToken)
    {
        _spool.EvictExpired();

        foreach (string evictedKey in _spool.DrainPendingEvictions())
        {
            Report(evictedKey, EventDeliveryOutcome.Evicted);
        }

        foreach (string refusedKey in _spool.DrainPendingRefusals())
        {
            Report(refusedKey, EventDeliveryOutcome.Refused);
        }

        if (!_isTargetUsable() || _targetKnownRevoked)
        {
            // Bookkeeping above already ran for this pass; there is nothing to send, and returning
            // TimeUntilNextDue here would be actively harmful while nothing has ever been attempted
            // (every entry's NextAttemptAt is still DateTimeOffset.MinValue), since that resolves to
            // TimeSpan.Zero and would busy-loop the scheduler against a target that cannot possibly
            // have become usable in between. Parking ("nothing due") is correct: capture's own
            // nudge on the next spooled event re-invokes this pass regardless, and
            // RefreshDeliveryTarget nudges directly the moment a target becomes usable again. A
            // worker that has already seen an Unauthorized response (_targetKnownRevoked) parks here
            // on every subsequent call for the rest of its own lifetime, exactly like an expired
            // target -- see that field's own remarks.
            return null;
        }

        var haltedSessions = new HashSet<string>(StringComparer.Ordinal);
        foreach (SpooledEventHandle handle in _spool.Drain())
        {
            cancellationToken.ThrowIfCancellationRequested();

            if (haltedSessions.Contains(handle.SessionId))
            {
                // A previous entry of this same session already came back Retrying this pass;
                // per-session FIFO means this later entry must wait for the next pass rather than
                // be delivered ahead of the one still retrying.
                continue;
            }

            if (!_spool.TryLease(handle.Key))
            {
                // Lost the narrow race against a concurrent eviction; the eviction already queued
                // this key for DrainPendingEvictions on the next pass.
                continue;
            }

            try
            {
                EventDeliveryOutcome outcome = await DrainOneAsync(handle, cancellationToken).ConfigureAwait(false);
                if (outcome == EventDeliveryOutcome.Retrying)
                {
                    haltedSessions.Add(handle.SessionId);
                }
            }
            finally
            {
                _spool.Release(handle.Key);
            }

            if (_targetKnownRevoked)
            {
                // This entry's send just came back Unauthorized (see DrainOneAsync). That means the
                // credential itself, not this one entry's bytes, is the problem -- continuing to
                // attempt the rest of this pass's due entries, of this session or any other, would
                // just keep hitting the same revoked capability URL. Stop the whole pass here,
                // parked exactly like the no-usable-target case above, rather than only halting this
                // one session the way an ordinary Retry does.
                return null;
            }
        }

        return _spool.TimeUntilNextDue;
    }

    private async Task<EventDeliveryOutcome> DrainOneAsync(SpooledEventHandle handle, CancellationToken cancellationToken)
    {
        if (!_spool.TryReadBody(handle.Key, out byte[] body))
        {
            Report(handle.Key, EventDeliveryOutcome.VerificationFailed);
            return EventDeliveryOutcome.VerificationFailed;
        }

        try
        {
            EventSendOutcome result;
            try
            {
                result = await _deliver(body, cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
            catch
            {
                // The sender threw something other than its own documented outcomes (e.g. a test
                // double, or a defect). Count it exactly like a retryable failure rather than
                // letting it escape and stall this session's remaining entries indefinitely, or
                // every other session's entries in this same pass.
                _spool.RecordRetry(handle.Key);
                Report(handle.Key, EventDeliveryOutcome.Retrying);
                return EventDeliveryOutcome.Retrying;
            }

            switch (result)
            {
                case EventSendOutcome.Acknowledged:
                    _spool.Remove(handle.Key);
                    Report(handle.Key, EventDeliveryOutcome.Acknowledged);
                    return EventDeliveryOutcome.Acknowledged;

                case EventSendOutcome.Dropped:
                    _spool.Remove(handle.Key);
                    Report(handle.Key, EventDeliveryOutcome.Dropped);
                    return EventDeliveryOutcome.Dropped;

                case EventSendOutcome.Unauthorized:
                    // Deliberate correction to the #48 plan's §2.5 (see EventSendOutcome.Unauthorized's
                    // own remarks): 401/403 no longer retry networking. RecordRetry still runs so the
                    // spool's own AnyRetrying -- and therefore the tray's existing "retrying N", not a
                    // new seventh state -- reflects that this entry is genuinely stalled rather than
                    // silently succeeding; _targetKnownRevoked (set below, read at the top of
                    // DrainOnceAsync and after every entry in its own loop) is what actually halts
                    // sending, regardless of how soon that scheduled backoff would otherwise elapse.
                    _spool.RecordRetry(handle.Key);
                    _targetKnownRevoked = true;
                    Report(handle.Key, EventDeliveryOutcome.Retrying);
                    return EventDeliveryOutcome.Retrying;

                case EventSendOutcome.Retry:
                default:
                    _spool.RecordRetry(handle.Key);
                    Report(handle.Key, EventDeliveryOutcome.Retrying);
                    return EventDeliveryOutcome.Retrying;
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(body);
        }
    }

    private void Report(string key, EventDeliveryOutcome outcome)
    {
        try
        {
            _onOutcome?.Invoke(new EventDeliveryOutcomeEvent(key, outcome));
        }
        catch
        {
            // A misbehaving observer must never break delivery.
        }
    }
}
