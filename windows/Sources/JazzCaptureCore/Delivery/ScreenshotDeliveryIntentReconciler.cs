using JazzCaptureCore.Journal;

namespace JazzCaptureCore.Delivery;

/// <summary>Local-only startup reconciliation for screenshot handoffs. It never creates a network
/// client or schedules transport work: it merely moves fully verified journal evidence into the
/// already durable spool, then records the journal admission marker.</summary>
public static class ScreenshotDeliveryIntentReconciler
{
    public static ScreenshotDeliveryIntentReconciliationResult Reconcile(
        string captureRoot,
        ArtifactDeliveryQueue queue,
        bool deliverySpoolWasMissing = false)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(captureRoot);
        ArgumentNullException.ThrowIfNull(queue);
        string claims = Path.Combine(captureRoot, CaptureJournal.StateRootName);
        try
        {
            FileAttributes claimsAttributes = File.GetAttributes(claims);
            if ((claimsAttributes & FileAttributes.Directory) == 0
                || (claimsAttributes & FileAttributes.ReparsePoint) != 0)
                return FenceUntrustedQueue(queue, needsAttention: true);
        }
        catch (Exception exception) when (exception is FileNotFoundException
            or DirectoryNotFoundException)
        {
            // Empty first run is harmless; an extant spool record has no journal proof and must
            // never reach transport merely because the claims root disappeared.
            return FenceUntrustedQueue(queue, needsAttention: false);
        }
        catch (Exception exception) when (IsRetryable(exception)) { return new(0, 0, 0, 1, null, true); }
        catch { return new(0, 0, 1); }
        int admitted = 0, skipped = 0, attention = 0, retryable = 0;
        var retryBlocked = new List<ScreenshotReconciliationBlock>();
        var trusted = new HashSet<string>(StringComparer.Ordinal);
        bool globalFence = false;
        string[] claimPaths;
        try { claimPaths = Directory.EnumerateDirectories(claims).ToArray(); }
        catch (Exception exception) when (IsRetryable(exception)) { return new(admitted, skipped, attention, retryable + 1, retryBlocked, true); }
        catch { return new(admitted, skipped, attention + 1, retryable, retryBlocked); }
        foreach (string claim in claimPaths)
        {
            try
            {
                if ((File.GetAttributes(claim) & FileAttributes.ReparsePoint) != 0)
                {
                    attention++;
                    continue;
                }
                CaptureJournal journal = CaptureJournal.Reopen(captureRoot, Path.GetFileName(claim));
                attention += journal.UnreadableScreenshotDeliveryIntentCount;
                foreach (ScreenshotDeliveryIntent intent in journal.ScreenshotDeliveryIntents)
                {
                    try
                    {
                        if (intent.Admitted && !deliverySpoolWasMissing
                            && !queue.HasDurableMetadata(intent.ArtifactId))
                        {
                            // The journal knows only admission, not remote completion. Without
                            // the matching local marker, recreating it could duplicate a prior
                            // successful OTLP post. Preserve the evidence and surface attention.
                            attention++;
                            continue;
                        }
                        // A missing spool root cannot distinguish acknowledged cleanup from lost
                        // durable state. Re-admit the retained canonical journal evidence; Files
                        // lookup makes this an idempotent at-least-once recovery on relaunch.
                        if (!journal.TryMaterializeScreenshotDeliveryIntent(
                                intent,
                                out var evidence,
                                allowAlreadyAdmitted: deliverySpoolWasMissing || intent.Admitted))
                        {
                            // A pending sidecar that cannot yet prove its observation/artifact is
                            // actionable local attention, never a silent completed skip.
                            // A queue record without materializable journal proof must never
                            // reach transport. Fence that one durable identity; healthy siblings
                            // remain independent.
                            try
                            {
                                if (queue.HasDurableMetadata(intent.ArtifactId))
                                {
                                    queue.QuarantineExistingAdmissionConflict(intent.ArtifactId);
                                }
                                attention++;
                            }
                            catch (DirectoryNotFoundException)
                            {
                                // No spool record exists to fence; retain this unverifiable
                                // journal handoff as local attention rather than a transport retry.
                                attention++;
                            }
                            catch (Exception exception) when (IsRetryable(exception))
                            {
                                retryable++;
                                retryBlocked.Add(new(intent.ArchiveId, intent.ArtifactId));
                            }
                            catch { attention++; }
                            continue;
                        }
                        try
                        {
                            ArtifactDeliveryRecord admittedRecord = deliverySpoolWasMissing
                                ? queue.RecoverMissingScreenshotBytes(
                                    evidence!.Descriptor, intent.CanonicalEvent, intent.Context)
                                : queue.EnqueueScreenshot(
                                    evidence!.Descriptor, intent.CanonicalEvent, intent.Context);
                            if (admittedRecord.Quarantined)
                            {
                                attention++;
                                continue;
                            }
                            trusted.Add(ProofKey(admittedRecord));
                        }
                        catch (ArtifactDeliveryAdmissionConflictException)
                        {
                            if (QuarantineConflictingRecord(queue, intent.ArtifactId)) attention++;
                            else { retryable++; retryBlocked.Add(new(intent.ArchiveId, intent.ArtifactId)); }
                            continue;
                        }
                        catch (Exception exception) when (IsRetryable(exception))
                        {
                            retryable++;
                            // Publication may have reached metadata before the local error.
                            // Block this identity until a later reconciliation proves WAL admission.
                            retryBlocked.Add(new(intent.ArchiveId, intent.ArtifactId));
                            continue;
                        }

                        if (intent.Admitted && !deliverySpoolWasMissing)
                        {
                            // Existing marker was revalidated above; never rewrite the journal
                            // admission state merely to repair/check the local spool.
                            skipped++;
                            continue;
                        }

                        try
                        {
                            journal.MarkScreenshotDeliveryIntentAdmitted(intent.ArtifactId);
                            admitted++;
                        }
                        catch
                        {
                            retryable++;
                            retryBlocked.Add(new(intent.ArchiveId, intent.ArtifactId));
                        }
                    }
                    catch (Exception exception) when (IsRetryable(exception))
                    {
                        retryable++; retryBlocked.Add(new(intent.ArchiveId, intent.ArtifactId));
                    }
                    catch { attention++; }
                }
            }
            catch (Exception exception) when (IsRetryable(exception))
            {
                retryable++; globalFence = true;
            }
            catch
            {
                // A corrupt claim is retained untouched and cannot block healthy siblings.
                attention++;
            }
        }
        // A global fence blocks every record, so no local proof-set sweep can safely admit work.
        // Per-record retry blocks remain eligible for the sweep below to fence unrelated records;
        // the loop skips only those exact identities so a transient local failure stays retryable.
        if (globalFence)
        {
            return new(admitted, skipped, attention, retryable, retryBlocked, globalFence);
        }

