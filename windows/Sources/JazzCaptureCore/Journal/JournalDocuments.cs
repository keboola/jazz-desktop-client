using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json.Nodes;
using JazzCaptureCore.Json;

namespace JazzCaptureCore.Journal;

/// <summary>
/// Producer lifecycle of one capture. New work is admitted only in <see cref="Recording"/>;
/// already admitted work may still finish while closing or draining.
/// </summary>
public enum JournalLifecycle
{
    /// <summary>No capture claimed.</summary>
    Idle,

    /// <summary>The archive identity is claimed on disk but capture has not started.</summary>
    Starting,

    /// <summary>Reservations are admitted.</summary>
    Recording,

    /// <summary>No new reservations; outstanding ones may still resolve.</summary>
    ClosingInput,

    /// <summary>Waiting for the last reservations before the commit gate.</summary>
    Draining,

    /// <summary>The capture commit has been produced; the journal is read-only.</summary>
    Committed,
}

/// <summary>Session status carried into the capture commit.</summary>
public static class JournalSessionStatus
{
    /// <summary>The producer finished the capture itself.</summary>
    public const string Closed = "closed";

    /// <summary>The capture was completed by crash recovery rather than by the producer.</summary>
    public const string Recovered = "recovered";
}

/// <summary>Gap reasons accepted by the capture commit schema (ANNEX-ARCHIVE section 4.2).</summary>
public static class GapReasons
{
    /// <summary>Evidence was produced but could not be captured.</summary>
    public const string CaptureLoss = "capture_loss";

    /// <summary>The operating system refused the capture.</summary>
    public const string PermissionDenied = "permission_denied";

    /// <summary>The capture source stopped responding.</summary>
    public const string SourceUnavailable = "source_unavailable";

    /// <summary>The producer queue overflowed.</summary>
    public const string BufferOverflow = "buffer_overflow";

    /// <summary>The producer was terminated before it resolved the reservation.</summary>
    public const string RecoveryTruncation = "recovery_truncation";

    /// <summary>The position was deliberately left without evidence.</summary>
    public const string IntentionallyOmitted = "intentionally_omitted";

    /// <summary>No reason could be determined.</summary>
    public const string Unknown = "unknown";

    private static readonly HashSet<string> Known = new(StringComparer.Ordinal)
    {
        CaptureLoss,
        PermissionDenied,
        SourceUnavailable,
        BufferOverflow,
        RecoveryTruncation,
        IntentionallyOmitted,
        Unknown,
    };

    /// <summary>All reasons the capture commit schema accepts, in schema order.</summary>
    public static IReadOnlyList<string> All { get; } = new[]
    {
        CaptureLoss,
        PermissionDenied,
        SourceUnavailable,
        BufferOverflow,
        RecoveryTruncation,
        IntentionallyOmitted,
        Unknown,
    };

    /// <summary>Whether <paramref name="reason"/> is one of the schema's enumerated reasons.</summary>
    public static bool IsKnown(string? reason) => reason is not null && Known.Contains(reason);
}

/// <summary>
/// Whole-token identity of one admitted producer slot. Every completion presents the entire token
/// so a late callback from a previous capture generation can never resolve current work.
/// </summary>
/// <param name="ReservationId">Working identifier, unique within the journal.</param>
/// <param name="ArchiveId">Archive the reservation belongs to.</param>
/// <param name="CaptureId">Capture the reservation belongs to.</param>
/// <param name="StreamId">Stream the sequence was allocated on.</param>
/// <param name="StreamSequence">Allocated position; never reused, never shifted.</param>
public sealed record ReservationToken(
    string ReservationId,
    string ArchiveId,
    string CaptureId,
    string StreamId,
    long StreamSequence);

/// <summary>
/// Whole-token identity of one admitted artifact reservation. Artifacts occupy no stream position —
/// they are referenced by the observations that cite them — so the token carries the artifact
/// identity instead of a sequence, and presenting the whole token still keeps a late callback from
/// a previous capture generation out of current work.
/// </summary>
/// <param name="ReservationId">Working identifier, unique within the journal.</param>
/// <param name="ArchiveId">Archive the reservation belongs to.</param>
/// <param name="CaptureId">Capture the reservation belongs to.</param>
/// <param name="ArtifactId">Identity the artifact will carry in the archive.</param>
public sealed record ArtifactReservationToken(
    string ReservationId,
    string ArchiveId,
    string CaptureId,
    string ArtifactId);

