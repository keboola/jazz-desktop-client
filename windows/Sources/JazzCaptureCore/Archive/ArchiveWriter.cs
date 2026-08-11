using System.Globalization;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization.Metadata;
using JazzCaptureCore.Journal;
using JazzCaptureCore.Json;

namespace JazzCaptureCore.Archive;

/// <summary>
/// Writes a finalized Jazz archive directory: the five canonical documents, their digests, and the
/// inventory that closes over them.
/// </summary>
/// <remarks>
/// <para>
/// The build order of ANNEX-ARCHIVE section 3.7 is the only order that converges, because each
/// document commits the previous one: records fix the commit, the commit digest is embedded in both
/// the session and the manifest, the files on disk fix the inventory, the inventory digest goes into
/// the manifest, and the manifest without <c>contentDigest</c> fixes <c>contentDigest</c>.
/// </para>
/// <para>
/// Nothing here is time- or environment-dependent: given the same identifiers, metadata and records,
/// the produced bytes — and therefore every digest — are identical on every run and every platform.
/// </para>
/// </remarks>
public static class ArchiveWriter
{
    /// <summary>Directory suffix of a finalized archive.</summary>
    public const string FinalizedSuffix = ".jazz-archive.finalized";

    /// <summary>Name of the record stream file inside a session directory.</summary>
    public const string RecordsFileName = "records.ndjson";

    /// <summary>Name of the label file inside a session directory; absent when nothing was labelled.</summary>
    public const string LabelsFileName = "labels.ndjson";

    private const string SessionsDirectoryName = "sessions";
    private const string SessionFileName = "session.json";
    private const string CommitFileName = "commit.json";
    private const string ManifestFileName = "manifest.json";
    private const string InventoryFileName = "inventory.json";
    private const string SyncDirectoryName = "sync";
    private const string ContentDigestKey = "contentDigest";

    private static readonly UTF8Encoding Utf8 = new(encoderShouldEmitUTF8Identifier: false);

    // A JsonNode tree may hold values that only a type resolver can serialize, so the resolver is
    // set explicitly rather than relying on the reflection default being registered.
    private static readonly JsonSerializerOptions Compact = new()
    {
        WriteIndented = false,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        TypeInfoResolver = new DefaultJsonTypeInfoResolver(),
    };

    private static readonly JsonSerializerOptions Indented = new()
    {
        WriteIndented = true,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        TypeInfoResolver = new DefaultJsonTypeInfoResolver(),
    };

