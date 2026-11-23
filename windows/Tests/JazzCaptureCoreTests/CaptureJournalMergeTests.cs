using System.Text;
using System.Text.Json.Nodes;
using JazzCaptureCore;
using JazzCaptureCore.Journal;
using JazzCaptureCore.Json;

namespace JazzCaptureCoreTests;

/// <summary>
/// Merging of finished write-ahead log files during a recording. Every event is flushed on its own
/// here, so one event is one file of three segments (level 0). A "crash" is simulated by
/// abandoning a journal instance and putting back on disk files that a merge had already
/// replaced: every file the journal publishes is immutable under its name, so any mix of them is
/// a state a process kill can leave.
/// </summary>
public sealed class CaptureJournalMergeTests : IDisposable
{
    private const string ArchiveId = "ar-00000000-0000-7000-8000-00000000b001";
    private const string CaptureId = "cap-00000000-0000-7000-8000-00000000b003";
    private const string StreamId = "stream-00000000-0000-7000-8000-00000000b004";
    private const string SessionId = "s-00000000-0000-7000-8000-00000000b009";
    private const string EndedAt = "2026-11-21T08:01:00Z";

    // One event is one reservation segment plus the intent and the acknowledgement segments.
    private const int SegmentsPerEvent = 3;

    // 33 files: the first merge (files 0..31, segments 0..95) has run and file 32 is not merged yet.
    private const int EventsForOneMerge = 33;

    // 1100 files: one level-2 file (events 0..1023), two level-1 files (events 1024..1087) and
    // twelve level-0 files (events 1088..1099).
    private const int EventsForTwoLevels = 1100;

    private const int FilesPerLevel1 = CaptureJournal.WalMergeFanIn;
    private const int FilesPerLevel2 = CaptureJournal.WalMergeFanIn * CaptureJournal.WalMergeFanIn;

    private static readonly UTF8Encoding Utf8NoBom = new(encoderShouldEmitUTF8Identifier: false);

    private readonly string _root;
    private readonly string _walDirectory;
    private readonly ManualTimeProvider _time = new();

