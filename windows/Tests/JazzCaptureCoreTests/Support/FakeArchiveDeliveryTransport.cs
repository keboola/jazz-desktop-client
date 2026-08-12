using System.Security.Cryptography;
using JazzCaptureCore.Delivery;

namespace JazzCaptureCoreTests.Support;

/// <summary>One call the transport received, with the bytes it was actually given.</summary>
/// <param name="DeliveryId">Durable idempotency identity the queue presented.</param>
/// <param name="ArchiveId">Archive the request named.</param>
/// <param name="Attempt">Attempt number the queue had committed.</param>
/// <param name="DeclaredSha256">Digest the request claimed.</param>
/// <param name="ObservedSha256">Digest of the bytes actually read from the package path.</param>
/// <param name="ObservedByteLength">Length of the bytes actually read.</param>
/// <param name="Bytes">The bytes themselves, so a later attempt can be compared against them.</param>
public sealed record RecordedDelivery(
    string DeliveryId,
    string ArchiveId,
    int Attempt,
    string DeclaredSha256,
    string ObservedSha256,
    long ObservedByteLength,
    byte[] Bytes);

/// <summary>One object the fake server holds.</summary>
/// <param name="DeliveryId">Operation that created it.</param>
/// <param name="Sha256">Digest of the stored bytes.</param>
/// <param name="ByteLength">Length of the stored bytes.</param>
/// <param name="ReceiptId">Receipt the server issued for it.</param>
public sealed record StoredArchive(string DeliveryId, string Sha256, long ByteLength, string ReceiptId);

/// <summary>
/// A transport that stands in for a server that does not exist yet.
/// </summary>
/// <remarks>
/// <para>
/// It is idempotent on the delivery identity, which is the contract every real implementation owes
/// the queue: a repeat of an operation it has already acknowledged returns the original receipt and
/// stores nothing new. That is what lets the tests distinguish "the client sent the request twice",
/// which is expected after a crash, from "the archive was delivered twice", which must never happen.
/// </para>
/// <para>
/// It reads the package from disk on every call and records the digest of what it actually got, so a
/// test can prove the second attempt carried the same bytes rather than trusting the request's own
/// claim about them.
/// </para>
/// </remarks>
public sealed class FakeArchiveDeliveryTransport : IArchiveDeliveryTransport
{
    private readonly List<RecordedDelivery> _requests = new();
    private readonly Dictionary<string, StoredArchive> _stored = new(StringComparer.Ordinal);

    /// <summary>Every call, in order.</summary>
    public IReadOnlyList<RecordedDelivery> Requests => _requests;

    /// <summary>What the fake server holds, keyed by delivery identity.</summary>
    public IReadOnlyDictionary<string, StoredArchive> Stored => _stored;

    /// <summary>Requests that repeated an operation the server had already acknowledged.</summary>
    public int RepeatedOperations { get; private set; }

    /// <summary>
    /// Chooses the outcome. Returning null takes the ordinary acknowledge path, which is what makes
    /// the idempotence above observable.
    /// </summary>
    public Func<ArchiveDeliveryRequest, ArchiveDeliveryOutcome?>? Respond { get; set; }

    /// <summary>Throws the returned exception, if any, after the request has been recorded.</summary>
    public Func<ArchiveDeliveryRequest, Exception?>? Fault { get; set; }

    /// <inheritdoc/>
    public Task<ArchiveDeliveryOutcome> DeliverAsync(
        ArchiveDeliveryRequest request,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        cancellationToken.ThrowIfCancellationRequested();

        byte[] bytes = File.ReadAllBytes(request.PackagePath);
        string observed = Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
        _requests.Add(new RecordedDelivery(
            request.DeliveryId,
            request.ArchiveId,
            request.Attempt,
            request.RawSha256,
            observed,
            bytes.LongLength,
            bytes));

        if (Fault?.Invoke(request) is { } fault)
        {
            throw fault;
        }

        if (Respond?.Invoke(request) is { } scripted)
        {
            return Task.FromResult(scripted);
        }

        if (_stored.TryGetValue(request.DeliveryId, out StoredArchive? existing))
        {
            RepeatedOperations++;
            return Task.FromResult(
                string.Equals(existing.Sha256, observed, StringComparison.Ordinal)
                    ? ArchiveDeliveryOutcome.Acknowledged(existing.ReceiptId)
                    : ArchiveDeliveryOutcome.Permanent("ARCHIVE_DIGEST_CONFLICT"));
        }

        var receipt = "rcpt-" + request.DeliveryId;
        _stored[request.DeliveryId] = new StoredArchive(request.DeliveryId, observed, bytes.LongLength, receipt);
        return Task.FromResult(ArchiveDeliveryOutcome.Acknowledged(receipt));
    }

    /// <summary>
    /// Delivers outside the coordinator, so a test can put bytes on the server and then behave as if
    /// the process died before the acknowledgement was ever committed.
    /// </summary>
    public ArchiveDeliveryOutcome DeliverWithoutRecordingTheOutcome(
        ArchiveDeliveryQueue queue,
        ArchiveDeliveryRecord record)
    {
        ArgumentNullException.ThrowIfNull(queue);
        ArgumentNullException.ThrowIfNull(record);

        return DeliverAsync(
            new ArchiveDeliveryRequest(
                record.DeliveryId,
                record.ArchiveId,
                record.OriginId,
                record.CaptureIds,
                record.FormatVersion,
                record.Revision,
                record.ContentDigest,
                record.RawSha256,
                record.ByteLength,
                record.Attempt,
                queue.VerifiedPackagePath(record.ArchiveId)),
            CancellationToken.None).GetAwaiter().GetResult();
    }
}
