using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using JazzCaptureCore.Json;

namespace JazzCaptureCore.Journal;

/// <summary>
/// Single-writer, crash-safe ledger of one capture (ANNEX-ARCHIVE section 5).
/// </summary>
/// <remarks>
/// <para>
/// The journal is working state, not archive content. It exists so that a process kill at any
/// instant leaves evidence that is either complete or explicitly declared missing — never silently
/// renumbered. Eight rules define it:
/// </para>
/// <list type="number">
/// <item>One writer per archive: creating <c>.capture-journal/&lt;archiveId&gt;/</c> is the claim.</item>
/// <item>Admit before any other work: <see cref="Reserve"/> persists a pending reservation and
/// flushes it before the caller receives the sequence, so an unresolved slot becomes an explicit
/// gap instead of shifting its successors.</item>
/// <item>Write-ahead intent before the record store: the record and its canonical digest are
/// persisted as <c>resolvingObservation</c> first, and only then acknowledged as
/// <c>observation</c>.</item>
/// <item>Token identity: a completion presents the whole <see cref="ReservationToken"/>, so a late
/// callback from a previous generation cannot resolve current work.</item>
/// <item>Idempotence: the same token with the same canonical digest is a no-op; a different digest
/// is a conflict and fails closed.</item>
/// <item>Poison on durability failure: a failed write fences this writer permanently rather than
/// risk reallocating a sequence that recovery may still observe.</item>
/// <item>The checkpoint is the write-ahead log truncation point, not the commit point.</item>
/// <item>Commit refuses unresolved work: it requires draining, zero pending or resolving
/// reservations, and at least one observation per stream. It never waits for the network.</item>
/// </list>
/// <para>
/// Artifacts follow the same admit-then-commit shape, with the bytes standing in for the sequence:
/// <see cref="ReserveArtifact"/> writes down that a payload is expected,
/// <see cref="IngestArtifact"/> hashes it and puts it in the draft under its own digest, and only
/// then does <see cref="ResolveArtifact"/> let anything claim the artifact exists. Because the
/// layout is content-addressed, recovery can answer "did those bytes survive" with a file lookup —
/// and an artifact that never reached the draft is discarded rather than declared missing, since an
/// artifact has no position on the stream to leave a hole in.
/// </para>
/// <para>
/// On disk: <c>&lt;root&gt;/.capture-journal/&lt;archiveId&gt;/state.json</c> is the checkpoint,
/// <c>.../wal/%020d.json</c> the numbered mutations applied on top of it, in filename order and
/// contiguously, and <c>.../draft/blobs/sha256/&lt;xx&gt;/&lt;digest&gt;</c> the artifact bytes of
/// the capture in progress. Instances are not thread-safe; the capture engine owns exactly one.
/// </para>
/// </remarks>
public sealed class CaptureJournal
{
    /// <summary>Detail recorded on gaps produced by crash recovery.</summary>
    public const string RecoveryTruncationDetail = "producer did not finish before process termination";

    /// <summary>Directory under the capture root that holds every journal claim.</summary>
    public const string StateRootName = ".capture-journal";

    /// <summary>
    /// Directory under one journal claim that holds the artifact bytes of the capture in progress.
    /// Its internal layout is the archive's own — <c>blobs/sha256/&lt;xx&gt;/&lt;digest&gt;</c> — so
    /// finalization copies each blob to the path its artifact document already names.
    /// </summary>
    public const string DraftDirectoryName = "draft";

    /// <summary>Prefix required by the schema's <c>artifactId</c> pattern.</summary>
    public const string ArtifactIdPrefix = "art";

    private const int StateSchemaVersion = 1;
    private const int WalSchemaVersion = 1;
    private const string StateFileName = "state.json";
    private const string WalDirectoryName = "wal";
    private const string WalFileExtension = ".json";
    private const string WalFileNameFormat = "D20";
    private const string WalSearchPattern = "*" + WalFileExtension;
    private const string ReservationIdPrefix = "res";
    private const string ArtifactReservationIdPrefix = "ares";

    private static readonly Regex SafeIdentifierPattern = new(
        "^[A-Za-z0-9._-]+$",
        RegexOptions.CultureInvariant | RegexOptions.Compiled);

    private static readonly UTF8Encoding Utf8NoBom = new(encoderShouldEmitUTF8Identifier: false);

    private readonly string _root;
    private readonly string _stateRoot;
    private readonly string _stateDirectory;
    private readonly string _statePath;
    private readonly string _walDirectory;
    private readonly string _draftDirectory;
    private readonly Dictionary<string, ReservationEntry> _reservationsById = new(StringComparer.Ordinal);
    private readonly Dictionary<string, ArtifactEntry> _artifactsByReservationId = new(StringComparer.Ordinal);
    private readonly HashSet<string> _artifactIds = new(StringComparer.Ordinal);

    private JournalCheckpoint? _document;
    private long _nextWalSequence;
    private bool _poisoned;

    private CaptureJournal(string root, string archiveId)
    {
        _root = Path.GetFullPath(root);
        _stateRoot = Path.Combine(_root, StateRootName);
        _stateDirectory = Path.Combine(_stateRoot, archiveId);
        _statePath = Path.Combine(_stateDirectory, StateFileName);
        _walDirectory = Path.Combine(_stateDirectory, WalDirectoryName);
        _draftDirectory = Path.Combine(_stateDirectory, DraftDirectoryName);
        ArchiveId = archiveId;
    }

    /// <summary>Capture root that contains the journal claim directory.</summary>
    public string Root => _root;

    /// <summary>Archive this journal is claimed for.</summary>
    public string ArchiveId { get; }

    /// <summary>Capture this journal records.</summary>
    public string CaptureId => Document.CaptureId;

    /// <summary>Current producer lifecycle.</summary>
    public JournalLifecycle Lifecycle => _document?.Lifecycle ?? JournalLifecycle.Idle;

    /// <summary>Streams this capture may reserve sequences on, in ordinal order.</summary>
    public IReadOnlyList<string> StreamIds => Document.Streams.Select(stream => stream.StreamId).ToArray();

    /// <summary>Reservations that carry neither an observation nor a gap yet.</summary>
    public int PendingReservationCount => Document.Streams
        .SelectMany(stream => stream.Reservations)
        .Count(reservation => reservation.Status is ReservationStatus.Pending or ReservationStatus.ResolvingObservation);

    /// <summary>Artifact reservations whose bytes have not been proven durable yet.</summary>
    public int PendingArtifactCount => Document.Artifacts
        .Count(artifact => artifact.Status != ArtifactStatus.Artifact);

