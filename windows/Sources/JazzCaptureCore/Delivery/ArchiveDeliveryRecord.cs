using System.Text.Json.Nodes;

namespace JazzCaptureCore.Delivery;

/// <summary>Why a delivery-queue operation refused.</summary>
public enum ArchiveDeliveryErrorKind
{
    /// <summary>A record on disk, or one about to be written, is not a well-formed delivery.</summary>
    InvalidRecord,

    /// <summary>No delivery is queued for that archive.</summary>
    Missing,

    /// <summary>The queue-owned package file is not there.</summary>
    PackageMissing,

    /// <summary>The queue-owned package no longer hashes to the bytes the record committed.</summary>
    PackageChanged,

    /// <summary>The same archive identity was presented with different immutable bytes or metadata.</summary>
    Collision,

    /// <summary>The requested state change is not admitted from the current state.</summary>
    InvalidTransition,

    /// <summary>The delivery state could not be committed durably.</summary>
    PersistenceFailed,

    /// <summary>The server contradicted something the queue already committed.</summary>
    Conflict,
}

/// <summary>A refusal from the durable archive delivery queue.</summary>
public sealed class ArchiveDeliveryException : Exception
{
    /// <summary>Creates a refusal.</summary>
    public ArchiveDeliveryException(ArchiveDeliveryErrorKind kind, string message, Exception? inner = null)
        : base(message, inner) => Kind = kind;

    /// <summary>Why the operation refused.</summary>
    public ArchiveDeliveryErrorKind Kind { get; }

    internal static ArchiveDeliveryException Invalid(string detail) =>
        new(ArchiveDeliveryErrorKind.InvalidRecord, "Invalid archive delivery record: " + detail);

    internal static ArchiveDeliveryException Missing(string archiveId) =>
        new(ArchiveDeliveryErrorKind.Missing, "No archive delivery is queued for " + archiveId + ".");

    internal static ArchiveDeliveryException PackageMissing(string archiveId) =>
        new(ArchiveDeliveryErrorKind.PackageMissing, "The queued package for " + archiveId + " is missing.");

    internal static ArchiveDeliveryException PackageChanged(string archiveId) =>
        new(
            ArchiveDeliveryErrorKind.PackageChanged,
            "The queued package for " + archiveId + " no longer matches the bytes the queue committed.");

    internal static ArchiveDeliveryException Collision(string archiveId) =>
        new(
            ArchiveDeliveryErrorKind.Collision,
            "Archive " + archiveId + " was queued again with different immutable bytes or metadata.");

    internal static ArchiveDeliveryException InvalidTransition(
        string archiveId,
        DeliveryLifecycle from,
        DeliveryLifecycle to) =>
        new(
            ArchiveDeliveryErrorKind.InvalidTransition,
            "Archive " + archiveId + " cannot move from "
                + DeliveryStates.ToWire(from) + " to " + DeliveryStates.ToWire(to) + ".");

    internal static ArchiveDeliveryException Conflict(string archiveId, string detail) =>
        new(ArchiveDeliveryErrorKind.Conflict, "Archive delivery conflict for " + archiveId + ": " + detail);

    internal static ArchiveDeliveryException PersistenceFailed(string archiveId, Exception inner) =>
        new(
            ArchiveDeliveryErrorKind.PersistenceFailed,
            "Archive delivery state for " + archiveId + " could not be committed durably.",
            inner);
}

/// <summary>
/// One durable delivery: the immutable identity of a confirmed archive, plus where its delivery has
/// got to.
/// </summary>
/// <remarks>
/// <para>
/// The identity half — archive, origin, captures, format version, revision, logical content digest,
/// raw ZIP SHA-256 and byte length — is written once at enqueue and never rewritten. Every retry and
/// every relaunch re-reads it and re-verifies the package against it, so a retry can only ever send
/// the bytes that were confirmed, never a package derived again from evidence that may have moved
/// on.
/// </para>
/// <para>
/// The lifecycle half — state, attempt, timestamps, error code, retry watermark and receipt — is
/// what the queue commits before and after every request. It is the authority;
/// <see cref="DeliveryStateDocument"/> is its contract-shaped projection.
/// </para>
/// </remarks>
public sealed record ArchiveDeliveryRecord
{
    /// <summary>The only record schema version this client writes.</summary>
    public const int CurrentSchemaVersion = 1;

