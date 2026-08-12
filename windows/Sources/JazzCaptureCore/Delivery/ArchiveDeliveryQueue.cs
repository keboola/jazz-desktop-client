using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using JazzCaptureCore.Journal;
using JazzCaptureCore.Json;

namespace JazzCaptureCore.Delivery;

/// <summary>What a caller knows about a confirmed archive when it queues it for delivery.</summary>
/// <remarks>
/// Everything here is read out of the finalized archive itself, never invented by the caller: the
/// identifiers and the revision come from the manifest, and the two digests are what the archive
/// says about its own bytes. The queue adds the raw container digest and byte length by measuring
/// the package it is about to own.
/// </remarks>
public sealed record ArchiveDeliveryDescriptor
{
    /// <summary>Archive being delivered.</summary>
    public required string ArchiveId { get; init; }

    /// <summary>Producer origin of the archive.</summary>
    public required string OriginId { get; init; }

    /// <summary>Captures the archive contains; at least one, distinct.</summary>
    public required IReadOnlyList<string> CaptureIds { get; init; }

    /// <summary>Logical content digest — <c>manifest.contentDigest</c>.</summary>
    public required string ContentDigest { get; init; }

    /// <summary>Archive format version.</summary>
    public int FormatVersion { get; init; } = 1;

    /// <summary>Archive revision.</summary>
    public int Revision { get; init; } = 1;

    /// <summary>
    /// Finalized archive directory whose <c>sync/</c> subtree receives the state projection. Absent
    /// when the caller does not want one, or when the local evidence is no longer on this machine.
    /// </summary>
    public string? ArchiveDirectory { get; init; }
}

/// <summary>Everything a queue listing found, including what it could not read.</summary>
/// <param name="Records">Readable deliveries, ordered by queue time then archive identity.</param>
/// <param name="Unreadable">
/// Archive identities whose record file could not be parsed. They are reported rather than thrown,
/// so a single damaged record cannot hide every delivery behind it.
/// </param>
public sealed record ArchiveDeliveryListing(
    IReadOnlyList<ArchiveDeliveryRecord> Records,
    IReadOnlyList<string> Unreadable);

/// <summary>
/// The durable queue of confirmed archives awaiting delivery.
/// </summary>
/// <remarks>
/// <para>
/// On disk the queue is its own root directory: <c>&lt;root&gt;/&lt;archiveId&gt;.jazz-archive</c>
/// holds the exact confirmed container bytes and <c>&lt;root&gt;/records/&lt;archiveId&gt;.json</c>
/// holds the durable delivery record. Nothing else is authoritative — in particular, no in-memory
/// state survives this object, so the queue after a relaunch is exactly the queue before the crash.
/// </para>
/// <para>
/// The ordering rule is the whole crash-safety argument in one line: <em>an intent is durable before
/// the request that acts on it</em>. Enqueue commits the package bytes to stable storage, then the
/// record; <see cref="BeginAttempt"/> commits the attempt before the transport is called;
/// <see cref="Acknowledge"/> commits the receipt before the delivery is considered done. Every
/// window a crash can fall into therefore leaves a state that is either safe to repeat or already
/// final, and never one that claims an outcome the queue did not observe.
/// </para>
/// <para>
/// Listing is metadata only. It never hashes a package, both because that made every status refresh
/// cost the whole queue on macOS and because one damaged package would then throw before any healthy
/// delivery behind it could be seen. The exact fingerprint check happens in
/// <see cref="VerifiedPackagePath"/>, immediately before the bytes are handed to a transport, where
/// failing closed costs exactly one delivery.
/// </para>
/// <para>
/// One writer per root, like the capture journal. There is no cross-process lease here; the host
/// runs a single delivery pass at a time.
/// </para>
/// </remarks>
public sealed class ArchiveDeliveryQueue
{
    /// <summary>Subdirectory of the queue root that holds the durable records.</summary>
    public const string RecordsDirectoryName = "records";

    /// <summary>Extension of a durable record file.</summary>
    public const string RecordExtension = ".json";

    private static readonly UTF8Encoding Utf8NoBom = new(encoderShouldEmitUTF8Identifier: false);

    private readonly string _root;
    private readonly string _recordsDirectory;
    private readonly Func<DateTimeOffset> _clock;