    /// <summary>Directory holding the artifact bytes of the capture in progress.</summary>
    public string DraftDirectory => _draftDirectory;

    /// <summary>
    /// Claims <paramref name="archiveId"/> under <paramref name="root"/> and persists the
    /// <see cref="JournalLifecycle.Starting"/> checkpoint. The claim directory is created before
    /// anything else so a second producer cannot record into the same archive identity.
    /// </summary>
    /// <exception cref="CaptureJournalException">The archive identifier is already claimed.</exception>
    public static CaptureJournal Prepare(string root, string archiveId, string captureId, string streamId)
    {
        ArgumentException.ThrowIfNullOrEmpty(root);
        ValidateDirectoryNameIdentifier(archiveId, nameof(archiveId));
        ArgumentException.ThrowIfNullOrEmpty(captureId);
        ArgumentException.ThrowIfNullOrEmpty(streamId);

        var journal = new CaptureJournal(root, archiveId);
        Directory.CreateDirectory(journal._stateRoot);

        if (Directory.Exists(journal._stateDirectory))
        {
            throw new CaptureJournalException(
                JournalErrorKind.ArchiveAlreadyClaimed,
                "Capture journal archive already claimed: " + archiveId);
        }

        Directory.CreateDirectory(journal._stateDirectory);

        var checkpoint = new JournalCheckpoint
        {
            SchemaVersion = StateSchemaVersion,
            ArchiveId = archiveId,
            CaptureId = captureId,
            WalSequence = 0,
            Lifecycle = JournalLifecycle.Starting,
        };
        checkpoint.Streams.Add(new StreamLedger { StreamId = streamId });

        try
        {
            // The rename cannot overwrite: a surviving state.json means the directory check above
            // raced another producer, and reusing the identity is less safe than failing.
            Durability.WriteAtomic(journal._statePath, Utf8NoBom.GetBytes(JournalJson.Canonical(checkpoint.ToJson())));
        }
        catch (IOException exception)
        {
            throw new CaptureJournalException(
                JournalErrorKind.ArchiveAlreadyClaimed,
                "Capture journal archive already claimed: " + archiveId,
                exception);
        }

        journal.FlushClaimChain();
        journal._document = checkpoint;
        journal._nextWalSequence = 0;
        journal.RebuildIndex();
        return journal;
    }

    /// <summary>
    /// Loads the checkpoint of <paramref name="archiveId"/> and replays its write-ahead log. The
    /// replay validates that segments are contiguous, that per-stream sequences have no holes, and
    /// that every persisted record still hashes to its recorded digest. A resolution intent that
    /// was persisted but never acknowledged is completed here, which is what makes a kill between
    /// the intent and the acknowledgement invisible to the archive.
    /// </summary>
    public static CaptureJournal Reopen(string root, string archiveId)
    {
        ArgumentException.ThrowIfNullOrEmpty(root);
        ValidateDirectoryNameIdentifier(archiveId, nameof(archiveId));

        var journal = new CaptureJournal(root, archiveId);
        if (!File.Exists(journal._statePath))
        {
            throw new CaptureJournalException(
                JournalErrorKind.StateNotFound,
                "Capture journal state not found: " + archiveId);
        }

        JournalCheckpoint checkpoint = journal.LoadAndReplay();
        journal._document = checkpoint;
        journal.RebuildIndex();
        journal.ReconcileObservationIntents();
        journal.ReconcileArtifactIntents();
        journal.ValidateLedger(checkpoint);
        journal.WriteCheckpoint(checkpoint);
        return journal;
    }

    /// <summary>Leaves <see cref="JournalLifecycle.Starting"/> and admits reservations.</summary>
    public void StartRecording()
    {
        JournalCheckpoint document = RequireLifecycle(JournalLifecycle.Starting, JournalLifecycle.Recording);
        document.Lifecycle = JournalLifecycle.Recording;
        WriteCheckpoint(document);
    }

    /// <summary>
    /// Allocates the next position on the capture's stream and makes it durable before returning.
    /// New work is admitted only while recording.
    /// </summary>
    public ReservationToken Reserve()
    {
        JournalCheckpoint document = RequireLifecycle(JournalLifecycle.Recording, JournalLifecycle.Recording);
        StreamLedger stream = document.Streams[0];

        var entry = new ReservationEntry
        {
            ReservationId = Identifiers.Prefixed(ReservationIdPrefix),
            StreamId = stream.StreamId,
            StreamSequence = stream.NextSequence,
            Status = ReservationStatus.Pending,
        };

        if (_reservationsById.ContainsKey(entry.ReservationId))
        {
            throw JournalJson.Corrupt("working reservation identity collision");
        }

        stream.Reservations.Add(entry);
        stream.NextSequence++;
        _reservationsById[entry.ReservationId] = entry;

        // Durable before the caller learns the sequence: rule 2 of ANNEX-ARCHIVE section 5.
        AppendWal(JournalMutation.AppendReservation(entry));

        return new ReservationToken(
            entry.ReservationId,
            document.ArchiveId,
            document.CaptureId,
            entry.StreamId,
            entry.StreamSequence);
    }

    /// <summary>
    /// Resolves a reserved position to exactly one canonical observation: intent first, then the
    /// record store, then the acknowledged state. Re-resolving with the same canonical digest is a
    /// no-op; a different digest is a conflict.
    /// </summary>
    public void ResolveObservation(ReservationToken token, JsonObject record)
    {
        ArgumentNullException.ThrowIfNull(token);
        ArgumentNullException.ThrowIfNull(record);

        JournalCheckpoint document = RequireResolutionLifecycle();
        ReservationEntry entry = Locate(document, token);
        JsonObject stored = record.DeepClone().AsObject();
        string digest = JsonCanonicalizer.Sha256Hex(stored);

        switch (entry.Status)
        {
            case ReservationStatus.Pending:
                break;

            case ReservationStatus.ResolvingObservation:
                throw new CaptureJournalException(
                    JournalErrorKind.CompletionInProgress,
                    "Capture journal completion already in progress: " + token.ReservationId);

            case ReservationStatus.Observation:
                if (!string.Equals(entry.RecordDigest, digest, StringComparison.Ordinal))
                {
                    throw Conflict(token);
                }

                return;

            default:
                throw Conflict(token);
        }

        // Write-ahead intent: after this segment the record is recoverable even if the process dies
        // before the acknowledgement below.
        entry.Status = ReservationStatus.ResolvingObservation;
        entry.Record = stored;
        entry.RecordDigest = digest;
        AppendWal(JournalMutation.UpdateReservation(entry));

        // The record store of this subset is the journal ledger itself: the intent above already
        // installed the canonical bytes, so the acknowledgement is the only remaining step.
        entry.Status = ReservationStatus.Observation;
        AppendWal(JournalMutation.UpdateReservation(entry));
    }

