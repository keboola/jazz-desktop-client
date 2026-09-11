using System.Security.Cryptography;
using System.Text.Json;
using JazzCaptureCore.Journal;

namespace JazzCaptureCore.Delivery;

/// <summary>Crash-safe exact-byte spool for live artifacts.  A failed delivery never mutates its
/// bytes or canonical identity; acknowledgement is the only operation that removes an item.</summary>
public sealed class ArtifactDeliveryQueue
{
    private const string MetadataExtension = ".json";
    private static readonly TimeSpan TemporaryPublishGrace = TimeSpan.FromMinutes(5);
    private readonly string root;
    private readonly Action<string>? protectFile;
    private readonly Action<string> deleteFile;
    private readonly Action<string>? protectDirectory;

    public ArtifactDeliveryQueue(
        string root,
        Action<string>? protectFile = null,
        Action<string>? deleteFile = null,
        Action<string>? protectDirectory = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(root);
        this.root = Path.GetFullPath(root);
        this.protectFile = protectFile;
        this.deleteFile = deleteFile ?? File.Delete;
        this.protectDirectory = protectDirectory;
    }

    public ArtifactDeliveryRecord Enqueue(ArtifactDeliveryDescriptor descriptor)
    {
        ArgumentNullException.ThrowIfNull(descriptor);
        return Enqueue(descriptor, ArtifactDeliveryRecord.From(descriptor));
    }

    /// <summary>Persists the canonical event/context before the artifact can be delivered. Only
    /// screenshots are eligible: narration keeps its own #48 path.</summary>
    public ArtifactDeliveryRecord EnqueueScreenshot(
        ArtifactDeliveryDescriptor descriptor,
        ActivityEvent activityEvent,
        SessionContext context)
    {
        ArgumentNullException.ThrowIfNull(descriptor);
        ArgumentNullException.ThrowIfNull(activityEvent);
        ArgumentNullException.ThrowIfNull(context);
        if (descriptor.ScreenshotId != descriptor.ArtifactId)
        {
            throw new ArgumentException("Only a canonical screenshot artifact can enter this queue.");
        }
        if (string.IsNullOrWhiteSpace(activityEvent.SessionId)
            || string.IsNullOrWhiteSpace(activityEvent.EventId)
            || activityEvent.SessionId != context.SessionId)
        {
            throw new ArgumentException("Screenshot delivery requires matching canonical session and event identity.");
        }

        ArtifactDeliveryRecord record = ArtifactDeliveryRecord.From(descriptor) with
        {
            CanonicalEvent = activityEvent,
            Context = context,
        };
        return Enqueue(descriptor, record);
    }

    public IReadOnlyList<ArtifactDeliveryRecord> Pending()
    {
        if (!EnsureRoot(create: false))
        {
            throw new DirectoryNotFoundException("Artifact delivery spool is unavailable.");
        }

        var result = new List<ArtifactDeliveryRecord>();
        foreach (string path in Directory
            .EnumerateFiles(root, "*" + MetadataExtension)
            .OrderBy(Path.GetFileName, StringComparer.Ordinal))
        {
            try
            {
                ArtifactDeliveryRecord record = Read(path);
                if (!IsCanonicalMetadataPath(path, record))
                {
                    continue;
                }
                if (record.Acknowledged)
                {
                    if (!HasValidAcknowledgement(record))
                        throw new InvalidOperationException("Artifact completion marker is malformed.");
                    try { CleanupAcknowledged(record); }
                    catch
                    {
                        // The marker is already durable. Retain it for the next recovery pass
                        // without replaying OTLP; this is cleanup debt, not unreadable metadata.
                    }
                    continue;
                }
                result.Add(record);
            }
            catch (Exception exception) when (!IsTransientFilesystemFailure(exception))
            {
                // A corrupt or inaccessible item is retained; healthy siblings still progress.
            }
        }
        return result;
    }

