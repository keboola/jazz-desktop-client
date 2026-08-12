using System.Globalization;
using System.Text;

namespace JazzCaptureCore.Archive;

/// <summary>
/// The published ingest envelope of ANNEX-ARCHIVE section 1.4. Every bound is finite and is checked
/// against a package's <em>declared</em> sizes before a single entry body is read, because these
/// numbers are the defence against a hostile package: discovering the limit by running out of memory
/// is not enforcement.
/// </summary>
/// <remarks>
/// The defaults are the desktop values the contract publishes (contract/README.md, "Canonical
/// desktop ZIP32 profile"). They are the configuration of the importer rather than incidental
/// constants, which is why they live on this one type and are injected wherever a smaller envelope
/// is wanted — a test proving a bound rejects, for instance, shrinks the bound instead of building a
/// two-gigabyte file.
/// </remarks>
public sealed record JazzArchiveImportLimits
{
    /// <summary>Largest accepted <c>.jazz-archive</c> package: 2 GiB.</summary>
    public long MaxArchiveBytes { get; init; } = 2L * 1024 * 1024 * 1024;

    /// <summary>Largest accepted entry count: 10 000.</summary>
    public int MaxEntries { get; init; } = 10_000;

    /// <summary>Largest accepted single entry: 512 MiB.</summary>
    public long MaxEntryBytes { get; init; } = 512L * 1024 * 1024;

    /// <summary>Largest accepted expanded total across all entries: 4 GiB.</summary>
    public long MaxTotalExpandedBytes { get; init; } = 4L * 1024 * 1024 * 1024;

    /// <summary>Largest accepted total of <c>.json</c> plus <c>.ndjson</c> entries: 256 MiB.</summary>
    public long MaxTotalStructuredBytes { get; init; } = 256L * 1024 * 1024;

    /// <summary>Largest accepted single JSON document: 32 MiB.</summary>
    public long MaxJsonEntryBytes { get; init; } = 32L * 1024 * 1024;

    /// <summary>Largest accepted NDJSON line: 4 MiB.</summary>
    public int MaxNdjsonLineBytes { get; init; } = 4 * 1024 * 1024;

    /// <summary>Largest accepted NDJSON record count across the whole package: 250 000.</summary>
    public int MaxNdjsonRecords { get; init; } = 250_000;

    /// <summary>Largest accepted entry path: 1 024 UTF-8 bytes.</summary>
    public int MaxPathBytes { get; init; } = 1024;

    /// <summary>Rejects a limit set that cannot bound anything.</summary>
    /// <exception cref="JazzArchiveImportException">A bound is zero or negative.</exception>
    public void Validate()
    {
        if (MaxArchiveBytes <= 0
            || MaxEntries <= 0
            || MaxEntryBytes <= 0
            || MaxTotalExpandedBytes <= 0
            || MaxTotalStructuredBytes <= 0
            || MaxJsonEntryBytes <= 0
            || MaxNdjsonLineBytes <= 0
            || MaxNdjsonRecords <= 0
            || MaxPathBytes <= 0)
        {
            throw JazzArchiveImportException.InvalidLimits();
        }
    }
}

/// <summary>Why an import was refused. Mirrors the macOS <c>JazzArchiveImportError</c> cases.</summary>
public enum JazzArchiveImportFailure
{
    /// <summary>The configured ingest envelope cannot bound anything.</summary>
    InvalidLimits,

    /// <summary>The selection is not a non-empty regular file.</summary>
    SourceNotRegularFile,

    /// <summary>The package is larger than the configured package bound.</summary>
    ArchiveTooLarge,

    /// <summary>A declared size, count or total is outside the ingest envelope.</summary>
    EntryLimitExceeded,

    /// <summary>The bytes do not form a well-formed deterministic ZIP32 package.</summary>
    MalformedZip,

    /// <summary>The package uses a ZIP feature outside the v1 profile.</summary>
    UnsupportedZipFeature,

    /// <summary>An entry name is not a portable relative path, or is not a regular file.</summary>
    UnsafeEntry,

    /// <summary>Two entries share a name, or two names collide when case is folded.</summary>
    DuplicateEntry,

    /// <summary>A digest, CRC or byte length does not describe the bytes behind it.</summary>
    IntegrityMismatch,

    /// <summary>The package is a well-formed container but not a valid archive.</summary>
    InvalidArchive,

    /// <summary>The archive id is already taken by different bytes.</summary>
    ArchiveConflict,

    /// <summary>The verified result could not be made durably visible.</summary>
    PublishFailed,
}

/// <summary>One refused import. The <see cref="Failure"/> is the machine-readable reason and the
/// message names the exact artefact that failed, so a rejection can be diagnosed from a log line.</summary>
public sealed class JazzArchiveImportException : Exception
{
    private JazzArchiveImportException(JazzArchiveImportFailure failure, string detail, string message)
        : base(message)
    {
        Failure = failure;
        Detail = detail;
    }

    /// <summary>The category of refusal.</summary>
    public JazzArchiveImportFailure Failure { get; }

    /// <summary>The subject of the refusal: an entry name, a document path, or a digest name.</summary>
    public string Detail { get; }

    /// <summary>The configured ingest envelope cannot bound anything.</summary>
    public static JazzArchiveImportException InvalidLimits() => new(
        JazzArchiveImportFailure.InvalidLimits,
        string.Empty,
        "Jazz Archive import limits are invalid");

