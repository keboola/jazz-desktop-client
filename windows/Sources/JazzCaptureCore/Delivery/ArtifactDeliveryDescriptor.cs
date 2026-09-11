using JazzCaptureCore.Archive;
using JazzCaptureCore.Journal;

namespace JazzCaptureCore.Delivery;

/// <summary>
/// Immutable post-durability projection of one screenshot artifact, handed to
/// <see cref="EngineConfig.ScreenshotDeliveryPreparer"/> so the host can prepare a Keboola Files
/// upload without ever touching the journal or the archive itself.
/// </summary>
/// <remarks>
/// <para>
/// The descriptor carries the four ids a Files object needs to be tagged back to its origin —
/// archive, capture, session, artifact — plus the content identity the journal already computed for
/// the same bytes. <see cref="Sha256"/> and <see cref="ByteLength"/> come from the journal's own
/// <see cref="ArtifactFingerprint"/> rather than being recomputed here, so the uploaded content
/// digest is equal to the archive's recorded digest by construction, not merely by coincidence of
/// two independent hashes of the same bytes.
/// </para>
/// <para>
/// This type is deliberately narrower than its counterpart on the closed durable-spool branch: it
/// carries no discriminator field misnamed <c>ScreenshotId</c> (a screenshot artifact id is not a
/// Files id, and the real Files id does not exist yet when this descriptor is built), and it exposes
/// no internal accessor for a durable spool to persist, because this design has none.
/// </para>
/// </remarks>
public sealed class ArtifactDeliveryDescriptor
{
    private readonly byte[] _bytes;

    public ArtifactDeliveryDescriptor(
        string archiveId,
        string captureId,
        string sessionId,
        string artifactId,
        string kind,
        string mediaType,
        string sha256,
        long byteLength,
        ReadOnlyMemory<byte> bytes)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(archiveId);
        ArgumentException.ThrowIfNullOrWhiteSpace(captureId);
        ArgumentException.ThrowIfNullOrWhiteSpace(sessionId);
        ArgumentException.ThrowIfNullOrWhiteSpace(artifactId);
        ArgumentException.ThrowIfNullOrWhiteSpace(kind);
        ArgumentException.ThrowIfNullOrWhiteSpace(mediaType);
        ArgumentException.ThrowIfNullOrWhiteSpace(sha256);
        if (byteLength != bytes.Length)
        {
            throw new ArgumentException(
                "byteLength (" + byteLength + ") does not match the supplied bytes length ("
                    + bytes.Length + "); the descriptor and the journal must agree on content length.",
                nameof(byteLength));
        }

        ArchiveId = archiveId;
        CaptureId = captureId;
        SessionId = sessionId;
        ArtifactId = artifactId;
        Kind = kind;
        MediaType = mediaType;
        Sha256 = sha256;
        ByteLength = byteLength;
        _bytes = bytes.ToArray();
    }

    /// <summary>Archive identity of the capture the artifact belongs to.</summary>
    public string ArchiveId { get; }

    /// <summary>Capture identity of the recording the artifact belongs to.</summary>
    public string CaptureId { get; }

    /// <summary>Legacy transport session identity, one of the four Files tag correlators.</summary>
    public string SessionId { get; }

    /// <summary>Journal-assigned artifact identity; never a remote Files id.</summary>
    public string ArtifactId { get; }

    /// <summary>The artifact declaration's kind token (<c>"screenshot"</c> for this design).</summary>
    public string Kind { get; }

    public string MediaType { get; }

    /// <summary>Lowercase hex SHA-256 of the bytes, taken from the journal's own fingerprint.</summary>
    public string Sha256 { get; }

    public long ByteLength { get; }

    /// <summary>Returns a defensive copy; callers cannot mutate the descriptor's exact bytes.</summary>
    public ReadOnlyMemory<byte> Bytes => _bytes.ToArray();

    /// <summary>
    /// Builds a descriptor for a screenshot artifact whose bytes the journal has already ingested.
    /// </summary>
    /// <param name="identity">Every identifier this capture writes.</param>
    /// <param name="artifactId">The journal-assigned artifact identity.</param>
    /// <param name="declaration">The artifact declaration the engine handed to the journal.</param>
    /// <param name="fingerprint">
    /// The fingerprint the journal computed for the same bytes while ingesting them. Using the
    /// journal's own digest and length, instead of recomputing them, is what makes the uploaded
    /// content digest equal to the archive's recorded digest by construction.
    /// </param>
    /// <param name="bytes">The bytes to be uploaded; snapshotted defensively by the constructor.</param>
    public static ArtifactDeliveryDescriptor Create(
        ArchiveIdentity identity,
        string artifactId,
        ArtifactDeclaration declaration,
        ArtifactFingerprint fingerprint,
        ReadOnlyMemory<byte> bytes)
    {
        ArgumentNullException.ThrowIfNull(identity);
        ArgumentException.ThrowIfNullOrWhiteSpace(artifactId);
        ArgumentNullException.ThrowIfNull(declaration);
        ArgumentNullException.ThrowIfNull(fingerprint);
        return new(
            identity.ArchiveId,
            identity.CaptureId,
            identity.SessionId,
            artifactId,
            declaration.Kind,
            declaration.MediaType,
            fingerprint.Sha256,
            fingerprint.ByteLength,
            bytes);
    }
}