    /// <summary>Version of the mapping from a finalized archive directory to delivered bytes.</summary>
    public const string ArchiveUploadMappingVersion = "jazz-archive-upload/v1";

    /// <summary>Extension of the queue-owned package.</summary>
    public const string PackageExtension = ".jazz-archive";

    private const string SchemaVersionKey = "schemaVersion";
    private const string DeliveryIdKey = "deliveryId";
    private const string ArchiveIdKey = "archiveId";
    private const string OriginIdKey = "originId";
    private const string CaptureIdsKey = "captureIds";
    private const string FormatVersionKey = "formatVersion";
    private const string RevisionKey = "revision";
    private const string ContentDigestKey = "contentDigest";
    private const string RawSha256Key = "rawSha256";
    private const string ByteLengthKey = "byteLength";
    private const string PackageFileNameKey = "packageFileName";
    private const string ArchiveDirectoryKey = "archiveDirectory";
    private const string TransportKey = "transport";
    private const string MappingVersionKey = "mappingVersion";
    private const string StateKey = "state";
    private const string AttemptKey = "attempt";
    private const string QueuedAtKey = "queuedAt";
    private const string UpdatedAtKey = "updatedAt";
    private const string ErrorCodeKey = "errorCode";
    private const string NextAttemptAtKey = "nextAttemptAt";
    private const string ReceiptIdKey = "receiptId";

    /// <summary>Always <see cref="CurrentSchemaVersion"/>.</summary>
    public int SchemaVersion { get; init; } = CurrentSchemaVersion;

    /// <summary>Durable idempotency identity, minted once and never reminted.</summary>
    public required string DeliveryId { get; init; }

    /// <summary>Archive being delivered.</summary>
    public required string ArchiveId { get; init; }

    /// <summary>Producer origin of the archive.</summary>
    public required string OriginId { get; init; }

    /// <summary>Captures the archive contains; at least one, distinct.</summary>
    public required IReadOnlyList<string> CaptureIds { get; init; }

    /// <summary>Archive format version.</summary>
    public required int FormatVersion { get; init; }

    /// <summary>Archive revision.</summary>
    public required int Revision { get; init; }

    /// <summary>Logical content digest — <c>manifest.contentDigest</c>, container-independent.</summary>
    public required string ContentDigest { get; init; }

    /// <summary>SHA-256 of the exact container bytes.</summary>
    public required string RawSha256 { get; init; }

    /// <summary>Length of the exact container bytes.</summary>
    public required long ByteLength { get; init; }

    /// <summary>File name of the package inside the queue root. Never a path.</summary>
    public required string PackageFileName { get; init; }

    /// <summary>
    /// Archive directory whose <c>sync/</c> subtree receives the state projection, when the local
    /// evidence is still on this machine. Absent once the user has removed it; the delivery itself
    /// does not depend on it.
    /// </summary>
    public string? ArchiveDirectory { get; init; }

    /// <summary>Transport token; always <see cref="DeliveryTransports.JazzArchiveUpload"/> here.</summary>
    public string Transport { get; init; } = DeliveryTransports.JazzArchiveUpload;

    /// <summary>Mapping version written into the state projection.</summary>
    public string MappingVersion { get; init; } = ArchiveUploadMappingVersion;

    /// <summary>Current durable state.</summary>
    public required DeliveryLifecycle State { get; init; }

    /// <summary>Attempts committed so far.</summary>
    public required int Attempt { get; init; }

    /// <summary>RFC 3339 instant the delivery was queued.</summary>
    public required string QueuedAt { get; init; }

    /// <summary>RFC 3339 instant of the last committed state change.</summary>
    public required string UpdatedAt { get; init; }