    /// <summary>Opens the queue rooted at <paramref name="root"/>, creating nothing yet.</summary>
    /// <param name="root">Directory that holds the packages and the record store.</param>
    /// <param name="clock">Time source; defaults to the system UTC clock.</param>
    public ArchiveDeliveryQueue(string root, Func<DateTimeOffset>? clock = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(root);

        _root = Path.GetFullPath(root);
        _recordsDirectory = Path.Combine(_root, RecordsDirectoryName);
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
    }

    /// <summary>Directory the queue owns.</summary>
    public string Root => _root;

    /// <summary>Absolute path the package for <paramref name="archiveId"/> occupies, verified or not.</summary>
    public string PackagePath(string archiveId)
    {
        ArgumentException.ThrowIfNullOrEmpty(archiveId);
        RequireArchiveId(archiveId);
        return Path.Combine(_root, archiveId + ArchiveDeliveryRecord.PackageExtension);
    }

    /// <summary>
    /// Takes durable ownership of the package already written at <see cref="PackagePath(string)"/>
    /// and records the intent to deliver it.
    /// </summary>
    /// <remarks>
    /// Re-queueing the same confirmed archive is a no-op that returns the delivery already on disk,
    /// including one that has already been acknowledged. The same archive identity presented with
    /// different bytes or different metadata is not a repeat but a collision: it fails closed, and
    /// the delivery already on disk is stopped rather than quietly rebound to bytes nobody
    /// confirmed.
    /// </remarks>
    /// <exception cref="ArchiveDeliveryException">
    /// The package is missing, or the archive identity collides with a different delivery.
    /// </exception>
    public ArchiveDeliveryRecord Enqueue(ArchiveDeliveryDescriptor descriptor)
    {
        ArgumentNullException.ThrowIfNull(descriptor);

        string archiveId = descriptor.ArchiveId;
        RequireArchiveId(archiveId);

        string packagePath = PackagePath(archiveId);
        if (!File.Exists(packagePath))
        {
            throw ArchiveDeliveryException.PackageMissing(archiveId);
        }

        (string rawSha256, long byteLength) = Fingerprint(packagePath);
        string now = Timestamps.IsoMillisUtc(_clock());

        var candidate = new ArchiveDeliveryRecord
        {
            DeliveryId = DeliveryIds.NewDeliveryId(),
            ArchiveId = archiveId,
            OriginId = descriptor.OriginId,
            CaptureIds = descriptor.CaptureIds.ToArray(),
            FormatVersion = descriptor.FormatVersion,
            Revision = descriptor.Revision,
            ContentDigest = descriptor.ContentDigest,
            RawSha256 = rawSha256,
            ByteLength = byteLength,
            PackageFileName = archiveId + ArchiveDeliveryRecord.PackageExtension,
            ArchiveDirectory = descriptor.ArchiveDirectory is null
                ? null
                : Path.GetFullPath(descriptor.ArchiveDirectory),
            State = DeliveryLifecycle.Pending,
            Attempt = 0,
            QueuedAt = now,
            UpdatedAt = now,
        };
        candidate.Validate();

        ArchiveDeliveryRecord? existing = Find(archiveId);
        if (existing is not null)
        {
            if (!existing.ImmutableIdentity().SequenceEqual(candidate.ImmutableIdentity(), StringComparer.Ordinal))
            {
                // An acknowledged delivery is a statement about bytes the server already holds. It
                // is not the thing that is wrong here, so it stands and only the caller is refused.
                if (existing.State != DeliveryLifecycle.Acked)
                {
                    Commit(existing with
                    {
                        State = DeliveryLifecycle.PermanentFailure,
                        ErrorCode = DeliveryErrorCodes.ArchiveIdCollision,
                        NextAttemptAt = null,
                        UpdatedAt = now,
                    });
                }

                throw ArchiveDeliveryException.Collision(archiveId);
            }

            SynchronizePackage(packagePath);
            Project(existing);
            return existing;
        }

        // The bytes reach stable storage before any record claims they exist. A crash in this window
        // leaves an unreferenced package, which the next confirmation adopts byte for byte; the
        // reverse order would leave a record pointing at bytes that were never committed.
        SynchronizePackage(packagePath);
        Durability.TryFlushDirectory(_root);

        Commit(candidate);
        return candidate;
    }