/// <summary>
/// What one artifact's bytes hash to, and where they live inside an archive.
/// </summary>
/// <remarks>
/// The layout is content-addressed by construction: the file name <em>is</em> the digest, which is
/// what lets the same bytes be stored once and lets the contract validator check the two against
/// each other without trusting any metadata.
/// </remarks>
/// <param name="Sha256">Lowercase hex SHA-256 of the bytes.</param>
/// <param name="ByteLength">Length of the bytes.</param>
/// <param name="ContentPath">POSIX-relative path inside the archive; the artifact's <c>content.path</c>.</param>
public sealed record ArtifactFingerprint(string Sha256, long ByteLength, string ContentPath)
{
    /// <summary>Root directory of the content-addressed blob store inside an archive.</summary>
    public const string BlobsDirectoryName = "blobs";

    private const string BlobPathPrefix = BlobsDirectoryName + "/sha256/";
    private const int FanOutLength = 2;

    /// <summary>
    /// The archive-relative path of the blob holding <paramref name="sha256"/>:
    /// <c>blobs/sha256/&lt;first two hex&gt;/&lt;full digest&gt;</c> (ANNEX-ARCHIVE section 2.2).
    /// </summary>
    public static string BlobPath(string sha256)
    {
        RequireDigest(sha256);
        return BlobPathPrefix + sha256[..FanOutLength] + "/" + sha256;
    }

    /// <summary>Hashes <paramref name="bytes"/> and derives the blob path they belong at.</summary>
    public static ArtifactFingerprint ForBytes(ReadOnlySpan<byte> bytes)
    {
        string digest = Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
        return new ArtifactFingerprint(digest, bytes.Length, BlobPath(digest));
    }

    /// <summary>Rejects anything that is not a lowercase hex SHA-256.</summary>
    public static void RequireDigest(string sha256)
    {
        ArgumentException.ThrowIfNullOrEmpty(sha256);

        if (sha256.Length != 64 || !sha256.All(character => character is (>= '0' and <= '9') or (>= 'a' and <= 'f')))
        {
            throw new ArgumentException("'" + sha256 + "' is not a lowercase hex SHA-256.", nameof(sha256));
        }
    }
}

/// <summary>
/// One artifact the capture committed: its canonical document, and the file in the journal draft
/// that holds the bytes the document describes.
/// </summary>
/// <param name="Document">The canonical artifact document, exactly as the producer built it.</param>
/// <param name="SourcePath">
/// Absolute path of the content-addressed blob in the journal draft. The archive writer copies it
/// to <c>content.path</c> inside the archive; the journal keeps owning the original until then.
/// </param>
public sealed record CommittedArtifact(JsonObject Document, string SourcePath);

/// <summary>
/// A contiguous run of stream positions that carry no observation. Adjacent runs sharing stream,
/// reason and detail are coalesced before they reach the capture commit.
/// </summary>
public sealed record GapEntry(
    string StreamId,
    long FirstSequence,
    long LastSequence,
    string Reason,
    string? Detail);

/// <summary>
/// Per-stream commit summary. <c>observationCount</c> plus the lengths of the stream's gaps always
/// equals <c>lastSequence - firstSequence + 1</c>.
/// </summary>
public sealed record StreamSummary(
    string StreamId,
    long FirstSequence,
    long LastSequence,
    int ObservationCount);

/// <summary>
/// Everything the archive writer needs to emit <c>commit.json</c>, <c>records.ndjson</c> and the
/// session document without recomputing journal state.
/// </summary>
/// <param name="ArchiveId">Archive the commit belongs to.</param>
/// <param name="CaptureId">Capture the commit belongs to.</param>
/// <param name="EndedAt">Commit and session end timestamp.</param>
/// <param name="Status">One of <see cref="JournalSessionStatus"/>.</param>
/// <param name="Records">Observations ordered by stream identifier then stream sequence.</param>
/// <param name="Gaps">Coalesced gaps ordered by stream identifier then first sequence.</param>
/// <param name="StreamSummaries">One summary per stream, ordered by stream identifier.</param>
/// <param name="Artifacts">
/// Resolved artifacts ordered by artifact identifier, each paired with the draft blob holding its
/// bytes. Ordered here because that is the order the commit's <c>artifactSetDigest</c> hashes.
/// </param>
public sealed record CommitResult(
    string ArchiveId,
    string CaptureId,
    string EndedAt,
    string Status,
    IReadOnlyList<JsonObject> Records,
    IReadOnlyList<GapEntry> Gaps,
    IReadOnlyList<StreamSummary> StreamSummaries,
    IReadOnlyList<CommittedArtifact> Artifacts);

