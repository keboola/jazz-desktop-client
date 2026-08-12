using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using JazzCaptureCore.Json;

namespace JazzCaptureCore.Archive;

/// <summary>How a package reached this installation.</summary>
public enum JazzArchiveImportAcquisition
{
    /// <summary>A person picked the file.</summary>
    UserSelectedFile,

    /// <summary>The package was downloaded from a Jazz server under an authorization grant.</summary>
    JazzServerDownload,
}

/// <summary>
/// A non-canonical identity claim: a namespace and an opaque value. Never authoritative — it is
/// recorded beside a package, never inside it.
/// </summary>
/// <param name="Namespace">Issuer namespace, for example <c>jazz.device</c>.</param>
/// <param name="Value">The claim itself.</param>
public sealed record JazzArchiveExternalIdentity(string Namespace, string Value);

/// <summary>
/// Who imported a package, from where, onto what. This is an acquisition receipt only: none of it may
/// ever be copied into the manifest, whose recorder identity is the immutable fact of who captured
/// the evidence and whose digests are already fixed.
/// </summary>
public sealed record JazzArchiveImportContext
{
    /// <summary>The person performing the import; omitted when unknown.</summary>
    public JazzArchiveExternalIdentity? ImportedBy { get; init; }

    /// <summary>The importing installation's origin identity; omitted when unknown.</summary>
    public string? ImportingOriginId { get; init; }

    /// <summary>The importing installation's source identity; omitted when unknown.</summary>
    public string? ImportingSourceId { get; init; }

    /// <summary>The device label of the importing machine; omitted when unknown.</summary>
    public JazzArchiveExternalIdentity? ImportingDevice { get; init; }

    /// <summary>How the package reached this installation.</summary>
    public JazzArchiveImportAcquisition Acquisition { get; init; } = JazzArchiveImportAcquisition.UserSelectedFile;

    /// <summary>Download operation identity; required for, and only for, a server download.</summary>
    public string? DownloadOperationId { get; init; }

    /// <summary>Download authorization identity; required for, and only for, a server download.</summary>
    public string? DownloadAuthorizationId { get; init; }
}

/// <summary>Whether the import published a new snapshot or found the same bytes already present.</summary>
public enum JazzArchiveImportDisposition
{
    /// <summary>The package was verified and published.</summary>
    Imported,

    /// <summary>The identical package was already published; only a receipt was appended.</summary>
    AlreadyPresent,
}

/// <summary>The outcome of one import.</summary>
/// <param name="Disposition">Published, or already present.</param>
/// <param name="Snapshot">The published, verified, read-only snapshot.</param>
/// <param name="Provenance">Package identity plus every append-only receipt.</param>
/// <param name="PackagePath">Absolute path of the retained exact package bytes.</param>
public sealed record JazzArchiveImportResult(
    JazzArchiveImportDisposition Disposition,
    JazzArchiveFinalizedSnapshot Snapshot,
    JazzArchivePackageProvenance Provenance,
    string PackagePath);

/// <summary>
/// One append-only local acquisition fact. Re-importing the exact same package appends another
/// receipt rather than replacing the first importer's attribution.
/// </summary>
public sealed record JazzArchiveImportReceipt
{
    /// <summary>Receipt document version.</summary>
    public int SchemaVersion { get; init; } = 1;

    /// <summary>Receipt identity, <c>imr-</c> plus a UUIDv7.</summary>
    public required string ReceiptId { get; init; }

    /// <summary>Package identity, derived from the raw package digest.</summary>
    public required string PackageId { get; init; }

    /// <summary>The archive the package carries.</summary>
    public required string ArchiveId { get; init; }

    /// <summary>Lowercase hexadecimal SHA-256 of the exact package bytes.</summary>
    public required string PackageSha256 { get; init; }

    /// <summary>Length of the exact package bytes.</summary>
    public required long PackageByteLength { get; init; }

    /// <summary>When the import happened (RFC 3339).</summary>
    public required string ImportedAt { get; init; }

    /// <summary>The importing person; omitted from the document when absent.</summary>
    public JazzArchiveExternalIdentity? ImportedBy { get; init; }

    /// <summary>The importing installation origin; omitted from the document when absent.</summary>
    public string? ImportingOriginId { get; init; }

    /// <summary>The importing installation source; omitted from the document when absent.</summary>
    public string? ImportingSourceId { get; init; }

    /// <summary>The importing device label; omitted from the document when absent.</summary>
    public JazzArchiveExternalIdentity? ImportingDevice { get; init; }

    /// <summary>How the package reached this installation.</summary>
    public required JazzArchiveImportAcquisition Acquisition { get; init; }

    /// <summary>The selected file's own name; omitted from the document when absent.</summary>
    public string? OriginalFileName { get; init; }

    /// <summary>Download operation identity; omitted from the document when absent.</summary>
    public string? DownloadOperationId { get; init; }

    /// <summary>Download authorization identity; omitted from the document when absent.</summary>
    public string? DownloadAuthorizationId { get; init; }
}

/// <summary>Stable package identity plus its append-only, non-canonical import receipts.</summary>
/// <param name="SchemaVersion">Provenance document version.</param>
/// <param name="PackageId">Package identity derived from the raw package digest.</param>
/// <param name="ArchiveId">The archive the package carries.</param>
/// <param name="ContentDigest">The manifest content digest, repeated for lookup.</param>
/// <param name="PackageSha256">Lowercase hexadecimal SHA-256 of the exact package bytes.</param>
/// <param name="PackageByteLength">Length of the exact package bytes.</param>
/// <param name="Receipts">The initial receipt first, then the rest ordered by receipt identity.</param>
public sealed record JazzArchivePackageProvenance(
    int SchemaVersion,
    string PackageId,
    string ArchiveId,
    string ContentDigest,
    string PackageSha256,
    long PackageByteLength,
    IReadOnlyList<JazzArchiveImportReceipt> Receipts)
{
    /// <summary>The package identity a raw digest implies.</summary>
    public static string PackageIdFor(string sha256) => "jap-sha256-" + sha256;

    /// <summary>The exact package bytes as a fingerprint.</summary>
    public JazzArchiveFileFingerprint PackageFingerprint => new(PackageSha256, PackageByteLength);
}

