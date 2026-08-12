using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using JazzCaptureCore.Journal;
using JazzCaptureCore.Json;

namespace JazzCaptureCore.Archive;

/// <summary>One verified capture inside a finalized snapshot.</summary>
/// <param name="CaptureId">Identity of the capture.</param>
/// <param name="SessionPath">Inventoried path of <c>session.json</c>.</param>
/// <param name="Session">The parsed session document.</param>
/// <param name="Commit">The parsed capture commit, whose JCS digest matched the manifest.</param>
/// <param name="Records">Observation envelopes, in stream order.</param>
/// <param name="Labels">Label documents; empty when the capture declared none.</param>
/// <param name="Artifacts">Artifact documents; empty when the capture attached none.</param>
/// <param name="Assertions">Review assertions; empty when the capture carries none.</param>
public sealed record JazzArchiveVerifiedCapture(
    string CaptureId,
    string SessionPath,
    JsonObject Session,
    JsonObject Commit,
    IReadOnlyList<JsonObject> Records,
    IReadOnlyList<JsonObject> Labels,
    IReadOnlyList<JsonObject> Artifacts,
    IReadOnlyList<JsonObject> Assertions);

/// <summary>
/// A directory that has passed every contract and digest check. Holding this value is the proof:
/// it is only ever produced by <see cref="JazzArchiveSnapshotVerifier.Verify"/>.
/// </summary>
/// <param name="DirectoryPath">Absolute path of the verified directory.</param>
/// <param name="ArchiveId">The manifest's archive identity.</param>
/// <param name="ContentDigest">The recomputed and matched <c>manifest.contentDigest</c>.</param>
/// <param name="Revision">The manifest revision every commit agreed with.</param>
/// <param name="Manifest">The parsed manifest.</param>
/// <param name="Inventory">The parsed inventory.</param>
/// <param name="Captures">One entry per session, in manifest order.</param>
/// <param name="FileFingerprints">Every regular file, keyed by its "/"-separated relative path.</param>
public sealed record JazzArchiveFinalizedSnapshot(
    string DirectoryPath,
    string ArchiveId,
    string ContentDigest,
    long Revision,
    JsonObject Manifest,
    JsonObject Inventory,
    IReadOnlyList<JazzArchiveVerifiedCapture> Captures,
    IReadOnlyDictionary<string, JazzArchiveFileFingerprint> FileFingerprints);

/// <summary>
/// Proves a staged or published archive directory is internally consistent: the shape the contract
/// requires, and every digest that closes over it.
/// </summary>
/// <remarks>
/// <para>
/// Four digests are checked, and they chain. Each inventory row must equal the bytes actually on
/// disk; <c>manifest.inventory.digest</c> must equal the JCS digest of the inventory document, which
/// binds every inventoried byte to the manifest; each capture commit's JCS digest must equal the
/// reference the manifest and the session both carry, and the commit's own closure hashes must
/// recompute from the records and artifacts; and <c>manifest.contentDigest</c> must equal the JCS
/// digest of the manifest without that key, which binds the whole chain to one value. Flipping any
/// byte anywhere breaks exactly one link, and the message names it.
/// </para>
/// <para>
/// The structural checks are the cross-document invariants a digest cannot express: coverage in both
/// directions between the inventory and the filesystem, a commit per session and no more, records
/// belonging to the capture that claims them, label boundaries landing on real observations, and
/// blobs stored under their own digest with nothing unreferenced left over. Per-document JSON Schema
/// validation is the contract validator's job, not this reader's; what is enforced here is every
/// invariant an importer must not take on trust.
/// </para>
/// </remarks>
public static class JazzArchiveSnapshotVerifier
{
    private const string ManifestFileName = "manifest.json";
    private const string InventoryFileName = "inventory.json";
    private const string RecordsFileName = "records.ndjson";
    private const string LabelsFileName = "labels.ndjson";
    private const string ArtifactsFileName = "artifacts.ndjson";
    private const string AssertionsFileName = "assertions.ndjson";
    private const string BlobPrefix = "blobs/";
    private const string ContentDigestKey = "contentDigest";
    private const string ArchiveFormat = "dev.jazz.archive";
    private const long ArchiveFormatVersion = 1;
    private const long DocumentSchemaVersion = 1;
    private const string FinalizedState = "finalized";
    private const string OpenSessionStatus = "open";
    private const int Sha256HexLength = 64;

    /// <summary>
    /// The payload contracts an importer will dispatch. A manifest naming anything else is refused:
    /// schema URIs are identifiers and are never fetched, so an unknown contract is unresolvable
    /// rather than merely unfamiliar.
    /// </summary>
    private static readonly (string RecordType, string SchemaId, long SchemaVersion)[] SupportedContracts =
    {
        ("jazz.activity-event", "https://jazz.dev/schema/activity-event.schema.json", 1),
        ("jazz.coach-interaction", "https://jazz.dev/schema/coach-interaction.schema.json", 1),
        ("jazz.media-observation", "https://jazz.dev/schema/media-observation.schema.json", 1),
        ("jazz.meeting-control-observation", "https://jazz.dev/schema/meeting-control-observation.schema.json", 1),
        ("jazz.capture-capability-observation", "https://jazz.dev/schema/capture-capability-observation.schema.json", 1),
    };