/// <summary>Failure classes of <see cref="CaptureJournal"/>, stable enough to branch on.</summary>
public enum JournalErrorKind
{
    /// <summary>The journal has no loaded capture document.</summary>
    NoActiveCapture,

    /// <summary>Another producer already claimed the archive identifier.</summary>
    ArchiveAlreadyClaimed,

    /// <summary>No checkpoint exists for the archive identifier.</summary>
    StateNotFound,

    /// <summary>The checkpoint or write-ahead log is unusable.</summary>
    CorruptState,

    /// <summary>The requested operation is not legal in the current lifecycle.</summary>
    InvalidTransition,

    /// <summary>The presented token does not match an admitted reservation.</summary>
    StaleReservation,

    /// <summary>A resolution intent for the reservation is already persisted.</summary>
    CompletionInProgress,

    /// <summary>The reservation was already resolved with different evidence.</summary>
    CompletionConflict,

    /// <summary>Commit was attempted while reservations were still unresolved.</summary>
    PendingWork,

    /// <summary>A stream reached the commit gate without a single observation.</summary>
    StreamHasNoObservation,

    /// <summary>An artifact identity was reserved twice within the same capture.</summary>
    DuplicateArtifact,

    /// <summary>A durability failure fenced the writer; the process must not keep recording.</summary>
    WriterPoisoned,
}

/// <summary>Error raised by <see cref="CaptureJournal"/>.</summary>
public sealed class CaptureJournalException : InvalidOperationException
{
    /// <summary>Creates an error of the given kind.</summary>
    public CaptureJournalException(JournalErrorKind kind, string message)
        : base(message) => Kind = kind;

    /// <summary>Creates an error of the given kind wrapping a lower level failure.</summary>
    public CaptureJournalException(JournalErrorKind kind, string message, Exception innerException)
        : base(message, innerException) => Kind = kind;

    /// <summary>Failure class of this error.</summary>
    public JournalErrorKind Kind { get; }
}

/// <summary>Resolution state of a reservation inside the journal ledger.</summary>
internal enum ReservationStatus
{
    /// <summary>Admitted; no evidence yet.</summary>
    Pending,

    /// <summary>Write-ahead intent persisted; the record store has not acknowledged it yet.</summary>
    ResolvingObservation,

    /// <summary>Resolved to exactly one canonical observation.</summary>
    Observation,

    /// <summary>Resolved to an explicit absence of evidence.</summary>
    Gap,
}

/// <summary>One admitted stream position and its resolution.</summary>
internal sealed class ReservationEntry
{
    public required string ReservationId { get; init; }

    public required string StreamId { get; init; }

    public required long StreamSequence { get; init; }

    public ReservationStatus Status { get; set; }

    /// <summary>The canonical observation; present from the write-ahead intent onwards.</summary>
    public JsonObject? Record { get; set; }

    /// <summary>SHA-256 of the RFC 8785 canonical form of <see cref="Record"/>.</summary>
    public string? RecordDigest { get; set; }

    public GapEntry? Gap { get; set; }

    public JsonObject ToJson()
    {
        var value = new JsonObject
        {
            [JournalKeys.ReservationId] = ReservationId,
            [JournalKeys.StreamId] = StreamId,
            [JournalKeys.StreamSequence] = StreamSequence,
            [JournalKeys.Status] = JournalTokens.From(Status),
        };

        if (Record is not null)
        {
            value[JournalKeys.Record] = Record.DeepClone();
        }

        if (RecordDigest is not null)
        {
            value[JournalKeys.RecordDigest] = RecordDigest;
        }

        if (Gap is not null)
        {
            value[JournalKeys.Gap] = JournalJson.GapToJson(Gap);
        }

        return value;
    }