/// <summary>
/// The trust boundary for cross-user <c>.jazz-archive</c> files. The selection is copied and
/// fingerprinted before anything parses it, verified entirely inside a staging directory, and only
/// then published — the exact package and its provenance first, then one final rename that makes the
/// read-only snapshot visible.
/// </summary>
/// <remarks>
/// <para>
/// Nothing partial survives a failure. Every intermediate lives under one staging directory that is
/// removed on the way out, so a package refused at byte one and a package refused at its last digest
/// leave the store in the same state: unchanged.
/// </para>
/// <para>
/// The two published trees answer different questions and are therefore kept apart. The snapshot is
/// the verified evidence a reader consumes. The package directory retains the exact original bytes,
/// because the package SHA-256 and byte length are durable delivery provenance that a re-export
/// could not reproduce, and it is where import receipts accumulate — beside the package, never
/// inside it, since the package is immutable and its digests are already fixed.
/// </para>
/// </remarks>
public sealed class JazzArchiveImporter
{
    /// <summary>Directory suffix of a published, verified snapshot.</summary>
    public const string FinalizedSuffix = ArchiveWriter.FinalizedSuffix;

    /// <summary>Directory suffix of a local draft; its presence blocks an import of the same id.</summary>
    public const string DraftSuffix = ".jazz-archive.draft";

    /// <summary>Root-relative directory holding the retained exact packages and their receipts.</summary>
    public const string PackagesDirectoryName = ".archive-packages";

    /// <summary>Root-relative directory holding refused conflicting packages.</summary>
    public const string QuarantineDirectoryName = ".archive-quarantine";

    /// <summary>File name of the retained exact package inside a package directory.</summary>
    public const string PackageFileName = "package.jazz-archive";

    /// <summary>File name of the package identity document.</summary>
    public const string ProvenanceFileName = "provenance.json";

    /// <summary>Directory name of the append-only receipts.</summary>
    public const string ReceiptsDirectoryName = "receipts";

    private const string StagingPrefix = ".archive-import-";
    private const string ReceiptIdPrefix = "imr";
    private const string OriginIdPrefix = "origin";
    private const string SourceIdPrefix = "src";
    private const string DownloadOperationIdPrefix = "dop";
    private const int MaxProvenanceDocumentBytes = 1024 * 1024;
    private const int MaxOriginalFileNameBytes = 1024;
    private const int MaxIdentityNamespaceBytes = 128;
    private const int MaxIdentityValueBytes = 4096;
    private const int MaxAuthorizationIdBytes = 256;
    private const int CopyChunkSize = 64 * 1024;

    private static readonly UTF8Encoding Utf8 = new(encoderShouldEmitUTF8Identifier: false);

    private readonly JazzArchiveImportLimits _limits;

    /// <summary>Creates an importer over one archive store root.</summary>
    /// <param name="root">Directory holding finalized snapshots and the package store.</param>
    /// <param name="limits">The ingest envelope; the published desktop defaults when omitted.</param>
    public JazzArchiveImporter(string root, JazzArchiveImportLimits? limits = null)
    {
        ArgumentException.ThrowIfNullOrEmpty(root);

        Root = Path.GetFullPath(root);
        _limits = limits ?? new JazzArchiveImportLimits();
    }

    /// <summary>The archive store root.</summary>
    public string Root { get; }

    /// <summary>
    /// Imports the <c>.jazz-archive</c> package at <paramref name="sourcePath"/>.
    /// </summary>
    /// <param name="sourcePath">The selected package file.</param>
    /// <param name="context">Non-canonical acquisition facts recorded as a receipt.</param>
    /// <param name="importedAt">Import time (RFC 3339); the current instant when omitted.</param>
    /// <param name="expectedPackageFingerprint">
    /// When given, the copied bytes must match it — the download grant's promise about the file.
    /// </param>
    /// <param name="expectedArchiveId">When given, the manifest must carry this archive id.</param>
    /// <param name="expectedContentDigest">When given, the manifest must carry this content digest.</param>
    /// <exception cref="JazzArchiveImportException">
    /// The package is not a v1 container, breaches the ingest envelope, fails a contract or digest
    /// check, or collides with a different archive already stored under the same id.
    /// </exception>
    public JazzArchiveImportResult Import(
        string sourcePath,
        JazzArchiveImportContext? context = null,
        string? importedAt = null,
        JazzArchiveFileFingerprint? expectedPackageFingerprint = null,
        string? expectedArchiveId = null,
        string? expectedContentDigest = null)
    {
        ArgumentException.ThrowIfNullOrEmpty(sourcePath);
        _limits.Validate();

        JazzArchiveImportContext acquisition = context ?? new JazzArchiveImportContext();
        string stamp = importedAt ?? Timestamps.IsoMillisUtc(DateTimeOffset.UtcNow);
        if (Timestamps.UnixNanos(stamp) is null)
        {
            throw JazzArchiveImportException.InvalidArchive("importedAt");
        }

        RequireCoherentAcquisition(acquisition);
        long declaredLength = RequireImportableFile(sourcePath);
        if (declaredLength > _limits.MaxArchiveBytes)
        {
            throw JazzArchiveImportException.ArchiveTooLarge(
                Invariant("{0} bytes", declaredLength));
        }

        Directory.CreateDirectory(Root);
        string staging = Path.Combine(Root, StagingPrefix + Identifiers.UuidV7());
        Directory.CreateDirectory(staging);

        try
        {
            return ImportStaged(
                sourcePath,
                staging,
                acquisition,
                stamp,
                expectedPackageFingerprint,
                expectedArchiveId,
                expectedContentDigest);
        }
        finally
        {
            RemoveTree(staging);
        }
    }