    /// <summary>Verifies the archive directory at <paramref name="directory"/>.</summary>
    /// <param name="directory">A staged or published finalized archive directory.</param>
    /// <param name="expectedArchiveId">
    /// When given, the manifest must carry this archive id; a mismatch is a conflict rather than a
    /// contract error, because it means the directory is not the archive it was filed under.
    /// </param>
    /// <param name="limits">The ingest envelope to enforce while reading.</param>
    /// <exception cref="JazzArchiveImportException">Any shape, coverage or digest check failed.</exception>
    public static JazzArchiveFinalizedSnapshot Verify(
        string directory,
        string? expectedArchiveId,
        JazzArchiveImportLimits limits)
    {
        ArgumentException.ThrowIfNullOrEmpty(directory);
        ArgumentNullException.ThrowIfNull(limits);
        limits.Validate();

        string root = Path.GetFullPath(directory);
        if (!Directory.Exists(root))
        {
            throw JazzArchiveImportException.InvalidArchive("finalized snapshot is not a directory");
        }

        IReadOnlyDictionary<string, JazzArchiveFileFingerprint> fingerprints = ScanFiles(root, limits);
        if (!fingerprints.ContainsKey(ManifestFileName) || !fingerprints.ContainsKey(InventoryFileName))
        {
            throw JazzArchiveImportException.InvalidArchive("manifest.json or inventory.json is missing");
        }

        JsonObject manifest = ReadJsonDocument(root, ManifestFileName, fingerprints, limits);
        string archiveId = VerifyManifestIdentity(manifest, expectedArchiveId);
        string contentDigest = VerifyContentDigest(manifest);
        long revision = RequireInteger(manifest, "revision", ManifestFileName);
        if (revision < 1)
        {
            throw JazzArchiveImportException.InvalidArchive("manifest revision must be at least 1");
        }

        JsonObject inventory = ReadJsonDocument(root, InventoryFileName, fingerprints, limits);
        VerifyInventory(manifest, inventory, fingerprints);
        VerifyContracts(manifest);

        IReadOnlyList<JazzArchiveVerifiedCapture> captures = VerifyCaptures(
            root,
            manifest,
            revision,
            fingerprints,
            limits);

        VerifyBlobCoverage(fingerprints, captures);
        VerifyEveryNdjsonWasParsed(fingerprints, captures);

        return new JazzArchiveFinalizedSnapshot(
            root,
            archiveId,
            contentDigest,
            revision,
            manifest,
            inventory,
            captures,
            fingerprints);
    }

    /// <summary>
    /// Fingerprints every regular file under <paramref name="root"/>, enforcing the path rules and
    /// the ingest envelope as it goes.
    /// </summary>
    private static IReadOnlyDictionary<string, JazzArchiveFileFingerprint> ScanFiles(
        string root,
        JazzArchiveImportLimits limits)
    {
        var fingerprints = new Dictionary<string, JazzArchiveFileFingerprint>(StringComparer.Ordinal);
        var collisionKeys = new HashSet<string>(StringComparer.Ordinal);
        long totalExpanded = 0;
        long totalStructured = 0;

        foreach (string path in Directory.EnumerateFileSystemEntries(root, "*", SearchOption.AllDirectories))
        {
            string relative = Path.GetRelativePath(root, path).Replace(Path.DirectorySeparatorChar, '/');
            var info = new FileInfo(path);

            // A reparse point is a symlink or a junction: it points at bytes outside the snapshot,
            // so it can never be inventoried honestly and is refused rather than followed.
            if (info.LinkTarget is not null || info.Attributes.HasFlag(FileAttributes.ReparsePoint))
            {
                throw JazzArchiveImportException.UnsafeEntry(relative);
            }

            if (Directory.Exists(path))
            {
                continue;
            }

            JazzArchivePortablePath.Validate(relative, limits.MaxPathBytes);
            if (!collisionKeys.Add(JazzArchivePortablePath.CollisionKey(relative)))
            {
                throw JazzArchiveImportException.DuplicateEntry(relative);
            }

            if (fingerprints.Count >= limits.MaxEntries)
            {
                throw JazzArchiveImportException.EntryLimitExceeded("entry count");
            }

            long byteLength = info.Length;
            if (byteLength > limits.MaxEntryBytes)
            {
                throw JazzArchiveImportException.EntryLimitExceeded(relative);
            }

            totalExpanded = BoundedAdd(totalExpanded, byteLength, limits.MaxTotalExpandedBytes, "total expanded bytes");
            if (relative.EndsWith(".json", StringComparison.Ordinal)
                || relative.EndsWith(".ndjson", StringComparison.Ordinal))
            {
                totalStructured = BoundedAdd(
                    totalStructured,
                    byteLength,
                    limits.MaxTotalStructuredBytes,
                    "total structured bytes");
            }

            fingerprints[relative] = new JazzArchiveFileFingerprint(
                JazzArchiveContainer.Sha256File(path),
                byteLength);
        }

        return fingerprints;
    }

    private static string VerifyManifestIdentity(JsonObject manifest, string? expectedArchiveId)
    {
        if (!string.Equals(Text(manifest, "format"), ArchiveFormat, StringComparison.Ordinal))
        {
            throw JazzArchiveImportException.InvalidArchive("manifest format");
        }

        if (RequireInteger(manifest, "formatVersion", ManifestFileName) != ArchiveFormatVersion)
        {
            throw JazzArchiveImportException.InvalidArchive("manifest formatVersion");
        }

        if (!string.Equals(Text(manifest, "state"), FinalizedState, StringComparison.Ordinal))
        {
            throw JazzArchiveImportException.InvalidArchive("manifest is not finalized");
        }

        string archiveId = RequireText(manifest, "archiveId", ManifestFileName);
        if (expectedArchiveId is not null && !string.Equals(archiveId, expectedArchiveId, StringComparison.Ordinal))
        {
            throw JazzArchiveImportException.ArchiveConflict(expectedArchiveId);
        }

        _ = RequireText(manifest, "originId", ManifestFileName);
        _ = RequireArray(manifest, "actors", ManifestFileName);
        _ = RequireArray(manifest, "sources", ManifestFileName);
        return archiveId;
    }