    /// <summary>
    /// Writes the finalized archive for one capture and returns the archive directory path.
    /// </summary>
    /// <param name="outputDir">Directory that will contain the archive directory.</param>
    /// <param name="ids">Identifiers minted for this archive.</param>
    /// <param name="meta">Frozen capture policy and producer facts.</param>
    /// <param name="records">
    /// Observation envelopes as committed by the journal, on <see cref="ArchiveIdentity.StreamId"/>.
    /// </param>
    /// <param name="gaps">Committed gaps; each covered sequence carries no observation.</param>
    /// <param name="capabilityObservations">
    /// Capability evidence that did not pass through the journal. Each becomes one additional
    /// record appended to the stream after the last committed sequence.
    /// </param>
    /// <param name="sessionStatus">
    /// <see cref="JournalSessionStatus.Closed"/> or <see cref="JournalSessionStatus.Recovered"/>.
    /// </param>
    /// <param name="observationIds">
    /// Identity source for the appended capability records; defaults to freshly minted
    /// <c>obs-</c> identifiers. Tests inject a deterministic factory to compare two runs byte for
    /// byte.
    /// </param>
    /// <param name="labels">
    /// Bracketed labels declared during the capture. Each interval endpoint must name a record of
    /// this capture, so the segments are checked against <paramref name="records"/> before anything
    /// is written; an empty set produces no <c>labels.ndjson</c> at all.
    /// </param>
    /// <returns>Absolute path of the written archive directory.</returns>
    /// <exception cref="IOException">The archive directory already exists.</exception>
    /// <exception cref="ArgumentException">
    /// The capture retains no observation, a record or gap belongs to another stream, or a label
    /// interval does not resolve against the records.
    /// </exception>
    public static string WriteFinalized(
        string outputDir,
        ArchiveIdentity ids,
        SessionMetadata meta,
        IReadOnlyList<JsonObject> records,
        IReadOnlyList<GapEntry> gaps,
        IReadOnlyList<CapabilityObservation> capabilityObservations,
        string sessionStatus = JournalSessionStatus.Closed,
        Func<string>? observationIds = null,
        IReadOnlyList<LabelSegment>? labels = null)
    {
        ArgumentException.ThrowIfNullOrEmpty(outputDir);
        ArgumentNullException.ThrowIfNull(ids);
        ArgumentNullException.ThrowIfNull(meta);
        ArgumentNullException.ThrowIfNull(records);
        ArgumentNullException.ThrowIfNull(gaps);
        ArgumentNullException.ThrowIfNull(capabilityObservations);

        List<JsonObject> allRecords = Materialize(ids, meta, records, gaps, capabilityObservations, observationIds);
        IReadOnlyList<JsonObject> labelDocuments = LabelDocuments(ids, allRecords, labels);
        string archiveDir = Path.GetFullPath(Path.Combine(outputDir, ids.ArchiveId + FinalizedSuffix));
        if (Directory.Exists(archiveDir))
        {
            throw new IOException("archive directory already exists: " + archiveDir);
        }

        string sessionRelativeDir = SessionsDirectoryName + "/" + ids.SessionId;
        string sessionDir = Path.Combine(archiveDir, SessionsDirectoryName, ids.SessionId);
        Directory.CreateDirectory(sessionDir);

        // 1. Records first: everything downstream is a digest of what they contain.
        WriteNdjson(Path.Combine(sessionDir, RecordsFileName), allRecords);

        // 1b. Labels are a reduction over those records, so they follow them and precede the
        // inventory that hashes both. A capture nobody labelled writes no file rather than an empty
        // one: an absent document is how the format says "no segments", and it keeps the inventory
        // — and therefore the content digest — identical to an unlabelled capture's.
        if (labelDocuments.Count > 0)
        {
            WriteNdjson(Path.Combine(sessionDir, LabelsFileName), labelDocuments);
        }

        // 2. The commit closes the record set.
        JsonObject commit = ArchiveDocuments.Commit(
            ids,
            ArchiveDocuments.InitialRevision,
            meta.EndedAt,
            Summaries(ids, allRecords, gaps),
            ArchiveDigests.OrderedObservationDigest(allRecords),
            artifactCount: 0,
            ArchiveDigests.ArtifactSetDigest(Array.Empty<JsonObject>()),
            gaps);
        WriteDocument(Path.Combine(sessionDir, CommitFileName), commit);

        // 3. The same commit reference is embedded in the session and later in the manifest.
        JsonObject commitRef = ArchiveDocuments.CaptureCommitRef(
            ids,
            sessionRelativeDir + "/" + CommitFileName,
            JsonCanonicalizer.Sha256Hex(commit));
        WriteDocument(
            Path.Combine(sessionDir, SessionFileName),
            ArchiveDocuments.Session(ids, meta, sessionStatus, commitRef));

        // 4. The inventory hashes the raw bytes of every canonical file as they were just written.
        JsonObject inventory = ArchiveDocuments.Inventory(CanonicalFiles(archiveDir));
        WriteDocument(Path.Combine(archiveDir, InventoryFileName), inventory);

        // 5/6. The manifest commits the inventory, and contentDigest commits the manifest.
        JsonObject manifest = ArchiveDocuments.Manifest(
            ids,
            meta,
            allRecords.Select(record => (string)record["recordType"]!).ToArray(),
            sessionRelativeDir + "/" + SessionFileName,
            commitRef,
            JsonCanonicalizer.Sha256Hex(inventory));
        manifest[ContentDigestKey] = JsonCanonicalizer.Sha256Hex(manifest);
        WriteDocument(Path.Combine(archiveDir, ManifestFileName), manifest);

        return archiveDir;
    }

    /// <summary>
    /// Writes the finalized archive straight from a journal commit. The session end and status are
    /// taken from the commit, so the two documents can never disagree.
    /// </summary>
    public static string WriteFinalized(
        string outputDir,
        ArchiveIdentity ids,
        SessionMetadata meta,
        CommitResult commit,
        IReadOnlyList<CapabilityObservation> capabilityObservations,
        Func<string>? observationIds = null,
        IReadOnlyList<LabelSegment>? labels = null)
    {
        ArgumentNullException.ThrowIfNull(meta);
        ArgumentNullException.ThrowIfNull(commit);

        return WriteFinalized(
            outputDir,
            ids,
            meta with { EndedAt = commit.EndedAt },
            commit.Records,
            commit.Gaps,
            capabilityObservations,
            commit.Status,
            observationIds,
            labels);
    }

