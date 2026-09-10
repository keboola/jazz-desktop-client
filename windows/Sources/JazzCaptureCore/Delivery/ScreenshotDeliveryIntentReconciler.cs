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
        int admitted = 0, skipped = 0, attention = 0;
        string[] claimPaths;
        try { claimPaths = Directory.EnumerateDirectories(claims).ToArray(); }
        catch { return new(admitted, skipped, attention + 1); }
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
                        queue.EnqueueScreenshot(evidence!.Descriptor, intent.CanonicalEvent, intent.Context);
                        journal.MarkScreenshotDeliveryIntentAdmitted(intent.ArtifactId);
                        admitted++;
                    }
                    catch { attention++; }
                }
            }
            catch
            {
                // A corrupt claim is retained untouched and cannot block healthy siblings.
                attention++;
            }
        }
        return new(admitted, skipped, attention);
    }
}

/// <summary>Sanitized reconciliation counts; no claim name, path, content, or exception escapes.</summary>
public sealed record ScreenshotDeliveryIntentReconciliationResult(
    int Admitted,
    int Skipped,
    int NeedsAttention);
