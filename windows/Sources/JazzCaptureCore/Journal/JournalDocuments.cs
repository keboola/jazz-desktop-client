using System.Globalization;
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
public sealed record CommitResult(
    string ArchiveId,
    string CaptureId,
    string EndedAt,
    string Status,
    IReadOnlyList<JsonObject> Records,
    IReadOnlyList<GapEntry> Gaps,
    IReadOnlyList<StreamSummary> StreamSummaries);

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
    Lifecycle,
    CommitIntent,
}

/// <summary>One write-ahead log mutation: the smallest durable step the journal can take.</summary>
internal sealed record JournalMutation(
    JournalMutationKind Kind,
    ReservationEntry? Reservation,
    JournalLifecycle? Lifecycle,
    CommitIntent? CommitIntent)
{
    public static JournalMutation AppendReservation(ReservationEntry entry) =>
        new(JournalMutationKind.AppendReservation, entry, null, null);

    public static JournalMutation UpdateReservation(ReservationEntry entry) =>
        new(JournalMutationKind.UpdateReservation, entry, null, null);

    public static JournalMutation ForLifecycle(JournalLifecycle lifecycle) =>
        new(JournalMutationKind.Lifecycle, null, lifecycle, null);

    public static JournalMutation ForCommitIntent(CommitIntent intent) =>
        new(JournalMutationKind.CommitIntent, null, null, intent);

    public JsonObject ToJson()
    {
        var value = new JsonObject { [JournalKeys.Kind] = JournalTokens.From(Kind) };

        if (Reservation is not null)
        {
            value[JournalKeys.Reservation] = Reservation.ToJson();
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

    private const string AppendReservation = "appendReservation";
    private const string UpdateReservation = "updateReservation";
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

    public static string From(JournalMutationKind value) => value switch
    {
        JournalMutationKind.AppendReservation => AppendReservation,
        JournalMutationKind.UpdateReservation => UpdateReservation,
        JournalMutationKind.Lifecycle => LifecycleMutation,
        _ => CommitIntentMutation,
    };

    public static JournalMutationKind ToMutationKind(string value) => value switch
    {
        AppendReservation => JournalMutationKind.AppendReservation,
        UpdateReservation => JournalMutationKind.UpdateReservation,
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
