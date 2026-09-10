using System.Security.Cryptography;
using JazzCaptureCore.Archive;

namespace JazzCaptureCore.Delivery;

/// <summary>Immutable post-durability projection of an artifact for a live uploader.</summary>
public sealed record ArtifactDeliveryDescriptor(
    string ArchiveId,
    string CaptureId,
    string ArtifactId,
    string? ScreenshotId,
    string MediaType,
    string Sha256,
    long ByteLength,
    byte[] Bytes)
{
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
