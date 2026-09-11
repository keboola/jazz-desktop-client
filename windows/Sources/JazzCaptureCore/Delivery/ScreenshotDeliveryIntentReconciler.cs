using JazzCaptureCore.Journal;

namespace JazzCaptureCore.Delivery;

/// <summary>Local-only startup reconciliation for screenshot handoffs. It never creates a network
/// client or schedules transport work: it merely moves fully verified journal evidence into the
/// already durable spool, then records the journal admission marker.</summary>
public static class ScreenshotDeliveryIntentReconciler
{
    public static ScreenshotDeliveryIntentReconciliationResult Reconcile(
        string captureRoot,
        ArtifactDeliveryQueue queue)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(captureRoot);
        ArgumentNullException.ThrowIfNull(queue);
        string claims = Path.Combine(captureRoot, CaptureJournal.StateRootName);
        if (!Directory.Exists(claims)) return new(0, 0, 0);
        try
        {
            if ((File.GetAttributes(claims) & FileAttributes.ReparsePoint) != 0)
                return new(0, 0, 1);
        }
        catch { return new(0, 0, 1); }
        int admitted = 0, skipped = 0, attention = 0, retryable = 0;
        var retryBlocked = new List<ScreenshotReconciliationBlock>();
        string[] claimPaths;
        try { claimPaths = Directory.EnumerateDirectories(claims).ToArray(); }
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
                        if (intent.Admitted) { skipped++; continue; }
                        if (!journal.TryMaterializeScreenshotDeliveryIntent(intent, out var evidence))
                        {
                            // A pending sidecar that cannot yet prove its observation/artifact is
                            // actionable local attention, never a silent completed skip.
                            attention++;
                            continue;
                        }
                        try
                        {
                            queue.EnqueueScreenshot(evidence!.Descriptor, intent.CanonicalEvent, intent.Context);
                        }
                        catch (ArtifactDeliveryAdmissionConflictException)
                        {
                            QuarantineConflictingRecord(queue, intent.ArtifactId);
                            attention++;
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
                    catch (Exception exception) when (IsRetryable(exception)) { retryable++; }
                    catch { attention++; }
                }
            }
            catch (Exception exception) when (IsRetryable(exception))
            {
                retryable++;
            }
            catch
            {
                // A corrupt claim is retained untouched and cannot block healthy siblings.
                attention++;
            }
        }
        return new(admitted, skipped, attention, retryable, retryBlocked);
    }

    private static void QuarantineConflictingRecord(ArtifactDeliveryQueue queue, string artifactId)
    {
        // A duplicate artifact id with different immutable admission data is not eligible for any
        // delivery path. Keep the journal handoff pending for support repair, but durably fence
        // only the conflicting spool record so healthy siblings can continue.
        try
        {
            queue.QuarantineExistingAdmissionConflict(artifactId);
        }
        catch
        {
            // The original evidence remains retained even if its fence cannot be persisted; this
            // claim still contributes sanitized attention.
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
    IReadOnlyList<ScreenshotReconciliationBlock>? RetryBlocked = null);

public sealed record ScreenshotReconciliationBlock(string ArchiveId, string ArtifactId);