    /// <summary>
    /// Returns the stored provenance of <paramref name="archiveId"/>, or <see langword="null"/> when
    /// no package is retained for it. Re-verifies the retained bytes rather than trusting the
    /// document that describes them.
    /// </summary>
    public JazzArchivePackageProvenance? Provenance(string archiveId)
    {
        ArgumentException.ThrowIfNullOrEmpty(archiveId);

        string directory = PackageDirectory(archiveId);
        if (!Directory.Exists(directory))
        {
            return null;
        }

        JazzArchiveFinalizedSnapshot snapshot = JazzArchiveSnapshotVerifier.Verify(
            FinalizedDirectory(archiveId),
            archiveId,
            _limits);

        return VerifyPackageDirectory(directory, snapshot);
    }

    private JazzArchiveImportResult ImportStaged(
        string sourcePath,
        string staging,
        JazzArchiveImportContext context,
        string importedAt,
        JazzArchiveFileFingerprint? expectedPackageFingerprint,
        string? expectedArchiveId,
        string? expectedContentDigest)
    {
        string packageCopy = Path.Combine(staging, PackageFileName);
        JazzArchiveFileFingerprint copied = CopyAndFingerprint(sourcePath, packageCopy);
        if (expectedPackageFingerprint is { } promised && copied != promised)
        {
            throw JazzArchiveImportException.IntegrityMismatch("download grant package fingerprint");
        }

        string snapshotStage = Path.Combine(staging, "snapshot");
        Directory.CreateDirectory(snapshotStage);
        IReadOnlyDictionary<string, JazzArchiveFileFingerprint> extracted =
            JazzArchiveContainerReader.Extract(packageCopy, snapshotStage, _limits);

        // The bytes that were hashed must be the bytes that were expanded. Re-reading the copy
        // closes the window in which something else could have rewritten it mid-verification.
        if (Fingerprint(packageCopy) != copied)
        {
            throw JazzArchiveImportException.IntegrityMismatch("package changed during verification");
        }

        JazzArchiveFinalizedSnapshot staged = JazzArchiveSnapshotVerifier.Verify(snapshotStage, null, _limits);
        RequireSameFiles(extracted, staged.FileFingerprints);

        if (expectedArchiveId is not null
            && !string.Equals(staged.ArchiveId, expectedArchiveId, StringComparison.Ordinal))
        {
            throw JazzArchiveImportException.IntegrityMismatch("download grant archiveId");
        }

        if (expectedContentDigest is not null
            && !string.Equals(staged.ContentDigest, expectedContentDigest, StringComparison.Ordinal))
        {
            throw JazzArchiveImportException.IntegrityMismatch("download grant contentDigest");
        }

        string archiveId = staged.ArchiveId;
        string finalized = FinalizedDirectory(archiveId);
        if (Directory.Exists(DraftDirectory(archiveId)) && !Directory.Exists(finalized))
        {
            throw JazzArchiveImportException.ArchiveConflict(archiveId);
        }

        JazzArchiveFinalizedSnapshot? existing = null;
        if (Directory.Exists(finalized))
        {
            existing = JazzArchiveSnapshotVerifier.Verify(finalized, archiveId, _limits);

            // Same id, different bytes. The package is refused and set aside rather than dropped:
            // whoever produced two different archives under one identity needs the evidence, and
            // overwriting the published snapshot would destroy the only copy of the first one.
            if (!string.Equals(existing.ContentDigest, staged.ContentDigest, StringComparison.Ordinal)
                || !SameFiles(existing.FileFingerprints, staged.FileFingerprints))
            {
                Quarantine(archiveId, packageCopy, copied, staged.ContentDigest, existing.ContentDigest, importedAt);
                throw JazzArchiveImportException.ArchiveConflict(archiveId);
            }
        }

        var identity = new JazzArchivePackageIdentity(
            JazzArchivePackageProvenance.PackageIdFor(copied.Sha256),
            archiveId,
            staged.ContentDigest,
            copied.Sha256,
            copied.ByteLength,
            Identifiers.Prefixed(ReceiptIdPrefix));

        var receipt = new JazzArchiveImportReceipt
        {
            ReceiptId = identity.InitialReceiptId,
            PackageId = identity.PackageId,
            ArchiveId = identity.ArchiveId,
            PackageSha256 = identity.PackageSha256,
            PackageByteLength = identity.PackageByteLength,
            ImportedAt = importedAt,
            ImportedBy = context.ImportedBy,
            ImportingOriginId = context.ImportingOriginId,
            ImportingSourceId = context.ImportingSourceId,
            ImportingDevice = context.ImportingDevice,
            Acquisition = context.Acquisition,
            OriginalFileName = Path.GetFileName(sourcePath),
            DownloadOperationId = context.DownloadOperationId,
            DownloadAuthorizationId = context.DownloadAuthorizationId,
        };

        ValidateReceipt(receipt, identity);

        // The package and its provenance become durable before the snapshot rename, so the rename is
        // the single commit point: a reader never sees published evidence whose exact bytes are gone.
        JazzArchivePackageProvenance provenance = PublishPackage(staging, packageCopy, identity, receipt, staged);

        JazzArchiveFinalizedSnapshot published;
        JazzArchiveImportDisposition disposition;
        if (existing is not null)
        {
            MakeImmutable(finalized);
            disposition = JazzArchiveImportDisposition.AlreadyPresent;
            published = existing;
        }
        else
        {
            PublishSnapshot(snapshotStage, finalized, archiveId, staged);
            disposition = JazzArchiveImportDisposition.Imported;
            published = JazzArchiveSnapshotVerifier.Verify(finalized, archiveId, _limits);
        }

        return new JazzArchiveImportResult(
            disposition,
            published,
            provenance,
            Path.Combine(PackageDirectory(archiveId), PackageFileName));
    }

