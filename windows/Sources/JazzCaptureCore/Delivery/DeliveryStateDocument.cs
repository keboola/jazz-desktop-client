using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using JazzCaptureCore.Json;

namespace JazzCaptureCore.Delivery;

/// <summary>Transport tokens admitted by <c>delivery-state.schema.json</c>.</summary>
public static class DeliveryTransports
{
    /// <summary>OTLP log records.</summary>
    public const string OtlpLogs = "otlp_logs";

    /// <summary>OTLP spans.</summary>
    public const string OtlpTraces = "otlp_traces";

    /// <summary>Keboola Storage files.</summary>
    public const string KeboolaFiles = "keboola_files";

    /// <summary>One whole immutable <c>.jazz-archive</c> container. The only transport this client uses.</summary>
    public const string JazzArchiveUpload = "jazz_archive_upload";

    /// <summary>Live per-record stream.</summary>
    public const string JazzRecordStream = "jazz_record_stream";

    /// <summary>Every admitted token, in schema order.</summary>
    public static readonly IReadOnlyList<string> All = new[]
    {
        OtlpLogs,
        OtlpTraces,
        KeboolaFiles,
        JazzArchiveUpload,
        JazzRecordStream,
    };

    /// <summary>Whether <paramref name="value"/> is one of the admitted transports.</summary>
    public static bool IsKnown(string? value) =>
        value is not null && All.Contains(value, StringComparer.Ordinal);
}

/// <summary>Subject kinds admitted by <c>delivery-state.schema.json</c>.</summary>
public static class DeliverySubjectKinds
{
    /// <summary>One capture.</summary>
    public const string Capture = "capture";

    /// <summary>One capture commit.</summary>
    public const string Commit = "commit";

    /// <summary>One observation.</summary>
    public const string Observation = "observation";

    /// <summary>One artifact.</summary>
    public const string Artifact = "artifact";

    /// <summary>Every admitted kind, in schema order.</summary>
    public static readonly IReadOnlyList<string> All = new[] { Capture, Commit, Observation, Artifact };

    /// <summary>Whether <paramref name="value"/> is one of the admitted kinds.</summary>
    public static bool IsKnown(string? value) =>
        value is not null && All.Contains(value, StringComparer.Ordinal);
}

/// <summary>
/// The five durable delivery states of <c>delivery-state.schema.json</c>.
/// </summary>
/// <remarks>
/// <para>
/// <see cref="Pending"/> and <see cref="Failed"/> are both runnable and are deliberately kept apart:
/// pending has never been attempted, failed has been attempted and is waiting out a backoff
/// watermark. Collapsing them would lose the distinction between "not started" and "the server or
/// the network said no", which is the only thing that tells a user whether waiting will help.
/// </para>
/// <para>
/// <see cref="Acked"/> and <see cref="PermanentFailure"/> are terminal. The first is never sent
/// again; the second stops rather than spinning.
/// </para>
/// </remarks>
public enum DeliveryLifecycle
{
    /// <summary>Durably queued, never attempted.</summary>
    Pending,

    /// <summary>An attempt is committed and its outcome is unknown until the transport answers.</summary>
    InFlight,

    /// <summary>The server acknowledged these exact bytes. Terminal.</summary>
    Acked,

    /// <summary>A retryable failure. The package is unchanged and another attempt is due later.</summary>
    Failed,

    /// <summary>A failure another identical attempt cannot fix. Terminal.</summary>
    PermanentFailure,
}

/// <summary>Wire spellings of <see cref="DeliveryLifecycle"/>.</summary>
public static class DeliveryStates
{
    /// <summary>Wire value of <see cref="DeliveryLifecycle.Pending"/>.</summary>
    public const string Pending = "pending";

    /// <summary>Wire value of <see cref="DeliveryLifecycle.InFlight"/>.</summary>
    public const string InFlight = "in_flight";

    /// <summary>Wire value of <see cref="DeliveryLifecycle.Acked"/>.</summary>
    public const string Acked = "acked";

    /// <summary>Wire value of <see cref="DeliveryLifecycle.Failed"/>.</summary>
    public const string Failed = "failed";

    /// <summary>Wire value of <see cref="DeliveryLifecycle.PermanentFailure"/>.</summary>
    public const string PermanentFailure = "permanent_failure";