    /// <summary>
    /// Resolves a reserved position to an explicit absence of evidence. Repeating the identical gap
    /// is a no-op; changing reason or detail is a conflict.
    /// </summary>
    public void ResolveGap(ReservationToken token, string reason, string? detail = null)
    {
        ArgumentNullException.ThrowIfNull(token);

        if (!GapReasons.IsKnown(reason))
        {
            throw new ArgumentException(
                "Unknown capture gap reason '" + reason + "'. Expected one of: " + string.Join(", ", GapReasons.All) + ".",
                nameof(reason));
        }

        JournalCheckpoint document = RequireResolutionLifecycle();
        ReservationEntry entry = Locate(document, token);
        var gap = new GapEntry(token.StreamId, token.StreamSequence, token.StreamSequence, reason, detail);

        switch (entry.Status)
        {
            case ReservationStatus.Pending:
                entry.Status = ReservationStatus.Gap;
                entry.Gap = gap;
                AppendWal(JournalMutation.UpdateReservation(entry));
                return;

            case ReservationStatus.Gap when entry.Gap == gap:
                return;

            default:
                throw Conflict(token);
        }
    }

    /// <summary>
    /// Admits one artifact and makes the reservation durable before returning. An artifact occupies
    /// no stream position, so this allocates an identity rather than a sequence; the reservation
    /// exists so that bytes are never attached to a capture that has not first written down that it
    /// is expecting them.
    /// </summary>
    /// <param name="artifactId">
    /// Identity to reserve; defaults to a freshly minted <c>art-</c> identifier. An identity already
    /// reserved by this capture is refused rather than silently reused.
    /// </param>
    public ArtifactReservationToken ReserveArtifact(string? artifactId = null)
    {
        JournalCheckpoint document = RequireLifecycle(JournalLifecycle.Recording, JournalLifecycle.Recording);
        string identity = artifactId ?? Identifiers.Prefixed(ArtifactIdPrefix);

        if (!_artifactIds.Add(identity))
        {
            throw new CaptureJournalException(
                JournalErrorKind.DuplicateArtifact,
                "Capture journal artifact already reserved: " + identity);
        }

        var entry = new ArtifactEntry
        {
            ReservationId = Identifiers.Prefixed(ArtifactReservationIdPrefix),
            ArtifactId = identity,
            Status = ArtifactStatus.Pending,
        };

        if (_artifactsByReservationId.ContainsKey(entry.ReservationId)
            || _reservationsById.ContainsKey(entry.ReservationId))
        {
            throw JournalJson.Corrupt("working artifact reservation identity collision");
        }

        document.Artifacts.Add(entry);
        _artifactsByReservationId[entry.ReservationId] = entry;

        // Durable before the caller learns the artifact identity, for the same reason a stream
        // position is: a reservation nobody can see is a reservation recovery cannot account for.
        AppendWal(JournalMutation.AppendArtifact(entry));

        return new ArtifactReservationToken(
            entry.ReservationId,
            document.ArchiveId,
            document.CaptureId,
            entry.ArtifactId);
    }

    /// <summary>
    /// Hashes <paramref name="bytes"/>, writes them content-addressed into the draft, and resolves
    /// the reservation to the canonical document <paramref name="document"/> builds around them.
    /// </summary>
    /// <param name="token">The whole reservation token, as returned by <see cref="ReserveArtifact"/>.</param>
    /// <param name="bytes">The artifact payload. Hashed here; never interpreted.</param>
    /// <param name="document">
    /// Builds the canonical artifact document from the fingerprint of the bytes. The journal stays
    /// out of the archive's document contract exactly as it does for observations — it hands over
    /// what it measured and stores what it is given.
    /// </param>
    /// <returns>The artifact document as persisted.</returns>
    /// <remarks>
    /// The order is the guarantee. The document — which carries the digest of the bytes it claims —
    /// is persisted as an intent first, the bytes reach the draft second, and only then does the
    /// token resolve. A process killed anywhere in that window leaves either a reservation whose
    /// promised blob is absent, which recovery discards because it never became evidence, or a blob
    /// that is byte-for-byte what the document says it is.
    /// </remarks>
    public JsonObject IngestArtifact(
        ArtifactReservationToken token,
        ReadOnlyMemory<byte> bytes,
        Func<ArtifactFingerprint, JsonObject> document)
    {
        ArgumentNullException.ThrowIfNull(token);
        ArgumentNullException.ThrowIfNull(document);

        JournalCheckpoint checkpoint = RequireResolutionLifecycle();
        ArtifactEntry entry = LocateArtifact(checkpoint, token);

        ArtifactFingerprint fingerprint = ArtifactFingerprint.ForBytes(bytes.Span);
        JsonObject built = (document(fingerprint)
                ?? throw new ArgumentException("Artifact document factory returned null.", nameof(document)))
            .DeepClone()
            .AsObject();
        RequireDescribes(built, fingerprint, token);

        string digest = JsonCanonicalizer.Sha256Hex(built);
        if (entry.Status == ArtifactStatus.Artifact)
        {
            if (!string.Equals(entry.DocumentDigest, digest, StringComparison.Ordinal))
            {
                throw ArtifactConflict(token);
            }

            return entry.Document!.DeepClone().AsObject();
        }

        if (entry.Status == ArtifactStatus.ResolvingArtifact
            && !string.Equals(entry.DocumentDigest, digest, StringComparison.Ordinal))
        {
            throw ArtifactConflict(token);
        }

        entry.Status = ArtifactStatus.ResolvingArtifact;
        entry.Document = built;
        entry.DocumentDigest = digest;
        AppendWal(JournalMutation.UpdateArtifact(entry));

        PublishBlob(fingerprint, bytes.Span);
        ResolveArtifact(token, built);
        return built.DeepClone().AsObject();
    }

