using System.Security.Cryptography;
using JazzCaptureCore.Archive;

namespace JazzCapture;

/// <summary>Outcome of one attempt to move a staged narration clip, reported through
/// <see cref="NarrationDeliveryWorker"/>'s status callback. Every value here is safe to display --
/// none can ever carry a bucket, key, or access token.</summary>
public enum NarrationDeliveryOutcome
{
    /// <summary>The clip's row was spooled to <see cref="EventSpool"/> with a real Files id; the pair was removed.</summary>
    Acknowledged,

    /// <summary>The attempt failed in a retryable way; the pair stays staged for a later attempt
    /// with no attempt budget -- see <see cref="NarrationSpool"/>'s own remarks.</summary>
    Retrying,

    /// <summary>
    /// Terminal (issue #84 plan §2.3, reversed by amendment 2): a 400 from prepare or the PUT, or
    /// staged bytes that no longer match the sidecar's length or digest. The clip's row is still
    /// spooled -- with <c>AudioFileId</c> null, which <c>OtlpMapper</c> projects as <c>""</c> -- and
    /// the pair is then removed. Reported once, after both have happened.
    /// </summary>
    Dropped,

    /// <summary>Terminal: an unparsable sidecar, discovered at adoption, not by this worker. Neither
    /// half of the pair means anything without the other, so no row can be built and none is
    /// emitted -- unlike <see cref="Dropped"/>, there is nothing here to spool.</summary>
    VerificationFailed,

    /// <summary>Terminal: the spool evicted this clip -- by the byte ceiling or by age -- before it
    /// was ever attempted. No row is emitted: the audio itself is gone, not merely undelivered.</summary>
    Evicted,

    /// <summary>Terminal: the spool refused to admit this clip in the first place (the clip alone
    /// exceeded a bound, debt left no room, or the write itself failed). Always counted, exactly
    /// like <see cref="EventSpool"/>'s identical refusal accounting.</summary>
    Refused,
}

/// <summary>Non-secret projection of one drain-pass outcome, for a tray or diagnostics surface.</summary>
public readonly record struct NarrationDeliveryOutcomeEvent(string Key, NarrationDeliveryOutcome Outcome);