    /// <summary>
    /// Turns the declared segments into label documents, in stream order, after proving that every
    /// interval endpoint is a real observation of this capture at exactly the sequence claimed.
    /// </summary>
    /// <remarks>
    /// The check runs here rather than being left to the validator because a label whose boundary
    /// does not resolve is not a formatting slip: it means the producer lost the correspondence
    /// between a declaration and the stream it brackets, and writing that archive out would publish
    /// evidence nobody can segment. Ordering by start position keeps the file byte-stable and makes
    /// it read in the order the user declared things.
    /// </remarks>
    private static IReadOnlyList<JsonObject> LabelDocuments(
        ArchiveIdentity ids,
        IReadOnlyList<JsonObject> records,
        IReadOnlyList<LabelSegment>? labels)
    {
        if (labels is null || labels.Count == 0)
        {
            return Array.Empty<JsonObject>();
        }

        var sequenceByObservation = new Dictionary<string, long>(records.Count, StringComparer.Ordinal);
        foreach (JsonObject record in records)
        {
            sequenceByObservation[(string)record["observationId"]!] = (long)record["streamSequence"]!;
        }

        List<LabelSegment> ordered = labels
            .OrderBy(segment => segment.StartStreamSequence)
            .ThenBy(segment => segment.LabelId, StringComparer.Ordinal)
            .ToList();

        var seen = new HashSet<string>(StringComparer.Ordinal);
        var documents = new List<JsonObject>(ordered.Count);
        foreach (LabelSegment segment in ordered)
        {
            if (!seen.Add(segment.LabelId))
            {
                throw new ArgumentException(
                    $"label '{segment.LabelId}' is declared twice",
                    nameof(labels));
            }

            RequireBoundary(sequenceByObservation, segment.LabelId, segment.StartObservationId, segment.StartStreamSequence);
            if (segment is
                {
                    EndObservationId: { } endObservationId,
                    EndStreamSequence: { } endStreamSequence,
                })
            {
                RequireBoundary(sequenceByObservation, segment.LabelId, endObservationId, endStreamSequence);
                if (endStreamSequence < segment.StartStreamSequence)
                {
                    throw new ArgumentException(
                        $"label '{segment.LabelId}' ends at {endStreamSequence} before it starts at {segment.StartStreamSequence}",
                        nameof(labels));
                }
            }

            documents.Add(ArchiveDocuments.Label(ids, segment));
        }

        return documents;
    }

    private static void RequireBoundary(
        IReadOnlyDictionary<string, long> sequenceByObservation,
        string labelId,
        string observationId,
        long streamSequence)
    {
        if (!sequenceByObservation.TryGetValue(observationId, out long actual))
        {
            throw new ArgumentException(
                $"label '{labelId}' names observation '{observationId}', which this capture did not retain",
                "labels");
        }

        if (actual != streamSequence)
        {
            throw new ArgumentException(
                $"label '{labelId}' claims observation '{observationId}' sits at {streamSequence}, but it sits at {actual}",
                "labels");
        }
    }

    /// <summary>
    /// Clones the committed records, appends one record per capability observation after the last
    /// committed sequence, and returns everything sorted by stream and sequence.
    /// </summary>
    private static List<JsonObject> Materialize(
        ArchiveIdentity ids,
        SessionMetadata meta,
        IReadOnlyList<JsonObject> records,
        IReadOnlyList<GapEntry> gaps,
        IReadOnlyList<CapabilityObservation> capabilityObservations,
        Func<string>? observationIds)
    {
        var all = new List<JsonObject>(records.Count + capabilityObservations.Count);
        long next = 0;
        foreach (JsonObject record in records)
        {
            var streamId = (string?)record["streamId"];
            if (!string.Equals(streamId, ids.StreamId, StringComparison.Ordinal))
            {
                throw new ArgumentException(
                    $"record stream '{streamId}' is not the capture's stream '{ids.StreamId}'",
                    nameof(records));
            }

            var sequence = (long)record["streamSequence"]!;
            next = Math.Max(next, sequence + 1);
            all.Add((JsonObject)record.DeepClone());
        }

        foreach (GapEntry gap in gaps)
        {
            if (!string.Equals(gap.StreamId, ids.StreamId, StringComparison.Ordinal))
            {
                throw new ArgumentException(
                    $"gap stream '{gap.StreamId}' is not the capture's stream '{ids.StreamId}'",
                    nameof(gaps));
            }

            next = Math.Max(next, gap.LastSequence + 1);
        }

        Func<string> mint = observationIds ?? (() => Identifiers.Prefixed("obs"));
        foreach (CapabilityObservation observation in capabilityObservations)
        {
            all.Add(ArchiveDocuments.CapabilityRecord(ids, mint(), next++, observation, meta.PolicyVersion));
        }

        if (all.Count == 0)
        {
            throw new ArgumentException(
                "a capture must retain at least one observation",
                nameof(records));
        }

        all.Sort(static (left, right) =>
        {
            int byStream = string.CompareOrdinal((string?)left["streamId"], (string?)right["streamId"]);
            return byStream != 0
                ? byStream
                : ((long)left["streamSequence"]!).CompareTo((long)right["streamSequence"]!);
        });

        return all;
    }

