using System.Security.Cryptography;
using System.Text.Json;
using JazzCaptureCore.Journal;

namespace JazzCaptureCore.Delivery;

/// <summary>Crash-safe exact-byte spool for live artifacts.  A failed delivery never mutates its
/// bytes or canonical identity; acknowledgement is the only operation that removes an item.</summary>
public sealed class ArtifactDeliveryQueue
{
    private const string MetadataExtension = ".json";
    private readonly string root;
    private readonly Action<string>? protectFile;

    public ArtifactDeliveryQueue(string root, Action<string>? protectFile = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(root);
        this.root = Path.GetFullPath(root);
        this.protectFile = protectFile;
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
        if (!Directory.Exists(root))
        {
            return Array.Empty<ArtifactDeliveryRecord>();
        }

        var result = new List<ArtifactDeliveryRecord>();
        foreach (string path in Directory
            .EnumerateFiles(root, "*" + MetadataExtension)
            .OrderBy(Path.GetFileName, StringComparer.Ordinal))
        {
            try
            {
                protectFile?.Invoke(path);
                ArtifactDeliveryRecord record = Read(path);
                if (record.Acknowledged)
                {
                    CleanupAcknowledged(record);
                    continue;
                }
                result.Add(record);
            }
            catch
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
            if (!Directory.Exists(root)) return 0;
            int count = 0;
            foreach (string path in Directory.EnumerateFiles(root, "*" + MetadataExtension))
            {
                try
                {
                    ArtifactDeliveryRecord record = Read(path);
                    string key = Key(record.ArtifactId);
                    if (record.Acknowledged
                        && !File.Exists(Path.Combine(root, key + ".bin"))
                        && !File.Exists(Path.Combine(root, key + ".otlp")))
                        continue;
                }
                catch { }
                count++;
            }
            return count;
        }
    }

    public void MarkQuarantined(ArtifactDeliveryRecord record)
    {
        ArtifactDeliveryRecord existing = Read(Path.Combine(root, Key(record.ArtifactId) + MetadataExtension));
        if (!HasSameAdmissionIdentity(existing, record))
            throw new InvalidOperationException("Artifact quarantine does not match durable identity.");
        Write(existing with { Quarantined = true });
    }

    /// <summary>Explicit local repair hook. Ordinary capture nudges never clear terminal state.</summary>
    public void RequeueQuarantined(ArtifactDeliveryRecord record)
    {
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
            if (!Directory.Exists(root)) return 0;
            int unreadable = 0;
            foreach (string path in Directory.EnumerateFiles(root, "*" + MetadataExtension))
            {
                try { protectFile?.Invoke(path); _ = Read(path); } catch { unreadable++; }
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
            if (!Directory.Exists(root)) return 0;
            var metadataKeys = Directory.EnumerateFiles(root, "*" + MetadataExtension)
                .Select(Path.GetFileNameWithoutExtension)
                .ToHashSet(StringComparer.Ordinal);
            return Directory.EnumerateFiles(root, "*.bin").Concat(Directory.EnumerateFiles(root, "*.otlp"))
                .Count(path => !metadataKeys.Contains(Path.GetFileNameWithoutExtension(path)));
        }
    }

    private ArtifactDeliveryRecord Enqueue(
        ArtifactDeliveryDescriptor descriptor,
        ArtifactDeliveryRecord record)
    {
        Validate(descriptor);
        Directory.CreateDirectory(root);
        string key = Key(descriptor.ArtifactId);
        string bytesPath = Path.Combine(root, key + ".bin");
        string metadataPath = Path.Combine(root, key + MetadataExtension);
        if (File.Exists(metadataPath))
        {
            ArtifactDeliveryRecord existing = Read(metadataPath);
            if (!HasSameAdmissionIdentity(existing, record))
            {
                throw new InvalidOperationException(
                    "Artifact delivery admission conflicts with existing durable state.");
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
        string path = Path.Combine(root, Key(record.ArtifactId) + ".bin");
        protectFile?.Invoke(path);
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
        if (remoteFileId <= 0 || record.CanonicalEvent is null || record.Context is null)
        {
            throw new ArgumentException("Incomplete screenshot delivery record.");
        }

        ActivityEvent projection = record.CanonicalEvent with
        {
            ScreenshotId = remoteFileId.ToString(
                System.Globalization.CultureInfo.InvariantCulture),
        };
        byte[] otlp = System.Text.Encoding.UTF8.GetBytes(
            OtlpMapper.LogsRequest(new[] { projection }, record.Context).ToJsonString());
        string key = Key(record.ArtifactId);
        string otlpPath = Path.Combine(root, key + ".otlp");
        Durability.ReplaceAtomic(otlpPath, otlp);
        protectFile?.Invoke(otlpPath);
        ArtifactDeliveryRecord next = record with
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
        string path = Path.Combine(root, Key(record.ArtifactId) + ".otlp");
        protectFile?.Invoke(path);
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
        ArtifactDeliveryRecord existing = Read(Path.Combine(
            root,
            Key(record.ArtifactId) + MetadataExtension));
        if (existing.ArtifactId != record.ArtifactId
            || existing.Sha256 != record.Sha256
            || existing.RemoteFileId != record.RemoteFileId)
        {
            throw new InvalidOperationException("Artifact acknowledgement does not match durable identity.");
        }
        // The durable marker is written only after the caller received OTLP 2xx. A crash after
        // this point can leave cleanup debris, but reopen removes it without replaying OTLP.
        Write(existing with { Acknowledged = true });
        string key = Key(record.ArtifactId);
        string metadata = Path.Combine(root, key + MetadataExtension);
        string bytes = Path.Combine(root, key + ".bin");
        // Remove metadata first: a crash leaves orphaned bytes, never a false acknowledgement.
        if (File.Exists(metadata))
        {
            File.Delete(metadata);
        }
        if (File.Exists(bytes))
        {
            File.Delete(bytes);
        }
        string otlp = Path.Combine(root, key + ".otlp");
        if (File.Exists(otlp))
        {
            File.Delete(otlp);
        }
    }

    private static ArtifactDeliveryRecord Read(string path) =>
        JsonSerializer.Deserialize<ArtifactDeliveryRecord>(File.ReadAllBytes(path))
            ?? throw new InvalidOperationException("Artifact delivery metadata is malformed.");

    private void Write(ArtifactDeliveryRecord record)
    {
        string path = Path.Combine(root, Key(record.ArtifactId) + MetadataExtension);
        Durability.ReplaceAtomic(path, JsonSerializer.SerializeToUtf8Bytes(record));
        protectFile?.Invoke(path);
    }

    private void CleanupAcknowledged(ArtifactDeliveryRecord record)
    {
        string key = Key(record.ArtifactId);
        foreach (string path in new[]
        {
            Path.Combine(root, key + ".bin"),
            Path.Combine(root, key + ".otlp"),
            Path.Combine(root, key + MetadataExtension),
        })
        {
            if (File.Exists(path)) File.Delete(path);
        }
    }

    private static string Key(string artifactId) =>
        Convert.ToHexString(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(artifactId)))
            .ToLowerInvariant();

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
