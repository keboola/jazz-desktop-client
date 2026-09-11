namespace JazzCapture;

/// <summary>Outcome of one attempt to move a staged screenshot, reported through
/// <see cref="ScreenshotDeliveryWorker"/>'s status callback. Every value here is safe to display or
/// put in an exception message -- none of them can ever carry a bucket, key, or access token.</summary>
public enum ScreenshotDeliveryOutcome
{
    /// <summary>The bytes reached GCS; the staged entry was removed.</summary>
    Acknowledged,

    /// <summary>Upload failed in a retryable way; the entry stays staged for a later attempt.</summary>
    Retrying,

    /// <summary>Terminal: dropped after either GCS or this client's own attempt budget refused any
    /// further retry. The staged entry was removed; the Files id from prepare is deliberately left
    /// dangling.</summary>
    Dropped,

    /// <summary>The bytes read back from the staging area failed length/digest verification. The
    /// entry was already dropped by the staging area itself.</summary>
    VerificationFailed,

    /// <summary>Terminal: the staging area evicted this entry -- by the byte ceiling
    /// (<see cref="ScreenshotDeliverySettings.StagingByteCeiling"/>) or by age
    /// (<see cref="ScreenshotDeliverySettings.StagingRetention"/>) -- before it was ever attempted.
    /// Kept distinct from <see cref="Dropped"/> because nothing was ever sent to GCS and no attempt
    /// budget was exhausted; the entry was simply crowded or aged out to make room for others. The
    /// Files id from prepare is left dangling exactly as with <see cref="Dropped"/>.</summary>
    Evicted,
}

/// <summary>Non-secret projection of one drain-pass outcome, for a tray or diagnostics surface.
/// Carries only an artifact id and an outcome -- see <see cref="ScreenshotDeliveryOutcome"/>'s own
/// remarks on why that is always safe to log or display.</summary>
public readonly record struct ScreenshotDeliveryOutcomeEvent(string ArtifactId, ScreenshotDeliveryOutcome Outcome);

/// <summary>
/// One bounded drain pass over <see cref="ScreenshotStagingArea"/>: reads each due entry's bytes
/// back (re-verifying them), attempts the GCS PUT through <see cref="KeboolaFilesClient.UploadAsync"/>,
/// and applies the bounded-retry-then-drop policy from <see cref="ScreenshotDeliverySettings"/>.
/// </summary>
/// <remarks>
/// <para>
/// This is a deliberately small type compared to the closed <c>codex/68-screenshot-files</c>
/// branch's 338-line uploader: that one managed a durable queue, dangling-object cleanup, and
/// acknowledge-after-2xx bookkeeping this design does not have. Here the staging area alone owns
/// admission, verification, retry counting and eviction; this type only sequences one drain pass
/// over it and talks to the transport.
/// </para>
/// <para>
/// <see cref="KeboolaFilesClient.UploadAsync"/> already applies
/// <see cref="ScreenshotDeliverySettings.UploadCallBudget"/> internally via its own linked
/// <see cref="CancellationTokenSource"/>, so this type does not wrap the call in a second timeout.
/// </para>
/// <para>
/// This codebase has no logging framework by design. Outcomes are reported only through the
/// optional <c>onOutcome</c> callback as a <see cref="ScreenshotDeliveryOutcomeEvent"/>, which
/// carries an artifact id and an outcome enum and can never carry a secret -- never a bucket, key,
/// access token, or signed URL.
/// </para>
/// <para>
/// <b>Exactly one terminal outcome per artifact (Finding 4, #74 review, second pass).</b>
/// <see cref="ScreenshotStagingArea.Drain"/> hands out a snapshot under its own lock, but this type
/// then processes each handle outside it -- the capture path's own <see cref="ScreenshotStagingArea.Stage"/>
/// can run concurrently and could otherwise evict the very entry a call here is mid-upload for,
/// giving that one artifact two conflicting terminal outcomes (this type's own, plus a later
/// eviction report). <see cref="DrainOnceAsync"/> closes that by leasing (see
/// <see cref="ScreenshotStagingArea.Lease"/>) the one entry it is actively attempting for exactly
/// the span of that attempt, which makes eviction of that entry impossible by construction rather
/// than merely unlikely -- not a race fixed by hoping the window stays small.
/// </para>
/// </remarks>
public sealed class ScreenshotDeliveryWorker
{
    private readonly KeboolaFilesClient _client;
    private readonly ScreenshotStagingArea _staging;
    private readonly Action<ScreenshotDeliveryOutcomeEvent>? _onOutcome;

    public ScreenshotDeliveryWorker(
        KeboolaFilesClient client,
        ScreenshotStagingArea staging,
        Action<ScreenshotDeliveryOutcomeEvent>? onOutcome = null)
    {
        _client = client ?? throw new ArgumentNullException(nameof(client));
        _staging = staging ?? throw new ArgumentNullException(nameof(staging));
        _onOutcome = onOutcome;
    }