    /// <summary>Number of durable metadata items, including malformed items retained for attention.</summary>
    /// <summary>Counts retained metadata in one enumeration. It does not invoke recovery cleanup;
    /// malformed entries remain visible, while a marker whose payload cleanup already finished is
    /// not reported as pending delivery.</summary>
    public int PendingFileCount
    {
        get
        {
            if (!EnsureRoot(create: false)) throw new DirectoryNotFoundException(
                "Artifact delivery spool is unavailable.");
            int count = 0;
            foreach (string path in Directory.EnumerateFiles(root, "*" + MetadataExtension))
            {
                try
                {
                    ArtifactDeliveryRecord record = Read(path);
                    if (!IsCanonicalMetadataPath(path, record))
                    {
                        count++;
                        continue;
                    }
                    if (record.Acknowledged)
                    {
                        if (!HasValidAcknowledgement(record))
                        {
                            count++;
                            continue;
                        }
                        // Completion is a durable lifecycle state, not pending delivery. Keep
                        // the marker for journal reconciliation while cleanup removes payloads.
                        continue;
                    }
                    // Keep the durable completion marker visible until Pending() successfully
                    // removes it. Otherwise a failed metadata cleanup would never be revisited.
                }
                catch (Exception exception) when (!IsTransientFilesystemFailure(exception)) { }
                count++;
            }
            return count;
        }
    }

    public void MarkQuarantined(ArtifactDeliveryRecord record)
    {
        if (!EnsureRoot(create: false)) throw new DirectoryNotFoundException();
        ArtifactDeliveryRecord existing = Read(Path.Combine(root, Key(record.ArtifactId) + MetadataExtension));
        if (!HasSameAdmissionIdentity(existing, record))
            throw new InvalidOperationException("Artifact quarantine does not match durable identity.");
        Write(existing with { Quarantined = true });
    }