    /// <summary>The delivery queued for <paramref name="archiveId"/>, or null.</summary>
    /// <exception cref="ArchiveDeliveryException">The record file exists but is not well formed.</exception>
    public ArchiveDeliveryRecord? Find(string archiveId)
    {
        ArgumentException.ThrowIfNullOrEmpty(archiveId);
        RequireArchiveId(archiveId);

        string path = RecordPath(archiveId);
        if (!File.Exists(path))
        {
            return null;
        }

        ArchiveDeliveryRecord record = Load(path);
        if (!string.Equals(record.ArchiveId, archiveId, StringComparison.Ordinal))
        {
            throw ArchiveDeliveryException.Invalid("record file name does not match its archiveId");
        }

        return record;
    }

    /// <summary>
    /// Every delivery on disk, ordered by queue time then archive identity, plus the identities of
    /// any record that could not be read. No package is opened or hashed.
    /// </summary>
    public ArchiveDeliveryListing List()
    {
        if (!Directory.Exists(_recordsDirectory))
        {
            return new ArchiveDeliveryListing(Array.Empty<ArchiveDeliveryRecord>(), Array.Empty<string>());
        }

        var records = new List<ArchiveDeliveryRecord>();
        var unreadable = new List<string>();

        foreach (string path in Directory.EnumerateFiles(_recordsDirectory, "*" + RecordExtension))
        {
            if (path.EndsWith(Durability.TemporaryFileSuffix, StringComparison.Ordinal))
            {
                continue;
            }

            string name = Path.GetFileNameWithoutExtension(path);
            try
            {
                ArchiveDeliveryRecord record = Load(path);
                if (!string.Equals(record.ArchiveId, name, StringComparison.Ordinal))
                {
                    unreadable.Add(name);
                    continue;
                }

                records.Add(record);
            }
            catch (ArchiveDeliveryException)
            {
                unreadable.Add(name);
            }
        }

        records.Sort(static (left, right) =>
        {
            int byQueuedAt = string.CompareOrdinal(left.QueuedAt, right.QueuedAt);
            return byQueuedAt != 0 ? byQueuedAt : string.CompareOrdinal(left.ArchiveId, right.ArchiveId);
        });
        unreadable.Sort(StringComparer.Ordinal);

        return new ArchiveDeliveryListing(records, unreadable);
    }

    /// <summary>Deliveries a pass may attempt now, in queue order.</summary>
    public IReadOnlyList<ArchiveDeliveryRecord> Runnable(DateTimeOffset? now = null)
    {
        DateTimeOffset at = now ?? _clock();
        return List().Records.Where(record => record.IsRunnable(at)).ToArray();
    }

    /// <summary>
    /// Proves the queue-owned package is byte for byte what the record committed, and returns its
    /// path.
    /// </summary>
    /// <remarks>
    /// This is the fail-closed gate every attempt passes through. It is what makes "a retry sends the
    /// same bytes" a checked fact rather than an assumption, and it is deliberately per delivery: a
    /// package that has been damaged fails here on its own, while every other delivery in the queue
    /// carries on.
    /// </remarks>
    /// <exception cref="ArchiveDeliveryException">
    /// The delivery is unknown, the package is gone, or its bytes no longer match the record.
    /// </exception>
    public string VerifiedPackagePath(string archiveId)
    {
        ArchiveDeliveryRecord record = Require(archiveId);
        string path = Path.Combine(_root, record.PackageFileName);

        if (!File.Exists(path))
        {
            throw ArchiveDeliveryException.PackageMissing(archiveId);
        }

        if (new FileInfo(path).Length != record.ByteLength)
        {
            throw ArchiveDeliveryException.PackageChanged(archiveId);
        }

        (string rawSha256, long byteLength) = Fingerprint(path);
        if (byteLength != record.ByteLength
            || !string.Equals(rawSha256, record.RawSha256, StringComparison.Ordinal))
        {
            throw ArchiveDeliveryException.PackageChanged(archiveId);
        }

        return path;
    }

    /// <summary>
    /// Commits one more attempt before the request that will make it real.
    /// </summary>
    /// <remarks>
    /// Called from in-flight as well, which is the crash-recovery path: a process that died before
    /// hearing an outcome resumes by counting a fresh attempt against the same durable delivery
    /// identity, so the far end sees a repeat rather than a new delivery.
    /// </remarks>
    /// <exception cref="ArchiveDeliveryException">The delivery is unknown or already terminal.</exception>
    public ArchiveDeliveryRecord BeginAttempt(string archiveId)
    {
        ArchiveDeliveryRecord record = Require(archiveId);
        if (record.IsTerminal)
        {
            throw ArchiveDeliveryException.InvalidTransition(archiveId, record.State, DeliveryLifecycle.InFlight);
        }

        return Commit(record with
        {
            State = DeliveryLifecycle.InFlight,
            Attempt = record.Attempt + 1,
            ErrorCode = null,
            NextAttemptAt = null,
            UpdatedAt = Timestamps.IsoMillisUtc(_clock()),
        });
    }