    /// <summary>The selection is not a non-empty regular file.</summary>
    public static JazzArchiveImportException SourceNotRegularFile(string detail) => new(
        JazzArchiveImportFailure.SourceNotRegularFile,
        detail,
        "The selected Jazz Archive is not a regular file: " + detail);

    /// <summary>The package is larger than the configured package bound.</summary>
    public static JazzArchiveImportException ArchiveTooLarge(string detail) => new(
        JazzArchiveImportFailure.ArchiveTooLarge,
        detail,
        "The selected Jazz Archive exceeds the configured package limit: " + detail);

    /// <summary>A declared size, count or total is outside the ingest envelope.</summary>
    public static JazzArchiveImportException EntryLimitExceeded(string detail) => new(
        JazzArchiveImportFailure.EntryLimitExceeded,
        detail,
        "Jazz Archive resource limit exceeded: " + detail);

    /// <summary>The bytes do not form a well-formed deterministic ZIP32 package.</summary>
    public static JazzArchiveImportException MalformedZip(string detail) => new(
        JazzArchiveImportFailure.MalformedZip,
        detail,
        "Malformed deterministic ZIP32 package: " + detail);

    /// <summary>The package uses a ZIP feature outside the v1 profile.</summary>
    public static JazzArchiveImportException UnsupportedZipFeature(string detail) => new(
        JazzArchiveImportFailure.UnsupportedZipFeature,
        detail,
        "Unsupported ZIP feature: " + detail);

    /// <summary>An entry name is not a portable relative path, or is not a regular file.</summary>
    public static JazzArchiveImportException UnsafeEntry(string detail) => new(
        JazzArchiveImportFailure.UnsafeEntry,
        detail,
        "Unsafe Jazz Archive entry: " + detail);

    /// <summary>Two entries share a name, or two names collide when case is folded.</summary>
    public static JazzArchiveImportException DuplicateEntry(string detail) => new(
        JazzArchiveImportFailure.DuplicateEntry,
        detail,
        "Colliding Jazz Archive entry: " + detail);

    /// <summary>A digest, CRC or byte length does not describe the bytes behind it.</summary>
    public static JazzArchiveImportException IntegrityMismatch(string detail) => new(
        JazzArchiveImportFailure.IntegrityMismatch,
        detail,
        "Jazz Archive integrity mismatch: " + detail);

    /// <summary>The package is a well-formed container but not a valid archive.</summary>
    public static JazzArchiveImportException InvalidArchive(string detail) => new(
        JazzArchiveImportFailure.InvalidArchive,
        detail,
        "Invalid Jazz Archive contract: " + detail);

    /// <summary>The archive id is already taken by different bytes.</summary>
    public static JazzArchiveImportException ArchiveConflict(string archiveId) => new(
        JazzArchiveImportFailure.ArchiveConflict,
        archiveId,
        "A different Jazz Archive already uses " + archiveId);

    /// <summary>The verified result could not be made durably visible.</summary>
    public static JazzArchiveImportException PublishFailed(string detail) => new(
        JazzArchiveImportFailure.PublishFailed,
        detail,
        "Jazz Archive could not be published: " + detail);
}

/// <summary>What one file is: the digest of its bytes and how many of them there are.</summary>
/// <param name="Sha256">Lowercase hexadecimal SHA-256 of the raw bytes.</param>
/// <param name="ByteLength">Length of those bytes.</param>
public readonly record struct JazzArchiveFileFingerprint(string Sha256, long ByteLength);

/// <summary>
/// The v1 portable path rule, applied to container entry names and to staged snapshot paths alike.
/// </summary>
/// <remarks>
/// This is <see cref="JazzArchiveContainer.IsPortableEntryName"/> — the writer's rule — plus the two
/// ingest-side additions the writer gets for free by construction: a byte bound on the path, and the
/// refusal of the <c>sync/</c> subtree, which is working state a producer must never have exported.
/// </remarks>
public static class JazzArchivePortablePath
{
    /// <summary>Working-state subtree that is excluded from every export and every inventory.</summary>
    private const string ExcludedSubtreePrefix = "sync/";

    /// <summary>Throws unless <paramref name="path"/> is a portable, bounded, non-<c>sync/</c> path.</summary>
    /// <exception cref="JazzArchiveImportException">The path is outside the v1 portable subset.</exception>
    public static void Validate(string path, int maxBytes)
    {
        if (!JazzArchiveContainer.IsPortableEntryName(path))
        {
            throw JazzArchiveImportException.UnsafeEntry(path);
        }

        if (Encoding.UTF8.GetByteCount(path) > maxBytes)
        {
            throw JazzArchiveImportException.UnsafeEntry(
                string.Format(
                    CultureInfo.InvariantCulture,
                    "{0} exceeds {1} UTF-8 bytes",
                    path,
                    maxBytes));
        }

        if (path.StartsWith(ExcludedSubtreePrefix, StringComparison.Ordinal))
        {
            throw JazzArchiveImportException.UnsafeEntry(path);
        }
    }

    /// <summary>
    /// The key two names collide on. Case folding catches <c>Manifest.json</c> against
    /// <c>manifest.json</c>: on a case-insensitive volume the second extraction would overwrite the
    /// first, so the pair is refused before anything is written rather than after.
    /// </summary>
    public static string CollisionKey(string path) =>
        path.Normalize(NormalizationForm.FormC).ToLowerInvariant();
}
