using System.Security.Cryptography;
using System.Text;
using JazzCaptureCore;
using JazzCaptureCore.Delivery;
using JazzCaptureCore.Journal;

namespace JazzCaptureCoreTests;

public sealed class ScreenshotDeliveryIntentTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), "jazz-intents-" + Guid.NewGuid().ToString("N"));

    [Fact]
    public void PendingIntentSurvivesRelaunchAndAdmissionMarker()
    {
        CaptureJournal journal = Journal();
        ScreenshotDeliveryIntent intent = Intent();
        journal.PersistScreenshotDeliveryIntent(intent);

        CaptureJournal reopened = CaptureJournal.Reopen(root, intent.ArchiveId);
        ScreenshotDeliveryIntent pending = Assert.Single(reopened.ScreenshotDeliveryIntents);
        Assert.False(pending.Admitted);
        Assert.Equal(intent, pending);

        reopened.MarkScreenshotDeliveryIntentAdmitted(intent.ArtifactId);
        Assert.True(Assert.Single(CaptureJournal.Reopen(root, intent.ArchiveId)
            .ScreenshotDeliveryIntents).Admitted);
    }

    [Fact]
    public void ConflictingReplayFailsClosedWithoutReplacingIntent()
    {
        CaptureJournal journal = Journal();
        ScreenshotDeliveryIntent intent = Intent();
        journal.PersistScreenshotDeliveryIntent(intent);

        Assert.Throws<InvalidOperationException>(() => journal.PersistScreenshotDeliveryIntent(
            intent with { ObservationId = "other-observation" }));
        Assert.Equal(intent, Assert.Single(journal.ScreenshotDeliveryIntents));
    }

    [Fact]
    public void CorruptSidecarIsRetainedAndIsolated()
    {
        ScreenshotDeliveryIntent intent = Intent();
        CaptureJournal journal = Journal();
        string directory = Path.Combine(root, CaptureJournal.StateRootName, intent.ArchiveId,
            "screenshot-delivery-intents");
        Directory.CreateDirectory(directory);
        string corrupt = Path.Combine(directory, "unknown.json");
        byte[] bytes = Encoding.UTF8.GetBytes("not-json");
        File.WriteAllBytes(corrupt, bytes);

        journal.PersistScreenshotDeliveryIntent(intent);

        Assert.Equal(1, journal.UnreadableScreenshotDeliveryIntentCount);
        Assert.Single(journal.ScreenshotDeliveryIntents);
        Assert.Equal(bytes, File.ReadAllBytes(corrupt));
    }

    private CaptureJournal Journal() => CaptureJournal.Prepare(root, "ar-1", "cap-1", "stream-1");

    private static ScreenshotDeliveryIntent Intent()
    {
        byte[] bytes = [1, 2];
        var descriptor = new ArtifactDeliveryDescriptor("ar-1", "cap-1", "art-1", "art-1",
            "image/jpeg", Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant(), 2, bytes);
        var activity = new ActivityEvent { SessionId = "session-1", EventId = "event-1", Timestamp = "2026-01-01T00:00:00.000Z", EventType = "click", Url = "app://x" };
        var context = new SessionContext("session-1", new string('a', 32), new string('b', 16), activity.Timestamp, null, "user", "host", null, null);
        return ScreenshotDeliveryIntent.Create(descriptor, "obs-1", activity, context);
    }

    public void Dispose() { if (Directory.Exists(root)) Directory.Delete(root, true); }
}