/// <summary>
/// One bounded drain pass over <see cref="NarrationSpool"/>: prepares and uploads each due clip
/// through <see cref="KeboolaFilesClient"/>, stamps the real Files id, hands the finished narration
/// event to the caller-supplied spool delegate, and applies the no-attempt-budget retry policy
/// issue #84 settles on for a clip -- exactly as slice 1 (issue #48) settled on for an event.
/// </summary>
/// <remarks>
/// <para>
/// <b>Ordering (issue #84, §2.6), and why it differs from <see cref="ScreenshotDeliveryWorker"/>'s.</b>
/// Prepare then upload then <em>stamp the sidecar</em> then <em>spool the event</em> then remove the
/// pair (sidecar first, then blob). The stamp is the upload's actual commit point: once
/// <see cref="NarrationSpool.TryStampFilesId"/> returns <see langword="true"/>, a crash before the
/// event is spooled re-enters directly at the spool step on the next launch -- no second prepare, no
/// second upload, no second Files id (R4 of the #84 plan: a narration row carries no
/// <c>eventId</c>/<c>sequence</c> on the wire, so two different ids for one clip would be
/// unreconcilable downstream, unlike an ordinary duplicated event).
/// </para>
/// <para>
/// <b>Stops the whole pass at the first retryable failure (deliberately unlike
/// <see cref="ScreenshotDeliveryWorker"/> and <see cref="EventDeliveryWorker"/>, both of which carry
/// on).</b> Narration clips are large and few -- one per closed label, not one per click or
/// keystroke -- so burning a second multi-megabyte PUT against a network connection that just failed
/// is waste, not resilience. This matches macOS's own narration drain, per the #84 plan.
/// </para>
/// <para>
/// <b>The dangling-allocation rule is inverted from <see cref="ScreenshotDeliveryWorker"/>'s, and the
/// inversion is a safety property (R5 of the #84 plan).</b> <see cref="ScreenshotDeliveryWorker"/>
/// never deletes a Files allocation on a retryable failure, because the event carrying that id has
/// already been emitted. Here the event has <em>not</em> gone out yet -- it cannot exist before the
/// upload returns an id -- so an allocation whose PUT just failed references nothing at all.
/// <see cref="KeboolaFilesClient.CleanupUnusedAllocationAsync"/> is called best-effort on every
/// retryable and terminal upload outcome, exactly the fix macOS's own uploader recorded shipping
/// ("delete the dangling file id we just minted so retries never pile up empty records").
/// </para>
/// <para>
/// Never throws for one clip's own failure; only genuine cancellation of the supplied
/// <see cref="CancellationToken"/> propagates.
/// </para>
/// <para>
/// <b>Accepted residual: the crash window between the PUT and the stamp (round 4 review finding).</b>
/// Every managed failure between minting an allocation and durably recording its id is cleaned up
/// by the catches below, but process termination is not a managed failure. If the process dies
/// after <see cref="KeboolaFilesClient.PrepareAsync"/> has minted an id -- or even after the PUT has
/// returned 2xx -- but before <see cref="NarrationSpool.TryStampFilesId"/> has persisted it, the
/// sidecar is still unstamped on relaunch, so this worker prepares and uploads the clip again and
/// the first Files object is left orphaned. Closing this properly needs a durable prepared/uploaded
/// state written before the network call and reconciled at adoption -- a second two-phase commit on
/// top of the one the spool already runs -- which is more machinery than the exposure justifies, so
/// it is deliberately not built here.
/// </para>
/// <para>
/// What that window costs is one unreferenced object in Keboola Files per crash landing inside it,
/// on a path that runs at most once per clip. Nothing downstream reads an object no row points at,
/// so the cost is storage rather than correctness. No observation is lost: the clip is still staged,
/// and its row still goes out on the next launch.
/// </para>
/// <para>
/// <b>What this type does not promise is exactly-once row delivery, and an earlier revision of this
/// paragraph wrongly said it did (round 6 review finding).</b> There is a second, distinct crash
/// window after the one above: <see cref="_trySpoolEvent"/> admits the row to the event spool
/// <em>before</em> <see cref="NarrationSpool.Remove"/> deletes the pair, so a crash between those
/// two leaves the pair adoptable with its <see cref="PendingNarration.FilesId"/> already stamped,
/// and the next launch re-enters at the spool step and emits the row again. That is
/// <see cref="NarrationSpool"/>'s own documented behaviour -- "at most one duplicate row, never a
/// second upload or a second id" -- and the ordering exists to bound the damage to exactly that.
/// The processor does not de-duplicate, so such a row is visible rather than absorbed.
/// </para>
/// <para>
/// So the honest statement of the guarantee, in both directions. Rows: <b>at-least-once</b>, which
/// is the same posture the event pipeline takes everywhere else and is what the durability ordering
/// is designed around -- a duplicated row is a recoverable annoyance, a lost one is not. Uploads and
/// Files ids: <b>never a second one once the stamp is durable</b>, which is the half that actually
/// has to hold, because a narration row carries no <c>eventId</c> or <c>sequence</c> on the wire and
/// two different ids for one clip would be unreconcilable downstream. And unconditionally: an id
/// that reaches a row is always one whose bytes finished uploading first.
/// </para>
/// </remarks>
public sealed class NarrationDeliveryWorker
{
    private readonly KeboolaFilesClient? _client;
    private readonly NarrationSpool _spool;
    private readonly Func<PendingNarration, bool> _trySpoolEvent;
    private readonly Action<NarrationDeliveryOutcomeEvent>? _onOutcome;

    /// <param name="client">
    /// The Files transport, built over <see cref="NarrationDeliverySettings"/>' budgets, or
    /// <see langword="null"/> when no usable Storage credential currently exists. A null client
    /// parks the networking half of every pass -- see <see cref="DrainOnceAsync"/>'s own remarks --
    /// exactly like a null target parks <see cref="EventDeliveryWorker"/>.
    /// </param>
    /// <param name="spool">The durable pair spool this worker drains.</param>
    /// <param name="trySpoolEvent">
    /// Builds the finished narration <c>ActivityEvent</c> and <c>SessionContext</c> from
    /// <see cref="PendingNarration"/>, projects the OTLP body, and hands it to
    /// <c>App.TrySpoolEvent</c> (the same helper the capture path itself uses for every other
    /// event). Returns whether the event spool actually admitted it. Runs on this worker's own
    /// background task, never on the capture path, and deliberately does not report into the
    /// <em>event</em> tracker -- a refusal here keeps the narration clip staged rather than being
    /// double-counted (§3.8(d) of the #84 plan).
    /// </param>
    /// <param name="onOutcome">Reported once per clip per pass; never invoked while any lock in this
    /// type or <see cref="NarrationSpool"/> is held.</param>
    public NarrationDeliveryWorker(
        KeboolaFilesClient? client,
        NarrationSpool spool,
        Func<PendingNarration, bool> trySpoolEvent,
        Action<NarrationDeliveryOutcomeEvent>? onOutcome = null)
    {
        _client = client;
        _spool = spool ?? throw new ArgumentNullException(nameof(spool));
        _trySpoolEvent = trySpoolEvent ?? throw new ArgumentNullException(nameof(trySpoolEvent));
        _onOutcome = onOutcome;
    }