    /// <summary>
    /// Recomputes <c>contentDigest</c> over the manifest with that key removed. This is the value the
    /// whole package is identified by, so it is computed from the parsed document through the JCS
    /// canonicalizer rather than from the bytes on disk: a producer may indent however it likes.
    /// </summary>
    private static string VerifyContentDigest(JsonObject manifest)
    {
        string declared = RequireSha256(manifest, ContentDigestKey, ManifestFileName);
        var unsigned = (JsonObject)manifest.DeepClone();
        unsigned.Remove(ContentDigestKey);

        if (!string.Equals(JsonCanonicalizer.Sha256Hex(unsigned), declared, StringComparison.Ordinal))
        {
            throw JazzArchiveImportException.IntegrityMismatch("manifest.contentDigest");
        }

        return declared;
    }

    /// <summary>
    /// Checks the inventory against the manifest and against the filesystem in both directions: every
    /// row describes the bytes on disk, and every file on disk is either a root document or a row.
    /// </summary>
    private static void VerifyInventory(
        JsonObject manifest,
        JsonObject inventory,
        IReadOnlyDictionary<string, JazzArchiveFileFingerprint> fingerprints)
    {
        JsonObject reference = RequireObject(manifest, "inventory", ManifestFileName);
        if (!string.Equals(Text(reference, "path"), InventoryFileName, StringComparison.Ordinal)
            || !string.Equals(Text(reference, "algorithm"), "sha256", StringComparison.Ordinal))
        {
            throw JazzArchiveImportException.InvalidArchive("manifest inventory reference");
        }

        string declaredDigest = RequireSha256(reference, "digest", ManifestFileName);
        if (!string.Equals(Text(inventory, "algorithm"), "sha256", StringComparison.Ordinal))
        {
            throw JazzArchiveImportException.InvalidArchive("inventory algorithm");
        }

        if (!string.Equals(JsonCanonicalizer.Sha256Hex(inventory), declaredDigest, StringComparison.Ordinal))
        {
            throw JazzArchiveImportException.IntegrityMismatch("manifest.inventory.digest");
        }

        JsonArray entries = RequireArray(inventory, "entries", InventoryFileName);
        var expected = new HashSet<string>(StringComparer.Ordinal) { ManifestFileName, InventoryFileName };
        string? previous = null;

        foreach (JsonNode? node in entries)
        {
            JsonObject entry = AsObject(node, InventoryFileName);
            string path = RequireText(entry, "path", InventoryFileName);

            if (string.Equals(path, ManifestFileName, StringComparison.Ordinal)
                || string.Equals(path, InventoryFileName, StringComparison.Ordinal)
                || path.StartsWith("sync/", StringComparison.Ordinal))
            {
                throw JazzArchiveImportException.InvalidArchive("invalid inventory path " + path);
            }

            if (previous is not null && string.CompareOrdinal(previous, path) >= 0)
            {
                throw JazzArchiveImportException.InvalidArchive("inventory entries are not canonical");
            }

            previous = path;
            var declared = new JazzArchiveFileFingerprint(
                RequireSha256(entry, "sha256", InventoryFileName),
                RequireInteger(entry, "byteLength", InventoryFileName));

            if (!fingerprints.TryGetValue(path, out JazzArchiveFileFingerprint actual) || actual != declared)
            {
                throw JazzArchiveImportException.IntegrityMismatch(path);
            }

            expected.Add(path);
        }

        List<string> unlisted = fingerprints.Keys.Where(path => !expected.Contains(path)).ToList();
        unlisted.Sort(StringComparer.Ordinal);
        if (unlisted.Count > 0)
        {
            throw JazzArchiveImportException.InvalidArchive("inventory coverage: unlisted " + unlisted[0]);
        }
    }

    private static void VerifyContracts(JsonObject manifest)
    {
        JsonArray contracts = RequireArray(manifest, "contracts", ManifestFileName);
        if (contracts.Count == 0)
        {
            throw JazzArchiveImportException.InvalidArchive("manifest declares no payload contract");
        }

        foreach (JsonNode? node in contracts)
        {
            JsonObject contract = AsObject(node, ManifestFileName);
            string recordType = RequireText(contract, "recordType", ManifestFileName);
            string schemaId = RequireText(contract, "schemaId", ManifestFileName);
            long schemaVersion = RequireInteger(contract, "schemaVersion", ManifestFileName);

            if (!SupportedContracts.Any(supported =>
                string.Equals(supported.RecordType, recordType, StringComparison.Ordinal)
                && string.Equals(supported.SchemaId, schemaId, StringComparison.Ordinal)
                && supported.SchemaVersion == schemaVersion))
            {
                throw JazzArchiveImportException.InvalidArchive(
                    "unsupported payload contract " + recordType);
            }
        }
    }

