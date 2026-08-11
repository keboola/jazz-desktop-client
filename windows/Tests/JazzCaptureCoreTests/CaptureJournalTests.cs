using System.Text;
using System.Text.Json.Nodes;
using JazzCaptureCore;
using JazzCaptureCore.Journal;
using JazzCaptureCore.Json;

namespace JazzCaptureCoreTests;

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
    private const string ArtifactId = "art-00000000-0000-7000-8000-00000000a00b";
    private const string OtherArtifactId = "art-00000000-0000-7000-8000-00000000a00a";

    /// <summary>
    /// A neutral payload. The journal never interprets artifact bytes, and the only two kinds that
    /// exist — <c>screenshot</c> and <c>narration_audio</c> — carry evidence profiles that belong to
    /// the archive layer, not here.
    /// </summary>
    private static readonly byte[] Payload = { 0x6a, 0x61, 0x7a, 0x7a };

    private static readonly ArtifactFingerprint PayloadFingerprint = ArtifactFingerprint.ForBytes(Payload);

    private readonly string _root;

    public CaptureJournalTests()
    {
        _root = Path.Combine(Path.GetTempPath(), "jazz-capture-journal-tests", Identifiers.UuidV7());
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
    public void ReserveArtifactIsDurableBeforeItReturns()
    {
        CaptureJournal journal = StartRecordingJournal();

        ArtifactReservationToken token = journal.ReserveArtifact();

        Assert.StartsWith("ares-", token.ReservationId, StringComparison.Ordinal);
        Assert.StartsWith("art-", token.ArtifactId, StringComparison.Ordinal);
        Assert.Equal(ArchiveId, token.ArchiveId);
        Assert.Equal(CaptureId, token.CaptureId);

        CaptureJournal reopened = CaptureJournal.Reopen(_root, ArchiveId);
        Assert.Equal(1, reopened.PendingArtifactCount);
    }

    [Fact]
    public void ReservingTheSameArtifactIdentityTwiceIsRefused()
    {
        CaptureJournal journal = StartRecordingJournal();
        ArtifactReservationToken token = journal.ReserveArtifact(ArtifactId);

        CaptureJournalException error = Assert.Throws<CaptureJournalException>(
            () => journal.ReserveArtifact(token.ArtifactId));

        Assert.Equal(JournalErrorKind.DuplicateArtifact, error.Kind);
    }

    [Fact]
    public void IngestArtifactPublishesTheBytesContentAddressedAndResolvesTheReservation()
    {
        CaptureJournal journal = StartRecordingJournal();
        ArtifactReservationToken token = journal.ReserveArtifact(ArtifactId);

        JsonObject artifact = journal.IngestArtifact(
            token,
            Payload,
            fingerprint => ArtifactDocument(token.ArtifactId, fingerprint));

        Assert.Equal(0, journal.PendingArtifactCount);

        string digest = PayloadFingerprint.Sha256;
        string blob = Path.Combine(
            _root,
            CaptureJournal.StateRootName,
            ArchiveId,
            CaptureJournal.DraftDirectoryName,
            "blobs",
            "sha256",
            digest[..2],
            digest);

        // The file name is the digest: that is what makes the draft content-addressed, and it is
        // what the contract validator re-checks against the artifact's own content block.
        Assert.True(File.Exists(blob));
        Assert.Equal(Payload.ToArray(), File.ReadAllBytes(blob));
        Assert.Equal(digest, Path.GetFileName(blob));
        Assert.Equal("blobs/sha256/" + digest[..2] + "/" + digest, (string?)artifact["content"]!["path"]);
        Assert.Equal(Payload.Length, (long?)artifact["content"]!["byteLength"]);
    }

    [Fact]
    public void IngestArtifactIsIdempotentForTheSameEvidenceAndConflictsOnADifferentOne()
    {
        CaptureJournal journal = StartRecordingJournal();
        ArtifactReservationToken token = journal.ReserveArtifact(ArtifactId);
        JsonObject first = journal.IngestArtifact(
            token,
            Payload,
            fingerprint => ArtifactDocument(token.ArtifactId, fingerprint));

        JsonObject again = journal.IngestArtifact(
            token,
            Payload,
            fingerprint => ArtifactDocument(token.ArtifactId, fingerprint));
        Assert.Equal(JsonCanonicalizer.Sha256Hex(first), JsonCanonicalizer.Sha256Hex(again));

        // Same reservation, different bytes: the archive would otherwise carry two different
        // artifacts under one identity, so it fails closed.
        CaptureJournalException error = Assert.Throws<CaptureJournalException>(() => journal.IngestArtifact(
            token,
            new byte[] { 9, 9, 9 },
            fingerprint => ArtifactDocument(token.ArtifactId, fingerprint)));
        Assert.Equal(JournalErrorKind.CompletionConflict, error.Kind);

        // Same bytes, different metadata is a conflict too: the document is the evidence.
        Assert.Equal(
            JournalErrorKind.CompletionConflict,
            Assert.Throws<CaptureJournalException>(() => journal.IngestArtifact(
                token,
                Payload,
                fingerprint => ArtifactDocument(token.ArtifactId, fingerprint, kind: "narration_audio"))).Kind);
    }

    [Fact]
    public void IngestArtifactRefusesADocumentThatDoesNotDescribeTheBytes()
    {
        CaptureJournal journal = StartRecordingJournal();
        ArtifactReservationToken token = journal.ReserveArtifact(ArtifactId);

        Assert.Throws<ArgumentException>(() => journal.IngestArtifact(
            token,
            Payload,
            _ => ArtifactDocument(
                token.ArtifactId,
                new ArtifactFingerprint(
                    "0000000000000000000000000000000000000000000000000000000000000000",
                    Payload.Length,
                    ArtifactFingerprint.BlobPath("0000000000000000000000000000000000000000000000000000000000000000")))));
    }

    [Fact]
    public void ResolveArtifactRefusesEvidenceThatIsNotInTheDraft()
    {
        CaptureJournal journal = StartRecordingJournal();
        ArtifactReservationToken token = journal.ReserveArtifact(ArtifactId);

        CaptureJournalException error = Assert.Throws<CaptureJournalException>(
            () => journal.ResolveArtifact(token, ArtifactDocument(token.ArtifactId, PayloadFingerprint)));

        Assert.Equal(JournalErrorKind.CompletionConflict, error.Kind);
        Assert.Equal(1, journal.PendingArtifactCount);
    }

    [Fact]
    public void CommitRefusesAPendingArtifact()
    {
        CaptureJournal journal = StartRecordingJournal();
        journal.ResolveObservation(journal.Reserve(), Record(0));
        journal.ReserveArtifact(ArtifactId);
        journal.CloseInput();
        journal.BeginDraining();

        CaptureJournalException error = Assert.Throws<CaptureJournalException>(() => journal.Commit(EndedAt));

        Assert.Equal(JournalErrorKind.PendingWork, error.Kind);
    }

    [Fact]
    public void ResolvedArtifactsReachTheCommitOrderedByIdentity()
    {
        CaptureJournal journal = StartRecordingJournal();
        journal.ResolveObservation(journal.Reserve(), Record(0));

        ArtifactReservationToken second = journal.ReserveArtifact(ArtifactId);
        ArtifactReservationToken first = journal.ReserveArtifact(OtherArtifactId);
        journal.IngestArtifact(second, Payload, fingerprint => ArtifactDocument(second.ArtifactId, fingerprint));
        journal.IngestArtifact(
            first,
            new byte[] { 1, 2, 3 },
            fingerprint => ArtifactDocument(first.ArtifactId, fingerprint));

        journal.CloseInput();
        journal.BeginDraining();
        CommitResult result = journal.Commit(EndedAt);

        Assert.Equal(
            new[] { OtherArtifactId, ArtifactId },
            result.Artifacts.Select(artifact => (string?)artifact.Document["artifactId"]).ToArray());
        Assert.All(result.Artifacts, artifact => Assert.True(File.Exists(artifact.SourcePath)));
    }

    /// <summary>
    /// Two artifacts holding the same bytes are two artifacts, but one blob. Content addressing
    /// makes that automatic, and the second ingest must not trip over the first one's file.
    /// </summary>
    [Fact]
    public void IdenticalBytesUnderTwoIdentitiesShareOneBlob()
    {
        CaptureJournal journal = StartRecordingJournal();
        journal.ResolveObservation(journal.Reserve(), Record(0));

        ArtifactReservationToken first = journal.ReserveArtifact(OtherArtifactId);
        ArtifactReservationToken second = journal.ReserveArtifact(ArtifactId);
        journal.IngestArtifact(first, Payload, fingerprint => ArtifactDocument(first.ArtifactId, fingerprint));
        journal.IngestArtifact(second, Payload, fingerprint => ArtifactDocument(second.ArtifactId, fingerprint));

        journal.CloseInput();
        journal.BeginDraining();
        CommitResult result = journal.Commit(EndedAt);

        Assert.Equal(2, result.Artifacts.Count);
        Assert.Single(result.Artifacts.Select(artifact => artifact.SourcePath).Distinct(StringComparer.Ordinal));
        Assert.Equal(
            new[] { PayloadFingerprint.Sha256 },
            Directory
                .GetFiles(
                    Path.Combine(
                        _root,
                        CaptureJournal.StateRootName,
                        ArchiveId,
                        CaptureJournal.DraftDirectoryName),
                    "*",
                    SearchOption.AllDirectories)
                .Select(Path.GetFileName)
                .ToArray());
    }

    /// <summary>
    /// The crash window the ingest ordering exists for: the write-ahead intent reached the log and
    /// the bytes reached the draft, but the acknowledgement never did. Deleting the last write-ahead
    /// segment is exactly that kill, because the segment is what the acknowledgement is.
    /// </summary>
    [Fact]
    public void ReopenResolvesAnArtifactIntentWhoseBytesSurvived()
    {
        CaptureJournal journal = StartRecordingJournal();
        journal.ResolveObservation(journal.Reserve(), Record(0));
        ArtifactReservationToken token = journal.ReserveArtifact(ArtifactId);
        journal.IngestArtifact(token, Payload, fingerprint => ArtifactDocument(token.ArtifactId, fingerprint));

        File.Delete(LastWalSegment());

        CaptureJournal reopened = CaptureJournal.Reopen(_root, ArchiveId);
        Assert.Equal(0, reopened.PendingArtifactCount);

        reopened.CloseInput();
        reopened.BeginDraining();
        CommitResult result = reopened.Commit(EndedAt);

        CommittedArtifact artifact = Assert.Single(result.Artifacts);
        Assert.Equal(ArtifactId, (string?)artifact.Document["artifactId"]);
        Assert.Equal(PayloadFingerprint.Sha256, (string?)artifact.Document["content"]!["sha256"]);
    }

    [Fact]
    public void RecoveryDiscardsAnArtifactWhoseBytesNeverLanded()
    {
        CaptureJournal journal = StartRecordingJournal();
        journal.ResolveObservation(journal.Reserve(), Record(0));
        ArtifactReservationToken token = journal.ReserveArtifact(ArtifactId);
        journal.IngestArtifact(token, Payload, fingerprint => ArtifactDocument(token.ArtifactId, fingerprint));

        // Kill after the intent but before the bytes: the acknowledgement segment and the blob are
        // both gone, so nothing on disk says the payload ever existed.
        File.Delete(LastWalSegment());
        File.Delete(Path.Combine(
            _root,
            CaptureJournal.StateRootName,
            ArchiveId,
            CaptureJournal.DraftDirectoryName,
            "blobs",
            "sha256",
            PayloadFingerprint.Sha256[..2],
            PayloadFingerprint.Sha256));

        CaptureJournal reopened = CaptureJournal.Reopen(_root, ArchiveId);
        Assert.Equal(1, reopened.PendingArtifactCount);

        CommitResult result = reopened.RecoverInterrupted(EndedAt);

        Assert.Empty(result.Artifacts);
        Assert.Equal(JournalSessionStatus.Recovered, result.Status);
        Assert.Single(result.Records);
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

    /// <summary>The highest-numbered write-ahead segment: the last durable step the journal took.</summary>
    private string LastWalSegment() => Directory
        .GetFiles(Path.Combine(_root, CaptureJournal.StateRootName, ArchiveId, "wal"), "*.json")
        .OrderBy(path => path, StringComparer.Ordinal)
        .Last();

    /// <summary>
    /// A minimal artifact document. The journal requires only an identity and a content block that
    /// describes the bytes; the canonical archive shape is <see cref="JazzCaptureCore.Archive.ArchiveDocuments"/>'s
    /// business.
    /// </summary>
    private static JsonObject ArtifactDocument(
        string artifactId,
        ArtifactFingerprint fingerprint,
        string kind = "attachment") =>
        new()
        {
            ["schemaVersion"] = 1,
            ["artifactId"] = artifactId,
            ["captureId"] = CaptureId,
            ["origin"] = "captured",
            ["kind"] = kind,
            ["content"] = new JsonObject
            {
                ["path"] = fingerprint.ContentPath,
                ["mediaType"] = "application/octet-stream",
                ["byteLength"] = fingerprint.ByteLength,
                ["sha256"] = fingerprint.Sha256,
            },
        };

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