    /// <summary>Moves the verified snapshot into place and freezes it.</summary>
    private void PublishSnapshot(
        string snapshotStage,
        string finalized,
        string archiveId,
        JazzArchiveFinalizedSnapshot staged)
    {
        try
        {
            Directory.Move(snapshotStage, finalized);
        }
        catch (IOException error)
        {
            // Another importer may have won the race with the identical package. That is the
            // idempotent outcome, not a failure — but only if it really is the identical package.
            if (!Directory.Exists(finalized))
            {
                throw JazzArchiveImportException.PublishFailed("snapshot " + archiveId + ": " + error.Message);
            }

            JazzArchiveFinalizedSnapshot concurrent = JazzArchiveSnapshotVerifier.Verify(
                finalized,
                archiveId,
                _limits);

            if (!string.Equals(concurrent.ContentDigest, staged.ContentDigest, StringComparison.Ordinal)
                || !SameFiles(concurrent.FileFingerprints, staged.FileFingerprints))
            {
                throw JazzArchiveImportException.ArchiveConflict(archiveId);
            }
        }

        MakeImmutable(finalized);
    }

    /// <summary>
    /// Publishes the exact package bytes, the package identity document and the first receipt. When
    /// the package directory already exists it must describe the very same bytes; the new receipt is
    /// then appended to it.
    /// </summary>
    private JazzArchivePackageProvenance PublishPackage(
        string staging,
        string packageCopy,
        JazzArchivePackageIdentity identity,
        JazzArchiveImportReceipt receipt,
        JazzArchiveFinalizedSnapshot snapshot)
    {
        string packageStage = Path.Combine(staging, "package-store");
        Directory.CreateDirectory(packageStage);
        File.Move(packageCopy, Path.Combine(packageStage, PackageFileName));

        byte[] identityBytes = CanonicalBytes(identity.ToDocument());
        if (identityBytes.Length > MaxProvenanceDocumentBytes)
        {
            throw JazzArchiveImportException.EntryLimitExceeded("package provenance");
        }

        File.WriteAllBytes(Path.Combine(packageStage, ProvenanceFileName), identityBytes);

        string stagedReceipts = Path.Combine(packageStage, ReceiptsDirectoryName);
        Directory.CreateDirectory(stagedReceipts);
        byte[] receiptBytes = CanonicalBytes(ToDocument(receipt));
        if (receiptBytes.Length > MaxProvenanceDocumentBytes)
        {
            throw JazzArchiveImportException.EntryLimitExceeded("import receipt");
        }

        string stagedReceipt = Path.Combine(stagedReceipts, receipt.ReceiptId + ".json");
        File.WriteAllBytes(stagedReceipt, receiptBytes);

        string destination = PackageDirectory(identity.ArchiveId);
        Directory.CreateDirectory(Path.GetDirectoryName(destination)!);

        if (!Directory.Exists(destination))
        {
            try
            {
                Directory.Move(packageStage, destination);
                MakeImmutable(destination);
                return VerifyPackageDirectory(destination, snapshot);
            }
            catch (IOException error) when (Directory.Exists(destination))
            {
                // Lost a race with a concurrent importer; fall through to the append path below,
                // which proves the winner stored the same package before adding this receipt.
                _ = error;
            }
        }

        JazzArchivePackageProvenance stored = VerifyPackageDirectory(destination, snapshot);
        if (!string.Equals(stored.PackageId, identity.PackageId, StringComparison.Ordinal)
            || !string.Equals(stored.ArchiveId, identity.ArchiveId, StringComparison.Ordinal)
            || !string.Equals(stored.ContentDigest, identity.ContentDigest, StringComparison.Ordinal)
            || stored.PackageFingerprint != identity.PackageFingerprint)
        {
            throw JazzArchiveImportException.ArchiveConflict(identity.ArchiveId);
        }

        AppendReceipt(destination, receipt, receiptBytes);
        return VerifyPackageDirectory(destination, snapshot);
    }

    /// <summary>
    /// Adds one receipt to an already-published package directory. Receipts are append-only, so an
    /// existing file under the same identity must hold byte-identical content rather than be replaced.
    /// </summary>
    private static void AppendReceipt(string packageDirectory, JazzArchiveImportReceipt receipt, byte[] bytes)
    {
        string receipts = Path.Combine(packageDirectory, ReceiptsDirectoryName);
        string destination = Path.Combine(receipts, receipt.ReceiptId + ".json");

        MakeWritable(receipts);
        try
        {
            if (File.Exists(destination))
            {
                if (!File.ReadAllBytes(destination).AsSpan().SequenceEqual(bytes))
                {
                    throw JazzArchiveImportException.ArchiveConflict(receipt.ArchiveId);
                }

                return;
            }

            File.WriteAllBytes(destination, bytes);
            MakeReadOnly(destination);
        }
        catch (IOException error)
        {
            throw JazzArchiveImportException.PublishFailed("receipt " + receipt.ReceiptId + ": " + error.Message);
        }
        finally
        {
            MakeDirectoryReadOnly(receipts);
        }
    }