    /// <summary>Verifies every session, its record stream, its attachments and its capture commit.</summary>
    private static IReadOnlyList<JazzArchiveVerifiedCapture> VerifyCaptures(
        string root,
        JsonObject manifest,
        long revision,
        IReadOnlyDictionary<string, JazzArchiveFileFingerprint> fingerprints,
        JazzArchiveImportLimits limits)
    {
        JsonArray sessionRefs = RequireArray(manifest, "sessions", ManifestFileName);
        JsonArray commitRefs = RequireArray(manifest, "captureCommits", ManifestFileName);
        if (sessionRefs.Count == 0 || sessionRefs.Count != commitRefs.Count)
        {
            throw JazzArchiveImportException.InvalidArchive("CaptureCommit coverage");
        }

        var commitsByCapture = new Dictionary<string, JsonObject>(StringComparer.Ordinal);
        foreach (JsonNode? node in commitRefs)
        {
            JsonObject reference = AsObject(node, ManifestFileName);
            string captureId = RequireText(reference, "captureId", ManifestFileName);
            if (!commitsByCapture.TryAdd(captureId, reference))
            {
                throw JazzArchiveImportException.InvalidArchive(
                    "capture " + captureId + " is committed more than once");
            }
        }

        var actorIds = IdentitySet(manifest, "actors", "actorId");
        var sourceIds = IdentitySet(manifest, "sources", "sourceId");
        var captures = new List<JazzArchiveVerifiedCapture>(sessionRefs.Count);
        var everyObservation = new HashSet<string>(StringComparer.Ordinal);
        var everyLabel = new HashSet<string>(StringComparer.Ordinal);
        var everyArtifact = new HashSet<string>(StringComparer.Ordinal);
        var budget = new NdjsonBudget(limits);

        foreach (JsonNode? node in sessionRefs)
        {
            JsonObject reference = AsObject(node, ManifestFileName);
            string captureId = RequireText(reference, "captureId", ManifestFileName);
            string sessionPath = RequireText(reference, "path", ManifestFileName);

            JsonObject session = ReadJsonDocument(root, sessionPath, fingerprints, limits);
            VerifySession(manifest, session, captureId, sessionPath, actorIds, sourceIds);

            string sessionDirectory = ParentPath(sessionPath);
            IReadOnlyList<JsonObject> records = ReadNdjson(
                root,
                Beside(sessionDirectory, RecordsFileName),
                fingerprints,
                budget,
                required: true);
            VerifyRecords(records, manifest, captureId, everyObservation, Beside(sessionDirectory, RecordsFileName));

            IReadOnlyList<JsonObject> labels = ReadNdjson(
                root,
                Beside(sessionDirectory, LabelsFileName),
                fingerprints,
                budget,
                required: false);
            IReadOnlyList<JsonObject> artifacts = ReadNdjson(
                root,
                Beside(sessionDirectory, ArtifactsFileName),
                fingerprints,
                budget,
                required: false);
            IReadOnlyList<JsonObject> assertions = ReadNdjson(
                root,
                Beside(sessionDirectory, AssertionsFileName),
                fingerprints,
                budget,
                required: false);

            VerifyLabels(labels, records, captureId, everyLabel);
            VerifyArtifacts(artifacts, fingerprints, captureId, everyArtifact);
            VerifyCrossReferences(records, labels, artifacts);

            JsonObject commit = VerifyCommit(
                root,
                commitsByCapture,
                session,
                captureId,
                revision,
                records,
                artifacts,
                fingerprints,
                limits);

            captures.Add(new JazzArchiveVerifiedCapture(
                captureId,
                sessionPath,
                session,
                commit,
                records,
                labels,
                artifacts,
                assertions));
        }

        foreach (string captureId in commitsByCapture.Keys)
        {
            if (!captures.Any(capture => string.Equals(capture.CaptureId, captureId, StringComparison.Ordinal)))
            {
                throw JazzArchiveImportException.InvalidArchive(
                    "CaptureCommit names capture " + captureId + ", which has no session");
            }
        }

        return captures;
    }

    /// <summary>
    /// Verifies one session against the manifest that lists it. The session's own
    /// <c>captureCommit</c> is checked against the manifest's in
    /// <see cref="VerifyCommit"/>, where the commit document itself is available.
    /// </summary>
    private static void VerifySession(
        JsonObject manifest,
        JsonObject session,
        string captureId,
        string sessionPath,
        IReadOnlySet<string> actorIds,
        IReadOnlySet<string> sourceIds)
    {
        if (RequireInteger(session, "schemaVersion", sessionPath) != DocumentSchemaVersion)
        {
            throw JazzArchiveImportException.InvalidArchive("session schemaVersion " + sessionPath);
        }

        if (!string.Equals(Text(session, "captureId"), captureId, StringComparison.Ordinal))
        {
            throw JazzArchiveImportException.InvalidArchive("session captureId " + sessionPath);
        }

        if (!string.Equals(Text(session, "archiveId"), Text(manifest, "archiveId"), StringComparison.Ordinal))
        {
            throw JazzArchiveImportException.InvalidArchive("session archiveId " + sessionPath);
        }

        if (string.Equals(Text(session, "status"), OpenSessionStatus, StringComparison.Ordinal))
        {
            throw JazzArchiveImportException.InvalidArchive("session " + captureId + " is still open");
        }

        _ = RequireText(session, "endedAt", sessionPath);
        string recorderActorId = RequireText(session, "recorderActorId", sessionPath);
        if (!actorIds.Contains(recorderActorId))
        {
            throw JazzArchiveImportException.InvalidArchive(
                "session recorder " + recorderActorId + " is not a manifest actor");
        }

        foreach (JsonNode? node in RequireArray(session, "sourceIds", sessionPath))
        {
            var sourceId = (string?)node;
            if (sourceId is null || !sourceIds.Contains(sourceId))
            {
                throw JazzArchiveImportException.InvalidArchive(
                    "session source " + (sourceId ?? "<null>") + " is not a manifest source");
            }
        }

        _ = RequireObject(session, "captureCommit", sessionPath);
    }