    /// <summary>
    /// Records that the far end holds these exact bytes. Terminal: the delivery is never attempted
    /// again.
    /// </summary>
    /// <exception cref="ArchiveDeliveryException">
    /// The delivery is unknown, was not in flight, or was already acknowledged under a different
    /// receipt.
    /// </exception>
    public ArchiveDeliveryRecord Acknowledge(string archiveId, string receiptId)
    {
        ArgumentException.ThrowIfNullOrEmpty(receiptId);

        ArchiveDeliveryRecord record = Require(archiveId);
        if (record.State == DeliveryLifecycle.Acked)
        {
            // Replaying an acknowledgement the queue already holds is the ordinary outcome of a
            // crash between the request and this commit, and it must be a no-op.
            if (string.Equals(record.ReceiptId, receiptId, StringComparison.Ordinal))
            {
                return record;
            }

            throw ArchiveDeliveryException.Conflict(
                archiveId,
                "a second receipt was offered for a delivery the server already acknowledged");
        }

        if (record.State != DeliveryLifecycle.InFlight)
        {
            throw ArchiveDeliveryException.InvalidTransition(archiveId, record.State, DeliveryLifecycle.Acked);
        }

        return Commit(record with
        {
            State = DeliveryLifecycle.Acked,
            ReceiptId = receiptId,
            ErrorCode = null,
            NextAttemptAt = null,
            UpdatedAt = Timestamps.IsoMillisUtc(_clock()),
        });
    }

    /// <summary>
    /// Records a failure another attempt may survive, and commits the instant that attempt becomes
    /// due.
    /// </summary>
    /// <param name="archiveId">Delivery that failed.</param>
    /// <param name="errorCode">Why it failed.</param>
    /// <param name="serverNextAttemptAt">
    /// A server-chosen retry instant. When supplied it is authoritative; otherwise the bounded
    /// jittered client policy chooses one.
    /// </param>
    /// <exception cref="ArchiveDeliveryException">The delivery is unknown or already terminal.</exception>
    public ArchiveDeliveryRecord MarkRetryable(
        string archiveId,
        string errorCode,
        DateTimeOffset? serverNextAttemptAt = null)
    {
        ArgumentException.ThrowIfNullOrEmpty(errorCode);

        ArchiveDeliveryRecord record = Require(archiveId);
        if (record.IsTerminal)
        {
            throw ArchiveDeliveryException.InvalidTransition(archiveId, record.State, DeliveryLifecycle.Failed);
        }

        DateTimeOffset anchor = _clock();
        DateTimeOffset due = serverNextAttemptAt
            ?? ArchiveDeliveryRetryPolicy.NextAttemptAt(anchor, record.Attempt, record.DeliveryId);

        return Commit(record with
        {
            State = DeliveryLifecycle.Failed,
            ErrorCode = errorCode,
            NextAttemptAt = Timestamps.IsoMillisUtc(due),
            UpdatedAt = Timestamps.IsoMillisUtc(anchor),
        });
    }

    /// <summary>
    /// Stops the delivery. Terminal: no backoff is scheduled and no pass will pick it up again.
    /// </summary>
    /// <exception cref="ArchiveDeliveryException">The delivery is unknown or already acknowledged.</exception>
    public ArchiveDeliveryRecord MarkPermanentFailure(string archiveId, string errorCode)
    {
        ArgumentException.ThrowIfNullOrEmpty(errorCode);

        ArchiveDeliveryRecord record = Require(archiveId);
        if (record.State == DeliveryLifecycle.PermanentFailure)
        {
            return record;
        }

        if (record.State == DeliveryLifecycle.Acked)
        {
            throw ArchiveDeliveryException.InvalidTransition(
                archiveId,
                record.State,
                DeliveryLifecycle.PermanentFailure);
        }

        return Commit(record with
        {
            State = DeliveryLifecycle.PermanentFailure,
            ErrorCode = errorCode,
            NextAttemptAt = null,
            UpdatedAt = Timestamps.IsoMillisUtc(_clock()),
        });
    }

