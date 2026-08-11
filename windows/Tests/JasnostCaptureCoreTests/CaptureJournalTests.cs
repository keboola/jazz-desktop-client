using System.Text;
using System.Text.Json.Nodes;
using JasnostCaptureCore;
using JasnostCaptureCore.Journal;
using JasnostCaptureCore.Json;

namespace JasnostCaptureCoreTests;

/// <summary>
/// Crash-safety contract of <see cref="CaptureJournal"/> (ANNEX-ARCHIVE section 5).
/// A "crash" is simulated by abandoning a journal instance and constructing a new one from the
/// same on-disk root: nothing but the checkpoint plus the write-ahead log may survive.
/// </summary>
public sealed class CaptureJournalTests : IDisposable
{
    private const string ArchiveId = "ar-00000000-0000-7000-8000-00000000a001";
    private const string CaptureId = "cap-00000000-0000-7000-8000-00000000a003";
    private const string StreamId = "stream-00000000-0000-7000-8000-00000000a004";
    private const string SessionId = "s-00000000-0000-7000-8000-00000000a009";
    private const string EndedAt = "2026-07-22T08:01:00Z";

    private readonly string _root;

    public CaptureJournalTests()
    {
        _root = Path.Combine(Path.GetTempPath(), "jasnost-capture-journal-tests", Identifiers.UuidV7());
        Directory.CreateDirectory(_root);
    }

    public void Dispose()
    {
        try
        {
            Directory.Delete(_root, recursive: true);
        }
        catch (IOException)
        {
            // Test scratch space only; a locked file must not fail the suite.
        }
    }

    [Fact]
    public void ReserveAssignsContiguousSequencesFromZero()
    {
        CaptureJournal journal = StartRecordingJournal();

        ReservationToken first = journal.Reserve();
        ReservationToken second = journal.Reserve();
        ReservationToken third = journal.Reserve();

        Assert.Equal(new long[] { 0, 1, 2 }, new[] { first.StreamSequence, second.StreamSequence, third.StreamSequence });
        Assert.All(
            new[] { first, second, third },
            token =>
            {
                Assert.Equal(ArchiveId, token.ArchiveId);
                Assert.Equal(CaptureId, token.CaptureId);
                Assert.Equal(StreamId, token.StreamId);
                Assert.StartsWith("res-", token.ReservationId, StringComparison.Ordinal);
            });
        Assert.Equal(3, new HashSet<string>(new[] { first, second, third }.Select(t => t.ReservationId)).Count);
    }

    [Fact]
    public void ReserveIsDurableBeforeItReturns()
    {
        CaptureJournal journal = StartRecordingJournal();
        journal.Reserve();

        CaptureJournal reopened = CaptureJournal.Reopen(_root, ArchiveId);

        Assert.Equal(1, reopened.PendingReservationCount);
        Assert.Equal(JournalLifecycle.Recording, reopened.Lifecycle);
    }

    [Fact]
    public void ResolvedObservationSurvivesReopenWithMatchingDigest()
    {
        CaptureJournal journal = StartRecordingJournal();
        ReservationToken token = journal.Reserve();
        JsonObject record = Record(0);
        journal.ResolveObservation(token, record);

        CaptureJournal reopened = CaptureJournal.Reopen(_root, ArchiveId);
        reopened.CloseInput();
        reopened.BeginDraining();
        CommitResult result = reopened.Commit(EndedAt);

        JsonObject retained = Assert.Single(result.Records);
        Assert.Equal(JsonCanonicalizer.Sha256Hex(record), JsonCanonicalizer.Sha256Hex(retained));
        Assert.Empty(result.Gaps);
        StreamSummary summary = Assert.Single(result.StreamSummaries);
        Assert.Equal(new StreamSummary(StreamId, 0, 0, 1), summary);
        Assert.Equal(EndedAt, result.EndedAt);
        Assert.Equal(JournalSessionStatus.Closed, result.Status);
    }