    /// <summary>
    /// Derives the per-stream summaries. Observations and gaps must partition the committed range
    /// exactly, so the range is simply the extent of both and the count is the number of records.
    /// </summary>
    private static IReadOnlyList<StreamSummary> Summaries(
        ArchiveIdentity ids,
        IReadOnlyList<JsonObject> records,
        IReadOnlyList<GapEntry> gaps)
    {
        long first = long.MaxValue;
        long last = long.MinValue;
        var count = 0;

        foreach (JsonObject record in records)
        {
            var sequence = (long)record["streamSequence"]!;
            first = Math.Min(first, sequence);
            last = Math.Max(last, sequence);
            count++;
        }

        foreach (GapEntry gap in gaps)
        {
            first = Math.Min(first, gap.FirstSequence);
            last = Math.Max(last, gap.LastSequence);
        }

        var covered = count;
        foreach (GapEntry gap in gaps)
        {
            covered += (int)(gap.LastSequence - gap.FirstSequence + 1);
        }

        if (covered != last - first + 1)
        {
            throw new ArgumentException(
                string.Format(
                    CultureInfo.InvariantCulture,
                    "observations and gaps do not partition [{0}, {1}] of stream {2}",
                    first,
                    last,
                    ids.StreamId),
                nameof(gaps));
        }

        return new[] { new StreamSummary(ids.StreamId, first, last, count) };
    }

    /// <summary>
    /// Every file that belongs in the inventory: all regular files except the manifest, the
    /// inventory itself, and the never-exported <c>sync/</c> working state, ordered by path.
    /// </summary>
    private static IReadOnlyList<InventoryEntry> CanonicalFiles(string archiveDir)
    {
        var entries = new List<InventoryEntry>();
        foreach (string file in Directory.EnumerateFiles(archiveDir, "*", SearchOption.AllDirectories))
        {
            string relative = Path
                .GetRelativePath(archiveDir, file)
                .Replace(Path.DirectorySeparatorChar, '/');

            if (string.Equals(relative, ManifestFileName, StringComparison.Ordinal)
                || string.Equals(relative, InventoryFileName, StringComparison.Ordinal)
                || relative.StartsWith(SyncDirectoryName + "/", StringComparison.Ordinal))
            {
                continue;
            }

            entries.Add(new InventoryEntry(
                relative,
                new FileInfo(file).Length,
                JazzArchiveContainer.Sha256File(file)));
        }

        entries.Sort(static (left, right) => string.CompareOrdinal(left.Path, right.Path));
        return entries;
    }

    /// <summary>Writes one NDJSON file: compact objects, line feeds only, UTF-8 without BOM.</summary>
    private static void WriteNdjson(string path, IReadOnlyList<JsonObject> values)
    {
        var text = new StringBuilder();
        foreach (JsonObject value in values)
        {
            text.Append(value.ToJsonString(Compact)).Append('\n');
        }

        File.WriteAllBytes(path, Utf8.GetBytes(text.ToString()));
    }

    /// <summary>
    /// Writes one indented JSON document. The line endings are normalized because the inventory
    /// hashes these bytes and a producer on Windows must agree with a producer on macOS.
    /// </summary>
    private static void WriteDocument(string path, JsonObject value)
    {
        string text = value.ToJsonString(Indented).Replace("\r\n", "\n", StringComparison.Ordinal) + "\n";
        File.WriteAllBytes(path, Utf8.GetBytes(text));
    }
}