    private static void VerifyRecords(
        IReadOnlyList<JsonObject> records,
        JsonObject manifest,
        string captureId,
        HashSet<string> everyObservation,
        string path)
    {
        if (records.Count == 0)
        {
            throw JazzArchiveImportException.InvalidArchive("records.ndjson framing " + path);
        }

        var declaredContracts = RequireArray(manifest, "contracts", ManifestFileName)
            .Select(node => AsObject(node, ManifestFileName))
            .Select(contract => (
                RecordType: RequireText(contract, "recordType", ManifestFileName),
                SchemaId: RequireText(contract, "schemaId", ManifestFileName)))
            .ToList();

        var positions = new HashSet<string>(StringComparer.Ordinal);
        (string StreamId, long Sequence, string ObservationId)? previous = null;

        foreach (JsonObject record in records)
        {
            if (RequireInteger(record, "schemaVersion", path) != DocumentSchemaVersion)
            {
                throw JazzArchiveImportException.InvalidArchive("record schemaVersion " + path);
            }

            string observationId = RequireText(record, "observationId", path);
            string recordType = RequireText(record, "recordType", path);
            string payloadSchema = RequireText(record, "payloadSchema", path);
            string streamId = RequireText(record, "streamId", path);
            long sequence = RequireInteger(record, "streamSequence", path);

            if (sequence < 0)
            {
                throw JazzArchiveImportException.InvalidArchive("record streamSequence " + observationId);
            }

            if (!string.Equals(Text(record, "captureId"), captureId, StringComparison.Ordinal))
            {
                throw JazzArchiveImportException.InvalidArchive("cross-capture record " + observationId);
            }

            if (!declaredContracts.Any(contract =>
                string.Equals(contract.RecordType, recordType, StringComparison.Ordinal)
                && string.Equals(contract.SchemaId, payloadSchema, StringComparison.Ordinal)))
            {
                throw JazzArchiveImportException.InvalidArchive(
                    "record " + observationId + " uses undeclared contract " + recordType);
            }

            if (!everyObservation.Add(observationId))
            {
                throw JazzArchiveImportException.InvalidArchive("duplicate observation " + observationId);
            }

            string position = streamId + ":" + sequence.ToString(CultureInfo.InvariantCulture);
            if (!positions.Add(position))
            {
                throw JazzArchiveImportException.InvalidArchive("duplicate stream position " + position);
            }

            var current = (streamId, sequence, observationId);
            if (previous is { } earlier && Compare(earlier, current) >= 0)
            {
                throw JazzArchiveImportException.InvalidArchive("records.ndjson order " + path);
            }

            previous = current;
        }
    }

    private static void VerifyLabels(
        IReadOnlyList<JsonObject> labels,
        IReadOnlyList<JsonObject> records,
        string captureId,
        HashSet<string> everyLabel)
    {
        var sequenceByObservation = records.ToDictionary(
            record => (string)record["observationId"]!,
            record => (long)record["streamSequence"]!,
            StringComparer.Ordinal);

        foreach (JsonObject label in labels)
        {
            string labelId = RequireText(label, "labelId", LabelsFileName);
            if (!string.Equals(Text(label, "captureId"), captureId, StringComparison.Ordinal))
            {
                throw JazzArchiveImportException.InvalidArchive("cross-capture label " + labelId);
            }

            if (!everyLabel.Add(labelId))
            {
                throw JazzArchiveImportException.InvalidArchive("duplicate label " + labelId);
            }

            JsonObject interval = RequireObject(label, "interval", LabelsFileName);
            RequireBoundary(
                sequenceByObservation,
                labelId,
                RequireText(interval, "startObservationId", LabelsFileName),
                RequireInteger(interval, "startStreamSequence", LabelsFileName));

            if (interval["endObservationId"] is not null || interval["endStreamSequence"] is not null)
            {
                RequireBoundary(
                    sequenceByObservation,
                    labelId,
                    RequireText(interval, "endObservationId", LabelsFileName),
                    RequireInteger(interval, "endStreamSequence", LabelsFileName));
            }
        }
    }

    private static void RequireBoundary(
        IReadOnlyDictionary<string, long> sequenceByObservation,
        string labelId,
        string observationId,
        long sequence)
    {
        if (!sequenceByObservation.TryGetValue(observationId, out long actual) || actual != sequence)
        {
            throw JazzArchiveImportException.InvalidArchive("label boundary " + labelId);
        }
    }

    private static void VerifyArtifacts(
        IReadOnlyList<JsonObject> artifacts,
        IReadOnlyDictionary<string, JazzArchiveFileFingerprint> fingerprints,
        string captureId,
        HashSet<string> everyArtifact)
    {
        foreach (JsonObject artifact in artifacts)
        {
            string artifactId = RequireText(artifact, "artifactId", ArtifactsFileName);
            if (!string.Equals(Text(artifact, "captureId"), captureId, StringComparison.Ordinal))
            {
                throw JazzArchiveImportException.InvalidArchive("cross-capture artifact " + artifactId);
            }

            if (!everyArtifact.Add(artifactId))
            {
                throw JazzArchiveImportException.InvalidArchive("duplicate artifact " + artifactId);
            }

            JsonObject content = RequireObject(artifact, "content", ArtifactsFileName);
            string blobPath = RequireText(content, "path", ArtifactsFileName);
            var declared = new JazzArchiveFileFingerprint(
                RequireSha256(content, "sha256", ArtifactsFileName),
                RequireInteger(content, "byteLength", ArtifactsFileName));

            // Content addressing is the invariant: the file name is the digest, so a blob cannot be
            // swapped for other bytes without also moving, and moving breaks the inventory.
            if (!string.Equals(blobPath, ArtifactFingerprint.BlobPath(declared.Sha256), StringComparison.Ordinal))
            {
                throw JazzArchiveImportException.InvalidArchive(
                    "artifact " + artifactId + " is not stored at the path its digest requires");
            }

            if (!fingerprints.TryGetValue(blobPath, out JazzArchiveFileFingerprint actual) || actual != declared)
            {
                throw JazzArchiveImportException.IntegrityMismatch(blobPath);
            }
        }
    }

    private static void VerifyCrossReferences(
        IReadOnlyList<JsonObject> records,
        IReadOnlyList<JsonObject> labels,
        IReadOnlyList<JsonObject> artifacts)
    {
        var observationIds = new HashSet<string>(
            records.Select(record => (string)record["observationId"]!),
            StringComparer.Ordinal);
        var labelIds = new HashSet<string>(
            labels.Select(label => (string)label["labelId"]!),
            StringComparer.Ordinal);
        var artifactIds = new HashSet<string>(
            artifacts.Select(artifact => (string)artifact["artifactId"]!),
            StringComparer.Ordinal);

        foreach (JsonObject record in records)
        {
            foreach (JsonNode? node in record["labelRefs"] as JsonArray ?? new JsonArray())
            {
                RequireKnown((string?)node, labelIds, "record references unknown label ");
            }

            foreach (JsonNode? node in record["artifactRefs"] as JsonArray ?? new JsonArray())
            {
                RequireKnown((string?)(node as JsonObject)?["artifactId"], artifactIds, "record references unknown artifact ");
            }
        }

        foreach (JsonObject artifact in artifacts)
        {
            foreach (JsonNode? node in artifact["observationRefs"] as JsonArray ?? new JsonArray())
            {
                RequireKnown((string?)node, observationIds, "artifact references unknown observation ");
            }

            foreach (JsonNode? node in artifact["labelRefs"] as JsonArray ?? new JsonArray())
            {
                RequireKnown((string?)node, labelIds, "artifact references unknown label ");
            }
        }

        foreach (JsonObject label in labels)
        {
            foreach (JsonNode? node in label["narrationArtifactRefs"] as JsonArray ?? new JsonArray())
            {
                RequireKnown((string?)node, artifactIds, "label references unknown artifact ");
            }
        }
    }