    /// <summary>
    /// Resolves an artifact reservation to exactly one canonical document, after proving the bytes
    /// it describes are already content-addressed in the draft. Re-resolving with the same canonical
    /// digest is a no-op; a different digest is a conflict.
    /// </summary>
    /// <exception cref="CaptureJournalException">
    /// The reservation is unknown, already carries different evidence, or the draft does not hold
    /// the bytes the document claims.
    /// </exception>
    public void ResolveArtifact(ArtifactReservationToken token, JsonObject artifact)
    {
        ArgumentNullException.ThrowIfNull(token);
        ArgumentNullException.ThrowIfNull(artifact);

        JournalCheckpoint checkpoint = RequireResolutionLifecycle();
        ArtifactEntry entry = LocateArtifact(checkpoint, token);
        JsonObject stored = artifact.DeepClone().AsObject();
        string digest = JsonCanonicalizer.Sha256Hex(stored);

        if (entry.Status == ArtifactStatus.Artifact)
        {
            if (!string.Equals(entry.DocumentDigest, digest, StringComparison.Ordinal))
            {
                throw ArtifactConflict(token);
            }

            return;
        }

        if (entry.Status == ArtifactStatus.ResolvingArtifact
            && !string.Equals(entry.DocumentDigest, digest, StringComparison.Ordinal))
        {
            throw ArtifactConflict(token);
        }

        // The resolution is the claim that this artifact exists, so it is refused unless the bytes
        // behind the claim are already on disk and still hash to what the document says.
        RequireDraftBlob(stored, token);

        entry.Status = ArtifactStatus.Artifact;
        entry.Document = stored;
        entry.DocumentDigest = digest;
        AppendWal(JournalMutation.UpdateArtifact(entry));
    }

    /// <summary>Stops admitting reservations; outstanding ones may still resolve.</summary>
    public void CloseInput() => Transition(JournalLifecycle.Recording, JournalLifecycle.ClosingInput);

    /// <summary>Enters the last window before the commit gate.</summary>
    public void BeginDraining() => Transition(JournalLifecycle.ClosingInput, JournalLifecycle.Draining);

    /// <summary>
    /// Produces the capture commit. Refuses unresolved reservations and streams without a single
    /// observation, persists the commit intent before deriving anything, and never waits for the
    /// network.
    /// </summary>
    /// <param name="endedAt">Session and commit end timestamp.</param>
    public CommitResult Commit(string endedAt)
    {
        ArgumentException.ThrowIfNullOrEmpty(endedAt);

        JournalCheckpoint document = RequireLifecycle(JournalLifecycle.Draining, JournalLifecycle.Committed);
        RequireComplete(document);

        if (document.CommitIntent is { } existing)
        {
            if (!string.Equals(existing.EndedAt, endedAt, StringComparison.Ordinal))
            {
                throw new CaptureJournalException(
                    JournalErrorKind.CompletionConflict,
                    "Capture journal commit intent conflicts: persisted endedAt " + existing.EndedAt + ".");
            }
        }
        else
        {
            document.CommitIntent = new CommitIntent(endedAt, JournalSessionStatus.Closed);
            AppendWal(JournalMutation.ForCommitIntent(document.CommitIntent));
        }

        return CompleteCommit(document);
    }

    /// <summary>
    /// Closes a capture that its producer never finished. Every reservation that never reached
    /// evidence becomes an explicit <see cref="GapReasons.RecoveryTruncation"/> gap; nothing is
    /// invented and no sequence moves. A commit intent that survived the crash is honoured rather
    /// than replaced, so a kill after the intent still produces the commit that was decided.
    /// </summary>
    /// <remarks>
    /// An artifact reservation whose bytes never landed is discarded instead of becoming a gap. A
    /// gap is a claim about a position on the stream that carries no observation; an artifact has no
    /// position, and one that never reached the draft is not missing evidence but evidence that
    /// never existed. Any observation that cited it would still be pending and therefore becomes a
    /// gap, so no record is left pointing at it.
    /// </remarks>
    /// <param name="endedAt">End timestamp to use when no commit intent survived.</param>
    public CommitResult RecoverInterrupted(string endedAt)
    {
        ArgumentException.ThrowIfNullOrEmpty(endedAt);

        JournalCheckpoint document = Document;
        RequireHealthy();

        if (document.Lifecycle == JournalLifecycle.Committed)
        {
            throw InvalidTransition(document.Lifecycle, JournalLifecycle.Committed);
        }

        foreach (ReservationEntry entry in document.Streams.SelectMany(stream => stream.Reservations))
        {
            if (entry.Status is not (ReservationStatus.Pending or ReservationStatus.ResolvingObservation))
            {
                continue;
            }

            entry.Status = ReservationStatus.Gap;
            entry.Record = null;
            entry.RecordDigest = null;
            entry.Gap = new GapEntry(
                entry.StreamId,
                entry.StreamSequence,
                entry.StreamSequence,
                GapReasons.RecoveryTruncation,
                RecoveryTruncationDetail);
        }

        document.Artifacts.RemoveAll(artifact => artifact.Status != ArtifactStatus.Artifact);
        RebuildIndex();

        document.Lifecycle = JournalLifecycle.Draining;
        document.CommitIntent ??= new CommitIntent(endedAt, JournalSessionStatus.Recovered);
        RequireComplete(document);

        // Recovery rewrites the whole snapshot: the lifecycle jump and the bulk gap conversion are
        // not expressible as incremental mutations of the log that is being superseded.
        WriteCheckpoint(document);
        return CompleteCommit(document);
    }

    private JournalCheckpoint Document => _document
        ?? throw new CaptureJournalException(
            _poisoned ? JournalErrorKind.WriterPoisoned : JournalErrorKind.NoActiveCapture,
            _poisoned
                ? "Capture journal writer is fenced after a durability failure."
                : "No active capture journal.");

    private CommitResult CompleteCommit(JournalCheckpoint document)
    {
        CommitIntent intent = document.CommitIntent
            ?? throw JournalJson.Corrupt("missing commit intent");

        CommitResult result = BuildCommitResult(document, intent);
        document.Lifecycle = JournalLifecycle.Committed;
        WriteCheckpoint(document);
        return result;
    }

    private CommitResult BuildCommitResult(JournalCheckpoint document, CommitIntent intent)
    {
        var records = new List<JsonObject>();
        var gaps = new List<GapEntry>();
        var summaries = new List<StreamSummary>();
        List<CommittedArtifact> artifacts = document.Artifacts
            .OrderBy(artifact => artifact.ArtifactId, StringComparer.Ordinal)
            .Select(artifact => new CommittedArtifact(
                artifact.Document!.DeepClone().AsObject(),
                DraftBlobPath(artifact.ContentPath)))
            .ToList();

        foreach (StreamLedger stream in document.Streams.OrderBy(stream => stream.StreamId, StringComparer.Ordinal))
        {
            List<ReservationEntry> ordered = stream.Reservations
                .OrderBy(reservation => reservation.StreamSequence)
                .ToList();

            int observationCount = 0;
            foreach (ReservationEntry entry in ordered)
            {
                if (entry.Status == ReservationStatus.Observation)
                {
                    records.Add(entry.Record!.DeepClone().AsObject());
                    observationCount++;
                }
                else
                {
                    gaps.Add(entry.Gap!);
                }
            }

            summaries.Add(new StreamSummary(
                stream.StreamId,
                ordered[0].StreamSequence,
                ordered[^1].StreamSequence,
                observationCount));
        }

        return new CommitResult(
            document.ArchiveId,
            document.CaptureId,
            intent.EndedAt,
            intent.Status,
            records,
            CoalesceGaps(gaps),
            summaries,
            artifacts);
    }