    [Fact]
    public void RecoverInterruptedConvertsPendingReservationsToRecoveryTruncationGaps()
    {
        CaptureJournal journal = StartRecordingJournal();
        ReservationToken first = journal.Reserve();
        journal.Reserve();
        ReservationToken third = journal.Reserve();
        journal.ResolveObservation(first, Record(0));
        journal.ResolveObservation(third, Record(2));

        // Crash: the process dies with sequence 1 reserved but never resolved.
        CaptureJournal reopened = CaptureJournal.Reopen(_root, ArchiveId);
        CommitResult result = reopened.RecoverInterrupted(EndedAt);

        GapEntry gap = Assert.Single(result.Gaps);
        Assert.Equal(
            new GapEntry(StreamId, 1, 1, GapReasons.RecoveryTruncation, "producer did not finish before process termination"),
            gap);
        Assert.Equal(new StreamSummary(StreamId, 0, 2, 2), Assert.Single(result.StreamSummaries));
        Assert.Equal(2, result.Records.Count);
        Assert.Equal(JournalSessionStatus.Recovered, result.Status);
        Assert.Equal(JournalLifecycle.Committed, reopened.Lifecycle);
    }

    [Fact]
    public void PrepareTwiceOnTheSameArchiveIdThrows()
    {
        StartRecordingJournal();

        CaptureJournalException error = Assert.Throws<CaptureJournalException>(
            () => CaptureJournal.Prepare(_root, ArchiveId, CaptureId, StreamId));

        Assert.Equal(JournalErrorKind.ArchiveAlreadyClaimed, error.Kind);
    }

    [Fact]
    public void ResolveObservationIsIdempotentForTheSameDigestAndConflictsOnADifferentOne()
    {
        CaptureJournal journal = StartRecordingJournal();
        ReservationToken token = journal.Reserve();
        journal.ResolveObservation(token, Record(0));

        journal.ResolveObservation(token, Record(0));

        CaptureJournalException error = Assert.Throws<CaptureJournalException>(
            () => journal.ResolveObservation(token, Record(0, eventType: "click")));
        Assert.Equal(JournalErrorKind.CompletionConflict, error.Kind);

        journal.CloseInput();
        journal.BeginDraining();
        Assert.Single(journal.Commit(EndedAt).Records);
    }

    [Fact]
    public void CommitRefusesPendingReservations()
    {
        CaptureJournal journal = StartRecordingJournal();
        ReservationToken resolved = journal.Reserve();
        journal.ResolveObservation(resolved, Record(0));
        journal.Reserve();
        journal.CloseInput();
        journal.BeginDraining();

        CaptureJournalException error = Assert.Throws<CaptureJournalException>(() => journal.Commit(EndedAt));

        Assert.Equal(JournalErrorKind.PendingWork, error.Kind);
    }

    [Fact]
    public void CommitRefusesAStreamWithoutAnyObservation()
    {
        CaptureJournal journal = StartRecordingJournal();
        ReservationToken token = journal.Reserve();
        journal.ResolveGap(token, GapReasons.CaptureLoss, "hook detached");
        journal.CloseInput();
        journal.BeginDraining();

        CaptureJournalException error = Assert.Throws<CaptureJournalException>(() => journal.Commit(EndedAt));

        Assert.Equal(JournalErrorKind.StreamHasNoObservation, error.Kind);
    }

    [Fact]
    public void WalReplayFromCheckpointReproducesTheDirectCommit()
    {
        CommitResult direct = RunScenario(_root, replayBeforeCommit: false);

        string replayRoot = Path.Combine(_root, "replay");
        Directory.CreateDirectory(replayRoot);
        CommitResult replayed = RunScenario(replayRoot, replayBeforeCommit: true);

        Assert.Equal(
            direct.Records.Select(JsonCanonicalizer.Sha256Hex).ToArray(),
            replayed.Records.Select(JsonCanonicalizer.Sha256Hex).ToArray());
        Assert.Equal(direct.Gaps, replayed.Gaps);
        Assert.Equal(direct.StreamSummaries, replayed.StreamSummaries);
        Assert.Equal(direct.EndedAt, replayed.EndedAt);
    }

    [Fact]
    public void AdjacentGapsAreCoalescedOnlyWhenReasonAndDetailMatch()
    {
        CaptureJournal journal = StartRecordingJournal();
        ReservationToken zero = journal.Reserve();
        ReservationToken one = journal.Reserve();
        ReservationToken two = journal.Reserve();
        ReservationToken three = journal.Reserve();
        ReservationToken four = journal.Reserve();
        journal.ResolveObservation(zero, Record(0));
        journal.ResolveGap(one, GapReasons.BufferOverflow, "queue full");
        journal.ResolveGap(two, GapReasons.BufferOverflow, "queue full");
        journal.ResolveGap(three, GapReasons.BufferOverflow, "hook stalled");
        journal.ResolveObservation(four, Record(4));
        journal.CloseInput();
        journal.BeginDraining();

        CommitResult result = journal.Commit(EndedAt);

        Assert.Equal(
            new[]
            {
                new GapEntry(StreamId, 1, 2, GapReasons.BufferOverflow, "queue full"),
                new GapEntry(StreamId, 3, 3, GapReasons.BufferOverflow, "hook stalled"),
            },
            result.Gaps);
        Assert.Equal(new StreamSummary(StreamId, 0, 4, 2), Assert.Single(result.StreamSummaries));
    }