    private static void RequireKnown(string? id, IReadOnlySet<string> known, string message)
    {
        if (id is not null && !known.Contains(id))
        {
            throw JazzArchiveImportException.InvalidArchive(message + id);
        }
    }

    /// <summary>
    /// Verifies the capture commit: its JCS digest against the reference both the manifest and the
    /// session carry, its identity fields, and its two closure hashes recomputed from the evidence.
    /// </summary>
    private static JsonObject VerifyCommit(
        string root,
        IReadOnlyDictionary<string, JsonObject> commitsByCapture,
        JsonObject session,
        string captureId,
        long revision,
        IReadOnlyList<JsonObject> records,
        IReadOnlyList<JsonObject> artifacts,
        IReadOnlyDictionary<string, JazzArchiveFileFingerprint> fingerprints,
        JazzArchiveImportLimits limits)
    {
        if (!commitsByCapture.TryGetValue(captureId, out JsonObject? reference))
        {
            throw JazzArchiveImportException.InvalidArchive("missing CaptureCommit for " + captureId);
        }

        string commitPath = RequireText(reference, "path", ManifestFileName);
        string commitId = RequireText(reference, "commitId", ManifestFileName);
        string declaredDigest = RequireSha256(reference, "digest", ManifestFileName);

        JsonObject sessionRef = RequireObject(session, "captureCommit", commitPath);
        if (!string.Equals(
                JsonCanonicalizer.Canonicalize(sessionRef),
                JsonCanonicalizer.Canonicalize(reference),
                StringComparison.Ordinal))
        {
            throw JazzArchiveImportException.InvalidArchive(
                "session and manifest disagree about the CaptureCommit of " + captureId);
        }

        JsonObject commit = ReadJsonDocument(root, commitPath, fingerprints, limits);
        if (!string.Equals(JsonCanonicalizer.Sha256Hex(commit), declaredDigest, StringComparison.Ordinal))
        {
            throw JazzArchiveImportException.IntegrityMismatch(commitPath);
        }

        if (!string.Equals(Text(commit, "commitId"), commitId, StringComparison.Ordinal)
            || !string.Equals(Text(commit, "captureId"), captureId, StringComparison.Ordinal)
            || RequireInteger(commit, "revision", commitPath) != revision
            || !string.Equals(Text(commit, "endedAt"), Text(session, "endedAt"), StringComparison.Ordinal))
        {
            throw JazzArchiveImportException.InvalidArchive("CaptureCommit " + commitId);
        }

        if (!string.Equals(
                Text(commit, "orderedObservationDigest"),
                ArchiveDigests.OrderedObservationDigest(records),
                StringComparison.Ordinal))
        {
            throw JazzArchiveImportException.IntegrityMismatch(
                "CaptureCommit orderedObservationDigest " + commitId);
        }

        if (RequireInteger(commit, "artifactCount", commitPath) != artifacts.Count
            || !string.Equals(
                Text(commit, "artifactSetDigest"),
                ArchiveDigests.ArtifactSetDigest(artifacts),
                StringComparison.Ordinal))
        {
            throw JazzArchiveImportException.IntegrityMismatch(
                "CaptureCommit artifactSetDigest " + commitId);
        }

        VerifyStreamSummaries(commit, commitPath, records, commitId);
        return commit;
    }

