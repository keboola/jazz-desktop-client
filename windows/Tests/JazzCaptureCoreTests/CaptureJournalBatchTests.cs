using System.Text;
using System.Text.Json.Nodes;
using JazzCaptureCore;
using JazzCaptureCore.Journal;
using JazzCaptureCore.Json;

namespace JazzCaptureCoreTests;

/// <summary>
/// The journal writes its write-ahead log at most once per second (ANNEX-ARCHIVE section 5): the
/// flush timer, the other flush triggers, and recovery after a crash that loses the buffer. A crash
/// is simulated by abandoning a journal instance and reopening the same root; time moves only when
/// a test advances a <see cref="ManualTimeProvider"/>.
/// </summary>
public sealed class CaptureJournalBatchTests : IDisposable
{
    private const string ArchiveId = "ar-00000000-0000-7000-8000-00000000c001";
    private const string CaptureId = "cap-00000000-0000-7000-8000-00000000c003";
    private const string StreamId = "stream-00000000-0000-7000-8000-00000000c004";
    private const string SessionId = "s-00000000-0000-7000-8000-00000000c009";
    private const string EndedAt = "2026-11-23T08:01:00Z";

    private static readonly TimeSpan Interval = TimeSpan.FromSeconds(1);
    private static readonly UTF8Encoding Utf8NoBom = new(encoderShouldEmitUTF8Identifier: false);

    private readonly string _root;
    private readonly string _stateDirectory;
    private readonly string _walDirectory;
    private readonly ManualTimeProvider _time = new();