    /// <summary>Code of the last failure, when the last outcome was one.</summary>
    public string? ErrorCode { get; init; }

    /// <summary>
    /// Earliest instant at which another attempt may run. A server-supplied value is authoritative;
    /// otherwise the queue derives one from <see cref="ArchiveDeliveryRetryPolicy"/> and commits it,
    /// so relaunch preserves the schedule instead of retrying immediately.
    /// </summary>
    public string? NextAttemptAt { get; init; }

    /// <summary>Opaque server acknowledgement. Present exactly when the state is acked.</summary>
    public string? ReceiptId { get; init; }

    /// <summary>Whether the delivery admits no further transition.</summary>
    public bool IsTerminal => DeliveryStates.IsTerminal(State);

    /// <summary>
    /// Whether a delivery pass may pick this record up now.
    /// </summary>
    /// <remarks>
    /// In-flight is runnable on purpose. A process that died between committing an attempt and
    /// hearing the outcome leaves exactly that state, and the only way not to strand the package is
    /// to run it again with the same delivery identity and the same bytes. That is safe precisely
    /// because the identity is durable: the server sees a repeat of an operation it has already
    /// seen, not a second delivery.
    /// </remarks>
    public bool IsRunnable(DateTimeOffset now) => State switch
    {
        DeliveryLifecycle.Pending => true,
        DeliveryLifecycle.InFlight => true,
        DeliveryLifecycle.Failed => Timestamps.TryParseRfc3339(NextAttemptAt) is not { } due || due <= now,
        _ => false,
    };

    /// <summary>Projects the record into the contract-shaped delivery state document.</summary>
    public DeliveryStateDocument ToStateDocument()
    {
        var subjects = new List<DeliverySubjectRef>(CaptureIds.Count);
        foreach (string captureId in CaptureIds)
        {
            subjects.Add(new DeliverySubjectRef(DeliverySubjectKinds.Capture, captureId));
        }

        return new DeliveryStateDocument
        {
            SchemaVersion = DeliveryStateDocument.CurrentSchemaVersion,
            DeliveryId = DeliveryId,
            Transport = Transport,
            MappingVersion = MappingVersion,
            SubjectRefs = subjects,
            State = State,
            Attempt = Attempt,
            UpdatedAt = UpdatedAt,
            ErrorCode = ErrorCode,
            RemoteBindings = ReceiptId is null ? null : new DeliveryRemoteBindings(ReceiptId: ReceiptId),
        };
    }

    /// <summary>Renders the durable record. Absent optional fields are omitted, never null.</summary>
    public JsonObject ToJson()
    {
        Validate();

        var captures = new JsonArray();
        foreach (string captureId in CaptureIds)
        {
            captures.Add(captureId);
        }

        var value = new JsonObject
        {
            [SchemaVersionKey] = SchemaVersion,
            [DeliveryIdKey] = DeliveryId,
            [ArchiveIdKey] = ArchiveId,
            [OriginIdKey] = OriginId,
            [CaptureIdsKey] = captures,
            [FormatVersionKey] = FormatVersion,
            [RevisionKey] = Revision,
            [ContentDigestKey] = ContentDigest,
            [RawSha256Key] = RawSha256,
            [ByteLengthKey] = ByteLength,
            [PackageFileNameKey] = PackageFileName,
            [TransportKey] = Transport,
            [MappingVersionKey] = MappingVersion,
            [StateKey] = DeliveryStates.ToWire(State),
            [AttemptKey] = Attempt,
            [QueuedAtKey] = QueuedAt,
            [UpdatedAtKey] = UpdatedAt,
        };

        if (ArchiveDirectory is not null)
        {
            value[ArchiveDirectoryKey] = ArchiveDirectory;
        }

        if (ErrorCode is not null)
        {
            value[ErrorCodeKey] = ErrorCode;
        }

        if (NextAttemptAt is not null)
        {
            value[NextAttemptAtKey] = NextAttemptAt;
        }

        if (ReceiptId is not null)
        {
            value[ReceiptIdKey] = ReceiptId;
        }

        return value;
    }