    /// <summary>Renders <paramref name="state"/> as its wire value.</summary>
    public static string ToWire(DeliveryLifecycle state) => state switch
    {
        DeliveryLifecycle.Pending => Pending,
        DeliveryLifecycle.InFlight => InFlight,
        DeliveryLifecycle.Acked => Acked,
        DeliveryLifecycle.Failed => Failed,
        DeliveryLifecycle.PermanentFailure => PermanentFailure,
        _ => throw new ArgumentOutOfRangeException(nameof(state), state, "Unknown delivery state."),
    };

    /// <summary>Parses a wire value; returns <see langword="false"/> for anything else.</summary>
    public static bool TryParse(string? value, out DeliveryLifecycle state)
    {
        switch (value)
        {
            case Pending: state = DeliveryLifecycle.Pending; return true;
            case InFlight: state = DeliveryLifecycle.InFlight; return true;
            case Acked: state = DeliveryLifecycle.Acked; return true;
            case Failed: state = DeliveryLifecycle.Failed; return true;
            case PermanentFailure: state = DeliveryLifecycle.PermanentFailure; return true;
            default: state = DeliveryLifecycle.Pending; return false;
        }
    }

    /// <summary>Whether the state admits no further transition.</summary>
    public static bool IsTerminal(DeliveryLifecycle state) =>
        state is DeliveryLifecycle.Acked or DeliveryLifecycle.PermanentFailure;
}

/// <summary>One <c>subjectRefs</c> entry: what this delivery carries.</summary>
/// <param name="Kind">One of <see cref="DeliverySubjectKinds"/>.</param>
/// <param name="Id">Identity of the subject, opaque to the schema beyond being non-empty.</param>
public readonly record struct DeliverySubjectRef(string Kind, string Id);

/// <summary>
/// Identities the server bound to this delivery. Every field is optional and an absent one is
/// omitted from the document rather than written as JSON <c>null</c>.
/// </summary>
/// <param name="TraceId">32 lowercase hex characters, for an OTLP transport.</param>
/// <param name="SpanId">16 lowercase hex characters, for an OTLP transport.</param>
/// <param name="FileId">Storage file identity, for a Keboola Files transport.</param>
/// <param name="ReceiptId">Opaque acknowledgement of the uploaded object.</param>
public sealed record DeliveryRemoteBindings(
    string? TraceId = null,
    string? SpanId = null,
    string? FileId = null,
    string? ReceiptId = null)
{
    /// <summary>Whether the whole block would be empty and must therefore be omitted.</summary>
    public bool IsEmpty =>
        TraceId is null && SpanId is null && FileId is null && ReceiptId is null;
}

/// <summary>
/// The contract-shaped delivery state of <c>contract/archive/schema/delivery-state.schema.json</c>.
/// </summary>
/// <remarks>
/// <para>
/// This is a projection, not the authority. The authority is
/// <see cref="ArchiveDeliveryRecord"/>, which the queue commits durably before any request; this
/// document is what that record looks like to anyone reading the archive. It is written to
/// <c>sync/delivery.ndjson</c> inside the archive directory, which the container writer never
/// exports and the inventory never hashes — so the state of a delivery can change without changing
/// the identity of the thing being delivered.
/// </para>
/// <para>
/// It carries no endpoint and no credential, by construction: there is no field for either.
/// </para>
/// </remarks>
public sealed record DeliveryStateDocument
{
    /// <summary>The only schema version this client writes or reads.</summary>
    public const int CurrentSchemaVersion = 1;

    private const string SchemaVersionKey = "schemaVersion";
    private const string DeliveryIdKey = "deliveryId";
    private const string TransportKey = "transport";
    private const string MappingVersionKey = "mappingVersion";
    private const string SubjectRefsKey = "subjectRefs";
    private const string StateKey = "state";
    private const string AttemptKey = "attempt";
    private const string UpdatedAtKey = "updatedAt";
    private const string ErrorCodeKey = "errorCode";
    private const string RemoteBindingsKey = "remoteBindings";
    private const string KindKey = "kind";
    private const string IdKey = "id";
    private const string TraceIdKey = "traceId";
    private const string SpanIdKey = "spanId";
    private const string FileIdKey = "fileId";
    private const string ReceiptIdKey = "receiptId";

    /// <summary>Always <see cref="CurrentSchemaVersion"/>.</summary>
    public int SchemaVersion { get; init; } = CurrentSchemaVersion;

    /// <summary><c>del-</c> plus a lowercase RFC 9562 UUIDv7.</summary>
    public required string DeliveryId { get; init; }

    /// <summary>One of <see cref="DeliveryTransports"/>.</summary>
    public required string Transport { get; init; }

    /// <summary>Version of the mapping that produced the delivered bytes.</summary>
    public required string MappingVersion { get; init; }