    /// <summary>
    /// Re-reads a published package directory and proves it is exactly what it claims: three known
    /// entries, a canonical identity document that agrees with the snapshot's manifest, package bytes
    /// that still hash to the recorded digest, and a well-formed receipt set containing the initial one.
    /// </summary>
    private JazzArchivePackageProvenance VerifyPackageDirectory(
        string directory,
        JazzArchiveFinalizedSnapshot snapshot)
    {
        var expectedNames = new HashSet<string>(StringComparer.Ordinal)
        {
            PackageFileName,
            ProvenanceFileName,
            ReceiptsDirectoryName,
        };

        var actualNames = new HashSet<string>(
            Directory.EnumerateFileSystemEntries(directory).Select(Path.GetFileName).Select(name => name!),
            StringComparer.Ordinal);

        if (!actualNames.SetEquals(expectedNames))
        {
            throw JazzArchiveImportException.ArchiveConflict(snapshot.ArchiveId);
        }

        string packagePath = Path.Combine(directory, PackageFileName);
        string provenancePath = Path.Combine(directory, ProvenanceFileName);
        byte[] identityBytes = File.ReadAllBytes(provenancePath);
        JazzArchivePackageIdentity identity = JazzArchivePackageIdentity.FromDocument(
            ParseCanonical(identityBytes, ProvenanceFileName));

        if (!CanonicalBytes(identity.ToDocument()).AsSpan().SequenceEqual(identityBytes))
        {
            throw JazzArchiveImportException.ArchiveConflict(snapshot.ArchiveId);
        }

        identity.Validate(snapshot);
        if (Fingerprint(packagePath) != identity.PackageFingerprint)
        {
            throw JazzArchiveImportException.ArchiveConflict(snapshot.ArchiveId);
        }

        string receiptsDirectory = Path.Combine(directory, ReceiptsDirectoryName);
        if (!Directory.Exists(receiptsDirectory))
        {
            throw JazzArchiveImportException.ArchiveConflict(snapshot.ArchiveId);
        }

        var receipts = new List<JazzArchiveImportReceipt>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (string path in Directory.EnumerateFileSystemEntries(receiptsDirectory))
        {
            var info = new FileInfo(path);
            if (!info.Exists
                || info.LinkTarget is not null
                || !string.Equals(info.Extension, ".json", StringComparison.Ordinal)
                || info.Length > Math.Min(MaxProvenanceDocumentBytes, _limits.MaxJsonEntryBytes))
            {
                throw JazzArchiveImportException.ArchiveConflict(snapshot.ArchiveId);
            }

            byte[] bytes = File.ReadAllBytes(path);
            JazzArchiveImportReceipt receipt = FromDocument(ParseCanonical(bytes, info.Name));
            if (!string.Equals(
                    Path.GetFileNameWithoutExtension(info.Name),
                    receipt.ReceiptId,
                    StringComparison.Ordinal)
                || !CanonicalBytes(ToDocument(receipt)).AsSpan().SequenceEqual(bytes)
                || !seen.Add(receipt.ReceiptId))
            {
                throw JazzArchiveImportException.ArchiveConflict(snapshot.ArchiveId);
            }

            ValidateReceipt(receipt, identity);
            receipts.Add(receipt);
        }

        if (receipts.Count == 0 || receipts.Count > _limits.MaxEntries)
        {
            throw JazzArchiveImportException.ArchiveConflict(snapshot.ArchiveId);
        }

        JazzArchiveImportReceipt initial = receipts.FirstOrDefault(
                value => string.Equals(value.ReceiptId, identity.InitialReceiptId, StringComparison.Ordinal))
            ?? throw JazzArchiveImportException.ArchiveConflict(snapshot.ArchiveId);

        var ordered = new List<JazzArchiveImportReceipt> { initial };
        ordered.AddRange(receipts
            .Where(value => !string.Equals(value.ReceiptId, initial.ReceiptId, StringComparison.Ordinal))
            .OrderBy(value => value.ReceiptId, StringComparer.Ordinal));

        return new JazzArchivePackageProvenance(
            identity.SchemaVersion,
            identity.PackageId,
            identity.ArchiveId,
            identity.ContentDigest,
            identity.PackageSha256,
            identity.PackageByteLength,
            ordered);
    }

    /// <summary>
    /// Sets a refused conflicting package aside with a note naming both content digests.
    /// </summary>
    /// <remarks>
    /// The quarantine tree is deliberately outside both published trees: it is refused material, not
    /// a snapshot and not a retained package, and nothing reads it back. Failing to write it must not
    /// change the outcome — the import is already refused — so the write is best-effort.
    /// </remarks>
    private void Quarantine(
        string archiveId,
        string packageCopy,
        JazzArchiveFileFingerprint fingerprint,
        string offeredContentDigest,
        string storedContentDigest,
        string importedAt)
    {
        try
        {
            string directory = Path.Combine(Root, QuarantineDirectoryName, archiveId);
            Directory.CreateDirectory(directory);

            string packageId = JazzArchivePackageProvenance.PackageIdFor(fingerprint.Sha256);
            File.Copy(packageCopy, Path.Combine(directory, packageId + ".jazz-archive"), overwrite: true);

            var note = new JsonObject
            {
                ["schemaVersion"] = 1,
                ["archiveId"] = archiveId,
                ["packageId"] = packageId,
                ["packageSha256"] = fingerprint.Sha256,
                ["packageByteLength"] = fingerprint.ByteLength,
                ["offeredContentDigest"] = offeredContentDigest,
                ["storedContentDigest"] = storedContentDigest,
                ["refusedAt"] = importedAt,
                ["reason"] = "archive id already published with different content",
            };

            File.WriteAllBytes(Path.Combine(directory, packageId + ".json"), CanonicalBytes(note));
        }
        catch (IOException)
        {
            // The refusal below is the outcome that matters; a quarantine that could not be written
            // must not turn a clean rejection into a different error.
        }
        catch (UnauthorizedAccessException)
        {
        }
    }

    private static void RequireCoherentAcquisition(JazzArchiveImportContext context)
    {
        bool hasDownloadIds = context.DownloadOperationId is not null || context.DownloadAuthorizationId is not null;
        bool isDownload = context.Acquisition == JazzArchiveImportAcquisition.JazzServerDownload;

        if (isDownload
            && (context.DownloadOperationId is null || context.DownloadAuthorizationId is null))
        {
            throw JazzArchiveImportException.InvalidArchive("download authorization");
        }

        if (!isDownload && hasDownloadIds)
        {
            throw JazzArchiveImportException.InvalidArchive("download authorization");
        }
    }