    /// <summary>The delivery for <paramref name="archiveId"/>, or a refusal when there is none.</summary>
    /// <exception cref="ArchiveDeliveryException">No delivery is queued for that archive.</exception>
    public ArchiveDeliveryRecord Require(string archiveId) =>
        Find(archiveId) ?? throw ArchiveDeliveryException.Missing(archiveId);

    /// <summary>Lowercase hex SHA-256 and byte length of a file, read once.</summary>
    private static (string Sha256, long ByteLength) Fingerprint(string path)
    {
        using FileStream stream = new(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        long length = stream.Length;
        return (Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant(), length);
    }

    /// <summary>
    /// Forces the package bytes to stable storage. The container writer streams them through the
    /// ordinary buffered path, so without this the record could outlive the bytes it names.
    /// </summary>
    private static void SynchronizePackage(string path)
    {
        using FileStream stream = new(path, FileMode.Open, FileAccess.Write, FileShare.Read);
        stream.Flush(flushToDisk: true);
    }

    private string RecordPath(string archiveId) =>
        Path.Combine(_recordsDirectory, archiveId + RecordExtension);

    private static void RequireArchiveId(string archiveId)
    {
        // The identity reaches the filesystem verbatim as both a package and a record name, so a
        // value that is not exactly 'ar-' plus a UUIDv7 never gets that far.
        if (!DeliveryIds.IsArchiveId(archiveId))
        {
            throw ArchiveDeliveryException.Invalid("archiveId '" + archiveId + "' is not 'ar-' plus a UUIDv7");
        }
    }

    private static ArchiveDeliveryRecord Load(string path)
    {
        try
        {
            JsonNode? node = JsonStrictParser.Parse(File.ReadAllBytes(path));
            return node is JsonObject value
                ? ArchiveDeliveryRecord.FromJson(value)
                : throw ArchiveDeliveryException.Invalid("record is not a JSON object: " + path);
        }
        catch (FormatException exception)
        {
            throw new ArchiveDeliveryException(
                ArchiveDeliveryErrorKind.InvalidRecord,
                "Corrupt archive delivery record " + path + ".",
                exception);
        }
    }

    /// <summary>
    /// Publishes the record durably, then refreshes its projection. The record is the authority, so
    /// it is committed first and the projection can never be ahead of it.
    /// </summary>
    private ArchiveDeliveryRecord Commit(ArchiveDeliveryRecord record)
    {
        record.Validate();

        try
        {
            Durability.ReplaceAtomic(
                RecordPath(record.ArchiveId),
                Utf8NoBom.GetBytes(JsonCanonicalizer.Canonicalize(record.ToJson()) + "\n"));
            Durability.TryFlushDirectoryChain(_recordsDirectory, _root);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            throw ArchiveDeliveryException.PersistenceFailed(record.ArchiveId, exception);
        }

        Project(record);
        return record;
    }

    /// <summary>
    /// Writes the contract-shaped state into the archive's never-exported <c>sync/</c> subtree.
    /// </summary>
    /// <remarks>
    /// An archive directory the user has removed is not an error: the queue owns the package and the
    /// record, and delivery continues without a local projection. A directory that is there but
    /// cannot be written to is a different matter and is reported.
    /// </remarks>
    private void Project(ArchiveDeliveryRecord record)
    {
        if (record.ArchiveDirectory is not { } directory || !Directory.Exists(directory))
        {
            return;
        }

        try
        {
            ArchiveDeliverySyncLog.Publish(directory, record.ToStateDocument());
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            throw ArchiveDeliveryException.PersistenceFailed(record.ArchiveId, exception);
        }
    }
}

/// <summary>Failure codes this client writes into a delivery state.</summary>
public static class DeliveryErrorCodes
{
    /// <summary>The same archive identity was presented with different immutable bytes or metadata.</summary>
    public const string ArchiveIdCollision = "ARCHIVE_ID_COLLISION";

    /// <summary>The queue-owned package no longer matches the bytes the queue committed.</summary>
    public const string LocalIntegrityConflict = "ARCHIVE_LOCAL_INTEGRITY_CONFLICT";

    /// <summary>The queue-owned package is not on disk.</summary>
    public const string PackageMissing = "ARCHIVE_PACKAGE_MISSING";

    /// <summary>The transport failed in a way that says nothing about the package.</summary>
    public const string DeliveryUnavailable = "ARCHIVE_DELIVERY_UNAVAILABLE";
}