        // The spool is not a source of capture truth. Every sendable record must have been
        // re-proven against this reconciliation's journal evidence; otherwise a copied/corrupt
        // metadata+bytes pair could bypass the in-memory retry block set after relaunch.
        try
        {
            foreach (ArtifactDeliveryRecord record in queue.PendingExceptArtifactIds(
                retryBlocked.Select(block => block.ArtifactId)))
            {
                if (trusted.Contains(ProofKey(record)))
                {
                    continue;
                }
                try
                {
                    queue.QuarantineExistingAdmissionConflict(record.ArtifactId);
                    attention++;
                }
                catch (Exception exception) when (IsRetryable(exception))
                {
                    retryable++;
                    retryBlocked.Add(new(record.ArchiveId, record.ArtifactId));
                }
                catch { attention++; }
            }
        }
        catch (DirectoryNotFoundException) { }
        catch (Exception exception) when (IsRetryable(exception)) { retryable++; globalFence = true; }
        catch { attention++; globalFence = true; }
        return new(admitted, skipped, attention, retryable, retryBlocked, globalFence);
    }

    private static ScreenshotDeliveryIntentReconciliationResult FenceUntrustedQueue(
        ArtifactDeliveryQueue queue,
        bool needsAttention)
    {
        try
        {
            IReadOnlyList<ArtifactDeliveryRecord> records = queue.Pending();
            if (records.Count == 0) return new(0, 0, needsAttention ? 1 : 0, 0, null, needsAttention);
            foreach (ArtifactDeliveryRecord record in records)
            {
                queue.QuarantineExistingAdmissionConflict(record.ArtifactId);
            }
            return new(0, 0, records.Count + (needsAttention ? 1 : 0), 0, null, true);
        }
        catch (DirectoryNotFoundException)
        {
            return new(0, 0, needsAttention ? 1 : 0, 0, null, needsAttention);
        }
        catch (Exception exception) when (IsRetryable(exception))
        {
            return new(0, 0, needsAttention ? 1 : 0, 1, null, true);
        }
        catch { return new(0, 0, needsAttention ? 1 : 0, 0, null, true); }
    }

    private static string ProofKey(ArtifactDeliveryRecord record) => record.ArchiveId + "\n" + record.ArtifactId;

    private static bool QuarantineConflictingRecord(ArtifactDeliveryQueue queue, string artifactId)
    {
        // A duplicate artifact id with different immutable admission data is not eligible for any
        // delivery path. Keep the journal handoff pending for support repair, but durably fence
        // only the conflicting spool record so healthy siblings can continue.
        try
        {
            queue.QuarantineExistingAdmissionConflict(artifactId); return true;
        }
        catch
        {
            // The original evidence remains retained even if its fence cannot be persisted; this
            // claim remains retry-blocked until a later attempt can persist its fence.
            return false;
        }
    }

    private static bool IsRetryable(Exception exception) =>
        exception is IOException or UnauthorizedAccessException;
}

/// <summary>Sanitized reconciliation counts; no claim name, path, content, or exception escapes.</summary>
public sealed record ScreenshotDeliveryIntentReconciliationResult(
    int Admitted,
    int Skipped,
    int NeedsAttention,
    int Retryable = 0,
    IReadOnlyList<ScreenshotReconciliationBlock>? RetryBlocked = null,
    bool GlobalFence = false);

public sealed record ScreenshotReconciliationBlock(string ArchiveId, string ArtifactId);
