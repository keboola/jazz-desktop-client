namespace JazzCaptureCore.Delivery;

/// <summary>
/// One attempt to deliver one immutable archive package.
/// </summary>
/// <remarks>
/// <para>
/// <see cref="DeliveryId"/> is the idempotency key. It is minted once, committed to disk before the
/// first request, and reused by every retry and every relaunch — so a transport that has already
/// seen it is looking at a repeat of an operation it has answered, not at a second delivery. A
/// transport implementation must return the original receipt for a repeated identity rather than
/// storing the object again.
/// </para>
/// <para>
/// <see cref="RawSha256"/>, <see cref="ByteLength"/> and <see cref="ContentDigest"/> travel with the
/// request so the far end can refuse bytes that do not match what the client says it is sending, and
/// so a repeat can be recognised as byte-identical rather than merely same-named.
/// </para>
/// </remarks>
/// <param name="DeliveryId">Durable idempotency identity, <c>del-</c> plus a UUIDv7.</param>
/// <param name="ArchiveId">Archive being delivered.</param>
/// <param name="OriginId">Producer origin of the archive.</param>
/// <param name="CaptureIds">Captures the archive contains.</param>
/// <param name="FormatVersion">Archive format version.</param>
/// <param name="Revision">Archive revision.</param>
/// <param name="ContentDigest">Logical content digest of the manifest.</param>
/// <param name="RawSha256">SHA-256 of the exact container bytes, verified immediately before this call.</param>
/// <param name="ByteLength">Length of the exact container bytes.</param>
/// <param name="Attempt">Number of this attempt, starting at 1.</param>
/// <param name="PackagePath">
/// Absolute path of the queue-owned package. It is read-only as far as the transport is concerned;
/// the queue has just proved these bytes hash to <paramref name="RawSha256"/>.
/// </param>
public sealed record ArchiveDeliveryRequest(
    string DeliveryId,
    string ArchiveId,
    string OriginId,
    IReadOnlyList<string> CaptureIds,
    int FormatVersion,
    int Revision,
    string ContentDigest,
    string RawSha256,
    long ByteLength,
    int Attempt,
    string PackagePath);

/// <summary>What a transport concluded about one attempt.</summary>
public enum ArchiveDeliveryOutcomeKind
{
    /// <summary>The far end holds these exact bytes and said so.</summary>
    Acknowledged,

    /// <summary>Nothing is wrong with the package; another attempt may succeed.</summary>
    Retryable,

    /// <summary>Another identical attempt cannot succeed. Stop.</summary>
    Permanent,
}

/// <summary>
/// The result of one delivery attempt.
/// </summary>
/// <remarks>
/// Retryable and permanent are separate cases rather than one failure with a flag, because the queue
/// treats them as opposites: a retryable failure schedules a bounded backoff and keeps the delivery
/// alive, and a permanent one stops it. A transport that cannot tell the two apart must return
/// <see cref="Retryable"/> — waiting costs time, whereas abandoning a deliverable archive costs the
/// recording.
/// </remarks>
public sealed record ArchiveDeliveryOutcome
{
    private ArchiveDeliveryOutcome(
        ArchiveDeliveryOutcomeKind kind,
        string? receiptId,
        string? errorCode,
        DateTimeOffset? nextAttemptAt)
    {
        Kind = kind;
        ReceiptId = receiptId;
        ErrorCode = errorCode;
        NextAttemptAt = nextAttemptAt;
    }

    /// <summary>What the transport concluded.</summary>
    public ArchiveDeliveryOutcomeKind Kind { get; }

    /// <summary>Opaque acknowledgement; present exactly when acknowledged.</summary>
    public string? ReceiptId { get; }

    /// <summary>Failure code; present exactly when not acknowledged.</summary>
    public string? ErrorCode { get; }

    /// <summary>
    /// Server-chosen earliest next attempt. When present it is authoritative and replaces the
    /// client's bounded backoff.
    /// </summary>
    public DateTimeOffset? NextAttemptAt { get; }

    /// <summary>The far end holds these bytes.</summary>
    /// <exception cref="ArgumentException"><paramref name="receiptId"/> is empty.</exception>
    public static ArchiveDeliveryOutcome Acknowledged(string receiptId)
    {
        ArgumentException.ThrowIfNullOrEmpty(receiptId);
        return new ArchiveDeliveryOutcome(ArchiveDeliveryOutcomeKind.Acknowledged, receiptId, null, null);
    }

    /// <summary>The attempt failed but the delivery is still viable.</summary>
    /// <exception cref="ArgumentException"><paramref name="errorCode"/> is empty.</exception>
    public static ArchiveDeliveryOutcome Retryable(string errorCode, DateTimeOffset? nextAttemptAt = null)
    {
        ArgumentException.ThrowIfNullOrEmpty(errorCode);
        return new ArchiveDeliveryOutcome(ArchiveDeliveryOutcomeKind.Retryable, null, errorCode, nextAttemptAt);
    }

    /// <summary>The delivery cannot succeed and must stop.</summary>
    /// <exception cref="ArgumentException"><paramref name="errorCode"/> is empty.</exception>
    public static ArchiveDeliveryOutcome Permanent(string errorCode)
    {
        ArgumentException.ThrowIfNullOrEmpty(errorCode);
        return new ArchiveDeliveryOutcome(ArchiveDeliveryOutcomeKind.Permanent, null, errorCode, null);
    }
}

/// <summary>
/// Where confirmed archives actually go.
/// </summary>
/// <remarks>
/// <para>
/// The queue, its durability, its retry schedule and its idempotence are all defined against this
/// interface and are provable without a network. Everything that needs a server lives behind it.
/// </para>
/// <para>
/// An implementation must be idempotent on <see cref="ArchiveDeliveryRequest.DeliveryId"/>: a repeat
/// of an operation it has already acknowledged returns the same receipt and stores nothing new. The
/// queue relies on that to recover from a crash between a request and its acknowledgement, which is
/// the one window in which it cannot know whether the bytes arrived.
/// </para>
/// <para>
/// An implementation may throw for a transport-level fault. The coordinator treats any exception
/// other than cancellation as retryable, because a thrown request is exactly the case where the
/// outcome is unknown and the local bytes are still safe.
/// </para>
/// </remarks>
public interface IArchiveDeliveryTransport
{
    /// <summary>Attempts one delivery.</summary>
    Task<ArchiveDeliveryOutcome> DeliverAsync(
        ArchiveDeliveryRequest request,
        CancellationToken cancellationToken);
}