    public static ReservationEntry FromJson(JsonObject value) => new()
    {
        ReservationId = JournalJson.RequireString(value, JournalKeys.ReservationId),
        StreamId = JournalJson.RequireString(value, JournalKeys.StreamId),
        StreamSequence = JournalJson.RequireLong(value, JournalKeys.StreamSequence),
        Status = JournalTokens.ToStatus(JournalJson.RequireString(value, JournalKeys.Status)),
        Record = JournalJson.OptionalObject(value, JournalKeys.Record),
        RecordDigest = JournalJson.OptionalString(value, JournalKeys.RecordDigest),
        Gap = JournalJson.OptionalObject(value, JournalKeys.Gap) is { } gap
            ? JournalJson.GapFromJson(gap)
            : null,
    };
}

/// <summary>Resolution state of an artifact reservation inside the journal ledger.</summary>
internal enum ArtifactStatus
{
    /// <summary>Admitted; neither metadata nor bytes exist yet.</summary>
    Pending,

    /// <summary>
    /// Write-ahead intent persisted: the canonical document — and therefore the digest of the bytes
    /// it claims — is durable, but the bytes themselves may not have reached the draft yet.
    /// </summary>
    ResolvingArtifact,

    /// <summary>Resolved: the bytes are content-addressed in the draft and the document is final.</summary>
    Artifact,
}

/// <summary>One admitted artifact reservation and its resolution.</summary>
internal sealed class ArtifactEntry
{
    public required string ReservationId { get; init; }

    public required string ArtifactId { get; init; }

    public ArtifactStatus Status { get; set; }

    /// <summary>The canonical artifact document; present from the write-ahead intent onwards.</summary>
    public JsonObject? Document { get; set; }

    /// <summary>SHA-256 of the RFC 8785 canonical form of <see cref="Document"/>.</summary>
    public string? DocumentDigest { get; set; }

    /// <summary>The digest of the bytes, read back out of the document's content block.</summary>
    public string ContentSha256 => JournalJson.RequireString(
        JournalJson.RequireObject(
            Document ?? throw JournalJson.Corrupt("artifact without a document: " + ReservationId),
            JournalKeys.Content),
        JournalKeys.Sha256);

    /// <summary>The byte length of the bytes, read back out of the document's content block.</summary>
    public long ContentByteLength => JournalJson.RequireLong(
        JournalJson.RequireObject(
            Document ?? throw JournalJson.Corrupt("artifact without a document: " + ReservationId),
            JournalKeys.Content),
        JournalKeys.ByteLength);

    /// <summary>The archive-relative blob path, read back out of the document's content block.</summary>
    public string ContentPath => JournalJson.RequireString(
        JournalJson.RequireObject(
            Document ?? throw JournalJson.Corrupt("artifact without a document: " + ReservationId),
            JournalKeys.Content),
        JournalKeys.Path);

    public JsonObject ToJson()
    {
        var value = new JsonObject
        {
            [JournalKeys.ReservationId] = ReservationId,
            [JournalKeys.ArtifactId] = ArtifactId,
            [JournalKeys.Status] = JournalTokens.From(Status),
        };

        if (Document is not null)
        {
            value[JournalKeys.Document] = Document.DeepClone();
        }

        if (DocumentDigest is not null)
        {
            value[JournalKeys.DocumentDigest] = DocumentDigest;
        }

        return value;
    }

    public static ArtifactEntry FromJson(JsonObject value) => new()
    {
        ReservationId = JournalJson.RequireString(value, JournalKeys.ReservationId),
        ArtifactId = JournalJson.RequireString(value, JournalKeys.ArtifactId),
        Status = JournalTokens.ToArtifactStatus(JournalJson.RequireString(value, JournalKeys.Status)),
        Document = JournalJson.OptionalObject(value, JournalKeys.Document),
        DocumentDigest = JournalJson.OptionalString(value, JournalKeys.DocumentDigest),
    };
}

/// <summary>Per-stream sequence allocator and reservation ledger.</summary>
internal sealed class StreamLedger
{
    public required string StreamId { get; init; }

    public long NextSequence { get; set; }

    public List<ReservationEntry> Reservations { get; } = new();

    public JsonObject ToJson()
    {
        var reservations = new JsonArray();
        foreach (ReservationEntry reservation in Reservations)
        {
            reservations.Add(reservation.ToJson());
        }

        return new JsonObject
        {
            [JournalKeys.StreamId] = StreamId,
            [JournalKeys.NextSequence] = NextSequence,
            [JournalKeys.Reservations] = reservations,
        };
    }