    public CaptureJournalBatchTests()
    {
        _root = Path.Combine(Path.GetTempPath(), "jazz-capture-journal-batch-tests", Identifiers.UuidV7());
        _stateDirectory = Path.Combine(_root, CaptureJournal.StateRootName, ArchiveId);
        _walDirectory = Path.Combine(_stateDirectory, "wal");
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
    public void DefaultOptionsFlushAtMostOncePerSecond()
    {
        var options = new JournalOptions();

        Assert.Equal(TimeSpan.FromSeconds(1), options.FlushInterval);
        Assert.Equal(1024 * 1024, options.MaxBufferedBytes);
    }

    [Fact]
    public void ChangesStayInMemoryUntilTheIntervalPassesAndThenReachDiskAsOneFile()
    {
        CaptureJournal journal = StartRecordingJournal();

        RecordEventWithoutFlush(journal, 0);

        Assert.Empty(WalFileNames());

        _time.Advance(Interval - TimeSpan.FromMilliseconds(1));
        Assert.Empty(WalFileNames());

        _time.Advance(TimeSpan.FromMilliseconds(1));
        Assert.Equal(new[] { Name(0, 2) }, WalFileNames());
        Assert.Equal(0, _time.ArmedTimers);

        CaptureJournal reopened = CaptureJournal.Reopen(_root, ArchiveId);
        Assert.Equal(0, reopened.PendingReservationCount);
    }

    [Fact]
    public void ManyChangesInsideOneIntervalAreOneFileWithOneTimer()
    {
        CaptureJournal journal = StartRecordingJournal();

        for (int sequence = 0; sequence < 50; sequence++)
        {
            RecordEventWithoutFlush(journal, sequence);
        }

        Assert.Equal(1, _time.ArmedTimers);
        Assert.Empty(WalFileNames());

        _time.Advance(Interval);

        Assert.Equal(new[] { Name(0, 149) }, WalFileNames());
    }

    [Fact]
    public void TheIntervalRunsFromTheFirstBufferedChangeAndTwoTimedWritesAreAnIntervalApart()
    {
        CaptureJournal journal = StartRecordingJournal();

        RecordEventWithoutFlush(journal, 0);
        _time.Advance(TimeSpan.FromMilliseconds(600));
        RecordEventWithoutFlush(journal, 1);
        _time.Advance(TimeSpan.FromMilliseconds(400));

        // Both events were written by the timer that the first one started.
        Assert.Equal(new[] { Name(0, 5) }, WalFileNames());

        RecordEventWithoutFlush(journal, 2);
        _time.Advance(TimeSpan.FromMilliseconds(999));
        Assert.Equal(new[] { Name(0, 5) }, WalFileNames());

        _time.Advance(TimeSpan.FromMilliseconds(1));
        Assert.Equal(new[] { Name(0, 5), Name(6, 8) }, WalFileNames());
    }

    [Fact]
    public void NothingIsWrittenAndNoTimerRunsWhenNothingChanged()
    {
        CaptureJournal journal = StartRecordingJournal();

        journal.Flush();
        _time.Advance(TimeSpan.FromMinutes(5));

        Assert.Empty(WalFileNames());
        Assert.Equal(0, _time.ArmedTimers);
    }

    [Fact]
    public void FlushWritesTheBufferAtOnceAndCancelsThePendingTimer()
    {
        CaptureJournal journal = StartRecordingJournal();
        RecordEventWithoutFlush(journal, 0);
        Assert.Equal(1, _time.ArmedTimers);

        journal.Flush();

        Assert.Equal(new[] { Name(0, 2) }, WalFileNames());
        Assert.Equal(0, _time.ArmedTimers);
    }

    [Fact]
    public void ABufferThatReachesTheSizeLimitIsWrittenWithoutWaitingForTheTimer()
    {
        CaptureJournal journal = CaptureJournal.Prepare(
            _root,
            ArchiveId,
            CaptureId,
            StreamId,
            options: new JournalOptions { TimeProvider = _time, MaxBufferedBytes = 1 });
        journal.StartRecording();

        journal.Reserve();

        Assert.Equal(new[] { Name(0, 0) }, WalFileNames());
        Assert.Equal(0, _time.ArmedTimers);
    }

    [Fact]
    public void ABufferBelowTheSizeLimitIsNotWrittenEarly()
    {
        CaptureJournal journal = StartRecordingJournal();

        for (int sequence = 0; sequence < 20; sequence++)
        {
            RecordEventWithoutFlush(journal, sequence);
        }

        Assert.Empty(WalFileNames());
    }

    [Fact]
    public void LifecycleTransitionsWriteTheBufferBeforeTheyReturn()
    {
        CaptureJournal journal = StartRecordingJournal();
        RecordEventWithoutFlush(journal, 0);

        journal.CloseInput();

        Assert.Equal(new[] { Name(0, 3) }, WalFileNames());
        Assert.Equal(JournalLifecycle.ClosingInput, CaptureJournal.Reopen(_root, ArchiveId).Lifecycle);
    }

    [Fact]
    public void BeginDrainingWritesTheBufferBeforeItReturns()
    {
        CaptureJournal journal = StartRecordingJournal();
        RecordEventWithoutFlush(journal, 0);
        journal.CloseInput();

        journal.BeginDraining();

        Assert.Equal(new[] { Name(0, 3), Name(4, 4) }, WalFileNames());
    }

    [Fact]
    public void CommitLeavesNoLogFileAndDropsTheTimer()
    {
        CaptureJournal journal = StartRecordingJournal();
        RecordEventWithoutFlush(journal, 0);
        journal.CloseInput();
        journal.BeginDraining();

        CommitResult result = journal.Commit(EndedAt);

        Assert.Single(result.Records);
        Assert.Empty(WalFileNames());
        Assert.Equal(0, _time.ArmedTimers);
        _time.Advance(Interval);
        Assert.Empty(WalFileNames());
    }

    [Fact]
    public void CrashBeforeTheFlushLosesOnlyTheBufferedChanges()
    {
        CaptureJournal journal = StartRecordingJournal();
        RecordEventWithoutFlush(journal, 0);
        journal.Flush();
        RecordEventWithoutFlush(journal, 1);

        // Kill: event 1 was still in memory.
        CaptureJournal reopened = CaptureJournal.Reopen(_root, ArchiveId);
        CommitResult result = reopened.RecoverInterrupted(EndedAt);

        Assert.Equal(JournalSessionStatus.Recovered, result.Status);
        Assert.Equal(new StreamSummary(StreamId, 0, 0, 1), Assert.Single(result.StreamSummaries));
        Assert.Equal(new[] { Hash(0) }, result.Records.Select(record => JsonCanonicalizer.Sha256Hex(record)));
        Assert.Empty(result.Gaps);
    }

    [Fact]
    public void CrashAfterTheTimerFlushKeepsEveryEvent()
    {
        CaptureJournal journal = StartRecordingJournal();
        RecordEventWithoutFlush(journal, 0);
        RecordEventWithoutFlush(journal, 1);
        _time.Advance(Interval);

        CaptureJournal reopened = CaptureJournal.Reopen(_root, ArchiveId);
        CommitResult result = reopened.RecoverInterrupted(EndedAt);

        Assert.Equal(new StreamSummary(StreamId, 0, 1, 2), Assert.Single(result.StreamSummaries));
        Assert.Equal(new[] { Hash(0), Hash(1) }, result.Records.Select(record => JsonCanonicalizer.Sha256Hex(record)));
        Assert.Empty(result.Gaps);
    }

    [Fact]
    public void CrashBetweenAReservationFlushAndItsResolutionMakesTheReservationAGap()
    {
        CaptureJournal journal = StartRecordingJournal();
        RecordEventWithoutFlush(journal, 0);
        ReservationToken second = journal.Reserve();
        journal.Flush();
        journal.ResolveObservation(second, Record(1));

        // Kill: the reservation of event 1 is on disk, its resolution was still in memory.
        CaptureJournal reopened = CaptureJournal.Reopen(_root, ArchiveId);
        Assert.Equal(1, reopened.PendingReservationCount);
        CommitResult result = reopened.RecoverInterrupted(EndedAt);

        GapEntry gap = Assert.Single(result.Gaps);
        Assert.Equal(new GapEntry(StreamId, 1, 1, GapReasons.RecoveryTruncation, CaptureJournal.RecoveryTruncationDetail), gap);
        Assert.Equal(new[] { Hash(0) }, result.Records.Select(record => JsonCanonicalizer.Sha256Hex(record)));
    }

    [Fact]
    public void CrashAfterSeveralTimedWritesRecoversEverythingWrittenBeforeTheKill()
    {
        CaptureJournal journal = StartRecordingJournal();
        for (int second = 0; second < 5; second++)
        {
            RecordEventWithoutFlush(journal, second);
            _time.Advance(Interval);
        }

        // The sixth event is in memory when the process is killed.
        RecordEventWithoutFlush(journal, 5);

        CaptureJournal reopened = CaptureJournal.Reopen(_root, ArchiveId);
        CommitResult result = reopened.RecoverInterrupted(EndedAt);

        Assert.Equal(
            Enumerable.Range(0, 5).Select(sequence => Hash(sequence)),
            result.Records.Select(record => JsonCanonicalizer.Sha256Hex(record)));
        Assert.Empty(result.Gaps);
    }

    [Fact]
    public void AFailedTimedWriteFencesTheWriterAndTheNextCallReportsIt()
    {
        CaptureJournal journal = StartRecordingJournal();
        journal.Reserve();
        Directory.Delete(_stateDirectory, recursive: true);

        _time.Advance(Interval);

        CaptureJournalException error = Assert.Throws<CaptureJournalException>(() => journal.Reserve());
        Assert.Equal(JournalErrorKind.WriterPoisoned, error.Kind);
    }

    [Fact]
    public void ReplayStillReadsOneSegmentFilesWrittenByEarlierVersions()
    {
        CaptureJournal journal = StartRecordingJournal();
        RecordEventWithoutFlush(journal, 0);
        journal.Flush();

        string batch = Path.Combine(_walDirectory, Name(0, 2));
        string[] lines = File.ReadAllText(batch, Utf8NoBom).Split('\n', StringSplitOptions.RemoveEmptyEntries);
        File.Delete(batch);
        for (int sequence = 0; sequence < lines.Length; sequence++)
        {
            File.WriteAllText(Path.Combine(_walDirectory, sequence.ToString("D20") + ".json"), lines[sequence], Utf8NoBom);
        }

        CaptureJournal reopened = CaptureJournal.Reopen(_root, ArchiveId);
        CommitResult result = reopened.RecoverInterrupted(EndedAt);

        Assert.Equal(new[] { Hash(0) }, result.Records.Select(record => JsonCanonicalizer.Sha256Hex(record)));
    }

    [Fact]
    public void InvalidOptionsAreRefused()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => CaptureJournal.Prepare(
            _root, ArchiveId, CaptureId, StreamId, options: new JournalOptions { FlushInterval = TimeSpan.Zero }));
        Assert.Throws<ArgumentOutOfRangeException>(() => CaptureJournal.Prepare(
            _root, ArchiveId, CaptureId, StreamId, options: new JournalOptions { MaxBufferedBytes = 0 }));
    }

    [Fact]
    public void EngineStartWritesItsFirstObservationsBeforeItReturns()
    {
        CaptureEngine engine = CaptureEngine.Start(new EngineConfig(
            _root,
            "fixture-user",
            "fixture-host",
            "0.0.0-test",
            Array.Empty<string>(),
            false,
            () => DateTimeOffset.UtcNow));

        // Kill right after Start: session_start must already be on disk, or recovery would find a
        // stream without an observation.
        CaptureJournalRecoveryResult recovery = CaptureJournalRecovery.Recover(_root, () => "2026-11-23T08:01:00.000Z");

        Assert.Equal(1, recovery.Recovered);
        Assert.Equal(0, recovery.NeedsAttention);
        Assert.Equal(JournalLifecycle.Committed, CaptureJournal.Reopen(_root, engine.Identity.ArchiveId).Lifecycle);
    }

    private CaptureJournal StartRecordingJournal()
    {
        CaptureJournal journal = CaptureJournal.Prepare(
            _root, ArchiveId, CaptureId, StreamId, options: new JournalOptions { TimeProvider = _time });
        journal.StartRecording();
        return journal;
    }

    /// <summary>One event is three segments: reservation, intent and acknowledgement.</summary>
    private static void RecordEventWithoutFlush(CaptureJournal journal, long sequence)
    {
        ReservationToken token = journal.Reserve();
        Assert.Equal(sequence, token.StreamSequence);
        journal.ResolveObservation(token, Record(sequence));
    }

    private string[] WalFileNames() => Directory.Exists(_walDirectory)
        ? Directory.GetFiles(_walDirectory)
            .Select(path => Path.GetFileName(path))
            .OrderBy(name => name, StringComparer.Ordinal)
            .ToArray()
        : Array.Empty<string>();

    private static string Name(long first, long last) =>
        first.ToString("D20") + "-" + last.ToString("D20") + CaptureJournal.WalMergedFileExtension;

    private static string Hash(long sequence) => JsonCanonicalizer.Sha256Hex(Record(sequence));

    private static JsonObject Record(long streamSequence) =>
        new()
        {
            ["schemaVersion"] = 1,
            ["observationId"] = "obs-00000000-0000-7000-8000-" + streamSequence.ToString("000000000000"),
            ["recordType"] = "jazz.activity-event",
            ["captureId"] = CaptureId,
            ["streamId"] = StreamId,
            ["streamSequence"] = streamSequence,
            ["capturedAt"] = "2026-11-23T08:00:00Z",
            ["payload"] = new JsonObject
            {
                ["sessionId"] = SessionId,
                ["eventId"] = Identifiers.EventId(SessionId, streamSequence),
                ["timestamp"] = "2026-11-23T08:00:00Z",
                ["eventType"] = "click",
                ["url"] = "app://session",
            },
        };
}
