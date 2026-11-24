using System.Text;
using System.Text.Json.Nodes;
using JazzCaptureCore;
using JazzCaptureCore.Journal;
using JazzCaptureCore.Json;

namespace JazzCaptureCoreTests;

/// <summary>
/// Merging of finished write-ahead log segments during a recording. A "crash" is simulated by
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

    // 33 segments: the first merge (segments 0..31) has run and segment 32 is not merged yet.
    private const int EventsForOneMerge = 11;

    // 1200 segments: one level-2 file (0..1023), five level-1 files (1024..1183), 16 segments.
    private const int EventsForTwoLevels = 400;

    private static readonly UTF8Encoding Utf8NoBom = new(encoderShouldEmitUTF8Identifier: false);

    private readonly string _root;
    private readonly string _walDirectory;

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
        int segments = EventsForTwoLevels * SegmentsPerEvent;
        int level2 = CaptureJournal.WalMergeFanIn * CaptureJournal.WalMergeFanIn;
        int level1Files = (segments - level2) / CaptureJournal.WalMergeFanIn;

        for (int sequence = 0; sequence < EventsForTwoLevels; sequence++)
        {
            RecordEvent(journal, sequence);
        }

        var expected = new List<string> { MergedName(0, level2 - 1) };
        for (int file = 0; file < level1Files; file++)
        {
            long first = level2 + ((long)file * CaptureJournal.WalMergeFanIn);
            expected.Add(MergedName(first, first + CaptureJournal.WalMergeFanIn - 1));
        }

        for (long sequence = level2 + ((long)level1Files * CaptureJournal.WalMergeFanIn); sequence < segments; sequence++)
        {
            expected.Add(SegmentName(sequence));
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
        // to three files — its own, a level-1 file and the level-2 file.
        foreach ((string name, byte[] bytes) in published)
        {
            string path = Path.Combine(_walDirectory, name);
            if (!File.Exists(path))
            {
                File.WriteAllBytes(path, bytes);
            }
        }

        Assert.Contains(SegmentName(0), WalFileNames());
        Assert.Contains(MergedName(0, CaptureJournal.WalMergeFanIn - 1), WalFileNames());
        Assert.Contains(MergedName(0, (CaptureJournal.WalMergeFanIn * CaptureJournal.WalMergeFanIn) - 1), WalFileNames());

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

        string mergedName = MergedName(0, CaptureJournal.WalMergeFanIn - 1);
        string mergedPath = Path.Combine(_walDirectory, mergedName);
        byte[] merged = File.ReadAllBytes(mergedPath);
        string[] lines = Utf8NoBom.GetString(merged).Split('\n');
        Assert.Equal(CaptureJournal.WalMergeFanIn + 1, lines.Length);

        // Put back the source segments the merge had deleted, as the crash point leaves them.
        for (int sequence = 0; sequence < CaptureJournal.WalMergeFanIn; sequence++)
        {
            if (crashPoint != "half of the sources deleted" || sequence % 2 == 0)
            {
                File.WriteAllText(Path.Combine(_walDirectory, SegmentName(sequence)), lines[sequence], Utf8NoBom);
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
                Path.Combine(_walDirectory, MergedName(0, CaptureJournal.WalMergeFanIn - 1)),
                Utf8NoBom)
            .Split('\n');
        string changed = lines[0].Replace("\"res-", "\"res-x", StringComparison.Ordinal);
        Assert.NotEqual(lines[0], changed);
        File.WriteAllText(Path.Combine(_walDirectory, SegmentName(0)), changed, Utf8NoBom);

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
            Path.Combine(_walDirectory, MergedName(0, CaptureJournal.WalMergeFanIn - 1)),
            Path.Combine(_walDirectory, MergedName(0, CaptureJournal.WalMergeFanIn - 2)));

        CaptureJournalException error = Assert.Throws<CaptureJournalException>(() => CaptureJournal.Reopen(_root, ArchiveId));

        Assert.Equal(JournalErrorKind.CorruptState, error.Kind);
    }

    private CaptureJournal StartRecordingJournal()
    {
        CaptureJournal journal = CaptureJournal.Prepare(_root, ArchiveId, CaptureId, StreamId);
        journal.StartRecording();
        return journal;
    }

    private static void RecordEvent(CaptureJournal journal, long sequence)
    {
        ReservationToken token = journal.Reserve();
        Assert.Equal(sequence, token.StreamSequence);
        journal.ResolveObservation(token, Record(sequence));
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

    private static string SegmentName(long sequence) => sequence.ToString("D20") + ".json";

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