    /// <summary>Checks only for the durable metadata marker. Reconciliation uses this before it
    /// revalidates an admitted journal handoff, avoiding an unsafe re-admission when normal
    /// acknowledged cleanup already removed the record.</summary>
    public bool HasDurableMetadata(string artifactId)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(artifactId);
        if (!EnsureRoot(create: false)) throw new DirectoryNotFoundException();
        string path = Path.Combine(root, Key(artifactId) + MetadataExtension);
        if (!File.Exists(path)) return false;
        RejectReparseFile(path);
        protectFile?.Invoke(path);
        RejectReparseFile(path);
        return true;
    }

    /// <summary>Durably fences the existing record after an
    /// <see cref="ArtifactDeliveryAdmissionConflictException"/>. The caller must not use this for
    /// retryable filesystem failures, which intentionally retain ordinary admission eligibility.</summary>
    public void QuarantineExistingAdmissionConflict(string artifactId)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(artifactId);
        if (!EnsureRoot(create: false)) throw new DirectoryNotFoundException();
        ArtifactDeliveryRecord existing = Read(Path.Combine(root, Key(artifactId) + MetadataExtension));
        Write(existing with { Quarantined = true });
    }

    /// <summary>Explicit local repair hook. Ordinary capture nudges never clear terminal state.</summary>
    public void RequeueQuarantined(ArtifactDeliveryRecord record)
    {
        if (!EnsureRoot(create: false)) throw new DirectoryNotFoundException();
        ArtifactDeliveryRecord existing = Read(Path.Combine(root, Key(record.ArtifactId) + MetadataExtension));
        if (!existing.Quarantined || !HasSameAdmissionIdentity(existing, record))
            throw new InvalidOperationException("Artifact requeue does not match quarantined durable state.");
        Write(existing with { Quarantined = false });
    }

    /// <summary>Counts unreadable metadata from one stable enumeration; it never infers this from
    /// two racing directory snapshots.</summary>
    public int UnreadableFileCount
    {
        get
        {
            if (!EnsureRoot(create: false)) throw new DirectoryNotFoundException(
                "Artifact delivery spool is unavailable.");
            int unreadable = 0;
            foreach (string path in Directory.EnumerateFiles(root, "*" + MetadataExtension))
            {
                try
                {
                    ArtifactDeliveryRecord record = Read(path);
                    if (!IsCanonicalMetadataPath(path, record)
                        || (record.Acknowledged && !HasValidAcknowledgement(record))) unreadable++;
                }
                catch (Exception exception) when (!IsTransientFilesystemFailure(exception)) { unreadable++; }
            }
            return unreadable;
        }
    }

    /// <summary>Counts legacy/unassociated payload files without deleting them. They have no
    /// metadata identity proving acknowledgement, so recovery must surface attention instead of
    /// guessing that they are safe cleanup candidates.</summary>
    public int OrphanFileCount
    {
        get
        {
            if (!EnsureRoot(create: false)) throw new DirectoryNotFoundException(
                "Artifact delivery spool is unavailable.");
            var metadataKeys = new HashSet<string>(StringComparer.Ordinal);
            foreach (string path in Directory.EnumerateFiles(root, "*" + MetadataExtension))
            {
                try
                {
                    ArtifactDeliveryRecord record = Read(path);
                    if (IsCanonicalMetadataPath(path, record)) metadataKeys.Add(Key(record.ArtifactId));
                }
                catch (Exception exception) when (!IsTransientFilesystemFailure(exception)) { }
            }
            return Directory.EnumerateFiles(root, "*.bin")
                .Concat(Directory.EnumerateFiles(root, "*.otlp"))
                .Concat(Directory.EnumerateFiles(root, "*" + Durability.TemporaryFileSuffix)
                    .Where(path => File.GetLastWriteTimeUtc(path)
                        <= DateTime.UtcNow.Subtract(TemporaryPublishGrace)))
                .Count(path => IsProtectedOrphan(path, metadataKeys));
        }
    }

    /// <summary>Completed records whose payload cleanup still needs a local retry. The metadata
    /// marker is deliberately excluded: it is the durable completion authority.</summary>
    public int AcknowledgedCleanupDebtCount
    {
        get
        {
            if (!EnsureRoot(create: false)) throw new DirectoryNotFoundException(
                "Artifact delivery spool is unavailable.");
            int debt = 0;
            foreach (string path in Directory.EnumerateFiles(root, "*" + MetadataExtension))
            {
                try
                {
                    ArtifactDeliveryRecord record = Read(path);
                    if (!IsCanonicalMetadataPath(path, record) || !record.Acknowledged) continue;
                    string key = Key(record.ArtifactId);
                    if (HasProtectedPayload(Path.Combine(root, key + ".bin"))
                        || HasProtectedPayload(Path.Combine(root, key + ".otlp"))) debt++;
                }
                catch (Exception exception) when (!IsTransientFilesystemFailure(exception)) { }
            }
            return debt;
        }
    }

    private ArtifactDeliveryRecord Enqueue(
        ArtifactDeliveryDescriptor descriptor,
        ArtifactDeliveryRecord record)
    {
        Validate(descriptor);
        _ = EnsureRoot(create: true);
        string key = Key(descriptor.ArtifactId);
        string bytesPath = Path.Combine(root, key + ".bin");
        string metadataPath = Path.Combine(root, key + MetadataExtension);
        if (File.Exists(metadataPath))
        {
            ArtifactDeliveryRecord existing = Read(metadataPath);
            if (!HasSameAdmissionIdentity(existing, record))
            {
                throw new ArtifactDeliveryAdmissionConflictException(
                    "Artifact delivery admission conflicts with existing durable state.");
            }

            if (existing.Acknowledged)
            {
                // The completion marker is authoritative while its owning journal advances; do
                // not require already-cleaned payload bytes or re-admit this screenshot.
                return existing;
            }

            _ = ReadBytes(existing);
            return existing;
        }

        if (File.Exists(bytesPath))
        {
            // A crash between the exact-byte write and metadata publication leaves an orphaned
            // .bin. Reconcile only when it is exactly the incoming immutable admission; never
            // overwrite unknown durable bytes.
            _ = ReadBytes(record);
            Write(record);
            return record;
        }

        // Metadata is the eligibility marker. Exact bytes and their ACL must be durable before the
        // single complete record appears, so the worker can never observe a half-admitted item.
        Durability.WriteAtomic(bytesPath, descriptor.CopyExactBytes());
        protectFile?.Invoke(bytesPath);
        Durability.WriteAtomic(metadataPath, JsonSerializer.SerializeToUtf8Bytes(record));
        protectFile?.Invoke(metadataPath);
        return record;
    }

    public byte[] ReadBytes(ArtifactDeliveryRecord record)
    {
        if (!EnsureRoot(create: false)) throw new DirectoryNotFoundException();
        string path = Path.Combine(root, Key(record.ArtifactId) + ".bin");
        RejectReparseFile(path);
        protectFile?.Invoke(path);
        RejectReparseFile(path);
        byte[] bytes = File.ReadAllBytes(path);
        if (bytes.LongLength != record.ByteLength
            || Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant() != record.Sha256)
        {
            throw new InvalidOperationException("Artifact delivery bytes do not match their durable digest.");
        }
        return bytes;
    }

    /// <summary>Commits the remote legacy binding and exact OTLP bytes before any OTLP POST. The
    /// original event remains unchanged; the copy exists only for this delivery projection.</summary>
    public ArtifactDeliveryRecord BindRemoteFile(ArtifactDeliveryRecord record, long remoteFileId)
    {
        if (remoteFileId <= 0)
        {
            throw new ArgumentException("Incomplete screenshot delivery record.");
        }
        if (!EnsureRoot(create: false)) throw new DirectoryNotFoundException();

        ArtifactDeliveryRecord existing = Read(Path.Combine(
            root,
            Key(record.ArtifactId) + MetadataExtension));
        if (existing.Acknowledged
            || existing.CanonicalEvent is null
            || existing.Context is null
            || string.IsNullOrWhiteSpace(existing.CanonicalEvent.SessionId)
            || existing.Context.SessionId != existing.CanonicalEvent.SessionId
            || !HasSameAdmissionIdentity(existing, record))
        {
            throw new InvalidOperationException(
                "Remote file binding does not match durable screenshot identity.");
        }
        _ = ReadBytes(existing);

        bool hasBindingProgress = existing.RemoteFileId is not null
            || existing.OtlpSha256 is not null
            || existing.OtlpByteLength is not null;
        if (hasBindingProgress)
        {
            if (existing.RemoteFileId != remoteFileId
                || existing.OtlpSha256 is null
                || existing.OtlpByteLength is null)
            {
                throw new InvalidOperationException(
                    "Remote file binding conflicts with durable progress.");
            }

            _ = ReadOtlpBytes(existing);
            return existing;
        }

        ActivityEvent projection = existing.CanonicalEvent with
        {
            ScreenshotId = remoteFileId.ToString(
                System.Globalization.CultureInfo.InvariantCulture),
        };
        byte[] otlp = System.Text.Encoding.UTF8.GetBytes(
            OtlpMapper.LogsRequest(new[] { projection }, existing.Context).ToJsonString());
        string key = Key(existing.ArtifactId);
        string otlpPath = Path.Combine(root, key + ".otlp");
        Durability.ReplaceAtomic(otlpPath, otlp);
        protectFile?.Invoke(otlpPath);
        ArtifactDeliveryRecord next = existing with
        {
            RemoteFileId = remoteFileId,
            OtlpSha256 = Convert.ToHexString(SHA256.HashData(otlp)).ToLowerInvariant(),
            OtlpByteLength = otlp.LongLength,
        };
        Write(next);
        return next;
    }

    public byte[] ReadOtlpBytes(ArtifactDeliveryRecord record)
    {
        if (record.RemoteFileId is null
            || record.OtlpSha256 is null
            || record.OtlpByteLength is null)
        {
            throw new InvalidOperationException("Remote file has not been durably bound.");
        }
        if (!EnsureRoot(create: false)) throw new DirectoryNotFoundException();
        string path = Path.Combine(root, Key(record.ArtifactId) + ".otlp");
        RejectReparseFile(path);
        protectFile?.Invoke(path);
        RejectReparseFile(path);
        byte[] bytes = File.ReadAllBytes(path);
        if (bytes.LongLength != record.OtlpByteLength
            || Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant()
                != record.OtlpSha256)
        {
            throw new InvalidOperationException(
                "OTLP delivery bytes do not match their durable digest.");
        }
        return bytes;
    }

    public void Acknowledge(ArtifactDeliveryRecord record)
    {
        if (!EnsureRoot(create: false)) throw new DirectoryNotFoundException();
        ArtifactDeliveryRecord existing = Read(Path.Combine(
            root,
            Key(record.ArtifactId) + MetadataExtension));
        if (existing.RemoteFileId is null
            || existing.OtlpSha256 is null
            || existing.OtlpByteLength is null
            || !HasSameAdmissionIdentity(existing, record)
            || existing.RemoteFileId != record.RemoteFileId
            || existing.OtlpSha256 != record.OtlpSha256
            || existing.OtlpByteLength != record.OtlpByteLength)
        {
            throw new InvalidOperationException("Artifact acknowledgement does not match durable identity.");
        }
        _ = ReadOtlpBytes(existing);
        // The durable marker is written only after the caller received OTLP 2xx. A crash after
        // this point can leave cleanup debris, but reopen removes it without replaying OTLP.
        ArtifactDeliveryRecord marked = existing with { Acknowledged = true };
        try
        {
            Write(marked);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            if (!HasDurableAcknowledgement(marked)) throw;
        }

        if (!HasDurableAcknowledgement(marked))
        {
            throw new InvalidOperationException("Artifact acknowledgement marker is not durable.");
        }
        try
        {
            CleanupAcknowledged(marked);
        }
        catch
        {
            // The verified marker is authoritative. Pending() retries cleanup without replaying
            // OTLP; cleanup debris is never converted into a failed delivery acknowledgement.
        }
    }

    private ArtifactDeliveryRecord Read(string path)
    {
        RejectReparseFile(path);
        protectFile?.Invoke(path);
        RejectReparseFile(path);
        return JsonSerializer.Deserialize<ArtifactDeliveryRecord>(File.ReadAllBytes(path))
            ?? throw new InvalidOperationException("Artifact delivery metadata is malformed.");
    }

    private void Write(ArtifactDeliveryRecord record)
    {
        if (!EnsureRoot(create: false)) throw new DirectoryNotFoundException();
        string path = Path.Combine(root, Key(record.ArtifactId) + MetadataExtension);
        Durability.ReplaceAtomic(path, JsonSerializer.SerializeToUtf8Bytes(record));
        protectFile?.Invoke(path);
    }

    private void CleanupAcknowledged(ArtifactDeliveryRecord record)
    {
        if (!EnsureRoot(create: false)) throw new DirectoryNotFoundException();
        string key = Key(record.ArtifactId);
        foreach (string path in new[]
        {
            Path.Combine(root, key + ".bin"),
            Path.Combine(root, key + ".otlp"),
        })
        {
            if (File.Exists(path)) deleteFile(path);
        }
    }

    private bool HasDurableAcknowledgement(ArtifactDeliveryRecord expected)
    {
        try
        {
            if (!EnsureRoot(create: false)) return false;
            string metadataPath = Path.Combine(
                root,
                Key(expected.ArtifactId) + MetadataExtension);
            ArtifactDeliveryRecord durable = Read(metadataPath);
            return durable.Acknowledged
                && HasValidAcknowledgement(durable)
                && HasSameAdmissionIdentity(durable, expected)
                && durable.RemoteFileId == expected.RemoteFileId
                && durable.OtlpSha256 == expected.OtlpSha256
                && durable.OtlpByteLength == expected.OtlpByteLength;
        }
        catch (Exception exception) when (IsTransientFilesystemFailure(exception))
        {
            throw;
        }
        catch
        {
            return false;
        }
    }

    private bool EnsureRoot(bool create)
    {
        RejectRedirectedPath(root);
        if (create) Directory.CreateDirectory(root);
        RejectRedirectedPath(root);
        if (!Directory.Exists(root))
        {
            if (File.Exists(root))
            {
                throw new InvalidOperationException("Artifact delivery root is not a directory.");
            }
            return false;
        }
        if ((File.GetAttributes(root) & FileAttributes.ReparsePoint) != 0)
        {
            throw new InvalidOperationException("Artifact delivery root is redirected.");
        }
        protectDirectory?.Invoke(root);
        if ((File.GetAttributes(root) & FileAttributes.ReparsePoint) != 0)
        {
            throw new InvalidOperationException("Artifact delivery root is redirected.");
        }
        return true;
    }

    private static void RejectRedirectedPath(string path)
    {
        DirectoryInfo? current = new(Path.GetFullPath(path));
        while (current is not null)
        {
            try
            {
                if ((File.GetAttributes(current.FullName) & FileAttributes.ReparsePoint) != 0)
                {
                    throw new InvalidOperationException("Artifact delivery path is redirected.");
                }
            }
            catch (Exception exception) when (exception is FileNotFoundException
                or DirectoryNotFoundException)
            {
                // Missing descendants are expected before first admission. Existing ancestors
                // still have to be checked before the directory is created beneath them.
            }
            current = current.Parent;
        }
    }

    private static void RejectReparseFile(string path)
    {
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
        {
            throw new InvalidOperationException("Artifact delivery metadata is redirected.");
        }
    }

    private static string Key(string artifactId) =>
        Convert.ToHexString(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(artifactId)))
        .ToLowerInvariant();

    private static bool IsCanonicalMetadataPath(string path, ArtifactDeliveryRecord record) =>
        string.Equals(
            Path.GetFileName(path),
            Key(record.ArtifactId) + MetadataExtension,
            StringComparison.Ordinal);

    private static bool IsTransientFilesystemFailure(Exception exception) =>
        exception is IOException or UnauthorizedAccessException;

    private bool IsProtectedOrphan(string path, ISet<string> metadataKeys)
    {
        RejectReparseFile(path);
        protectFile?.Invoke(path);
        RejectReparseFile(path);
        return !metadataKeys.Contains(Path.GetFileNameWithoutExtension(path));
    }

    private bool HasProtectedPayload(string path)
    {
        try
        {
            _ = File.GetAttributes(path);
        }
        catch (Exception exception) when (exception is FileNotFoundException
            or DirectoryNotFoundException)
        {
            return false;
        }
        RejectReparseFile(path);
        protectFile?.Invoke(path);
        RejectReparseFile(path);
        return true;
    }

    private static bool HasValidAcknowledgement(ArtifactDeliveryRecord record) =>
        record.RemoteFileId is > 0
        && record.OtlpByteLength is > 0
        && record.OtlpSha256 is { Length: 64 } digest
        && digest.All(Uri.IsHexDigit);

    /// <summary>Progress fields (remote Files id and exact OTLP projection) are deliberately
    /// excluded: a replay of the same canonical admission must preserve them. Everything that
    /// names or describes the local evidence must be identical.</summary>
    private static bool HasSameAdmissionIdentity(
        ArtifactDeliveryRecord existing,
        ArtifactDeliveryRecord incoming) =>
        existing.ArchiveId == incoming.ArchiveId
        && existing.CaptureId == incoming.CaptureId
        && existing.ArtifactId == incoming.ArtifactId
        && existing.ScreenshotId == incoming.ScreenshotId
        && existing.MediaType == incoming.MediaType
        && existing.Sha256 == incoming.Sha256
        && existing.ByteLength == incoming.ByteLength
        && existing.CanonicalEvent == incoming.CanonicalEvent
        && existing.Context == incoming.Context;

    private static void Validate(ArtifactDeliveryDescriptor value)
    {
        if (value.ExactBytes.Length != value.ByteLength
            || Convert.ToHexString(SHA256.HashData(value.ExactBytes)).ToLowerInvariant()
                != value.Sha256)
        {
            throw new ArgumentException("Artifact descriptor bytes do not match its fingerprint.", nameof(value));
        }
    }
}

/// <summary>Signals only an immutable collision with an existing spool admission. Callers may
/// fence that durable record; transient filesystem failures intentionally use their original types.</summary>
public sealed class ArtifactDeliveryAdmissionConflictException : InvalidOperationException
{
    public ArtifactDeliveryAdmissionConflictException(string message) : base(message) { }
}

public sealed record ArtifactDeliveryRecord(
    string ArchiveId,
    string CaptureId,
    string ArtifactId,
    string? ScreenshotId,
    string MediaType,
    string Sha256,
    long ByteLength)
{
    public ActivityEvent? CanonicalEvent { get; init; }
    public SessionContext? Context { get; init; }
    public long? RemoteFileId { get; init; }
    public string? OtlpSha256 { get; init; }
    public long? OtlpByteLength { get; init; }
    public bool Acknowledged { get; init; }
    public bool Quarantined { get; init; }
    internal static ArtifactDeliveryRecord From(ArtifactDeliveryDescriptor value) => new(
        value.ArchiveId,
        value.CaptureId,
        value.ArtifactId,
        value.ScreenshotId,
        value.MediaType,
        value.Sha256,
        value.ByteLength);
}
