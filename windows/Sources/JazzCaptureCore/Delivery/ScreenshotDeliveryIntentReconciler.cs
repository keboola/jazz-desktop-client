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
                return new(0, 0, 1);
        }
        catch (Exception exception) when (exception is FileNotFoundException
            or DirectoryNotFoundException) { return new(0, 0, 0); }
        catch (Exception exception) when (IsRetryable(exception)) { return new(0, 0, 0, 1, null, true); }
        catch { return new(0, 0, 1); }
        int admitted = 0, skipped = 0, attention = 0, retryable = 0;
        var retryBlocked = new List<ScreenshotReconciliationBlock>();
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
                            attention++;
                            continue;
                        }
                        try
                        {
                            ArtifactDeliveryRecord admittedRecord = queue.EnqueueScreenshot(
                                evidence!.Descriptor, intent.CanonicalEvent, intent.Context);
                            if (admittedRecord.Quarantined)
                            {
                                attention++;
                                continue;
                            }
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
        return new(admitted, skipped, attention, retryable, retryBlocked, globalFence);
    }

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