    /// <summary>What this delivery carries; at least one entry.</summary>
    public required IReadOnlyList<DeliverySubjectRef> SubjectRefs { get; init; }

    /// <summary>Current durable state.</summary>
    public required DeliveryLifecycle State { get; init; }

    /// <summary>Number of attempts committed so far.</summary>
    public required int Attempt { get; init; }

    /// <summary>RFC 3339 instant of the last state change.</summary>
    public required string UpdatedAt { get; init; }

    /// <summary>Last error code, when the last outcome was a failure.</summary>
    public string? ErrorCode { get; init; }

    /// <summary>Server-assigned identities, when the server assigned any.</summary>
    public DeliveryRemoteBindings? RemoteBindings { get; init; }

    /// <summary>
    /// Renders the document. Optional fields that are absent are omitted; none is ever written as
    /// JSON <c>null</c>, which the schema would reject and which reads as "known to be nothing"
    /// rather than "not known".
    /// </summary>
    public JsonObject ToJson()
    {
        Validate();

        var subjects = new JsonArray();
        foreach (DeliverySubjectRef subject in SubjectRefs)
        {
            subjects.Add(new JsonObject
            {
                [KindKey] = subject.Kind,
                [IdKey] = subject.Id,
            });
        }

        var value = new JsonObject
        {
            [SchemaVersionKey] = (long)SchemaVersion,
            [DeliveryIdKey] = DeliveryId,
            [TransportKey] = Transport,
            [MappingVersionKey] = MappingVersion,
            [SubjectRefsKey] = subjects,
            [StateKey] = DeliveryStates.ToWire(State),
            [AttemptKey] = (long)Attempt,
            [UpdatedAtKey] = UpdatedAt,
        };

        if (ErrorCode is not null)
        {
            value[ErrorCodeKey] = ErrorCode;
        }

        if (RemoteBindings is { IsEmpty: false } bindings)
        {
            var block = new JsonObject();
            if (bindings.TraceId is not null)
            {
                block[TraceIdKey] = bindings.TraceId;
            }

            if (bindings.SpanId is not null)
            {
                block[SpanIdKey] = bindings.SpanId;
            }

            if (bindings.FileId is not null)
            {
                block[FileIdKey] = bindings.FileId;
            }

            if (bindings.ReceiptId is not null)
            {
                block[ReceiptIdKey] = bindings.ReceiptId;
            }

            value[RemoteBindingsKey] = block;
        }

        return value;
    }

    /// <summary>Renders the document as one compact NDJSON line, without the terminator.</summary>
    public string ToNdjsonLine() => JsonCanonicalizer.Canonicalize(ToJson());

    /// <summary>Reads back a document this client wrote.</summary>
    /// <exception cref="FormatException">The value is not a well-formed delivery state.</exception>
    public static DeliveryStateDocument FromJson(JsonObject value)
    {
        ArgumentNullException.ThrowIfNull(value);

        // Integers are read as 64-bit: the strict parser types every whole number as a long, and
        // asking a long-backed node for an int throws instead of narrowing.
        if ((long?)value[SchemaVersionKey] != CurrentSchemaVersion)
        {
            throw new FormatException("Delivery state schemaVersion must be " + CurrentSchemaVersion + ".");
        }

        if (!DeliveryStates.TryParse((string?)value[StateKey], out DeliveryLifecycle state))
        {
            throw new FormatException("Delivery state has no admitted state.");
        }

        var subjects = new List<DeliverySubjectRef>();
        foreach (JsonNode? node in value[SubjectRefsKey] as JsonArray ?? new JsonArray())
        {
            if (node is not JsonObject subject)
            {
                throw new FormatException("Delivery state subjectRefs entry is not an object.");
            }

            subjects.Add(new DeliverySubjectRef(
                (string?)subject[KindKey] ?? throw new FormatException("subjectRefs entry has no kind."),
                (string?)subject[IdKey] ?? throw new FormatException("subjectRefs entry has no id.")));
        }

        DeliveryRemoteBindings? bindings = null;
        if (value[RemoteBindingsKey] is JsonObject block)
        {
            bindings = new DeliveryRemoteBindings(
                (string?)block[TraceIdKey],
                (string?)block[SpanIdKey],
                (string?)block[FileIdKey],
                (string?)block[ReceiptIdKey]);
        }

        var document = new DeliveryStateDocument
        {
            SchemaVersion = CurrentSchemaVersion,
            DeliveryId = (string?)value[DeliveryIdKey] ?? throw new FormatException("Delivery state has no deliveryId."),
            Transport = (string?)value[TransportKey] ?? throw new FormatException("Delivery state has no transport."),
            MappingVersion = (string?)value[MappingVersionKey]
                ?? throw new FormatException("Delivery state has no mappingVersion."),
            SubjectRefs = subjects,
            State = state,
            Attempt = (int)((long?)value[AttemptKey] ?? throw new FormatException("Delivery state has no attempt.")),
            UpdatedAt = (string?)value[UpdatedAtKey] ?? throw new FormatException("Delivery state has no updatedAt."),
            ErrorCode = (string?)value[ErrorCodeKey],
            RemoteBindings = bindings,
        };

        document.Validate();
        return document;
    }

