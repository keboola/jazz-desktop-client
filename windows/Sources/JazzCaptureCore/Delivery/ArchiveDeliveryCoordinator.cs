namespace JazzCaptureCore.Delivery;

/// <summary>One delivery that failed during a pass, without stopping the pass.</summary>
/// <param name="ArchiveId">Delivery that failed.</param>
/// <param name="Message">What went wrong, in terms safe to show a user.</param>
public sealed record ArchiveDeliveryPassFailure(string ArchiveId, string Message);

/// <summary>
/// Advances durable deliveries. It owns no evidence and mints no identity.
/// </summary>
/// <remarks>
/// <para>
/// Every attempt follows the same four steps: verify the queue-owned package against the record,
/// commit the attempt, call the transport, commit the outcome. Steps one and two happen before the
/// network so that a crash at any point leaves a state the queue can resume from; step four is the
/// only place a delivery becomes final.
/// </para>
/// <para>
/// Faults are isolated per delivery. A damaged package, a missing package or a transport that throws
/// affects exactly the delivery it happened to, and <see cref="DrainAsync"/> carries on to the next
/// one — because a queue that stops at the first bad entry loses everything behind it. Cancellation
/// is the one exception: it ends the pass and is never recorded as a delivery failure.
/// </para>
/// </remarks>
public sealed class ArchiveDeliveryCoordinator
{
    private readonly ArchiveDeliveryQueue _queue;
    private readonly IArchiveDeliveryTransport _transport;
    private readonly Func<DateTimeOffset> _clock;

    /// <summary>Creates a coordinator over one queue and one transport.</summary>
    /// <param name="queue">The durable queue.</param>
    /// <param name="transport">Where the bytes go.</param>
    /// <param name="clock">Time source; defaults to the system UTC clock.</param>
    public ArchiveDeliveryCoordinator(
        ArchiveDeliveryQueue queue,
        IArchiveDeliveryTransport transport,
        Func<DateTimeOffset>? clock = null)
    {
        _queue = queue ?? throw new ArgumentNullException(nameof(queue));
        _transport = transport ?? throw new ArgumentNullException(nameof(transport));
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
    }

    /// <summary>Runs the delivery that has been waiting longest, or returns null when none is due.</summary>
    public async Task<ArchiveDeliveryRecord?> RunNextAsync(CancellationToken cancellationToken = default)
    {
        IReadOnlyList<ArchiveDeliveryRecord> runnable = _queue.Runnable(_clock());
        return runnable.Count == 0
            ? null
            : await RunAsync(runnable[0].ArchiveId, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>
    /// Attempts every delivery that is due, one at a time, and returns the ones that failed.
    /// </summary>
    /// <remarks>
    /// The runnable set is taken once, at the start. A delivery that a failure has just pushed into
    /// a backoff is therefore not retried inside the same pass, and one that becomes due while the
    /// pass runs waits for the next one.
    /// </remarks>
    public async Task<IReadOnlyList<ArchiveDeliveryPassFailure>> DrainAsync(
        CancellationToken cancellationToken = default)
    {
        var failures = new List<ArchiveDeliveryPassFailure>();

        foreach (ArchiveDeliveryRecord record in _queue.Runnable(_clock()))
        {
            cancellationToken.ThrowIfCancellationRequested();

            try
            {
                await RunAsync(record.ArchiveId, cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (ArchiveDeliveryException exception)
            {
                failures.Add(new ArchiveDeliveryPassFailure(record.ArchiveId, exception.Message));
            }
            catch (Exception)
            {
                // Deliberately everything else. A pass that stops at the first unexpected fault
                // loses every delivery behind it, which is a far worse outcome than one archive
                // waiting for the next pass. The message stays generic because an arbitrary
                // exception is not something to put in front of a user.
                failures.Add(new ArchiveDeliveryPassFailure(
                    record.ArchiveId,
                    "Archive delivery is temporarily unavailable; the local bytes are unchanged."));
            }
        }

        return failures;
    }

    /// <summary>
    /// Attempts one delivery, committing before and after the request.
    /// </summary>
    /// <remarks>
    /// A delivery that is not due — terminal, or waiting out a backoff — is returned unchanged
    /// rather than refused, so a caller may always ask.
    /// </remarks>
    /// <exception cref="ArchiveDeliveryException">
    /// The delivery is unknown, or its state could not be committed.
    /// </exception>
    public async Task<ArchiveDeliveryRecord> RunAsync(
        string archiveId,
        CancellationToken cancellationToken = default)
    {
        ArchiveDeliveryRecord record = _queue.Require(archiveId);
        if (!record.IsRunnable(_clock()))
        {
            return record;
        }

        string packagePath;
        try
        {
            // Fail closed on the local bytes before anything else. A package that is not what the
            // record says it is can never be fixed by trying again, so it stops here; one that is
            // simply absent may come back, so it waits.
            packagePath = _queue.VerifiedPackagePath(archiveId);
        }
        catch (ArchiveDeliveryException exception)
            when (exception.Kind == ArchiveDeliveryErrorKind.PackageChanged)
        {
            return _queue.MarkPermanentFailure(archiveId, DeliveryErrorCodes.LocalIntegrityConflict);
        }
        catch (ArchiveDeliveryException exception)
            when (exception.Kind == ArchiveDeliveryErrorKind.PackageMissing)
        {
            return _queue.MarkRetryable(archiveId, DeliveryErrorCodes.PackageMissing);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            // A package that cannot be read right now — a scanner holding it open, a volume that
            // went away — says nothing about whether the bytes are still correct, so this waits
            // rather than condemning an archive that is probably fine.
            return _queue.MarkRetryable(archiveId, DeliveryErrorCodes.PackageUnreadable);
        }

        // Durable before the request. After this line a crash leaves an in-flight delivery, which is
        // resumable; before it, a crash leaves a pending one, which is also resumable. There is no
        // window in which the queue believes an attempt happened that did not, or forgets one that
        // did.
        ArchiveDeliveryRecord attempting = _queue.BeginAttempt(archiveId);

        ArchiveDeliveryOutcome outcome;
        try
        {
            outcome = await _transport.DeliverAsync(
                new ArchiveDeliveryRequest(
                    attempting.DeliveryId,
                    attempting.ArchiveId,
                    attempting.OriginId,
                    attempting.CaptureIds,
                    attempting.FormatVersion,
                    attempting.Revision,
                    attempting.ContentDigest,
                    attempting.RawSha256,
                    attempting.ByteLength,
                    attempting.Attempt,
                    packagePath),
                cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            // The delivery stays in flight, which is exactly what it is: the request may or may not
            // have reached the far end, and the next pass resumes the same operation.
            throw;
        }
        catch (Exception)
        {
            // An unknown fault says nothing about the package and everything about the moment. The
            // bytes are safe, so this waits rather than stopping.
            return _queue.MarkRetryable(archiveId, DeliveryErrorCodes.DeliveryUnavailable);
        }

        return outcome.Kind switch
        {
            ArchiveDeliveryOutcomeKind.Acknowledged =>
                _queue.Acknowledge(archiveId, outcome.ReceiptId!),
            ArchiveDeliveryOutcomeKind.Retryable =>
                _queue.MarkRetryable(archiveId, outcome.ErrorCode!, outcome.NextAttemptAt),
            ArchiveDeliveryOutcomeKind.Permanent =>
                _queue.MarkPermanentFailure(archiveId, outcome.ErrorCode!),
            _ => throw ArchiveDeliveryException.Conflict(archiveId, "the transport returned no outcome"),
        };
    }
}