    /// <summary>
    /// Drains every currently-due staged clip once, stopping at the first retryable failure. Also
    /// reports any byte-ceiling/age evictions and any refusals -- including an unparsable sidecar
    /// discovered at adoption -- <see cref="NarrationSpool"/> has accumulated since the previous
    /// pass, on the same footing as an upload's own terminal outcome.
    /// </summary>
    /// <remarks>
    /// <b>Bookkeeping runs regardless of whether a usable client exists</b> -- the identical
    /// reasoning <see cref="EventDeliveryWorker.DrainOnceAsync"/> documents: narration recorded on
    /// an unprovisioned machine (the ordinary case #53 scope 4 describes) must still age out and
    /// report visibly, not accumulate silently until a credential eventually arrives.
    /// </remarks>
    public async Task<TimeSpan?> DrainOnceAsync(CancellationToken cancellationToken)
    {
        _spool.EvictExpired();

        foreach (string evictedKey in _spool.DrainPendingEvictions())
        {
            Report(evictedKey, NarrationDeliveryOutcome.Evicted);
        }

        foreach (string refusedKey in _spool.DrainPendingRefusals())
        {
            Report(refusedKey, NarrationDeliveryOutcome.Refused);
        }

        foreach (string unparsableKey in _spool.DrainPendingVerificationFailures())
        {
            // An incomplete or unparsable pair found at adoption -- no live entry ever existed for
            // it, so no row was ever spooled and none ever can be.
            Report(unparsableKey, NarrationDeliveryOutcome.VerificationFailed);
        }

        // Deliberately no "no client, park the whole pass" shortcut here (unlike EventDeliveryWorker,
        // which parks entirely on no target): a clip whose sidecar already carries a stamped Files
        // id needs no client at all to reach the spool step, so gating the whole loop on _client
        // would leave an already-uploaded clip stranded behind a lapsed Storage credential. The
        // null-client case is instead handled per clip, inside DrainOneAsync, only for a clip that
        // still needs a prepare or upload.
        foreach (StagedNarrationHandle handle in _spool.Drain())
        {
            cancellationToken.ThrowIfCancellationRequested();

            if (!_spool.TryLease(handle.Key))
            {
                continue;
            }

            NarrationDeliveryOutcome outcome;
            try
            {
                outcome = await DrainOneAsync(handle, cancellationToken).ConfigureAwait(false);
            }
            finally
            {
                _spool.Release(handle.Key);
            }

            // Halt the whole pass only on a Retrying outcome that actually came from an attempted
            // (or at least attemptable) network call -- not from _client being null (review
            // finding). _spool.Drain() returns clips oldest-first, mixing not-yet-stamped and
            // already-stamped ones; on an unprovisioned machine every not-yet-stamped clip reports
            // Retrying from DrainOneAsync's own client-null branch, and halting the pass on the
            // very first one would strand every already-stamped clip behind it -- clips that need
            // no client at all to reach the event spool -- for as long as the machine stays
            // unprovisioned. There is no wasted attempt to avoid by halting here, unlike a genuine
            // network Retry: _client is null means nothing was attempted in the first place.
            if (outcome == NarrationDeliveryOutcome.Retrying && _client is not null)
            {
                // Return specifically this entry's own just-scheduled backoff, not
                // _spool.TimeUntilNextDue (review finding, H1): that property's minimum is taken
                // over every staged clip, including every one this halt never reached, which still
                // sits at DateTimeOffset.MinValue and would make the reported delay resolve to Zero
                // for as long as any of them exists -- making DeliveryDrainScheduler re-enter
                // near-instantly and attempt a *different* clip immediately, defeating the entire
                // point of stopping the pass. TimeUntilNextAttempt can itself return null (the
                // entry was removed or evicted in the narrow window since it released its lease
                // above), in which case TimeUntilNextExpiry is still a safe, never-zero fallback.
                return _spool.TimeUntilNextAttempt(handle.Key) ?? _spool.TimeUntilNextExpiry;
            }
        }

        return _spool.TimeUntilNextDue ?? _spool.TimeUntilNextExpiry;
    }