    public static StreamLedger FromJson(JsonObject value)
    {
        var ledger = new StreamLedger
        {
            StreamId = JournalJson.RequireString(value, JournalKeys.StreamId),
            NextSequence = JournalJson.RequireLong(value, JournalKeys.NextSequence),
        };

        foreach (JsonNode? element in JournalJson.RequireArray(value, JournalKeys.Reservations))
        {
            ledger.Reservations.Add(ReservationEntry.FromJson(JournalJson.RequireElementObject(element)));
        }

        return ledger;
    }
}

/// <summary>Durable statement that a commit was decided, persisted before any archive document.</summary>
internal sealed record CommitIntent(string EndedAt, string Status)
{
    public JsonObject ToJson() => new()
    {
        [JournalKeys.EndedAt] = EndedAt,
        [JournalKeys.Status] = Status,
    };

    public static CommitIntent FromJson(JsonObject value) => new(
        JournalJson.RequireString(value, JournalKeys.EndedAt),
        JournalJson.RequireString(value, JournalKeys.Status));
}

/// <summary>Kinds of write-ahead log mutation.</summary>
internal enum JournalMutationKind
{
    AppendReservation,
    UpdateReservation,
    AppendArtifact,
    UpdateArtifact,
    Lifecycle,
    CommitIntent,
}

/// <summary>One write-ahead log mutation: the smallest durable step the journal can take.</summary>
internal sealed record JournalMutation(
    JournalMutationKind Kind,
    ReservationEntry? Reservation,
    ArtifactEntry? Artifact,
    JournalLifecycle? Lifecycle,
    CommitIntent? CommitIntent)
{
    public static JournalMutation AppendReservation(ReservationEntry entry) =>
        new(JournalMutationKind.AppendReservation, entry, null, null, null);

    public static JournalMutation UpdateReservation(ReservationEntry entry) =>
        new(JournalMutationKind.UpdateReservation, entry, null, null, null);

    public static JournalMutation AppendArtifact(ArtifactEntry entry) =>
        new(JournalMutationKind.AppendArtifact, null, entry, null, null);

    public static JournalMutation UpdateArtifact(ArtifactEntry entry) =>
        new(JournalMutationKind.UpdateArtifact, null, entry, null, null);

    public static JournalMutation ForLifecycle(JournalLifecycle lifecycle) =>
        new(JournalMutationKind.Lifecycle, null, null, lifecycle, null);

    public static JournalMutation ForCommitIntent(CommitIntent intent) =>
        new(JournalMutationKind.CommitIntent, null, null, null, intent);

    public JsonObject ToJson()
    {
        var value = new JsonObject { [JournalKeys.Kind] = JournalTokens.From(Kind) };

        if (Reservation is not null)
        {
            value[JournalKeys.Reservation] = Reservation.ToJson();
        }

        if (Artifact is not null)
        {
            value[JournalKeys.Artifact] = Artifact.ToJson();
        }

        if (Lifecycle is { } lifecycle)
        {
            value[JournalKeys.Lifecycle] = JournalTokens.From(lifecycle);
        }

        if (CommitIntent is not null)
        {
            value[JournalKeys.CommitIntent] = CommitIntent.ToJson();
        }

        return value;
    }

    public static JournalMutation FromJson(JsonObject value)
    {
        JournalMutationKind kind = JournalTokens.ToMutationKind(JournalJson.RequireString(value, JournalKeys.Kind));

        return kind switch
        {
            JournalMutationKind.AppendReservation => AppendReservation(
                ReservationEntry.FromJson(JournalJson.RequireObject(value, JournalKeys.Reservation))),
            JournalMutationKind.UpdateReservation => UpdateReservation(
                ReservationEntry.FromJson(JournalJson.RequireObject(value, JournalKeys.Reservation))),
            JournalMutationKind.AppendArtifact => AppendArtifact(
                ArtifactEntry.FromJson(JournalJson.RequireObject(value, JournalKeys.Artifact))),
            JournalMutationKind.UpdateArtifact => UpdateArtifact(
                ArtifactEntry.FromJson(JournalJson.RequireObject(value, JournalKeys.Artifact))),
            JournalMutationKind.Lifecycle => ForLifecycle(
                JournalTokens.ToLifecycle(JournalJson.RequireString(value, JournalKeys.Lifecycle))),
            _ => ForCommitIntent(
                Journal.CommitIntent.FromJson(JournalJson.RequireObject(value, JournalKeys.CommitIntent))),
        };
    }
}