    /// <summary>
    /// Merges runs that touch and agree. The capture commit carries intervals, so two adjacent
    /// single-position gaps with the same reason and detail must arrive as one interval.
    /// </summary>
    private static IReadOnlyList<GapEntry> CoalesceGaps(IEnumerable<GapEntry> gaps)
    {
        var result = new List<GapEntry>();

        foreach (GapEntry gap in gaps
            .OrderBy(gap => gap.StreamId, StringComparer.Ordinal)
            .ThenBy(gap => gap.FirstSequence)
            .ThenBy(gap => gap.LastSequence))
        {
            if (result.Count > 0
                && result[^1] is { } previous
                && string.Equals(previous.StreamId, gap.StreamId, StringComparison.Ordinal)
                && string.Equals(previous.Reason, gap.Reason, StringComparison.Ordinal)
                && string.Equals(previous.Detail, gap.Detail, StringComparison.Ordinal)
                && previous.LastSequence + 1 == gap.FirstSequence)
            {
                result[^1] = previous with { LastSequence = gap.LastSequence };
                continue;
            }

            result.Add(gap);
        }

        return result;
    }

    private static void RequireComplete(JournalCheckpoint document)
    {
        int pending = document.Streams
            .SelectMany(stream => stream.Reservations)
            .Count(reservation => reservation.Status is ReservationStatus.Pending or ReservationStatus.ResolvingObservation);
        int pendingArtifacts = document.Artifacts.Count(artifact => artifact.Status != ArtifactStatus.Artifact);

        if (pending > 0 || pendingArtifacts > 0)
        {
            throw new CaptureJournalException(
                JournalErrorKind.PendingWork,
                string.Format(
                    CultureInfo.InvariantCulture,
                    "Capture journal has {0} unresolved reservation(s) and {1} unresolved artifact(s).",
                    pending,
                    pendingArtifacts));
        }

        foreach (StreamLedger stream in document.Streams)
        {
            if (!stream.Reservations.Any(reservation => reservation.Status == ReservationStatus.Observation))
            {
                throw new CaptureJournalException(
                    JournalErrorKind.StreamHasNoObservation,
                    "Capture journal stream has no observation: " + stream.StreamId);
            }
        }
    }

    private ReservationEntry Locate(JournalCheckpoint document, ReservationToken token)
    {
        if (!string.Equals(token.ArchiveId, document.ArchiveId, StringComparison.Ordinal)
            || !string.Equals(token.CaptureId, document.CaptureId, StringComparison.Ordinal)
            || !_reservationsById.TryGetValue(token.ReservationId, out ReservationEntry? entry)
            || !string.Equals(entry.StreamId, token.StreamId, StringComparison.Ordinal)
            || entry.StreamSequence != token.StreamSequence)
        {
            throw new CaptureJournalException(
                JournalErrorKind.StaleReservation,
                "Stale capture journal reservation: " + token.ReservationId);
        }

        return entry;
    }

    private static CaptureJournalException Conflict(ReservationToken token) => new(
        JournalErrorKind.CompletionConflict,
        "Capture journal completion conflicts: " + token.ReservationId);

    private ArtifactEntry LocateArtifact(JournalCheckpoint document, ArtifactReservationToken token)
    {
        if (!string.Equals(token.ArchiveId, document.ArchiveId, StringComparison.Ordinal)
            || !string.Equals(token.CaptureId, document.CaptureId, StringComparison.Ordinal)
            || !_artifactsByReservationId.TryGetValue(token.ReservationId, out ArtifactEntry? entry)
            || !string.Equals(entry.ArtifactId, token.ArtifactId, StringComparison.Ordinal))
        {
            throw new CaptureJournalException(
                JournalErrorKind.StaleReservation,
                "Stale capture journal artifact reservation: " + token.ReservationId);
        }

        return entry;
    }

    private static CaptureJournalException ArtifactConflict(ArtifactReservationToken token) => new(
        JournalErrorKind.CompletionConflict,
        "Capture journal artifact completion conflicts: " + token.ReservationId);

    /// <summary>
    /// Refuses a document whose content block does not describe the bytes that were just hashed.
    /// The document is the producer's claim about the payload; if the two disagree the archive would
    /// publish a digest nobody can reproduce.
    /// </summary>
    private static void RequireDescribes(
        JsonObject artifact,
        ArtifactFingerprint fingerprint,
        ArtifactReservationToken token)
    {
        JsonObject content = JournalJson.RequireObject(artifact, JournalKeys.Content);

        if (!string.Equals(JournalJson.RequireString(content, JournalKeys.Sha256), fingerprint.Sha256, StringComparison.Ordinal)
            || JournalJson.RequireLong(content, JournalKeys.ByteLength) != fingerprint.ByteLength
            || !string.Equals(JournalJson.RequireString(content, JournalKeys.Path), fingerprint.ContentPath, StringComparison.Ordinal))
        {
            throw new ArgumentException(
                "Artifact document does not describe the ingested bytes: " + token.ArtifactId,
                nameof(artifact));
        }
    }

    /// <summary>
    /// Proves the draft holds exactly the bytes <paramref name="artifact"/> claims. The digest is
    /// recomputed rather than trusted: this is the last point at which the producer can tell the
    /// difference between an artifact and a promise of one.
    /// </summary>
    private void RequireDraftBlob(JsonObject artifact, ArtifactReservationToken token)
    {
        JsonObject content = JournalJson.RequireObject(artifact, JournalKeys.Content);
        string digest = JournalJson.RequireString(content, JournalKeys.Sha256);
        long byteLength = JournalJson.RequireLong(content, JournalKeys.ByteLength);
        string relativePath = JournalJson.RequireString(content, JournalKeys.Path);
        string path = DraftBlobPath(relativePath);

        if (!string.Equals(relativePath, ArtifactFingerprint.BlobPath(digest), StringComparison.Ordinal))
        {
            throw new CaptureJournalException(
                JournalErrorKind.CompletionConflict,
                "Capture journal artifact is not content-addressed: " + token.ArtifactId);
        }

        if (!File.Exists(path)
            || new FileInfo(path).Length != byteLength
            || !string.Equals(Sha256File(path), digest, StringComparison.Ordinal))
        {
            throw new CaptureJournalException(
                JournalErrorKind.CompletionConflict,
                "Capture journal draft does not hold artifact bytes: " + token.ArtifactId);
        }
    }