    /// <summary>
    /// Drains every currently-due staged entry once. Never throws for a single entry's own
    /// failure -- a transport exception, a verification failure, or a rejected upload all leave the
    /// rest of the pass unaffected -- so one bad entry can never stall the others. Only genuine
    /// cancellation of <paramref name="cancellationToken"/> propagates.
    /// </summary>
    /// <remarks>
    /// Also reports any byte-ceiling or age evictions <see cref="ScreenshotStagingArea"/> has
    /// accumulated since the previous pass (see <see cref="ScreenshotStagingArea.DrainPendingEvictions"/>)
    /// as a terminal <see cref="ScreenshotDeliveryOutcome.Evicted"/> outcome, on the same footing as
    /// an upload's own <see cref="ScreenshotDeliveryOutcome.Dropped"/>. Without this, an eviction --
    /// which always removes an already-prepared, already-stamped entry -- would be invisible to
    /// <see cref="ScreenshotDeliveryPresentationTracker"/>, and the tray could read "up to date" while
    /// a Files id is left dangling. Because each reported outcome flows through <see cref="_onOutcome"/>
    /// exactly like an upload outcome does, a pass that only evicted and uploaded nothing still
    /// refreshes the tray line rather than leaving it on a stale "uploading N".
    /// </remarks>
    /// <returns>
    /// <see cref="ScreenshotStagingArea.TimeUntilNextDue"/>, read after this pass's own
    /// <see cref="ScreenshotStagingArea.RecordRetry"/> calls -- so it reflects any backoff just
    /// scheduled -- rather than before them. <see langword="null"/> means nothing is staged, so
    /// there is nothing to wake the scheduler for.
    /// </returns>
    public async Task<TimeSpan?> DrainOnceAsync(CancellationToken cancellationToken)
    {
        _staging.EvictExpired();

        // Every id here was already staged and already prepared (its Files id already stamped on an
        // emitted event) before either the byte ceiling or the age bound evicted it -- possibly just
        // now via the EvictExpired() call above, possibly earlier via a byte-ceiling eviction inside
        // some Stage() call on the capture path. Reporting them here, on this background task, is
        // exactly the seam ScreenshotStagingArea's own remarks describe: the staging area never
        // invokes a caller callback itself, so it cannot ever do so while its own lock (or the
        // capture engine's) is held.
        foreach (string evictedArtifactId in _staging.DrainPendingEvictions())
        {
            Report(evictedArtifactId, ScreenshotDeliveryOutcome.Evicted);
        }

        foreach (StagedScreenshotHandle handle in _staging.Drain())
        {
            cancellationToken.ThrowIfCancellationRequested();

            // Finding 4 (#74 review, second pass): lease the entry this iteration is about to
            // attempt, immediately before attempting it, and release it in a finally regardless of
            // how the attempt ends -- success, a retryable failure, a terminal drop, a verification
            // failure, an unexpected exception from the transport, or genuine cancellation of
            // cancellationToken all take this same path out. See ScreenshotStagingArea.Lease's own
            // remarks for why this is what makes the byte-ceiling/age eviction race on a
            // concurrently-Staged entry impossible by construction rather than merely unlikely.
            // Only this one entry is ever leased at a time: the foreach here is sequential, so the
            // previous iteration's lease is already released before this one is taken.
            _staging.Lease(handle.ArtifactId);
            try
            {
                await DrainOneAsync(handle, cancellationToken).ConfigureAwait(false);
            }
            finally
            {
                _staging.Release(handle.ArtifactId);
            }
        }

        return _staging.TimeUntilNextDue;
    }

    private async Task DrainOneAsync(StagedScreenshotHandle handle, CancellationToken cancellationToken)
    {
        try
        {
            if (!_staging.TryReadBytes(handle.ArtifactId, out byte[] bytes))
            {
                Report(handle.ArtifactId, ScreenshotDeliveryOutcome.VerificationFailed);
                return;
            }

            FilesUploadResult result = await _client
                .UploadAsync(handle.Prepared, handle.Request, bytes, cancellationToken)
                .ConfigureAwait(false);

            switch (result.Outcome)
            {
                case FilesDeliveryOutcome.Acknowledged:
                    _staging.Remove(handle.ArtifactId);
                    Report(handle.ArtifactId, ScreenshotDeliveryOutcome.Acknowledged);
                    break;

                case FilesDeliveryOutcome.Dropped:
                    // Terminal per the transport (e.g. a malformed-request response it cannot fix
                    // by retrying identical bytes). Never delete the remote Files record -- the
                    // event carrying its id has already gone out.
                    _staging.Remove(handle.ArtifactId);
                    Report(handle.ArtifactId, ScreenshotDeliveryOutcome.Dropped);
                    break;

                case FilesDeliveryOutcome.Retry:
                default:
                    bool stillStaged = _staging.RecordRetry(handle.ArtifactId);
                    Report(
                        handle.ArtifactId,
                        stillStaged ? ScreenshotDeliveryOutcome.Retrying : ScreenshotDeliveryOutcome.Dropped);
                    break;
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            // The transport threw something other than its own documented outcomes (e.g. an
            // unexpected exception from a test double, or a defect). Count it exactly like a
            // retryable failure rather than letting it escape and stall every other staged entry.
            bool stillStaged = _staging.RecordRetry(handle.ArtifactId);
            Report(
                handle.ArtifactId,
                stillStaged ? ScreenshotDeliveryOutcome.Retrying : ScreenshotDeliveryOutcome.Dropped);
        }
    }

    private void Report(string artifactId, ScreenshotDeliveryOutcome outcome)
    {
        try
        {
            _onOutcome?.Invoke(new ScreenshotDeliveryOutcomeEvent(artifactId, outcome));
        }
        catch
        {
            // A misbehaving observer must never break delivery.
        }
    }
}