/// <summary>One numbered write-ahead log file.</summary>
internal sealed record JournalSegment(int SchemaVersion, long Sequence, JournalMutation Mutation)
{
    public JsonObject ToJson() => new()
    {
        [JournalKeys.SchemaVersion] = SchemaVersion,
        [JournalKeys.Sequence] = Sequence,
        [JournalKeys.Mutation] = Mutation.ToJson(),
    };

    public static JournalSegment FromJson(JsonObject value) => new(
        (int)JournalJson.RequireLong(value, JournalKeys.SchemaVersion),
        JournalJson.RequireLong(value, JournalKeys.Sequence),
        JournalMutation.FromJson(JournalJson.RequireObject(value, JournalKeys.Mutation)));
}

/// <summary>
/// Full journal snapshot. The checkpoint is the write-ahead log truncation point, never the commit
/// point: every mutation numbered below <see cref="WalSequence"/> is already folded in here.
/// </summary>
internal sealed class JournalCheckpoint
{
    public required int SchemaVersion { get; init; }

    public required string ArchiveId { get; init; }

    public required string CaptureId { get; init; }

    public long WalSequence { get; set; }

    public JournalLifecycle Lifecycle { get; set; }

    public List<StreamLedger> Streams { get; } = new();

    /// <summary>Artifact reservations in admission order; artifacts occupy no stream position.</summary>
    public List<ArtifactEntry> Artifacts { get; } = new();

    public CommitIntent? CommitIntent { get; set; }

    public JsonObject ToJson()
    {
        var streams = new JsonArray();
        foreach (StreamLedger stream in Streams)
        {
            streams.Add(stream.ToJson());
        }

        var value = new JsonObject
        {
            [JournalKeys.SchemaVersion] = SchemaVersion,
            [JournalKeys.WalSequence] = WalSequence,
            [JournalKeys.Lifecycle] = JournalTokens.From(Lifecycle),
            [JournalKeys.ArchiveId] = ArchiveId,
            [JournalKeys.CaptureId] = CaptureId,
            [JournalKeys.Streams] = streams,
        };

        // A capture that attached nothing writes no artifact key at all, so its checkpoint bytes are
        // identical to those of a build that has never heard of artifacts.
        if (Artifacts.Count > 0)
        {
            var artifacts = new JsonArray();
            foreach (ArtifactEntry artifact in Artifacts)
            {
                artifacts.Add(artifact.ToJson());
            }

            value[JournalKeys.Artifacts] = artifacts;
        }

        if (CommitIntent is not null)
        {
            value[JournalKeys.CommitIntent] = CommitIntent.ToJson();
        }

        return value;
    }

    public static JournalCheckpoint FromJson(JsonObject value)
    {
        var checkpoint = new JournalCheckpoint
        {
            SchemaVersion = (int)JournalJson.RequireLong(value, JournalKeys.SchemaVersion),
            ArchiveId = JournalJson.RequireString(value, JournalKeys.ArchiveId),
            CaptureId = JournalJson.RequireString(value, JournalKeys.CaptureId),
            WalSequence = JournalJson.RequireLong(value, JournalKeys.WalSequence),
            Lifecycle = JournalTokens.ToLifecycle(JournalJson.RequireString(value, JournalKeys.Lifecycle)),
            CommitIntent = JournalJson.OptionalObject(value, JournalKeys.CommitIntent) is { } intent
                ? Journal.CommitIntent.FromJson(intent)
                : null,
        };

        foreach (JsonNode? element in JournalJson.RequireArray(value, JournalKeys.Streams))
        {
            checkpoint.Streams.Add(StreamLedger.FromJson(JournalJson.RequireElementObject(element)));
        }

        if (value.ContainsKey(JournalKeys.Artifacts))
        {
            foreach (JsonNode? element in JournalJson.RequireArray(value, JournalKeys.Artifacts))
            {
                checkpoint.Artifacts.Add(ArtifactEntry.FromJson(JournalJson.RequireElementObject(element)));
            }
        }

        return checkpoint;
    }
}