    /// <summary>
    /// Publishes the bytes at their content-addressed path. Identical bytes reaching the draft twice
    /// is not a conflict — the path is the digest — so an existing blob of the right length is left
    /// alone rather than rewritten.
    /// </summary>
    private void PublishBlob(ArtifactFingerprint fingerprint, ReadOnlySpan<byte> bytes)
    {
        string path = DraftBlobPath(fingerprint.ContentPath);

        if (File.Exists(path))
        {
            if (new FileInfo(path).Length != fingerprint.ByteLength)
            {
                throw JournalJson.Corrupt("draft blob length disagrees with its digest: " + fingerprint.Sha256);
            }

            return;
        }

        Durability.WriteAtomic(path, bytes.ToArray());
        Durability.TryFlushDirectoryChain(Path.GetDirectoryName(path)!, _root);
    }

    /// <summary>Maps an archive-relative content path onto this journal's draft.</summary>
    private string DraftBlobPath(string contentPath) => Path.Combine(
        _draftDirectory,
        contentPath.Replace('/', Path.DirectorySeparatorChar));

    private static string Sha256File(string path)
    {
        using FileStream stream = new(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
    }

    private void Transition(JournalLifecycle expected, JournalLifecycle next)
    {
        JournalCheckpoint document = RequireLifecycle(expected, next);
        document.Lifecycle = next;
        AppendWal(JournalMutation.ForLifecycle(next));
    }

    private JournalCheckpoint RequireLifecycle(JournalLifecycle expected, JournalLifecycle next)
    {
        JournalCheckpoint document = Document;
        RequireHealthy();

        if (document.Lifecycle != expected)
        {
            throw InvalidTransition(document.Lifecycle, next);
        }

        return document;
    }

    private JournalCheckpoint RequireResolutionLifecycle()
    {
        JournalCheckpoint document = Document;
        RequireHealthy();

        if (document.Lifecycle is not (JournalLifecycle.Recording or JournalLifecycle.ClosingInput or JournalLifecycle.Draining))
        {
            throw InvalidTransition(document.Lifecycle, JournalLifecycle.Recording);
        }

        return document;
    }

    private void RequireHealthy()
    {
        if (_poisoned)
        {
            throw new CaptureJournalException(
                JournalErrorKind.WriterPoisoned,
                "Capture journal writer is fenced after a durability failure.");
        }
    }

    private static CaptureJournalException InvalidTransition(JournalLifecycle from, JournalLifecycle to) => new(
        JournalErrorKind.InvalidTransition,
        "Illegal capture journal transition " + from + " to " + to + ".");

    private void RebuildIndex()
    {
        _reservationsById.Clear();
        _artifactsByReservationId.Clear();
        _artifactIds.Clear();

        foreach (ReservationEntry entry in Document.Streams.SelectMany(stream => stream.Reservations))
        {
            if (!_reservationsById.TryAdd(entry.ReservationId, entry))
            {
                throw JournalJson.Corrupt("duplicate reservation identifier " + entry.ReservationId);
            }
        }

        foreach (ArtifactEntry entry in Document.Artifacts)
        {
            if (!_artifactsByReservationId.TryAdd(entry.ReservationId, entry)
                || _reservationsById.ContainsKey(entry.ReservationId)
                || !_artifactIds.Add(entry.ArtifactId))
            {
                throw JournalJson.Corrupt("duplicate artifact reservation " + entry.ReservationId);
            }
        }
    }

    /// <summary>
    /// Completes resolutions whose intent is on disk but whose acknowledgement never was. The
    /// record and its digest were persisted together with the intent, so promoting the entry
    /// re-establishes exactly the observation the producer had already handed over.
    /// </summary>
    private void ReconcileObservationIntents()
    {
        foreach (ReservationEntry entry in Document.Streams.SelectMany(stream => stream.Reservations))
        {
            if (entry.Status != ReservationStatus.ResolvingObservation)
            {
                continue;
            }

            if (entry.Record is null || entry.RecordDigest is null)
            {
                throw JournalJson.Corrupt("resolution intent without a record: " + entry.ReservationId);
            }

            entry.Status = ReservationStatus.Observation;
        }
    }

    /// <summary>
    /// Completes artifact ingests whose intent is on disk but whose acknowledgement never was. The
    /// intent carries the document, and the document carries the digest, so the question recovery
    /// has to answer is exactly "did those bytes reach the draft" — and the content-addressed layout
    /// makes that a file lookup. A reservation whose blob is absent is left unresolved: it never
    /// became evidence, and <see cref="RecoverInterrupted"/> discards it.
    /// </summary>
    private void ReconcileArtifactIntents()
    {
        foreach (ArtifactEntry entry in Document.Artifacts)
        {
            if (entry.Status != ArtifactStatus.ResolvingArtifact)
            {
                continue;
            }

            if (entry.Document is null || entry.DocumentDigest is null)
            {
                throw JournalJson.Corrupt("artifact intent without a document: " + entry.ReservationId);
            }

            string path = DraftBlobPath(entry.ContentPath);
            if (File.Exists(path)
                && new FileInfo(path).Length == entry.ContentByteLength
                && string.Equals(Sha256File(path), entry.ContentSha256, StringComparison.Ordinal))
            {
                entry.Status = ArtifactStatus.Artifact;
            }
        }
    }

    private void ValidateLedger(JournalCheckpoint document)
    {
        if (document.SchemaVersion != StateSchemaVersion)
        {
            throw JournalJson.Corrupt("unsupported state schema version " + document.SchemaVersion.ToString(CultureInfo.InvariantCulture));
        }

        if (!string.Equals(document.ArchiveId, ArchiveId, StringComparison.Ordinal))
        {
            throw JournalJson.Corrupt("archive identity mismatch");
        }

        if (document.Streams.Count == 0)
        {
            throw JournalJson.Corrupt("capture without a stream");
        }

        foreach (StreamLedger stream in document.Streams)
        {
            if (stream.NextSequence != stream.Reservations.Count)
            {
                throw JournalJson.Corrupt("stream sequence allocator disagrees with its ledger: " + stream.StreamId);
            }

            long expected = 0;
            foreach (ReservationEntry entry in stream.Reservations)
            {
                if (entry.StreamSequence != expected || !string.Equals(entry.StreamId, stream.StreamId, StringComparison.Ordinal))
                {
                    throw JournalJson.Corrupt("non-contiguous stream sequence at " + entry.StreamSequence.ToString(CultureInfo.InvariantCulture));
                }

                ValidateResolution(entry);
                expected++;
            }
        }

        foreach (ArtifactEntry entry in document.Artifacts)
        {
            ValidateArtifact(entry);
        }
    }

    private static void ValidateArtifact(ArtifactEntry entry)
    {
        if (entry.Status == ArtifactStatus.Pending)
        {
            if (entry.Document is not null || entry.DocumentDigest is not null)
            {
                throw JournalJson.Corrupt("pending artifact carries a document: " + entry.ReservationId);
            }

            return;
        }

        if (entry.Document is null || entry.DocumentDigest is null)
        {
            throw JournalJson.Corrupt("resolved artifact without a document: " + entry.ReservationId);
        }

        if (!string.Equals(JsonCanonicalizer.Sha256Hex(entry.Document), entry.DocumentDigest, StringComparison.Ordinal))
        {
            throw JournalJson.Corrupt("artifact document digest mismatch at " + entry.ReservationId);
        }

        if (!string.Equals(
            JournalJson.RequireString(entry.Document, JournalKeys.ArtifactId),
            entry.ArtifactId,
            StringComparison.Ordinal))
        {
            throw JournalJson.Corrupt("artifact document identity mismatch at " + entry.ReservationId);
        }
    }

    private static void ValidateResolution(ReservationEntry entry)
    {
        switch (entry.Status)
        {
            case ReservationStatus.Observation or ReservationStatus.ResolvingObservation:
                if (entry.Record is null || entry.RecordDigest is null)
                {
                    throw JournalJson.Corrupt("resolved observation without a record: " + entry.ReservationId);
                }

                if (!string.Equals(JsonCanonicalizer.Sha256Hex(entry.Record), entry.RecordDigest, StringComparison.Ordinal))
                {
                    throw JournalJson.Corrupt("record digest mismatch at " + entry.ReservationId);
                }

                return;

            case ReservationStatus.Gap:
                if (entry.Gap is null)
                {
                    throw JournalJson.Corrupt("resolved gap without an interval: " + entry.ReservationId);
                }

                if (!GapReasons.IsKnown(entry.Gap.Reason))
                {
                    throw JournalJson.Corrupt("unknown gap reason " + entry.Gap.Reason);
                }

                return;

            default:
                return;
        }
    }

    private JournalCheckpoint LoadAndReplay()
    {
        JsonObject stateDocument = JournalJson.ParseDocument(File.ReadAllText(_statePath, Utf8NoBom), _statePath);
        JournalCheckpoint checkpoint = JournalCheckpoint.FromJson(stateDocument);

        if (!string.Equals(checkpoint.ArchiveId, ArchiveId, StringComparison.Ordinal))
        {
            throw JournalJson.Corrupt("archive identity mismatch");
        }

        var index = new Dictionary<string, ReservationEntry>(StringComparer.Ordinal);
        foreach (ReservationEntry entry in checkpoint.Streams.SelectMany(stream => stream.Reservations))
        {
            index[entry.ReservationId] = entry;
        }

        var artifactIndex = new Dictionary<string, ArtifactEntry>(StringComparer.Ordinal);
        foreach (ArtifactEntry entry in checkpoint.Artifacts)
        {
            artifactIndex[entry.ReservationId] = entry;
        }

        long checkpointSequence = checkpoint.WalSequence;
        long expectedSequence = checkpointSequence;

        foreach (string path in WalSegmentPaths())
        {
            JournalSegment segment = JournalSegment.FromJson(
                JournalJson.ParseDocument(File.ReadAllText(path, Utf8NoBom), path));

            if (segment.SchemaVersion != WalSchemaVersion)
            {
                throw JournalJson.Corrupt(
                    "unsupported WAL schema version " + segment.SchemaVersion.ToString(CultureInfo.InvariantCulture));
            }

            if (segment.Sequence < checkpointSequence)
            {
                // Already folded into the checkpoint; retiring these files is reclamation only.
                continue;
            }

            if (segment.Sequence != expectedSequence
                || !string.Equals(Path.GetFileName(path), WalFileName(segment.Sequence), StringComparison.Ordinal))
            {
                throw JournalJson.Corrupt("non-contiguous WAL segment " + Path.GetFileName(path));
            }

            Apply(checkpoint, index, artifactIndex, segment.Mutation);
            expectedSequence++;
        }

        checkpoint.WalSequence = expectedSequence;
        _nextWalSequence = expectedSequence;
        return checkpoint;
    }

    private static void Apply(
        JournalCheckpoint checkpoint,
        Dictionary<string, ReservationEntry> index,
        Dictionary<string, ArtifactEntry> artifactIndex,
        JournalMutation mutation)
    {
        switch (mutation.Kind)
        {
            case JournalMutationKind.AppendReservation:
            {
                ReservationEntry entry = mutation.Reservation!;
                StreamLedger stream = checkpoint.Streams
                    .FirstOrDefault(candidate => string.Equals(candidate.StreamId, entry.StreamId, StringComparison.Ordinal))
                    ?? throw JournalJson.Corrupt("WAL reservation for unknown stream " + entry.StreamId);

                if (checkpoint.Lifecycle != JournalLifecycle.Recording
                    || entry.Status != ReservationStatus.Pending
                    || entry.StreamSequence != stream.NextSequence
                    || index.ContainsKey(entry.ReservationId))
                {
                    throw JournalJson.Corrupt("invalid WAL reservation append");
                }

                stream.Reservations.Add(entry);
                stream.NextSequence++;
                index[entry.ReservationId] = entry;
                return;
            }

            case JournalMutationKind.UpdateReservation:
            {
                ReservationEntry entry = mutation.Reservation!;
                if (!index.TryGetValue(entry.ReservationId, out ReservationEntry? previous)
                    || !string.Equals(previous.StreamId, entry.StreamId, StringComparison.Ordinal)
                    || previous.StreamSequence != entry.StreamSequence
                    || !IsLegalResolutionStep(previous.Status, entry.Status))
                {
                    throw JournalJson.Corrupt("invalid WAL reservation update");
                }

                ValidateResolution(entry);
                previous.Status = entry.Status;
                previous.Record = entry.Record;
                previous.RecordDigest = entry.RecordDigest;
                previous.Gap = entry.Gap;
                return;
            }

            case JournalMutationKind.AppendArtifact:
            {
                ArtifactEntry entry = mutation.Artifact!;
                if (checkpoint.Lifecycle != JournalLifecycle.Recording
                    || entry.Status != ArtifactStatus.Pending
                    || artifactIndex.ContainsKey(entry.ReservationId)
                    || index.ContainsKey(entry.ReservationId)
                    || checkpoint.Artifacts.Any(existing => string.Equals(
                        existing.ArtifactId,
                        entry.ArtifactId,
                        StringComparison.Ordinal)))
                {
                    throw JournalJson.Corrupt("invalid WAL artifact append");
                }

                checkpoint.Artifacts.Add(entry);
                artifactIndex[entry.ReservationId] = entry;
                return;
            }

            case JournalMutationKind.UpdateArtifact:
            {
                ArtifactEntry entry = mutation.Artifact!;
                if (!artifactIndex.TryGetValue(entry.ReservationId, out ArtifactEntry? previous)
                    || !string.Equals(previous.ArtifactId, entry.ArtifactId, StringComparison.Ordinal)
                    || !IsLegalArtifactStep(previous.Status, entry.Status))
                {
                    throw JournalJson.Corrupt("invalid WAL artifact update");
                }

                ValidateArtifact(entry);
                previous.Status = entry.Status;
                previous.Document = entry.Document;
                previous.DocumentDigest = entry.DocumentDigest;
                return;
            }

            case JournalMutationKind.Lifecycle:
            {
                JournalLifecycle next = mutation.Lifecycle!.Value;
                JournalLifecycle? expected = checkpoint.Lifecycle switch
                {
                    JournalLifecycle.Recording => JournalLifecycle.ClosingInput,
                    JournalLifecycle.ClosingInput => JournalLifecycle.Draining,
                    _ => null,
                };

                if (next != expected)
                {
                    throw JournalJson.Corrupt("invalid WAL lifecycle transition");
                }

                checkpoint.Lifecycle = next;
                return;
            }

            default:
            {
                if (checkpoint.Lifecycle != JournalLifecycle.Draining || checkpoint.CommitIntent is not null)
                {
                    throw JournalJson.Corrupt("invalid WAL commit intent");
                }

                checkpoint.CommitIntent = mutation.CommitIntent;
                return;
            }
        }
    }

    private static bool IsLegalResolutionStep(ReservationStatus from, ReservationStatus to) => (from, to) switch
    {
        (ReservationStatus.Pending, ReservationStatus.ResolvingObservation) => true,
        (ReservationStatus.Pending, ReservationStatus.Gap) => true,
        (ReservationStatus.ResolvingObservation, ReservationStatus.Observation) => true,
        _ => false,
    };

    /// <summary>
    /// An artifact resolution only ever moves forward. The intent may be repeated — an ingest
    /// retried after a failed blob write replays it with the identical document — but a resolved
    /// artifact never steps back to a promise.
    /// </summary>
    private static bool IsLegalArtifactStep(ArtifactStatus from, ArtifactStatus to) => (from, to) switch
    {
        (ArtifactStatus.Pending, ArtifactStatus.ResolvingArtifact) => true,
        (ArtifactStatus.Pending, ArtifactStatus.Artifact) => true,
        (ArtifactStatus.ResolvingArtifact, ArtifactStatus.ResolvingArtifact) => true,
        (ArtifactStatus.ResolvingArtifact, ArtifactStatus.Artifact) => true,
        _ => false,
    };

    private IEnumerable<string> WalSegmentPaths()
    {
        if (!Directory.Exists(_walDirectory))
        {
            return Array.Empty<string>();
        }

        return Directory.GetFiles(_walDirectory, WalSearchPattern)
            .Where(path => !path.EndsWith(Durability.TemporaryFileSuffix, StringComparison.Ordinal))
            .OrderBy(path => Path.GetFileName(path), StringComparer.Ordinal)
            .ToArray();
    }

    private void AppendWal(JournalMutation mutation)
    {
        var segment = new JournalSegment(WalSchemaVersion, _nextWalSequence, mutation);
        string path = Path.Combine(_walDirectory, WalFileName(_nextWalSequence));

        try
        {
            if (File.Exists(path))
            {
                throw JournalJson.Corrupt("WAL sequence already exists " + _nextWalSequence.ToString(CultureInfo.InvariantCulture));
            }

            Durability.WriteAtomic(path, Utf8NoBom.GetBytes(JournalJson.Canonical(segment.ToJson())));
            Durability.TryFlushDirectoryChain(_walDirectory, _root);
        }
        catch
        {
            // A failed append has an unknown outcome on disk. Fence the writer so a retry cannot
            // hand the same stream sequence to a second producer over a segment recovery may see.
            Poison();
            throw;
        }

        _nextWalSequence++;
    }

    private void WriteCheckpoint(JournalCheckpoint document)
    {
        document.WalSequence = _nextWalSequence;

        try
        {
            Durability.ReplaceAtomic(_statePath, Utf8NoBom.GetBytes(JournalJson.Canonical(document.ToJson())));
            FlushClaimChain();
        }
        catch
        {
            Poison();
            throw;
        }

        RetireWalSegments(document.WalSequence);
    }

    /// <summary>
    /// Deletes segments the checkpoint already contains. Replay skips anything numbered below the
    /// checkpoint, so this is storage reclamation and never a commit point.
    /// </summary>
    private void RetireWalSegments(long checkpointSequence)
    {
        foreach (string path in WalSegmentPaths())
        {
            string name = Path.GetFileNameWithoutExtension(path);
            if (!long.TryParse(name, NumberStyles.None, CultureInfo.InvariantCulture, out long sequence)
                || sequence >= checkpointSequence)
            {
                continue;
            }

            try
            {
                File.Delete(path);
            }
            catch (IOException)
            {
                // Reclamation only; a retained segment is skipped on replay.
            }
            catch (UnauthorizedAccessException)
            {
                // Same reasoning.
            }
        }
    }

    private void FlushClaimChain() => Durability.TryFlushDirectoryChain(_stateDirectory, _root);

    private void Poison()
    {
        _poisoned = true;
        _document = null;
        _reservationsById.Clear();
    }

    private static string WalFileName(long sequence) =>
        sequence.ToString(WalFileNameFormat, CultureInfo.InvariantCulture) + WalFileExtension;

    /// <summary>
    /// Rejects identifiers that are not usable as a single directory name. The archive identifier
    /// reaches the filesystem verbatim, so path separators, traversal segments and empty names must
    /// never get that far.
    /// </summary>
    private static void ValidateDirectoryNameIdentifier(string value, string parameterName)
    {
        ArgumentException.ThrowIfNullOrEmpty(value, parameterName);

        if (value is "." or ".." || !SafeIdentifierPattern.IsMatch(value))
        {
            throw new ArgumentException(
                "Identifier '" + value + "' is not a safe directory name.",
                parameterName);
        }
    }
}