    [Fact]
    public void RecordsAreOrderedByStreamSequenceEvenWhenResolvedOutOfOrder()
    {
        CaptureJournal journal = StartRecordingJournal();
        ReservationToken zero = journal.Reserve();
        ReservationToken one = journal.Reserve();
        ReservationToken two = journal.Reserve();
        journal.ResolveObservation(two, Record(2));
        journal.ResolveObservation(zero, Record(0));
        journal.ResolveObservation(one, Record(1));
        journal.CloseInput();
        journal.BeginDraining();

        CommitResult result = journal.Commit(EndedAt);

        Assert.Equal(
            new long[] { 0, 1, 2 },
            result.Records.Select(record => (long)record["streamSequence"]!.GetValue<long>()).ToArray());
    }

    [Fact]
    public void LifecycleGatesRejectOutOfOrderTransitions()
    {
        CaptureJournal journal = CaptureJournal.Prepare(_root, ArchiveId, CaptureId, StreamId);
        Assert.Equal(JournalLifecycle.Starting, journal.Lifecycle);
        Assert.Equal(JournalErrorKind.InvalidTransition, Assert.Throws<CaptureJournalException>(() => journal.Reserve()).Kind);
        Assert.Equal(JournalErrorKind.InvalidTransition, Assert.Throws<CaptureJournalException>(() => journal.BeginDraining()).Kind);

        journal.StartRecording();
        ReservationToken token = journal.Reserve();
        journal.ResolveObservation(token, Record(0));
        Assert.Equal(JournalErrorKind.InvalidTransition, Assert.Throws<CaptureJournalException>(() => journal.Commit(EndedAt)).Kind);

        journal.CloseInput();
        Assert.Equal(JournalErrorKind.InvalidTransition, Assert.Throws<CaptureJournalException>(() => journal.Reserve()).Kind);

        journal.BeginDraining();
        journal.Commit(EndedAt);
        Assert.Equal(JournalLifecycle.Committed, journal.Lifecycle);
        Assert.Equal(JournalErrorKind.InvalidTransition, Assert.Throws<CaptureJournalException>(() => journal.Commit(EndedAt)).Kind);
    }

    [Fact]
    public void TokenFromAnotherArchiveIsRejected()
    {
        CaptureJournal journal = StartRecordingJournal();
        ReservationToken token = journal.Reserve();
        var foreign = token with { ArchiveId = "ar-00000000-0000-7000-8000-0000000000ff" };

        CaptureJournalException error = Assert.Throws<CaptureJournalException>(
            () => journal.ResolveObservation(foreign, Record(0)));

        Assert.Equal(JournalErrorKind.StaleReservation, error.Kind);
    }

    [Fact]
    public void ReopenRejectsATamperedRecordDigest()
    {
        CaptureJournal journal = StartRecordingJournal();
        ReservationToken token = journal.Reserve();
        journal.ResolveObservation(token, Record(0));

        string walFile = Directory.GetFiles(Path.Combine(_root, ".capture-journal", ArchiveId, "wal"), "*.json")
            .OrderBy(path => path, StringComparer.Ordinal)
            .Last();
        string tampered = File.ReadAllText(walFile).Replace("session_start", "session_end", StringComparison.Ordinal);
        File.WriteAllText(walFile, tampered, new UTF8Encoding(false));

        CaptureJournalException error = Assert.Throws<CaptureJournalException>(() => CaptureJournal.Reopen(_root, ArchiveId));

        Assert.Equal(JournalErrorKind.CorruptState, error.Kind);
    }

    [Fact]
    public void ReopenRejectsANonContiguousWal()
    {
        CaptureJournal journal = StartRecordingJournal();
        journal.Reserve();
        journal.Reserve();

        string walDirectory = Path.Combine(_root, ".capture-journal", ArchiveId, "wal");
        string[] segments = Directory.GetFiles(walDirectory, "*.json").OrderBy(path => path, StringComparer.Ordinal).ToArray();
        File.Delete(segments[0]);

        CaptureJournalException error = Assert.Throws<CaptureJournalException>(() => CaptureJournal.Reopen(_root, ArchiveId));

        Assert.Equal(JournalErrorKind.CorruptState, error.Kind);
    }