    /// <summary>Reads back a record this client wrote.</summary>
    /// <exception cref="ArchiveDeliveryException">The value is not a well-formed record.</exception>
    public static ArchiveDeliveryRecord FromJson(JsonObject value)
    {
        ArgumentNullException.ThrowIfNull(value);

        if ((long?)value[SchemaVersionKey] != CurrentSchemaVersion)
        {
            throw ArchiveDeliveryException.Invalid("schemaVersion must be " + CurrentSchemaVersion);
        }

        if (!DeliveryStates.TryParse((string?)value[StateKey], out DeliveryLifecycle state))
        {
            throw ArchiveDeliveryException.Invalid("state is not admitted");
        }

        var captureIds = new List<string>();
        foreach (JsonNode? node in value[CaptureIdsKey] as JsonArray ?? new JsonArray())
        {
            captureIds.Add((string?)node ?? throw ArchiveDeliveryException.Invalid("captureIds entry is not a string"));
        }

        var record = new ArchiveDeliveryRecord
        {
            SchemaVersion = CurrentSchemaVersion,
            DeliveryId = Text(value, DeliveryIdKey),
            ArchiveId = Text(value, ArchiveIdKey),
            OriginId = Text(value, OriginIdKey),
            CaptureIds = captureIds,
            FormatVersion = Number(value, FormatVersionKey),
            Revision = Number(value, RevisionKey),
            ContentDigest = Text(value, ContentDigestKey),
            RawSha256 = Text(value, RawSha256Key),
            ByteLength = (long?)value[ByteLengthKey]
                ?? throw ArchiveDeliveryException.Invalid("byteLength is missing"),
            PackageFileName = Text(value, PackageFileNameKey),
            ArchiveDirectory = (string?)value[ArchiveDirectoryKey],
            Transport = Text(value, TransportKey),
            MappingVersion = Text(value, MappingVersionKey),
            State = state,
            Attempt = Number(value, AttemptKey),
            QueuedAt = Text(value, QueuedAtKey),
            UpdatedAt = Text(value, UpdatedAtKey),
            ErrorCode = (string?)value[ErrorCodeKey],
            NextAttemptAt = (string?)value[NextAttemptAtKey],
            ReceiptId = (string?)value[ReceiptIdKey],
        };

        record.Validate();
        return record;
    }

