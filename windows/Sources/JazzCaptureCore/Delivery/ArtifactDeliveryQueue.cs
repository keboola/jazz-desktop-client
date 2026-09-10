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

    public ArtifactDeliveryQueue(string root)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(root);
        this.root = Path.GetFullPath(root);
    }

    public ArtifactDeliveryRecord Enqueue(ArtifactDeliveryDescriptor descriptor)
    {
        ArgumentNullException.ThrowIfNull(descriptor);
        Validate(descriptor);
        Directory.CreateDirectory(root);
        string key = Key(descriptor.ArtifactId);
        string bytesPath = Path.Combine(root, key + ".bin");
        string metadataPath = Path.Combine(root, key + MetadataExtension);
        ArtifactDeliveryRecord record = ArtifactDeliveryRecord.From(descriptor);
        if (File.Exists(metadataPath))
        {
            ArtifactDeliveryRecord existing = Read(metadataPath);
            if (existing.ArtifactId != record.ArtifactId || existing.Sha256 != record.Sha256 || existing.ByteLength != record.ByteLength)
                throw new InvalidOperationException("Artifact delivery identity conflicts with existing durable bytes.");
            _ = ReadBytes(existing);
            return existing;
        }
        Durability.WriteAtomic(bytesPath, descriptor.Bytes.ToArray());
        Durability.WriteAtomic(metadataPath, JsonSerializer.SerializeToUtf8Bytes(record));
        return record;
    }

    /// <summary>Persists the canonical event/context before the artifact can be delivered. Only
    /// screenshots are eligible: narration keeps its own #48 path.</summary>
    public ArtifactDeliveryRecord EnqueueScreenshot(ArtifactDeliveryDescriptor descriptor, ActivityEvent activityEvent, SessionContext context)
    {
        if (descriptor.ScreenshotId is null || activityEvent.ScreenshotId != descriptor.ArtifactId)
            throw new ArgumentException("Only a canonical screenshot artifact can enter this queue.");
        ArtifactDeliveryRecord record = Enqueue(descriptor) with { CanonicalEvent = activityEvent, Context = context };
        Write(record);
        return record;
    }

    public IReadOnlyList<ArtifactDeliveryRecord> Pending()
    {
        if (!Directory.Exists(root)) return Array.Empty<ArtifactDeliveryRecord>();
        var result = new List<ArtifactDeliveryRecord>();
        foreach (string path in Directory.EnumerateFiles(root, "*" + MetadataExtension).OrderBy(Path.GetFileName, StringComparer.Ordinal))
        {
            try { result.Add(Read(path)); } catch { /* corrupt item is retained; other work continues */ }
        }
        return result;
    }

    public byte[] ReadBytes(ArtifactDeliveryRecord record)
    {
        byte[] bytes = File.ReadAllBytes(Path.Combine(root, Key(record.ArtifactId) + ".bin"));
        if (bytes.LongLength != record.ByteLength || Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant() != record.Sha256)
            throw new InvalidOperationException("Artifact delivery bytes do not match their durable digest.");
        return bytes;
    }

    /// <summary>Commits the remote legacy binding and exact OTLP bytes before any OTLP POST. The
    /// original event remains unchanged; the copy exists only for this delivery projection.</summary>
    public ArtifactDeliveryRecord BindRemoteFile(ArtifactDeliveryRecord record, long remoteFileId)
    {
        if (remoteFileId <= 0 || record.CanonicalEvent is null || record.Context is null) throw new ArgumentException("Incomplete screenshot delivery record.");
        ActivityEvent projection = record.CanonicalEvent with { ScreenshotId = remoteFileId.ToString(System.Globalization.CultureInfo.InvariantCulture) };
        byte[] otlp = System.Text.Encoding.UTF8.GetBytes(OtlpMapper.LogsRequest(new[] { projection }, record.Context).ToJsonString());
        string key = Key(record.ArtifactId); Durability.ReplaceAtomic(Path.Combine(root, key + ".otlp"), otlp);
        ArtifactDeliveryRecord next = record with { RemoteFileId = remoteFileId, OtlpSha256 = Convert.ToHexString(SHA256.HashData(otlp)).ToLowerInvariant(), OtlpByteLength = otlp.LongLength };
        Write(next); return next;
    }

    public byte[] ReadOtlpBytes(ArtifactDeliveryRecord record)
    {
        if (record.RemoteFileId is null || record.OtlpSha256 is null || record.OtlpByteLength is null) throw new InvalidOperationException("Remote file has not been durably bound.");
        byte[] bytes = File.ReadAllBytes(Path.Combine(root, Key(record.ArtifactId) + ".otlp"));
        if (bytes.LongLength != record.OtlpByteLength || Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant() != record.OtlpSha256) throw new InvalidOperationException("OTLP delivery bytes do not match their durable digest.");
        return bytes;
    }

    public void Acknowledge(ArtifactDeliveryRecord record)
    {
        ArtifactDeliveryRecord existing = Read(Path.Combine(root, Key(record.ArtifactId) + MetadataExtension));
        if (existing.ArtifactId != record.ArtifactId || existing.Sha256 != record.Sha256 || existing.RemoteFileId != record.RemoteFileId)
            throw new InvalidOperationException("Artifact acknowledgement does not match durable identity.");
        string key = Key(record.ArtifactId);
        string metadata = Path.Combine(root, key + MetadataExtension);
        string bytes = Path.Combine(root, key + ".bin");
        // Remove metadata first: a crash leaves orphaned bytes, never a false acknowledgement.
        if (File.Exists(metadata)) File.Delete(metadata);
        if (File.Exists(bytes)) File.Delete(bytes);
        string otlp = Path.Combine(root, key + ".otlp"); if (File.Exists(otlp)) File.Delete(otlp);
    }

    private static ArtifactDeliveryRecord Read(string path) => JsonSerializer.Deserialize<ArtifactDeliveryRecord>(File.ReadAllBytes(path))
        ?? throw new InvalidOperationException("Artifact delivery metadata is malformed.");
    private void Write(ArtifactDeliveryRecord record) => Durability.ReplaceAtomic(Path.Combine(root, Key(record.ArtifactId) + MetadataExtension), JsonSerializer.SerializeToUtf8Bytes(record));
    private static string Key(string artifactId) => Convert.ToHexString(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(artifactId))).ToLowerInvariant();
    private static void Validate(ArtifactDeliveryDescriptor value)
    {
        if (value.Bytes.LongLength != value.ByteLength || Convert.ToHexString(SHA256.HashData(value.Bytes)).ToLowerInvariant() != value.Sha256)
            throw new ArgumentException("Artifact descriptor bytes do not match its fingerprint.", nameof(value));
    }
}

public sealed record ArtifactDeliveryRecord(string ArchiveId, string CaptureId, string ArtifactId, string? ScreenshotId, string MediaType, string Sha256, long ByteLength)
{
    public ActivityEvent? CanonicalEvent { get; init; }
    public SessionContext? Context { get; init; }
    public long? RemoteFileId { get; init; }
    public string? OtlpSha256 { get; init; }
    public long? OtlpByteLength { get; init; }
    internal static ArtifactDeliveryRecord From(ArtifactDeliveryDescriptor value) => new(value.ArchiveId, value.CaptureId, value.ArtifactId, value.ScreenshotId, value.MediaType, value.Sha256, value.ByteLength);
}