    public CaptureJournalMergeTests()
    {
        _root = Path.Combine(Path.GetTempPath(), "jazz-capture-journal-merge-tests", Identifiers.UuidV7());
        _walDirectory = Path.Combine(_root, CaptureJournal.StateRootName, ArchiveId, "wal");
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
    public void MergeDuringRecordingKeepsTheFileCountBoundedAndCommitsEveryEventOnce()
    {
        CaptureJournal journal = StartRecordingJournal();

        for (int sequence = 0; sequence < EventsForTwoLevels; sequence++)
        {
            RecordEvent(journal, sequence);
        }

        var expected = new List<string> { MergedName(0, (FilesPerLevel2 * SegmentsPerEvent) - 1) };
        for (int file = 0; file < 2; file++)
        {
            long first = (FilesPerLevel2 + ((long)file * FilesPerLevel1)) * SegmentsPerEvent;
            expected.Add(MergedName(first, first + (FilesPerLevel1 * SegmentsPerEvent) - 1));
        }

        for (long eventSequence = FilesPerLevel2 + (2 * FilesPerLevel1); eventSequence < EventsForTwoLevels; eventSequence++)
        {
            expected.Add(MergedName(eventSequence * SegmentsPerEvent, (eventSequence * SegmentsPerEvent) + SegmentsPerEvent - 1));
        }

        Assert.Equal(expected.OrderBy(name => name, StringComparer.Ordinal), WalFileNames());

        journal.CloseInput();
        journal.BeginDraining();
        CommitResult result = journal.Commit(EndedAt);

        AssertEveryEventOnce(result, EventsForTwoLevels, JournalSessionStatus.Closed);
        Assert.Empty(WalFileNames());
    }

    [Fact]
    public void CrashThatKeptEveryMergedSourceFileReplaysEachEventOnce()
    {
        CaptureJournal journal = StartRecordingJournal();
        var published = new Dictionary<string, byte[]>(StringComparer.Ordinal);

        for (int sequence = 0; sequence < EventsForTwoLevels; sequence++)
        {
            RecordEvent(journal, sequence);
            CollectPublishedFiles(published);
        }

        // Crash: not one delete of a merged source reached the disk, so every segment exists in up
        // to three files: its level-0 file, a level-1 file and the level-2 file.
        foreach ((string name, byte[] bytes) in published)
        {
            string path = Path.Combine(_walDirectory, name);
            if (!File.Exists(path))
            {
                File.WriteAllBytes(path, bytes);
            }
        }

        Assert.Contains(MergedName(0, SegmentsPerEvent - 1), WalFileNames());
        Assert.Contains(MergedName(0, (FilesPerLevel1 * SegmentsPerEvent) - 1), WalFileNames());
        Assert.Contains(MergedName(0, (FilesPerLevel2 * SegmentsPerEvent) - 1), WalFileNames());

        CaptureJournal reopened = CaptureJournal.Reopen(_root, ArchiveId);
        Assert.Equal(0, reopened.PendingReservationCount);
        CommitResult result = reopened.RecoverInterrupted(EndedAt);

        AssertEveryEventOnce(result, EventsForTwoLevels, JournalSessionStatus.Recovered);
    }

    [Theory]
    [InlineData("before rename")]
    [InlineData("after rename")]
    [InlineData("half of the sources deleted")]
    public void CrashDuringAMergeLosesAndDuplicatesNothing(string crashPoint)
    {
        CaptureJournal journal = StartRecordingJournal();
        for (int sequence = 0; sequence < EventsForOneMerge; sequence++)
        {
            RecordEvent(journal, sequence);
        }

        string mergedName = MergedName(0, (FilesPerLevel1 * SegmentsPerEvent) - 1);
        string mergedPath = Path.Combine(_walDirectory, mergedName);
        byte[] merged = File.ReadAllBytes(mergedPath);
        string[] lines = Utf8NoBom.GetString(merged).Split('\n');
        Assert.Equal((FilesPerLevel1 * SegmentsPerEvent) + 1, lines.Length);

        // Put back the source files the merge had deleted, as the crash point leaves them.
        for (int file = 0; file < FilesPerLevel1; file++)
        {
            if (crashPoint != "half of the sources deleted" || file % 2 == 0)
            {
                PutBackLevel0File(lines, file);
            }
        }

        if (crashPoint == "before rename")
        {
            // The merged bytes never got their name: only a partial temporary file exists.
            File.Delete(mergedPath);
            File.WriteAllBytes(
                mergedPath + "." + Identifiers.UuidV7() + Durability.TemporaryFileSuffix,
                merged.AsSpan(0, merged.Length / 2).ToArray());
        }

        CaptureJournal reopened = CaptureJournal.Reopen(_root, ArchiveId);
        Assert.Equal(0, reopened.PendingReservationCount);
        CommitResult result = reopened.RecoverInterrupted(EndedAt);

        AssertEveryEventOnce(result, EventsForOneMerge, JournalSessionStatus.Recovered);
        Assert.DoesNotContain(WalFileNames(), name => name.EndsWith(".json", StringComparison.Ordinal)
            || name.EndsWith(CaptureJournal.WalMergedFileExtension, StringComparison.Ordinal));
    }

    [Fact]
    public void ReplayRefusesTwoDifferentCopiesOfOneSegment()
    {
        CaptureJournal journal = StartRecordingJournal();
        for (int sequence = 0; sequence < EventsForOneMerge; sequence++)
        {
            RecordEvent(journal, sequence);
        }

        string[] lines = File.ReadAllText(
                Path.Combine(_walDirectory, MergedName(0, (FilesPerLevel1 * SegmentsPerEvent) - 1)),
                Utf8NoBom)
            .Split('\n');
        string changed = lines[0].Replace("\"res-", "\"res-x", StringComparison.Ordinal);
        Assert.NotEqual(lines[0], changed);
        lines[0] = changed;
        PutBackLevel0File(lines, 0);

        CaptureJournalException error = Assert.Throws<CaptureJournalException>(() => CaptureJournal.Reopen(_root, ArchiveId));

        Assert.Equal(JournalErrorKind.CorruptState, error.Kind);
    }

    [Fact]
    public void ReplayRefusesAMergedFileThatDoesNotMatchItsName()
    {
        CaptureJournal journal = StartRecordingJournal();
        for (int sequence = 0; sequence < EventsForOneMerge; sequence++)
        {
            RecordEvent(journal, sequence);
        }

        File.Move(
            Path.Combine(_walDirectory, MergedName(0, (FilesPerLevel1 * SegmentsPerEvent) - 1)),
            Path.Combine(_walDirectory, MergedName(0, (FilesPerLevel1 * SegmentsPerEvent) - 2)));

        CaptureJournalException error = Assert.Throws<CaptureJournalException>(() => CaptureJournal.Reopen(_root, ArchiveId));

        Assert.Equal(JournalErrorKind.CorruptState, error.Kind);
    }

    private CaptureJournal StartRecordingJournal()
    {
        CaptureJournal journal = CaptureJournal.Prepare(
            _root, ArchiveId, CaptureId, StreamId, options: new JournalOptions { TimeProvider = _time });
        journal.StartRecording();
        return journal;
    }

    /// <summary>One event: three segments, written as one level-0 file.</summary>
    private static void RecordEvent(CaptureJournal journal, long sequence)
    {
        ReservationToken token = journal.Reserve();
        Assert.Equal(sequence, token.StreamSequence);
        journal.ResolveObservation(token, Record(sequence));
        journal.Flush();
    }

    /// <summary>Writes the level-0 file of event <paramref name="file"/> from the segment lines of a merged file.</summary>
    private void PutBackLevel0File(string[] lines, int file)
    {
        long first = (long)file * SegmentsPerEvent;
        File.WriteAllText(
            Path.Combine(_walDirectory, MergedName(first, first + SegmentsPerEvent - 1)),
            string.Join('\n', lines[(int)first..(int)(first + SegmentsPerEvent)]) + "\n",
            Utf8NoBom);
    }

    /// <summary>Copies every finished WAL file not seen before. Published files never change.</summary>
    private void CollectPublishedFiles(Dictionary<string, byte[]> published)
    {
        foreach (string path in Directory.GetFiles(_walDirectory))
        {
            string name = Path.GetFileName(path);
            if (!name.EndsWith(Durability.TemporaryFileSuffix, StringComparison.Ordinal) && !published.ContainsKey(name))
            {
                published[name] = File.ReadAllBytes(path);
            }
        }
    }

    private string[] WalFileNames() => Directory.Exists(_walDirectory)
        ? Directory.GetFiles(_walDirectory)
            .Select(path => Path.GetFileName(path))
            .OrderBy(name => name, StringComparer.Ordinal)
            .ToArray()
        : Array.Empty<string>();

    private static void AssertEveryEventOnce(CommitResult result, int events, string status)
    {
        Assert.Empty(result.Gaps);
        Assert.Equal(status, result.Status);
        Assert.Equal(new StreamSummary(StreamId, 0, events - 1, events), Assert.Single(result.StreamSummaries));
        Assert.Equal(
            Enumerable.Range(0, events).Select(sequence => JsonCanonicalizer.Sha256Hex(Record(sequence))),
            result.Records.Select(record => JsonCanonicalizer.Sha256Hex(record)));
    }

    private static string MergedName(long first, long last) =>
        first.ToString("D20") + "-" + last.ToString("D20") + CaptureJournal.WalMergedFileExtension;

    private static JsonObject Record(long streamSequence) =>
        new()
        {
            ["schemaVersion"] = 1,
            ["observationId"] = "obs-00000000-0000-7000-8000-" + streamSequence.ToString("000000000000"),
            ["recordType"] = "jazz.activity-event",
            ["captureId"] = CaptureId,
            ["streamId"] = StreamId,
            ["streamSequence"] = streamSequence,
            ["capturedAt"] = "2026-11-21T08:00:00Z",
            ["payload"] = new JsonObject
            {
                ["sessionId"] = SessionId,
                ["eventId"] = Identifiers.EventId(SessionId, streamSequence),
                ["timestamp"] = "2026-11-21T08:00:00Z",
                ["eventType"] = "click",
                ["url"] = "app://session",
            },
        };
}