/// <summary>Property names of the journal's working documents.</summary>
internal static class JournalKeys
{
    public const string SchemaVersion = "schemaVersion";
    public const string WalSequence = "walSequence";
    public const string Lifecycle = "lifecycle";
    public const string ArchiveId = "archiveId";
    public const string CaptureId = "captureId";
    public const string Streams = "streams";
    public const string StreamId = "streamId";
    public const string NextSequence = "nextSequence";
    public const string Reservations = "reservations";
    public const string Reservation = "reservation";
    public const string ReservationId = "reservationId";
    public const string StreamSequence = "streamSequence";
    public const string Status = "status";
    public const string Record = "record";
    public const string RecordDigest = "recordDigest";
    public const string Artifacts = "artifacts";
    public const string Artifact = "artifact";
    public const string ArtifactId = "artifactId";
    public const string Document = "document";
    public const string DocumentDigest = "documentDigest";
    public const string Content = "content";
    public const string Path = "path";
    public const string Sha256 = "sha256";
    public const string ByteLength = "byteLength";
    public const string Gap = "gap";
    public const string FirstSequence = "firstSequence";
    public const string LastSequence = "lastSequence";
    public const string Reason = "reason";
    public const string Detail = "detail";
    public const string CommitIntent = "commitIntent";
    public const string EndedAt = "endedAt";
    public const string Kind = "kind";
    public const string Mutation = "mutation";
    public const string Sequence = "sequence";
}

/// <summary>String forms of the journal's enumerations.</summary>
internal static class JournalTokens
{
    private const string Idle = "idle";
    private const string Starting = "starting";
    private const string Recording = "recording";
    private const string ClosingInput = "closingInput";
    private const string Draining = "draining";
    private const string Committed = "committed";

    private const string Pending = "pending";
    private const string ResolvingObservation = "resolvingObservation";
    private const string Observation = "observation";
    private const string Gap = "gap";

    private const string ResolvingArtifact = "resolvingArtifact";
    private const string Artifact = "artifact";

    private const string AppendReservation = "appendReservation";
    private const string UpdateReservation = "updateReservation";
    private const string AppendArtifact = "appendArtifact";
    private const string UpdateArtifact = "updateArtifact";
    private const string LifecycleMutation = "lifecycle";
    private const string CommitIntentMutation = "commitIntent";

    public static string From(JournalLifecycle value) => value switch
    {
        JournalLifecycle.Idle => Idle,
        JournalLifecycle.Starting => Starting,
        JournalLifecycle.Recording => Recording,
        JournalLifecycle.ClosingInput => ClosingInput,
        JournalLifecycle.Draining => Draining,
        _ => Committed,
    };

    public static JournalLifecycle ToLifecycle(string value) => value switch
    {
        Idle => JournalLifecycle.Idle,
        Starting => JournalLifecycle.Starting,
        Recording => JournalLifecycle.Recording,
        ClosingInput => JournalLifecycle.ClosingInput,
        Draining => JournalLifecycle.Draining,
        Committed => JournalLifecycle.Committed,
        _ => throw JournalJson.Corrupt("Unknown journal lifecycle '" + value + "'."),
    };

    public static string From(ReservationStatus value) => value switch
    {
        ReservationStatus.Pending => Pending,
        ReservationStatus.ResolvingObservation => ResolvingObservation,
        ReservationStatus.Observation => Observation,
        _ => Gap,
    };

    public static ReservationStatus ToStatus(string value) => value switch
    {
        Pending => ReservationStatus.Pending,
        ResolvingObservation => ReservationStatus.ResolvingObservation,
        Observation => ReservationStatus.Observation,
        Gap => ReservationStatus.Gap,
        _ => throw JournalJson.Corrupt("Unknown reservation status '" + value + "'."),
    };

    public static string From(ArtifactStatus value) => value switch
    {
        ArtifactStatus.Pending => Pending,
        ArtifactStatus.ResolvingArtifact => ResolvingArtifact,
        _ => Artifact,
    };

    public static ArtifactStatus ToArtifactStatus(string value) => value switch
    {
        Pending => ArtifactStatus.Pending,
        ResolvingArtifact => ArtifactStatus.ResolvingArtifact,
        Artifact => ArtifactStatus.Artifact,
        _ => throw JournalJson.Corrupt("Unknown artifact status '" + value + "'."),
    };