    /// <summary>
    /// Enforces the parts of the schema a producer can get wrong: the identifier shape, the two
    /// enumerations, the non-empty strings, the non-negative attempt, and the timestamp.
    /// </summary>
    /// <exception cref="FormatException">The document would not validate.</exception>
    public void Validate()
    {
        if (SchemaVersion != CurrentSchemaVersion)
        {
            throw new FormatException("Delivery state schemaVersion must be " + CurrentSchemaVersion + ".");
        }

        if (!DeliveryIds.IsDeliveryId(DeliveryId))
        {
            throw new FormatException("Delivery state deliveryId is not 'del-' plus a UUIDv7.");
        }

        if (!DeliveryTransports.IsKnown(Transport))
        {
            throw new FormatException("Delivery state transport '" + Transport + "' is not admitted.");
        }

        if (string.IsNullOrEmpty(MappingVersion))
        {
            throw new FormatException("Delivery state mappingVersion must not be empty.");
        }

        if (SubjectRefs.Count == 0)
        {
            throw new FormatException("Delivery state must carry at least one subjectRef.");
        }

        foreach (DeliverySubjectRef subject in SubjectRefs)
        {
            if (!DeliverySubjectKinds.IsKnown(subject.Kind))
            {
                throw new FormatException("Delivery state subject kind '" + subject.Kind + "' is not admitted.");
            }

            if (string.IsNullOrEmpty(subject.Id))
            {
                throw new FormatException("Delivery state subject id must not be empty.");
            }
        }

        if (Attempt < 0)
        {
            throw new FormatException("Delivery state attempt must not be negative.");
        }

        if (Timestamps.TryParseRfc3339(UpdatedAt) is null)
        {
            throw new FormatException("Delivery state updatedAt is not an RFC 3339 instant.");
        }

        if (ErrorCode is { Length: 0 })
        {
            throw new FormatException("Delivery state errorCode must not be empty when present.");
        }
    }
}

/// <summary>Identifier shapes the delivery queue admits.</summary>
public static class DeliveryIds
{
    private const string Uuid7 = "[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}";

    private static readonly Regex DeliveryIdPattern = Build("del");
    private static readonly Regex ArchiveIdPattern = Build("ar");
    private static readonly Regex OriginIdPattern = Build("origin");
    private static readonly Regex CaptureIdPattern = Build("cap");
    private static readonly Regex Sha256Pattern = new(
        "^[0-9a-f]{64}$",
        RegexOptions.CultureInvariant | RegexOptions.Compiled);

    /// <summary>Mints a fresh <c>del-</c> identifier.</summary>
    public static string NewDeliveryId() => Identifiers.Prefixed("del");

    /// <summary>Whether the value is <c>del-</c> plus a lowercase UUIDv7.</summary>
    public static bool IsDeliveryId(string? value) => Matches(DeliveryIdPattern, value);

    /// <summary>Whether the value is <c>ar-</c> plus a lowercase UUIDv7.</summary>
    public static bool IsArchiveId(string? value) => Matches(ArchiveIdPattern, value);

    /// <summary>Whether the value is <c>origin-</c> plus a lowercase UUIDv7.</summary>
    public static bool IsOriginId(string? value) => Matches(OriginIdPattern, value);

    /// <summary>Whether the value is <c>cap-</c> plus a lowercase UUIDv7.</summary>
    public static bool IsCaptureId(string? value) => Matches(CaptureIdPattern, value);

    /// <summary>Whether the value is 64 lowercase hexadecimal characters.</summary>
    public static bool IsSha256(string? value) => Matches(Sha256Pattern, value);

    private static bool Matches(Regex pattern, string? value) =>
        value is not null && pattern.IsMatch(value);

    private static Regex Build(string prefix) => new(
        "^" + prefix + "-" + Uuid7 + "$",
        RegexOptions.CultureInvariant | RegexOptions.Compiled);
}