    /// <summary>
    /// Recomputes each stream's first, last and observation count, and proves the observations and
    /// the declared gaps partition that range exactly — a missing sequence that no gap claims is
    /// evidence silently dropped, which is what the gap list exists to make impossible.
    /// </summary>
    private static void VerifyStreamSummaries(
        JsonObject commit,
        string commitPath,
        IReadOnlyList<JsonObject> records,
        string commitId)
    {
        var first = new Dictionary<string, long>(StringComparer.Ordinal);
        var last = new Dictionary<string, long>(StringComparer.Ordinal);
        var counts = new Dictionary<string, long>(StringComparer.Ordinal);
        var covered = new Dictionary<string, long>(StringComparer.Ordinal);

        foreach (JsonObject record in records)
        {
            var streamId = (string)record["streamId"]!;
            var sequence = (long)record["streamSequence"]!;
            first[streamId] = first.TryGetValue(streamId, out long lo) ? Math.Min(lo, sequence) : sequence;
            last[streamId] = last.TryGetValue(streamId, out long hi) ? Math.Max(hi, sequence) : sequence;
            counts[streamId] = counts.GetValueOrDefault(streamId) + 1;
            covered[streamId] = covered.GetValueOrDefault(streamId) + 1;
        }

        foreach (JsonNode? node in RequireArray(commit, "gaps", commitPath))
        {
            JsonObject gap = AsObject(node, commitPath);
            string streamId = RequireText(gap, "streamId", commitPath);
            long gapFirst = RequireInteger(gap, "firstSequence", commitPath);
            long gapLast = RequireInteger(gap, "lastSequence", commitPath);
            _ = RequireText(gap, "reason", commitPath);

            if (gapFirst < 0 || gapLast < gapFirst)
            {
                throw JazzArchiveImportException.InvalidArchive("CaptureCommit gap range " + commitId);
            }

            first[streamId] = first.TryGetValue(streamId, out long lo) ? Math.Min(lo, gapFirst) : gapFirst;
            last[streamId] = last.TryGetValue(streamId, out long hi) ? Math.Max(hi, gapLast) : gapLast;
            covered[streamId] = covered.GetValueOrDefault(streamId) + (gapLast - gapFirst + 1);
        }

        var declared = new Dictionary<string, (long First, long Last, long Count)>(StringComparer.Ordinal);
        foreach (JsonNode? node in RequireArray(commit, "streamSummaries", commitPath))
        {
            JsonObject summary = AsObject(node, commitPath);
            string streamId = RequireText(summary, "streamId", commitPath);
            if (!declared.TryAdd(
                    streamId,
                    (RequireInteger(summary, "firstSequence", commitPath),
                     RequireInteger(summary, "lastSequence", commitPath),
                     RequireInteger(summary, "observationCount", commitPath))))
            {
                throw JazzArchiveImportException.InvalidArchive(
                    "CaptureCommit summarizes stream " + streamId + " twice");
            }
        }

        if (declared.Count != first.Count)
        {
            throw JazzArchiveImportException.IntegrityMismatch("CaptureCommit closure " + commitId);
        }

        foreach ((string streamId, long lo) in first)
        {
            long hi = last[streamId];
            long count = counts.GetValueOrDefault(streamId);

            if (!declared.TryGetValue(streamId, out (long First, long Last, long Count) summary)
                || summary.First != lo
                || summary.Last != hi
                || summary.Count != count)
            {
                throw JazzArchiveImportException.IntegrityMismatch("CaptureCommit closure " + commitId);
            }

            if (covered.GetValueOrDefault(streamId) != hi - lo + 1)
            {
                throw JazzArchiveImportException.IntegrityMismatch(
                    "CaptureCommit does not partition stream " + streamId);
            }
        }
    }

    private static void VerifyBlobCoverage(
        IReadOnlyDictionary<string, JazzArchiveFileFingerprint> fingerprints,
        IReadOnlyList<JazzArchiveVerifiedCapture> captures)
    {
        var referenced = new HashSet<string>(StringComparer.Ordinal);
        foreach (JazzArchiveVerifiedCapture capture in captures)
        {
            foreach (JsonObject artifact in capture.Artifacts)
            {
                referenced.Add((string)artifact["content"]!["path"]!);
            }
        }

        foreach (string path in fingerprints.Keys)
        {
            if (path.StartsWith(BlobPrefix, StringComparison.Ordinal) && !referenced.Contains(path))
            {
                throw JazzArchiveImportException.InvalidArchive("unreferenced blob " + path);
            }
        }
    }

    /// <summary>
    /// Refuses an NDJSON file nobody parsed. Every structured byte in the package must have been
    /// read by a rule above; an unknown stream is evidence the importer would silently ignore.
    /// </summary>
    private static void VerifyEveryNdjsonWasParsed(
        IReadOnlyDictionary<string, JazzArchiveFileFingerprint> fingerprints,
        IReadOnlyList<JazzArchiveVerifiedCapture> captures)
    {
        var parsed = new HashSet<string>(StringComparer.Ordinal);
        foreach (JazzArchiveVerifiedCapture capture in captures)
        {
            string directory = ParentPath(capture.SessionPath);
            foreach (string name in new[] { RecordsFileName, LabelsFileName, ArtifactsFileName, AssertionsFileName })
            {
                parsed.Add(Beside(directory, name));
            }
        }

        foreach (string path in fingerprints.Keys)
        {
            if (path.EndsWith(".ndjson", StringComparison.Ordinal) && !parsed.Contains(path))
            {
                throw JazzArchiveImportException.InvalidArchive("unknown NDJSON entry " + path);
            }
        }
    }

    private static IReadOnlySet<string> IdentitySet(JsonObject manifest, string arrayKey, string idKey)
    {
        var identities = new HashSet<string>(StringComparer.Ordinal);
        foreach (JsonNode? node in RequireArray(manifest, arrayKey, ManifestFileName))
        {
            identities.Add(RequireText(AsObject(node, ManifestFileName), idKey, ManifestFileName));
        }

        return identities;
    }