    [Fact]
    public void ReopenOfAnUnknownArchiveThrows()
    {
        CaptureJournalException error = Assert.Throws<CaptureJournalException>(
            () => CaptureJournal.Reopen(_root, ArchiveId));

        Assert.Equal(JournalErrorKind.StateNotFound, error.Kind);
    }

    [Fact]
    public void PrepareRejectsIdentifiersThatAreNotSafeDirectoryNames()
    {
        Assert.Throws<ArgumentException>(() => CaptureJournal.Prepare(_root, "../escape", CaptureId, StreamId));
        Assert.Throws<ArgumentException>(() => CaptureJournal.Prepare(_root, "..", CaptureId, StreamId));
        Assert.Throws<ArgumentException>(() => CaptureJournal.Prepare(_root, "ar-1/nested", CaptureId, StreamId));
        Assert.Throws<ArgumentException>(() => CaptureJournal.Prepare(_root, ArchiveId, CaptureId, string.Empty));
    }

    [Fact]
    public void ResolveGapRejectsAnUnknownReason()
    {
        CaptureJournal journal = StartRecordingJournal();
        ReservationToken token = journal.Reserve();

        Assert.Throws<ArgumentException>(() => journal.ResolveGap(token, "made_up_reason", detail: null));
    }

    [Fact]
    public void WriteAtomicPublishesBytesWithoutOverwritingAndLeavesNoTemporaryFiles()
    {
        string target = Path.Combine(_root, "atomic.json");
        byte[] payload = new UTF8Encoding(false).GetBytes("{\"a\":1}");

        Durability.WriteAtomic(target, payload);

        Assert.Equal(payload, File.ReadAllBytes(target));
        Assert.Throws<IOException>(() => Durability.WriteAtomic(target, payload));
        Assert.Empty(Directory.GetFiles(_root, "*" + Durability.TemporaryFileSuffix));

        byte[] replacement = new UTF8Encoding(false).GetBytes("{\"a\":2}");
        Durability.ReplaceAtomic(target, replacement);
        Assert.Equal(replacement, File.ReadAllBytes(target));
        Assert.Empty(Directory.GetFiles(_root, "*" + Durability.TemporaryFileSuffix));
    }

    private CaptureJournal StartRecordingJournal()
    {
        CaptureJournal journal = CaptureJournal.Prepare(_root, ArchiveId, CaptureId, StreamId);
        journal.StartRecording();
        return journal;
    }

    /// <summary>
    /// Four reservations — two observations, one declared gap, one observation — committed either
    /// directly or after a simulated crash that forces a full checkpoint plus WAL replay.
    /// </summary>
    private static CommitResult RunScenario(string root, bool replayBeforeCommit)
    {
        CaptureJournal journal = CaptureJournal.Prepare(root, ArchiveId, CaptureId, StreamId);
        journal.StartRecording();
        ReservationToken zero = journal.Reserve();
        ReservationToken one = journal.Reserve();
        ReservationToken two = journal.Reserve();
        ReservationToken three = journal.Reserve();
        journal.ResolveObservation(zero, Record(0));
        journal.ResolveObservation(one, Record(1, eventType: "click"));
        journal.ResolveGap(two, GapReasons.SourceUnavailable, "accessibility timeout");
        journal.ResolveObservation(three, Record(3, eventType: "keydown"));
        journal.CloseInput();
        journal.BeginDraining();

        CaptureJournal committer = replayBeforeCommit ? CaptureJournal.Reopen(root, ArchiveId) : journal;
        return committer.Commit(EndedAt);
    }

    private static JsonObject Record(long streamSequence, string eventType = "session_start") =>
        new()
        {
            ["schemaVersion"] = 1,
            ["observationId"] = "obs-00000000-0000-7000-8000-" + streamSequence.ToString("000000000000"),
            ["recordType"] = "jazz.activity-event",
            ["captureId"] = CaptureId,
            ["streamId"] = StreamId,
            ["streamSequence"] = streamSequence,
            ["capturedAt"] = "2026-07-22T08:00:00Z",
            ["payload"] = new JsonObject
            {
                ["sessionId"] = SessionId,
                ["eventId"] = Identifiers.EventId(SessionId, streamSequence),
                ["timestamp"] = "2026-07-22T08:00:00Z",
                ["eventType"] = eventType,
                ["url"] = "app://session",
            },
        };
}
