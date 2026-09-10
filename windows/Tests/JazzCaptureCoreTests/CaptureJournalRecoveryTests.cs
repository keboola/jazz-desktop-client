using JazzCaptureCore;
using JazzCaptureCore.Journal;
using System.Text.Json.Nodes;
using System.Text;

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

    [Fact]
    public void InterruptedRecoveryCanBeRetriedWithoutChangingTheJournal()
    {
        CaptureEngine journal = Start();

        CaptureJournalRecoveryResult interrupted = CaptureJournalRecovery.Recover(
            _root,
            () => throw new InvalidOperationException("fixture interruption"));
        Assert.Equal(1, interrupted.NeedsAttention);
        Assert.Equal(JournalLifecycle.Recording, CaptureJournal.Reopen(_root, journal.Identity.ArchiveId).Lifecycle);

        CaptureJournalRecoveryResult retry = CaptureJournalRecovery.Recover(
            _root,
            () => "2026-09-10T12:02:00.000Z");
        Assert.Equal(1, retry.Recovered);
        Assert.Equal(JournalLifecycle.Committed, CaptureJournal.Reopen(_root, journal.Identity.ArchiveId).Lifecycle);
    }

    [Fact]
    public void UnsafeDirectoryNameStaysUntouchedWhileHealthySiblingRecovers()
    {
        CaptureEngine healthy = Start();
        string unsafeDirectory = Path.Combine(_root, CaptureJournal.StateRootName, "not-a-journal");
        Directory.CreateDirectory(unsafeDirectory);
        byte[] marker = new byte[] { 1, 2, 3 };
        File.WriteAllBytes(Path.Combine(unsafeDirectory, "marker"), marker);

        CaptureJournalRecoveryResult result = CaptureJournalRecovery.Recover(
            _root,
            () => "2026-09-10T12:02:00.000Z");

        Assert.Equal(1, result.Recovered);
        Assert.Equal(1, result.NeedsAttention);
        Assert.Equal(marker, File.ReadAllBytes(Path.Combine(unsafeDirectory, "marker")));
        Assert.Equal(JournalLifecycle.Committed, CaptureJournal.Reopen(_root, healthy.Identity.ArchiveId).Lifecycle);
    }

    [Fact]
    public void UnknownLegacyStateStaysByteIdenticalWhileHealthySiblingRecovers()
    {
        CaptureEngine healthy = Start();
        string legacyDirectory = Path.Combine(
            _root, CaptureJournal.StateRootName, "ar-00000000-0000-7000-8000-000000000099");
        Directory.CreateDirectory(legacyDirectory);
        string legacyState = Path.Combine(legacyDirectory, "state.json");
        byte[] source = new UTF8Encoding(false).GetBytes("{\"schemaVersion\":99,\"legacy\":true}");
        File.WriteAllBytes(legacyState, source);

        CaptureJournalRecoveryResult result = CaptureJournalRecovery.Recover(
            _root,
            () => "2026-09-10T12:04:00.000Z");

        Assert.Equal(1, result.Recovered);
        Assert.Equal(1, result.NeedsAttention);
        Assert.Equal(source, File.ReadAllBytes(legacyState));
        Assert.Equal(JournalLifecycle.Committed, CaptureJournal.Reopen(_root, healthy.Identity.ArchiveId).Lifecycle);
    }

    [Fact]
    public void StartPersistsIdentityAndFrozenPolicyBeforeRecoveryCanRun()
    {
        CaptureEngine engine = CaptureEngine.Start(new EngineConfig(
            _root, "fixture-user", "fixture-host", "0.0.0-test", new[] { "fixture-deny" }, false,
            () => DateTimeOffset.UtcNow)
        {
            NarrationEnabled = true,
        });
        string path = Path.Combine(_root, CaptureJournal.StateRootName, engine.Identity.ArchiveId, "state.json");
        JsonObject state = JsonNode.Parse(File.ReadAllText(path))!.AsObject();
        JsonObject policy = state["recoveryPolicy"]!.AsObject();

        Assert.Equal(engine.Identity.ArchiveId, (string?)state["archiveId"]);
        Assert.Equal(engine.Identity.CaptureId, (string?)state["captureId"]);
        Assert.Equal("consent-v1", (string?)policy["policyVersion"]);
        Assert.Contains("narration", policy["modalities"]!.AsArray().Select(node => (string?)node));
        Assert.Contains("fixture-deny", policy["excludedApplications"]!.AsArray().Select(node => (string?)node));
        Assert.Equal(JournalLifecycle.Recording, CaptureJournal.Reopen(_root, engine.Identity.ArchiveId).Lifecycle);
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