    private static JsonObject ReadJsonDocument(
        string root,
        string path,
        IReadOnlyDictionary<string, JazzArchiveFileFingerprint> fingerprints,
        JazzArchiveImportLimits limits)
    {
        if (!fingerprints.TryGetValue(path, out JazzArchiveFileFingerprint fingerprint))
        {
            throw JazzArchiveImportException.InvalidArchive("missing " + path);
        }

        if (fingerprint.ByteLength > limits.MaxJsonEntryBytes)
        {
            throw JazzArchiveImportException.EntryLimitExceeded(path);
        }

        string text = ReadUtf8(root, path);
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

    /// <summary>
    /// Reads one NDJSON file under the shared record and line budgets. An absent optional file is an
    /// empty list, which is how the format says "none of these".
    /// </summary>
    /// <remarks>
    /// The framing is enforced on bytes rather than through a text reader: exactly one line feed ends
    /// every line including the last, an empty line is an error, and a carriage return is a byte
    /// inside a line rather than a second kind of terminator. A reader that silently accepted CRLF
    /// would parse a file whose bytes — and therefore whose inventory digest — differ from the one
    /// the producer meant to write.
    /// </remarks>
    private static IReadOnlyList<JsonObject> ReadNdjson(
        string root,
        string path,
        IReadOnlyDictionary<string, JazzArchiveFileFingerprint> fingerprints,
        NdjsonBudget budget,
        bool required)
    {
        if (!fingerprints.ContainsKey(path))
        {
            if (required)
            {
                throw JazzArchiveImportException.InvalidArchive("missing " + path);
            }

            return Array.Empty<JsonObject>();
        }

        const byte LineFeed = 0x0A;
        var values = new List<JsonObject>();
        var pending = new List<byte>();

        using FileStream stream = new(
            Path.Combine(root, path.Replace('/', Path.DirectorySeparatorChar)),
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read);

        byte[] buffer = new byte[64 * 1024];
        int read;
        while ((read = stream.Read(buffer, 0, buffer.Length)) > 0)
        {
            for (int index = 0; index < read; index++)
            {
                if (buffer[index] != LineFeed)
                {
                    pending.Add(buffer[index]);
                    if (pending.Count > budget.MaxLineBytes)
                    {
                        throw JazzArchiveImportException.EntryLimitExceeded("NDJSON line " + path);
                    }

                    continue;
                }

                if (pending.Count == 0)
                {
                    throw JazzArchiveImportException.InvalidArchive("NDJSON framing " + path);
                }

                budget.AdmitRecord(pending.Count, path);
                values.Add(ParseNdjsonLine(pending, path));
                pending.Clear();
            }
        }

        if (pending.Count > 0)
        {
            throw JazzArchiveImportException.InvalidArchive("NDJSON framing " + path);
        }

        return values;
    }

    private static JsonObject ParseNdjsonLine(List<byte> line, string path)
    {
        string text;
        try
        {
            text = new UTF8Encoding(false, throwOnInvalidBytes: true).GetString(line.ToArray());
        }
        catch (DecoderFallbackException)
        {
            throw JazzArchiveImportException.InvalidArchive(path + " holds a line that is not valid UTF-8");
        }

        try
        {
            return JsonStrictParser.Parse(text) as JsonObject
                ?? throw JazzArchiveImportException.InvalidArchive(path + " holds a non-object line");
        }
        catch (FormatException error)
        {
            throw JazzArchiveImportException.InvalidArchive(path + ": " + error.Message);
        }
    }

    private static string ReadUtf8(string root, string path)
    {
        byte[] bytes = File.ReadAllBytes(Path.Combine(root, path.Replace('/', Path.DirectorySeparatorChar)));
        try
        {
            return new UTF8Encoding(false, throwOnInvalidBytes: true).GetString(bytes);
        }
        catch (DecoderFallbackException)
        {
            throw JazzArchiveImportException.InvalidArchive(path + " is not valid UTF-8");
        }
    }

    private static int Compare(
        (string StreamId, long Sequence, string ObservationId) left,
        (string StreamId, long Sequence, string ObservationId) right)
    {
        int byStream = string.CompareOrdinal(left.StreamId, right.StreamId);
        if (byStream != 0)
        {
            return byStream;
        }

        int bySequence = left.Sequence.CompareTo(right.Sequence);
        return bySequence != 0 ? bySequence : string.CompareOrdinal(left.ObservationId, right.ObservationId);
    }

    private static string ParentPath(string path)
    {
        int separator = path.LastIndexOf('/');
        return separator < 0 ? string.Empty : path[..separator];
    }

    private static string Beside(string directory, string name) =>
        directory.Length == 0 ? name : directory + "/" + name;

    private static long BoundedAdd(long left, long right, long limit, string subject)
    {
        long value = left + right;
        if (value < left || value > limit)
        {
            throw JazzArchiveImportException.EntryLimitExceeded(subject);
        }

        return value;
    }

    private static string? Text(JsonObject value, string key) =>
        value[key] is JsonValue node && node.TryGetValue(out string? text) ? text : null;

    private static string RequireText(JsonObject value, string key, string path) =>
        Text(value, key) is { Length: > 0 } text
            ? text
            : throw JazzArchiveImportException.InvalidArchive(path + " is missing string '" + key + "'");

    private static string RequireSha256(JsonObject value, string key, string path)
    {
        string digest = RequireText(value, key, path);
        if (digest.Length != Sha256HexLength || !digest.All(c => c is (>= '0' and <= '9') or (>= 'a' and <= 'f')))
        {
            throw JazzArchiveImportException.InvalidArchive(path + " has a malformed '" + key + "'");
        }

        return digest;
    }

    private static long RequireInteger(JsonObject value, string key, string path) =>
        value[key] is JsonValue node && node.TryGetValue(out long number)
            ? number
            : throw JazzArchiveImportException.InvalidArchive(path + " is missing integer '" + key + "'");

    private static JsonObject RequireObject(JsonObject value, string key, string path) =>
        value[key] as JsonObject
        ?? throw JazzArchiveImportException.InvalidArchive(path + " is missing object '" + key + "'");

    private static JsonArray RequireArray(JsonObject value, string key, string path) =>
        value[key] as JsonArray
        ?? throw JazzArchiveImportException.InvalidArchive(path + " is missing array '" + key + "'");

    private static JsonObject AsObject(JsonNode? node, string path) =>
        node as JsonObject
        ?? throw JazzArchiveImportException.InvalidArchive(path + " holds a non-object array element");

    /// <summary>
    /// The NDJSON line and record budgets, shared across every stream in one package so that a
    /// thousand small files cannot together exceed what one large file is forbidden to reach.
    /// </summary>
    private sealed class NdjsonBudget(JazzArchiveImportLimits limits)
    {
        private int _records;

        /// <summary>Largest accepted line, in UTF-8 bytes.</summary>
        public int MaxLineBytes => limits.MaxNdjsonLineBytes;

        /// <summary>Charges one complete line to the shared line and record budgets.</summary>
        public void AdmitRecord(int lineBytes, string path)
        {
            if (lineBytes > limits.MaxNdjsonLineBytes)
            {
                throw JazzArchiveImportException.EntryLimitExceeded("NDJSON line " + path);
            }

            _records++;
            if (_records > limits.MaxNdjsonRecords)
            {
                throw JazzArchiveImportException.EntryLimitExceeded("NDJSON record count");
            }
        }
    }
}