    /// <summary>
    /// Rejects anything the queue must never persist or act on.
    /// </summary>
    /// <exception cref="ArchiveDeliveryException">The record is not well formed.</exception>
    public void Validate()
    {
        if (SchemaVersion != CurrentSchemaVersion)
        {
            throw ArchiveDeliveryException.Invalid("schemaVersion must be " + CurrentSchemaVersion);
        }

        if (!DeliveryIds.IsDeliveryId(DeliveryId))
        {
            throw ArchiveDeliveryException.Invalid("deliveryId '" + DeliveryId + "' is not 'del-' plus a UUIDv7");
        }

        if (!DeliveryIds.IsArchiveId(ArchiveId))
        {
            throw ArchiveDeliveryException.Invalid("archiveId '" + ArchiveId + "' is not 'ar-' plus a UUIDv7");
        }

        if (!DeliveryIds.IsOriginId(OriginId))
        {
            throw ArchiveDeliveryException.Invalid("originId '" + OriginId + "' is not 'origin-' plus a UUIDv7");
        }

        if (CaptureIds.Count == 0)
        {
            throw ArchiveDeliveryException.Invalid("a delivery must name at least one capture");
        }

        var distinct = new HashSet<string>(StringComparer.Ordinal);
        foreach (string captureId in CaptureIds)
        {
            if (!DeliveryIds.IsCaptureId(captureId) || !distinct.Add(captureId))
            {
                throw ArchiveDeliveryException.Invalid("captureIds must be distinct 'cap-' UUIDv7 values");
            }
        }

        if (FormatVersion < 1 || Revision < 1)
        {
            throw ArchiveDeliveryException.Invalid("formatVersion and revision must be at least 1");
        }

        if (!DeliveryIds.IsSha256(ContentDigest) || !DeliveryIds.IsSha256(RawSha256))
        {
            throw ArchiveDeliveryException.Invalid("contentDigest and rawSha256 must be 64 lowercase hex characters");
        }

        if (ByteLength <= 0)
        {
            throw ArchiveDeliveryException.Invalid("byteLength must be positive");
        }

        // The queue resolves the package by joining this against its own root, so a name that could
        // escape the root, or one that does not follow from the archive identity, is refused before
        // it can be written down.
        if (!string.Equals(PackageFileName, ArchiveId + PackageExtension, StringComparison.Ordinal))
        {
            throw ArchiveDeliveryException.Invalid("packageFileName must be the archive id plus " + PackageExtension);
        }

        if (!DeliveryTransports.IsKnown(Transport))
        {
            throw ArchiveDeliveryException.Invalid("transport '" + Transport + "' is not admitted");
        }

        if (string.IsNullOrEmpty(MappingVersion))
        {
            throw ArchiveDeliveryException.Invalid("mappingVersion must not be empty");
        }

        if (Attempt < 0)
        {
            throw ArchiveDeliveryException.Invalid("attempt must not be negative");
        }

        if (Timestamps.TryParseRfc3339(QueuedAt) is null || Timestamps.TryParseRfc3339(UpdatedAt) is null)
        {
            throw ArchiveDeliveryException.Invalid("queuedAt and updatedAt must be RFC 3339 instants");
        }

        if (NextAttemptAt is not null && Timestamps.TryParseRfc3339(NextAttemptAt) is null)
        {
            throw ArchiveDeliveryException.Invalid("nextAttemptAt must be an RFC 3339 instant when present");
        }

        if (ErrorCode is { Length: 0 })
        {
            throw ArchiveDeliveryException.Invalid("errorCode must not be empty when present");
        }

        // A receipt is what makes "acked" mean anything, and an unacknowledged delivery holding one
        // would let a later reader believe the server had spoken when it had not.
        if (State == DeliveryLifecycle.Acked)
        {
            if (string.IsNullOrEmpty(ReceiptId))
            {
                throw ArchiveDeliveryException.Invalid("an acknowledged delivery must carry a receipt");
            }
        }
        else if (ReceiptId is not null)
        {
            throw ArchiveDeliveryException.Invalid("only an acknowledged delivery may carry a receipt");
        }
    }

    /// <summary>The immutable half of the record, as an ordered comparison key.</summary>
    internal IReadOnlyList<string> ImmutableIdentity() => new[]
    {
        ArchiveId,
        OriginId,
        string.Join(",", CaptureIds),
        FormatVersion.ToString(System.Globalization.CultureInfo.InvariantCulture),
        Revision.ToString(System.Globalization.CultureInfo.InvariantCulture),
        ContentDigest,
        RawSha256,
        ByteLength.ToString(System.Globalization.CultureInfo.InvariantCulture),
        PackageFileName,
        Transport,
    };

    private static string Text(JsonObject value, string key) =>
        (string?)value[key] ?? throw ArchiveDeliveryException.Invalid("'" + key + "' is missing");

    /// <summary>
    /// Reads an integer property. Integers are read as 64-bit and narrowed on purpose: the strict
    /// parser types every whole number as <see cref="long"/>, and asking it for an
    /// <see cref="int"/> directly throws rather than converting.
    /// </summary>
    private static int Number(JsonObject value, string key)
    {
        long number = Number64(value, key);
        if (number is < int.MinValue or > int.MaxValue)
        {
            throw ArchiveDeliveryException.Invalid("'" + key + "' is outside the 32-bit range");
        }

        return (int)number;
    }

    private static long Number64(JsonObject value, string key) =>
        (long?)value[key] ?? throw ArchiveDeliveryException.Invalid("'" + key + "' is missing");
}