    private static long RequireImportableFile(string sourcePath)
    {
        var info = new FileInfo(sourcePath);
        if (!info.Exists || info.LinkTarget is not null || info.Attributes.HasFlag(FileAttributes.ReparsePoint))
        {
            throw JazzArchiveImportException.SourceNotRegularFile(sourcePath);
        }

        if (info.Length <= 0)
        {
            throw JazzArchiveImportException.SourceNotRegularFile(sourcePath);
        }

        return info.Length;
    }

    /// <summary>
    /// Streams the selection into staging while hashing it, refusing at the moment the copy would
    /// exceed the package bound rather than after the whole file has landed.
    /// </summary>
    private JazzArchiveFileFingerprint CopyAndFingerprint(string sourcePath, string destination)
    {
        using var hasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        long byteLength = 0;

        using (FileStream input = new(sourcePath, FileMode.Open, FileAccess.Read, FileShare.Read))
        using (FileStream output = new(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None))
        {
            byte[] buffer = new byte[CopyChunkSize];
            int read;
            while ((read = input.Read(buffer, 0, buffer.Length)) > 0)
            {
                byteLength += read;
                if (byteLength > _limits.MaxArchiveBytes)
                {
                    throw JazzArchiveImportException.ArchiveTooLarge(
                        Invariant("more than {0} bytes", _limits.MaxArchiveBytes));
                }

                output.Write(buffer, 0, read);
                hasher.AppendData(buffer, 0, read);
            }

            output.Flush(flushToDisk: true);
        }

        if (byteLength == 0)
        {
            throw JazzArchiveImportException.SourceNotRegularFile(sourcePath);
        }

        return new JazzArchiveFileFingerprint(
            Convert.ToHexString(hasher.GetHashAndReset()).ToLowerInvariant(),
            byteLength);
    }

    private static JazzArchiveFileFingerprint Fingerprint(string path) =>
        new(JazzArchiveContainer.Sha256File(path), new FileInfo(path).Length);

    private static void RequireSameFiles(
        IReadOnlyDictionary<string, JazzArchiveFileFingerprint> left,
        IReadOnlyDictionary<string, JazzArchiveFileFingerprint> right)
    {
        if (!SameFiles(left, right))
        {
            throw JazzArchiveImportException.IntegrityMismatch("extracted snapshot");
        }
    }

    private static bool SameFiles(
        IReadOnlyDictionary<string, JazzArchiveFileFingerprint> left,
        IReadOnlyDictionary<string, JazzArchiveFileFingerprint> right) =>
        left.Count == right.Count
        && left.All(entry =>
            right.TryGetValue(entry.Key, out JazzArchiveFileFingerprint other) && other == entry.Value);

    private static void ValidateReceipt(JazzArchiveImportReceipt receipt, JazzArchivePackageIdentity identity)
    {
        if (receipt.SchemaVersion != 1
            || !IsPrefixedUuidV7(receipt.ReceiptId, ReceiptIdPrefix)
            || !string.Equals(receipt.PackageId, identity.PackageId, StringComparison.Ordinal)
            || !string.Equals(receipt.ArchiveId, identity.ArchiveId, StringComparison.Ordinal)
            || !string.Equals(receipt.PackageSha256, identity.PackageSha256, StringComparison.Ordinal)
            || receipt.PackageByteLength != identity.PackageByteLength
            || Timestamps.UnixNanos(receipt.ImportedAt) is null)
        {
            throw JazzArchiveImportException.InvalidArchive("import receipt");
        }

        ValidateExternalIdentity(receipt.ImportedBy, "importedBy");
        ValidateExternalIdentity(receipt.ImportingDevice, "importingDevice");

        if (receipt.ImportingOriginId is { } originId && !IsPrefixedUuidV7(originId, OriginIdPrefix))
        {
            throw JazzArchiveImportException.InvalidArchive("importingOriginId");
        }

        if (receipt.ImportingSourceId is { } sourceId && !IsPrefixedUuidV7(sourceId, SourceIdPrefix))
        {
            throw JazzArchiveImportException.InvalidArchive("importingSourceId");
        }

        if (receipt.OriginalFileName is { } fileName
            && (fileName.Length == 0
                || Encoding.UTF8.GetByteCount(fileName) > MaxOriginalFileNameBytes
                || fileName.Contains('/', StringComparison.Ordinal)
                || fileName.Contains('\\', StringComparison.Ordinal)))
        {
            throw JazzArchiveImportException.InvalidArchive("originalFileName");
        }

        switch (receipt.DownloadOperationId, receipt.DownloadAuthorizationId)
        {
            case (null, null):
                break;
            case ({ } operationId, { } authorizationId)
                when receipt.Acquisition == JazzArchiveImportAcquisition.JazzServerDownload
                    && IsPrefixedUuidV7(operationId, DownloadOperationIdPrefix)
                    && IsBoundedCanonicalText(authorizationId, MaxAuthorizationIdBytes):
                break;
            default:
                throw JazzArchiveImportException.InvalidArchive("download authorization");
        }
    }

    private static void ValidateExternalIdentity(JazzArchiveExternalIdentity? identity, string field)
    {
        if (identity is null)
        {
            return;
        }

        string space = identity.Namespace.Trim();
        string value = identity.Value.Trim();
        if (space.Length == 0
            || Encoding.UTF8.GetByteCount(space) > MaxIdentityNamespaceBytes
            || value.Length == 0
            || Encoding.UTF8.GetByteCount(value) > MaxIdentityValueBytes)
        {
            throw JazzArchiveImportException.InvalidArchive(field);
        }
    }

    private static bool IsBoundedCanonicalText(string value, int maximumBytes) =>
        value.Length > 0
        && Encoding.UTF8.GetByteCount(value) <= maximumBytes
        && string.Equals(value, value.Trim(), StringComparison.Ordinal)
        && !value.Any(char.IsControl);