    public static string From(JournalMutationKind value) => value switch
    {
        JournalMutationKind.AppendReservation => AppendReservation,
        JournalMutationKind.UpdateReservation => UpdateReservation,
        JournalMutationKind.AppendArtifact => AppendArtifact,
        JournalMutationKind.UpdateArtifact => UpdateArtifact,
        JournalMutationKind.Lifecycle => LifecycleMutation,
        _ => CommitIntentMutation,
    };

    public static JournalMutationKind ToMutationKind(string value) => value switch
    {
        AppendReservation => JournalMutationKind.AppendReservation,
        UpdateReservation => JournalMutationKind.UpdateReservation,
        AppendArtifact => JournalMutationKind.AppendArtifact,
        UpdateArtifact => JournalMutationKind.UpdateArtifact,
        LifecycleMutation => JournalMutationKind.Lifecycle,
        CommitIntentMutation => JournalMutationKind.CommitIntent,
        _ => throw JournalJson.Corrupt("Unknown journal mutation '" + value + "'."),
    };
}

/// <summary>
/// Reading and writing helpers for the journal's working documents. Every failure is reported as
/// <see cref="JournalErrorKind.CorruptState"/>: a document that cannot be understood must stop
/// recovery rather than silently drop evidence.
/// </summary>
internal static class JournalJson
{
    public static CaptureJournalException Corrupt(string detail) =>
        new(JournalErrorKind.CorruptState, "Corrupt capture journal state: " + detail);

    public static JsonObject GapToJson(GapEntry gap)
    {
        var value = new JsonObject
        {
            [JournalKeys.StreamId] = gap.StreamId,
            [JournalKeys.FirstSequence] = gap.FirstSequence,
            [JournalKeys.LastSequence] = gap.LastSequence,
            [JournalKeys.Reason] = gap.Reason,
        };

        if (gap.Detail is not null)
        {
            value[JournalKeys.Detail] = gap.Detail;
        }

        return value;
    }

    public static GapEntry GapFromJson(JsonObject value) => new(
        RequireString(value, JournalKeys.StreamId),
        RequireLong(value, JournalKeys.FirstSequence),
        RequireLong(value, JournalKeys.LastSequence),
        RequireString(value, JournalKeys.Reason),
        OptionalString(value, JournalKeys.Detail));

    public static string RequireString(JsonObject value, string key)
    {
        if (value[key] is JsonValue node && node.TryGetValue(out string? text))
        {
            return text;
        }

        throw Corrupt("missing string property '" + key + "'");
    }

    public static long RequireLong(JsonObject value, string key)
    {
        if (value[key] is JsonValue node && node.TryGetValue(out long number))
        {
            return number;
        }

        throw Corrupt("missing integer property '" + key + "'");
    }

    public static JsonObject RequireObject(JsonObject value, string key) =>
        value[key] as JsonObject ?? throw Corrupt("missing object property '" + key + "'");

    public static JsonArray RequireArray(JsonObject value, string key) =>
        value[key] as JsonArray ?? throw Corrupt("missing array property '" + key + "'");

    public static JsonObject RequireElementObject(JsonNode? element) =>
        element as JsonObject ?? throw Corrupt("array element is not an object");

    public static JsonObject? OptionalObject(JsonObject value, string key) =>
        value.ContainsKey(key) ? RequireObject(value, key) : null;

    public static string? OptionalString(JsonObject value, string key) =>
        value.ContainsKey(key) ? RequireString(value, key) : null;

    /// <summary>Parses a journal document written by <see cref="Canonical"/>.</summary>
    public static JsonObject ParseDocument(string text, string path)
    {
        try
        {
            return JsonStrictParser.Parse(text) as JsonObject
                ?? throw Corrupt("document is not a JSON object: " + path);
        }
        catch (FormatException exception)
        {
            throw new CaptureJournalException(
                JournalErrorKind.CorruptState,
                string.Format(CultureInfo.InvariantCulture, "Corrupt capture journal document {0}.", path),
                exception);
        }
    }

    /// <summary>
    /// Serializes a journal document. The canonical form keeps the working files byte-stable so a
    /// crash-recovery diff shows real state changes rather than serializer ordering noise.
    /// </summary>
    public static string Canonical(JsonObject value) => JsonCanonicalizer.Canonicalize(value);
}
