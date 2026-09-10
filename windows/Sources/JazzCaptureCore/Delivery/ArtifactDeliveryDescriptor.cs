using System.Security.Cryptography;
using JazzCaptureCore.Archive;

namespace JazzCaptureCore.Delivery;

/// <summary>Immutable post-durability projection of an artifact for a live uploader.</summary>
public sealed class ArtifactDeliveryDescriptor
{
    private readonly byte[] bytes;

    public ArtifactDeliveryDescriptor(
        string archiveId,
        string captureId,
        string artifactId,
        string? screenshotId,
        string mediaType,
        string sha256,
        long byteLength,
        ReadOnlyMemory<byte> bytes)
    {
        ArchiveId = archiveId;
        CaptureId = captureId;
        ArtifactId = artifactId;
        ScreenshotId = screenshotId;
        MediaType = mediaType;
        Sha256 = sha256;
        ByteLength = byteLength;
        this.bytes = bytes.ToArray();
    }

    public string ArchiveId { get; }
    public string CaptureId { get; }
    public string ArtifactId { get; }
    public string? ScreenshotId { get; }
    public string MediaType { get; }
    public string Sha256 { get; }
    public long ByteLength { get; }

    /// <summary>Returns a defensive copy; callers cannot mutate the descriptor's exact bytes.</summary>
    public ReadOnlyMemory<byte> Bytes => bytes.ToArray();

    internal ReadOnlySpan<byte> ExactBytes => bytes;

    internal byte[] CopyExactBytes() => bytes.ToArray();

    public static ArtifactDeliveryDescriptor Create(
        ArchiveIdentity identity, string artifactId, ArtifactDeclaration declaration, ReadOnlyMemory<byte> bytes)
    {
        ArgumentNullException.ThrowIfNull(identity);
        ArgumentException.ThrowIfNullOrWhiteSpace(artifactId);
        ArgumentNullException.ThrowIfNull(declaration);
        byte[] exact = bytes.ToArray();
        return new(identity.ArchiveId, identity.CaptureId, artifactId,
            declaration.Kind == "screenshot" ? artifactId : null, declaration.MediaType,
            Convert.ToHexString(SHA256.HashData(exact)).ToLowerInvariant(), exact.LongLength, exact);
    }
}