    /// <summary>Reports whether <paramref name="value"/> is <c>&lt;prefix&gt;-</c> plus a lowercase UUIDv7.</summary>
    private static bool IsPrefixedUuidV7(string value, string prefix)
    {
        string marker = prefix + "-";
        if (!value.StartsWith(marker, StringComparison.Ordinal))
        {
            return false;
        }

        string raw = value[marker.Length..];
        if (raw.Length != 36 || raw[14] != '7' || !"89ab".Contains(raw[19], StringComparison.Ordinal))
        {
            return false;
        }

        for (int index = 0; index < raw.Length; index++)
        {
            bool isSeparator = index is 8 or 13 or 18 or 23;
            char c = raw[index];
            if (isSeparator ? c != '-' : c is not ((>= '0' and <= '9') or (>= 'a' and <= 'f')))
            {
                return false;
            }
        }

        return true;
    }

    /// <summary>
    /// Renders one receipt. Every absent optional field is left out of the document entirely rather
    /// than written as <c>null</c>: the canonical form must not distinguish "unknown" from "declared
    /// unknown", and a null would.
    /// </summary>
    private static JsonObject ToDocument(JazzArchiveImportReceipt receipt)
    {
        var document = new JsonObject
        {
            ["schemaVersion"] = receipt.SchemaVersion,
            ["receiptId"] = receipt.ReceiptId,
            ["packageId"] = receipt.PackageId,
            ["archiveId"] = receipt.ArchiveId,
            ["packageSHA256"] = receipt.PackageSha256,
            ["packageByteLength"] = receipt.PackageByteLength,
            ["importedAt"] = receipt.ImportedAt,
            ["acquisition"] = Wire(receipt.Acquisition),
        };

        if (receipt.ImportedBy is { } importedBy)
        {
            document["importedBy"] = ToDocument(importedBy);
        }

        if (receipt.ImportingOriginId is { } originId)
        {
            document["importingOriginId"] = originId;
        }

        if (receipt.ImportingSourceId is { } sourceId)
        {
            document["importingSourceId"] = sourceId;
        }

        if (receipt.ImportingDevice is { } device)
        {
            document["importingDevice"] = ToDocument(device);
        }

        if (receipt.OriginalFileName is { } fileName)
        {
            document["originalFileName"] = fileName;
        }

        if (receipt.DownloadOperationId is { } operationId)
        {
            document["downloadOperationId"] = operationId;
        }

        if (receipt.DownloadAuthorizationId is { } authorizationId)
        {
            document["downloadAuthorizationId"] = authorizationId;
        }

        return document;
    }

    private static JsonObject ToDocument(JazzArchiveExternalIdentity identity) => new()
    {
        ["namespace"] = identity.Namespace,
        ["value"] = identity.Value,
    };

    private static JazzArchiveImportReceipt FromDocument(JsonObject document) => new()
    {
        SchemaVersion = (int)ReadInteger(document, "schemaVersion"),
        ReceiptId = ReadText(document, "receiptId"),
        PackageId = ReadText(document, "packageId"),
        ArchiveId = ReadText(document, "archiveId"),
        PackageSha256 = ReadText(document, "packageSHA256"),
        PackageByteLength = ReadInteger(document, "packageByteLength"),
        ImportedAt = ReadText(document, "importedAt"),
        Acquisition = ReadAcquisition(document),
        ImportedBy = ReadIdentity(document, "importedBy"),
        ImportingOriginId = ReadOptionalText(document, "importingOriginId"),
        ImportingSourceId = ReadOptionalText(document, "importingSourceId"),
        ImportingDevice = ReadIdentity(document, "importingDevice"),
        OriginalFileName = ReadOptionalText(document, "originalFileName"),
        DownloadOperationId = ReadOptionalText(document, "downloadOperationId"),
        DownloadAuthorizationId = ReadOptionalText(document, "downloadAuthorizationId"),
    };

    private static JazzArchiveExternalIdentity? ReadIdentity(JsonObject document, string key) =>
        document[key] is JsonObject value
            ? new JazzArchiveExternalIdentity(ReadText(value, "namespace"), ReadText(value, "value"))
            : null;

    private static JazzArchiveImportAcquisition ReadAcquisition(JsonObject document) =>
        ReadText(document, "acquisition") switch
        {
            "user_selected_file" => JazzArchiveImportAcquisition.UserSelectedFile,
            "jazz_server_download" => JazzArchiveImportAcquisition.JazzServerDownload,
            var other => throw JazzArchiveImportException.InvalidArchive("acquisition " + other),
        };

    private static string Wire(JazzArchiveImportAcquisition acquisition) => acquisition switch
    {
        JazzArchiveImportAcquisition.UserSelectedFile => "user_selected_file",
        JazzArchiveImportAcquisition.JazzServerDownload => "jazz_server_download",
        _ => throw JazzArchiveImportException.InvalidArchive("acquisition"),
    };

    internal static string ReadText(JsonObject document, string key) =>
        document[key] is JsonValue node && node.TryGetValue(out string? text) && text.Length > 0
            ? text
            : throw JazzArchiveImportException.InvalidArchive("provenance is missing string '" + key + "'");

    internal static string? ReadOptionalText(JsonObject document, string key) =>
        document.ContainsKey(key) ? ReadText(document, key) : null;

    internal static long ReadInteger(JsonObject document, string key) =>
        document[key] is JsonValue node && node.TryGetValue(out long number)
            ? number
            : throw JazzArchiveImportException.InvalidArchive("provenance is missing integer '" + key + "'");

    internal static byte[] CanonicalBytes(JsonNode document) =>
        Utf8.GetBytes(JsonCanonicalizer.Canonicalize(document));