    private async Task<NarrationDeliveryOutcome> DrainOneAsync(StagedNarrationHandle handle, CancellationToken cancellationToken)
    {
        PendingNarration meta = handle.Meta;

        if (meta.FilesId is { } stampedFilesId)
        {
            // Already stamped: a previous process crashed between the stamp and the event being
            // spooled (§2.1). Skip prepare and upload entirely and re-enter directly at the spool
            // step -- no blob read needed, since nothing more is ever sent to Storage for this clip.
            return await OnUploadAcknowledgedAsync(handle.Key, meta, stampedFilesId, cancellationToken)
                .ConfigureAwait(false);
        }

        if (_client is null)
        {
            // No usable Storage credential right now, and this clip still needs a prepare -- unlike
            // the already-stamped case above, there is genuinely nothing to do. Checked before
            // reading the blob back at all (review finding, M2): on an unprovisioned machine --
            // #53 scope 4's ordinary case -- reading and re-hashing every staged clip on every pass
            // would mean up to SpoolByteCeiling of disk I/O and SHA-256 under NarrationSpool's own
            // coarse lock, the same lock the capture path takes Stage through, on every backoff
            // cycle for no gain: nothing here can be uploaded anyway. Retry -- and, since the outer
            // loop no longer halts the whole pass for this specific outcome, this does not strand
            // any other clip either. A blob that happens to be corrupted while unprovisioned is
            // simply detected later, the next time a credential is present to actually check it --
            // never lost, since the pair stays staged either way.
            _spool.RecordRetry(handle.Key);
            Report(handle.Key, NarrationDeliveryOutcome.Retrying);
            return NarrationDeliveryOutcome.Retrying;
        }

        NarrationBlobRead read = _spool.ReadBlob(handle.Key, out byte[] blob);
        if (read == NarrationBlobRead.Unavailable)
        {
            _spool.RecordRetry(handle.Key);
            Report(handle.Key, NarrationDeliveryOutcome.Retrying);
            return NarrationDeliveryOutcome.Retrying;
        }

        if (read == NarrationBlobRead.Corrupt)
        {
            // Terminal: staged bytes no longer match the sidecar's own length/digest (amendment 2).
            return TerminalDrop(handle.Key, meta);
        }

        try
        {
            var request = new ArtifactFilesRequest(
                meta.ArchiveId,
                meta.CaptureId,
                meta.SessionId,
                meta.ArtifactId,
                meta.MediaType,
                meta.Sha256,
                meta.ByteLength)
            {
                Kind = NarrationAudioV1.Kind,
            };

            FilesPrepareOutcome prepareOutcome = await _client!
                .PrepareAsync(request, cancellationToken).ConfigureAwait(false);
            if (prepareOutcome.Result is not { } prepared)
            {
                CryptographicOperations.ZeroMemory(blob);
                if (prepareOutcome.FailureKind is FilesPrepareFailureKind.PermanentRejection
                    or FilesPrepareFailureKind.InvalidRequest
                    or FilesPrepareFailureKind.UnusableTarget)
                {
                    // Terminal: a 400/422 from prepare, a request that failed local validation
                    // before any network call was made, or an allocation this client can never
                    // upload to (amendment 2).
                    //
                    // InvalidRequest is terminal for the same reason PermanentRejection is, and
                    // treating it as retryable was a real defect (review finding). Its own summary
                    // says "the request failed local validation; no network call was made" -- so
                    // identical bytes with identical metadata can never start succeeding, and an
                    // event has no attempt budget (§2.3). A staged clip whose media type this
                    // client does not accept -- an adopted sidecar from a future encoder, or a
                    // hand-edited one -- would therefore have retried every backoff interval for
                    // the full 48-hour retention and then left by *eviction*, which reports
                    // Evicted rather than Dropped and so never runs TerminalDrop. Amendment 2
                    // exists precisely to make a failed narration upload visible as a row with an
                    // empty audio_file_id; routing this case through the bound instead would have
                    // silently denied it that row, which is the outcome amendment 2 forbids.
                    //
                    // UnusableTarget is terminal for the same reason (a second review finding): its
                    // own summary is "an allocation this client can never upload to (a non-gcp
                    // provider, or gcsUploadParams that failed validation), or the response could
                    // not be interpreted at all", and it records that any recovered Files id has
                    // already been deleted best-effort, so there is nothing dangling to clean up
                    // here either. Every one of those causes is a property of how the project or
                    // its Storage backend is configured, not a transient network fault, so the
                    // choice is not between "retry and maybe succeed" and "give up" -- it is
                    // between losing the clip after 48 hours of pointless retries with no row, and
                    // losing it now with the row that says so.
                    return TerminalDrop(handle.Key, meta);
                }

                _spool.RecordRetry(handle.Key);
                Report(handle.Key, NarrationDeliveryOutcome.Retrying);
                return NarrationDeliveryOutcome.Retrying;
            }

            FilesUploadResult uploadResult;
            try
            {
                uploadResult = await _client
                    .UploadAsync(prepared, request, blob, cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                // Shutdown mid-upload (review finding): this id has never been recorded anywhere --
                // the event has not gone out either way -- so it must not be left dangling (R5) just
                // because this attempt was cancelled rather than classified Retry/Dropped by the
                // transport itself. Cleaned up on a fresh, unlinked token: the caller's own token is
                // already cancelled, and PrepareCleanupBudget bounds this regardless.
                await CleanupBestEffortAsync(prepared.FilesId, CancellationToken.None).ConfigureAwait(false);
                throw;
            }
            catch (Exception)
            {
                // Any failure from the upload transport itself that it did not classify into a
                // FilesUploadResult outcome -- KeboolaFilesClient.UploadAsync already converts its
                // own budget timeout, HttpRequestException and IOException into Retry/Dropped, so
                // what actually reaches here is a genuinely unclassified throw (an
                // InvalidOperationException or ObjectDisposedException from the transport, say;
                // exactly what the accompanying regression test simulates -- corrected wording,
                // round 3 review finding). This id has never been recorded on any emitted event
                // either, so it must not be left dangling (R5) just because the failure surfaced as
                // a thrown exception instead of a classified outcome. Without this, the outer catch
                // below would still convert this into a Retrying outcome, but without ever deleting
                // the allocation PrepareAsync minted -- and the very next attempt would mint another.
                await CleanupBestEffortAsync(prepared.FilesId, CancellationToken.None).ConfigureAwait(false);
                _spool.RecordRetry(handle.Key);
                Report(handle.Key, NarrationDeliveryOutcome.Retrying);
                return NarrationDeliveryOutcome.Retrying;
            }
            finally
            {
                CryptographicOperations.ZeroMemory(blob);
            }

            switch (uploadResult.Outcome)
            {
                case FilesDeliveryOutcome.Acknowledged:
                    return await OnUploadAcknowledgedAsync(handle.Key, meta, prepared.FilesId, cancellationToken)
                        .ConfigureAwait(false);

                case FilesDeliveryOutcome.Dropped:
                    // Terminal per the transport (a 400 from the PUT, or a re-verified bytes
                    // mismatch). The dangling-allocation rule (R5): this id has never been on any
                    // emitted event, so delete it best-effort rather than leaving it dangling.
                    await CleanupBestEffortAsync(prepared.FilesId, cancellationToken).ConfigureAwait(false);
                    return TerminalDrop(handle.Key, meta);

                case FilesDeliveryOutcome.Retry:
                default:
                    await CleanupBestEffortAsync(prepared.FilesId, cancellationToken).ConfigureAwait(false);
                    _spool.RecordRetry(handle.Key);
                    Report(handle.Key, NarrationDeliveryOutcome.Retrying);
                    return NarrationDeliveryOutcome.Retrying;
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            // Same gap as the catch below, same fix: shutdown arriving during PrepareAsync lands
            // here without the upload's finally ever running. Cheap, and it keeps "every exit from
            // this method zeroes the blob" true without exception -- which is the only form of that
            // rule anyone can actually check.
            CryptographicOperations.ZeroMemory(blob);
            throw;
        }
        catch
        {
            // Reachable only for a failure with no allocation to clean up either way: PrepareAsync
            // itself throwing (no id was ever minted), or OnUploadAcknowledgedAsync/TerminalDrop
            // throwing after the upload's own outcome was already classified and handled (where
            // deleting prepared.FilesId could wrongly destroy an id already committed to Files). The
            // upload-specific catch above is what owns cleanup for everything in between.
            //
            // Zeroed here too (review finding): the upload's own finally only covers the region
            // from PrepareAsync succeeding onwards, so a throw out of PrepareAsync itself reached
            // this catch with up to MaximumClipBytes of captured audio left unzeroed on the
            // large-object heap until a collection happened to reclaim it. Every other exit from
            // this method already zeroes the blob, and this was the one that did not.
            CryptographicOperations.ZeroMemory(blob);
            _spool.RecordRetry(handle.Key);
            Report(handle.Key, NarrationDeliveryOutcome.Retrying);
            return NarrationDeliveryOutcome.Retrying;
        }
    }

    /// <summary>
    /// Stamps the sidecar (unless it already carries this exact id) then hands the finished event to
    /// <see cref="_trySpoolEvent"/>. Both are treated as the same commit sequence: a failure at
    /// either step keeps the pair staged, and the next pass re-enters here directly rather than
    /// re-uploading (§2.6 steps 4-6).
    /// </summary>
    private async Task<NarrationDeliveryOutcome> OnUploadAcknowledgedAsync(
        string key, PendingNarration meta, long filesId, CancellationToken cancellationToken)
    {
        if (meta.FilesId != filesId && !_spool.TryStampFilesId(key, filesId))
        {
            // The stamp itself failed (an I/O or ACL problem rewriting the sidecar) after the PUT
            // had already succeeded (review finding). This id was never recorded anywhere, so --
            // exactly like a retryable upload failure -- it references nothing and must not be left
            // dangling while the next attempt prepares and uploads a second one (R5).
            await CleanupBestEffortAsync(filesId, cancellationToken).ConfigureAwait(false);
            _spool.RecordRetry(key);
            Report(key, NarrationDeliveryOutcome.Retrying);
            return NarrationDeliveryOutcome.Retrying;
        }

        PendingNarration stamped = meta with { FilesId = filesId };
        if (!_trySpoolEvent(stamped))
        {
            _spool.RecordRetry(key);
            Report(key, NarrationDeliveryOutcome.Retrying);
            return NarrationDeliveryOutcome.Retrying;
        }

        _spool.Remove(key);
        Report(key, NarrationDeliveryOutcome.Acknowledged);
        return NarrationDeliveryOutcome.Acknowledged;
    }

    /// <summary>
    /// Amendment 2 to the #84 plan (reversing §2.3): builds and spools the row with
    /// <c>AudioFileId</c> null <em>before</em> removing the pair, not after -- removing first and
    /// then trying to emit would mean a crash in between loses the row entirely, with nothing left
    /// to rebuild it from once the sidecar is gone.
    /// </summary>
    /// <remarks>
    /// <b>The pair is removed only once the row has actually been admitted (review finding, fix for
    /// what was originally a best-effort admission here).</b> Amendment 2 exists specifically to
    /// make a terminal upload failure visible rather than indistinguishable from "narration was
    /// never attempted"; unconditionally removing the pair even when <see cref="_trySpoolEvent"/>
    /// returns <see langword="false"/> (the event spool is unavailable, or momentarily refuses
    /// admission) would silently defeat that same guarantee it exists to provide. So a refusal here
    /// is treated exactly like any other retryable failure: the pair stays staged and the next pass
    /// re-enters this same terminal path. Re-running the upload classification too (rather than
    /// remembering "already decided terminal, only the row needs retrying") is an accepted, bounded
    /// cost: the clip already failed for a reason retrying identical bytes cannot fix, so the retry
    /// only ever repeats the identical terminal outcome -- it does not risk a second success, a
    /// second Files id, or a duplicate row, and it is paced by the same jittered backoff as every
    /// other retry.
    /// </remarks>
    private NarrationDeliveryOutcome TerminalDrop(string key, PendingNarration meta)
    {
        PendingNarration withNoFilesId = meta with { FilesId = null };
        if (!_trySpoolEvent(withNoFilesId))
        {
            _spool.RecordRetry(key);
            Report(key, NarrationDeliveryOutcome.Retrying);
            return NarrationDeliveryOutcome.Retrying;
        }

        _spool.Remove(key);
        Report(key, NarrationDeliveryOutcome.Dropped);
        return NarrationDeliveryOutcome.Dropped;
    }

    private async Task CleanupBestEffortAsync(long filesId, CancellationToken cancellationToken)
    {
        try
        {
            await _client!.CleanupUnusedAllocationAsync(filesId).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            // Best-effort: this costs storage, not correctness, and must never throw out of a drain
            // pass.
        }
    }

    private void Report(string key, NarrationDeliveryOutcome outcome)
    {
        try
        {
            _onOutcome?.Invoke(new NarrationDeliveryOutcomeEvent(key, outcome));
        }
        catch
        {
            // A misbehaving observer must never break delivery.
        }
    }
}
