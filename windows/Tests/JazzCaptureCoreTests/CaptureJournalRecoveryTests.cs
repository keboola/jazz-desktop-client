using JazzCaptureCore;
using JazzCaptureCore.Journal;

namespace JazzCaptureCoreTests;

public sealed class CaptureJournalRecoveryTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "jazz-recovery-" + Guid.NewGuid().ToString("N"));

    [Fact]
    public void RecoversEachInterruptedSiblingWithoutCreatingDeliveryState()
    {
        CaptureEngine interrupted = Start();
        CaptureEngine committed = Start();
        committed.Stop();

        CaptureJournalRecoveryResult result = CaptureJournalRecovery.Recover(
            _root,
            () => "2026-09-10T12:01:00.000Z");

        Assert.Equal(1, result.Recovered);
        Assert.Equal(1, result.AlreadyCommitted);
        Assert.Equal(0, result.NeedsAttention);
        Assert.Equal(JournalLifecycle.Committed, CaptureJournal.Reopen(_root, interrupted.Identity.ArchiveId).Lifecycle);
        Assert.False(Directory.Exists(Path.Combine(_root, "queue")));
        Assert.False(Directory.Exists(Path.Combine(_root, "archives")));
    }

    [Fact]
    public void LeavesCorruptSiblingByteIdenticalWhileRecoveringHealthyJournal()
    {
        CaptureEngine healthy = Start();
        CaptureEngine corrupt = Start();
        string state = Path.Combine(_root, CaptureJournal.StateRootName, corrupt.Identity.ArchiveId, "state.json");
        File.WriteAllText(state, "not a journal");
        byte[] before = File.ReadAllBytes(state);

        CaptureJournalRecoveryResult result = CaptureJournalRecovery.Recover(
            _root,
            () => "2026-09-10T12:01:00.000Z");

        Assert.Equal(1, result.Recovered);
        Assert.Equal(1, result.NeedsAttention);
        Assert.Equal(before, File.ReadAllBytes(state));
        Assert.Equal(JournalLifecycle.Committed, CaptureJournal.Reopen(_root, healthy.Identity.ArchiveId).Lifecycle);
    }

    [Fact]
    public void RepeatingRecoveryDoesNotDuplicateTheCommit()
    {
        CaptureEngine journal = Start();
        CaptureJournalRecovery.Recover(_root, () => "2026-09-10T12:01:00.000Z");
        string state = Path.Combine(_root, CaptureJournal.StateRootName, journal.Identity.ArchiveId, "state.json");
        byte[] first = File.ReadAllBytes(state);

        CaptureJournalRecoveryResult second = CaptureJournalRecovery.Recover(
            _root,
            () => "2026-09-10T12:02:00.000Z");

        Assert.Equal(0, second.Recovered);
        Assert.Equal(1, second.AlreadyCommitted);
        Assert.Equal(first, File.ReadAllBytes(state));
    }

    private CaptureEngine Start()
    {
        return CaptureEngine.Start(new EngineConfig(
            _root,
            "fixture-user",
            "fixture-host",
            "0.0.0-test",
            Array.Empty<string>(),
            false,
            () => DateTimeOffset.UtcNow));
    }

    public void Dispose()
    {
        if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true);
    }
}
