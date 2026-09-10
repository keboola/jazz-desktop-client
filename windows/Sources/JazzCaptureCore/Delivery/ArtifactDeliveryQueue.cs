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
        if (descriptor.ScreenshotId is null
            || activityEvent.ScreenshotId != descriptor.ArtifactId)
        {
            throw new ArgumentException("Only a canonical screenshot artifact can enter this queue.");
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
                result.Add(Read(path));
            }
            catch
            {
                // A corrupt or inaccessible item is retained; healthy siblings still progress.
            }
        }
        return result;
    }

    /// <summary>Number of durable metadata items, including malformed items retained for attention.</summary>
    public int PendingFileCount => !Directory.Exists(root)
        ? 0
        : Directory.EnumerateFiles(root, "*" + MetadataExtension).Count();

    public int UnreadableFileCount => Math.Max(0, PendingFileCount - Pending().Count);

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
            if (existing.ArtifactId != record.ArtifactId
                || existing.Sha256 != record.Sha256
                || existing.ByteLength != record.ByteLength)
            {
                throw new InvalidOperationException(
                    "Artifact delivery identity conflicts with existing durable bytes.");
            }

            _ = ReadBytes(existing);
            if (existing.CanonicalEvent is null && record.CanonicalEvent is not null)
            {
                // Repair metadata written by the earlier two-step queue implementation. The exact
                // bytes have just been verified; publishing the complete record makes it eligible.
                Write(record);
                return record;
            }

            return existing;
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

    private static string Key(string artifactId) =>
        Convert.ToHexString(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(artifactId)))
            .ToLowerInvariant();

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
    internal static ArtifactDeliveryRecord From(ArtifactDeliveryDescriptor value) => new(
        value.ArchiveId,
        value.CaptureId,
        value.ArtifactId,
        value.ScreenshotId,
        value.MediaType,
        value.Sha256,
        value.ByteLength);
}