    private static JsonObject ParseCanonical(byte[] bytes, string path)
    {
        string text;
        try
        {
            text = new UTF8Encoding(false, throwOnInvalidBytes: true).GetString(bytes);
        }
        catch (DecoderFallbackException)
        {
            throw JazzArchiveImportException.InvalidArchive(path + " is not valid UTF-8");
        }

        try
        {
            return JsonStrictParser.Parse(text) as JsonObject
                ?? throw JazzArchiveImportException.InvalidArchive(path + " is not a JSON object");
        }
        catch (FormatException error)
        {
            throw JazzArchiveImportException.InvalidArchive(path + ": " + error.Message);
        }
    }

    private string FinalizedDirectory(string archiveId) =>
        Path.Combine(Root, archiveId + FinalizedSuffix);

    private string DraftDirectory(string archiveId) =>
        Path.Combine(Root, archiveId + DraftSuffix);

    private string PackageDirectory(string archiveId) =>
        Path.Combine(Root, PackagesDirectoryName, archiveId);

    /// <summary>
    /// Freezes a published tree: every file becomes read-only, then every directory, deepest first.
    /// </summary>
    /// <remarks>
    /// On a POSIX host this is a real mode change; on Windows it is the read-only attribute, which
    /// the filesystem enforces for files and ignores for directories. Either way this is a guard
    /// against accident, not a security boundary — the digests are what prove the bytes.
    /// </remarks>
    private static void MakeImmutable(string directory)
    {
        foreach (string path in Directory.EnumerateFiles(directory, "*", SearchOption.AllDirectories))
        {
            MakeReadOnly(path);
        }

        List<string> directories = Directory
            .EnumerateDirectories(directory, "*", SearchOption.AllDirectories)
            .ToList();
        directories.Add(directory);
        directories.Sort(static (left, right) => right.Length.CompareTo(left.Length));

        foreach (string path in directories)
        {
            MakeDirectoryReadOnly(path);
        }
    }

    private static void MakeReadOnly(string path)
    {
        if (OperatingSystem.IsWindows())
        {
            File.SetAttributes(path, File.GetAttributes(path) | FileAttributes.ReadOnly);
            return;
        }

        File.SetUnixFileMode(path, UnixFileMode.UserRead);
    }

    private static void MakeDirectoryReadOnly(string path)
    {
        if (OperatingSystem.IsWindows())
        {
            return;
        }

        File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserExecute);
    }

    private static void MakeWritable(string path)
    {
        if (OperatingSystem.IsWindows())
        {
            return;
        }

        File.SetUnixFileMode(
            path,
            UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
    }

    /// <summary>
    /// Removes a staging tree, clearing the read-only marks a partially published subtree may carry.
    /// </summary>
    public static void RemoveTree(string directory)
    {
        ArgumentException.ThrowIfNullOrEmpty(directory);

        if (!Directory.Exists(directory))
        {
            return;
        }

        MakeWritable(directory);
        foreach (string path in Directory.EnumerateDirectories(directory, "*", SearchOption.AllDirectories))
        {
            MakeWritable(path);
        }

        foreach (string path in Directory.EnumerateFiles(directory, "*", SearchOption.AllDirectories))
        {
            if (OperatingSystem.IsWindows())
            {
                File.SetAttributes(path, File.GetAttributes(path) & ~FileAttributes.ReadOnly);
            }
            else
            {
                File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
            }
        }

        Directory.Delete(directory, recursive: true);
    }

    private static string Invariant(string template, params object[] arguments) =>
        string.Format(CultureInfo.InvariantCulture, template, arguments);
}

/// <summary>
/// The package identity document stored beside the retained bytes. It is the fixed part of a package
/// directory: the receipts accumulate around it, but this never changes.
/// </summary>
internal sealed record JazzArchivePackageIdentity(
    string PackageId,
    string ArchiveId,
    string ContentDigest,
    string PackageSha256,
    long PackageByteLength,
    string InitialReceiptId)
{
    public int SchemaVersion => 1;

    public JazzArchiveFileFingerprint PackageFingerprint => new(PackageSha256, PackageByteLength);

    public JsonObject ToDocument() => new()
    {
        ["schemaVersion"] = SchemaVersion,
        ["packageId"] = PackageId,
        ["archiveId"] = ArchiveId,
        ["contentDigest"] = ContentDigest,
        ["packageSHA256"] = PackageSha256,
        ["packageByteLength"] = PackageByteLength,
        ["initialReceiptId"] = InitialReceiptId,
    };

    public static JazzArchivePackageIdentity FromDocument(JsonObject document)
    {
        if (JazzArchiveImporter.ReadInteger(document, "schemaVersion") != 1)
        {
            throw JazzArchiveImportException.InvalidArchive("package provenance");
        }

        return new JazzArchivePackageIdentity(
            JazzArchiveImporter.ReadText(document, "packageId"),
            JazzArchiveImporter.ReadText(document, "archiveId"),
            JazzArchiveImporter.ReadText(document, "contentDigest"),
            JazzArchiveImporter.ReadText(document, "packageSHA256"),
            JazzArchiveImporter.ReadInteger(document, "packageByteLength"),
            JazzArchiveImporter.ReadText(document, "initialReceiptId"));
    }

    /// <summary>Checks the identity against the snapshot the package expands to.</summary>
    public void Validate(JazzArchiveFinalizedSnapshot snapshot)
    {
        if (!string.Equals(
                PackageId,
                JazzArchivePackageProvenance.PackageIdFor(PackageSha256),
                StringComparison.Ordinal)
            || !string.Equals(ArchiveId, snapshot.ArchiveId, StringComparison.Ordinal)
            || !string.Equals(ContentDigest, snapshot.ContentDigest, StringComparison.Ordinal)
            || PackageByteLength <= 0
            || PackageSha256.Length != 64
            || !PackageSha256.All(c => c is (>= '0' and <= '9') or (>= 'a' and <= 'f')))
        {
            throw JazzArchiveImportException.InvalidArchive("package provenance");
        }
    }
}
