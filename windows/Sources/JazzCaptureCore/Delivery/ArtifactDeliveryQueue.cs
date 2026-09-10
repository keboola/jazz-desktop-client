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
            return existing;
        }
        Durability.WriteAtomic(bytesPath, descriptor.Bytes.ToArray());
        Durability.WriteAtomic(metadataPath, JsonSerializer.SerializeToUtf8Bytes(record));
        return record;
    }

    public IReadOnlyList<ArtifactDeliveryRecord> Pending() => !Directory.Exists(root) ? Array.Empty<ArtifactDeliveryRecord>() :
        Directory.EnumerateFiles(root, "*" + MetadataExtension).OrderBy(Path.GetFileName, StringComparer.Ordinal).Select(Read).ToArray();

    public byte[] ReadBytes(ArtifactDeliveryRecord record)
    {
        byte[] bytes = File.ReadAllBytes(Path.Combine(root, Key(record.ArtifactId) + ".bin"));
        if (bytes.LongLength != record.ByteLength || Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant() != record.Sha256)
            throw new InvalidOperationException("Artifact delivery bytes do not match their durable digest.");
        return bytes;
    }

    public void Acknowledge(ArtifactDeliveryRecord record)
    {
        string key = Key(record.ArtifactId);
        string metadata = Path.Combine(root, key + MetadataExtension);
        string bytes = Path.Combine(root, key + ".bin");
        // Remove metadata first: a crash leaves orphaned bytes, never a false acknowledgement.
        if (File.Exists(metadata)) File.Delete(metadata);
        if (File.Exists(bytes)) File.Delete(bytes);
    }

    private static ArtifactDeliveryRecord Read(string path) => JsonSerializer.Deserialize<ArtifactDeliveryRecord>(File.ReadAllBytes(path))
        ?? throw new InvalidOperationException("Artifact delivery metadata is malformed.");
    private static string Key(string artifactId) => Convert.ToHexString(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(artifactId))).ToLowerInvariant();
    private static void Validate(ArtifactDeliveryDescriptor value)
    {
        if (value.Bytes.LongLength != value.ByteLength || Convert.ToHexString(SHA256.HashData(value.Bytes)).ToLowerInvariant() != value.Sha256)
            throw new ArgumentException("Artifact descriptor bytes do not match its fingerprint.", nameof(value));
    }
}

public sealed record ArtifactDeliveryRecord(string ArchiveId, string CaptureId, string ArtifactId, string? ScreenshotId, string MediaType, string Sha256, long ByteLength)
{
    internal static ArtifactDeliveryRecord From(ArtifactDeliveryDescriptor value) => new(value.ArchiveId, value.CaptureId, value.ArtifactId, value.ScreenshotId, value.MediaType, value.Sha256, value.ByteLength);
}
