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

    /// <summary>Name of the artifact file inside a session directory; absent when nothing was attached.</summary>
    public const string ArtifactsFileName = "artifacts.ndjson";

    /// <summary>Name of the review overlay inside a session directory; absent when nobody reviewed.</summary>
    public const string AssertionsFileName = "assertions.ndjson";

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
    /// Bracketed labels declared during the capture. The segments and the records are checked
    /// against each other in both directions before anything is written — each interval endpoint
    /// must name a record of this capture, and each <c>labelRefs</c> entry on a record must name a
    /// segment declared here. An empty set produces no <c>labels.ndjson</c> at all.
    /// </param>
    /// <param name="artifacts">
    /// Artifacts the journal committed, each paired with the draft blob holding its bytes. Checked
    /// against the records in both directions like the labels are, and against the bytes themselves.
    /// An empty set produces no <c>artifacts.ndjson</c> and no <c>blobs/</c> at all.
    /// </param>
    /// <param name="assertions">
    /// The review overlay: the reviewer's decisions about this archive, in the order they were made.
    /// Every target, author and supersedes link is resolved against this archive before anything is
    /// written. An empty set produces no <c>assertions.ndjson</c> at all, so an archive nobody
    /// reviewed stays byte-identical to one written before the overlay existed.
    /// </param>
    /// <returns>Absolute path of the written archive directory.</returns>
    /// <exception cref="IOException">The archive directory already exists.</exception>
    /// <exception cref="ArgumentException">
    /// The capture retains no observation, a record or gap belongs to another stream, a label
    /// interval does not resolve against the records, a record carries a <c>labelRefs</c> or
    /// <c>artifactRefs</c> entry naming something this capture did not declare, an artifact does
    /// not describe the bytes behind it, or an assertion names something this archive does not
    /// contain.
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
        IReadOnlyList<LabelSegment>? labels = null,
        IReadOnlyList<CommittedArtifact>? artifacts = null,
        IReadOnlyList<JsonObject>? assertions = null)
    {
        ArgumentException.ThrowIfNullOrEmpty(outputDir);
        ArgumentNullException.ThrowIfNull(ids);
        ArgumentNullException.ThrowIfNull(meta);
        ArgumentNullException.ThrowIfNull(records);
        ArgumentNullException.ThrowIfNull(gaps);
        ArgumentNullException.ThrowIfNull(capabilityObservations);

        List<JsonObject> allRecords = Materialize(ids, meta, records, gaps, capabilityObservations, observationIds);
        IReadOnlyList<JsonObject> labelDocuments = LabelDocuments(ids, allRecords, labels);
        IReadOnlyList<CommittedArtifact> artifactDocuments = ArtifactDocuments(ids, allRecords, labelDocuments, artifacts);
        IReadOnlyList<JsonObject> assertionDocuments = AssertionDocuments(
            ids,
            allRecords,
            labelDocuments,
            artifactDocuments,
            assertions);
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

        // 1c. Artifacts and their bytes, on the same terms: no attachment, no file and no blob
        // directory, so an archive that carries none is byte-identical to one written before the
        // pipeline existed. The blobs land under the very path their documents already name, which
        // is what makes the copy a copy rather than a rewrite — and puts them in the inventory, and
        // therefore in the content digest, without any special case below.
        if (artifactDocuments.Count > 0)
        {
            foreach (CommittedArtifact artifact in artifactDocuments)
            {
                string blob = Path.Combine(
                    archiveDir,
                    ContentPath(artifact.Document).Replace('/', Path.DirectorySeparatorChar));

                // Two artifacts can legitimately hold the same bytes — an unchanged screen shot
                // twice — and content addressing means they share one file. Each has already been
                // checked against those bytes above, so the second copy is a no-op rather than a
                // collision.
                if (File.Exists(blob))
                {
                    continue;
                }

                Directory.CreateDirectory(Path.GetDirectoryName(blob)!);
                File.Copy(artifact.SourcePath, blob);
            }

            WriteNdjson(
                Path.Combine(sessionDir, ArtifactsFileName),
                artifactDocuments.Select(artifact => artifact.Document).ToArray());
        }

        // 1d. The review overlay last of the four, because it is the only document that may name any
        // of the other three. It is written on the same terms: no decision, no file, so an archive
        // nobody reviewed is byte-identical to one written before review existed. The overlay is
        // deliberately outside the commit's closure digests — the commit proves what was observed,
        // and a human decision taken afterwards must not be able to change that proof — but it is an
        // ordinary canonical file, so the inventory and the content digest cover it like the rest.
        if (assertionDocuments.Count > 0)
        {
            WriteNdjson(Path.Combine(sessionDir, AssertionsFileName), assertionDocuments);
        }

        // 2. The commit closes the record set and the artifact set together.
        JsonObject commit = ArchiveDocuments.Commit(
            ids,
            ArchiveDocuments.InitialRevision,
            meta.EndedAt,
            Summaries(ids, allRecords, gaps),
            ArchiveDigests.OrderedObservationDigest(allRecords),
            artifactDocuments.Count,
            ArchiveDigests.ArtifactSetDigest(artifactDocuments.Select(artifact => artifact.Document).ToArray()),
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
    /// Writes the finalized archive straight from a journal commit. The session end, the status and
    /// the artifact set are taken from the commit, so the documents can never disagree with it.
    /// </summary>
    public static string WriteFinalized(
        string outputDir,
        ArchiveIdentity ids,
        SessionMetadata meta,
        CommitResult commit,
        IReadOnlyList<CapabilityObservation> capabilityObservations,
        Func<string>? observationIds = null,
        IReadOnlyList<LabelSegment>? labels = null,
        IReadOnlyList<JsonObject>? assertions = null)
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
            labels,
            commit.Artifacts,
            assertions);
    }

    /// <summary>
    /// Turns the declared segments into label documents, in stream order, after proving that the
    /// declarations and the records agree in both directions: every interval endpoint is a real
    /// observation of this capture at exactly the sequence claimed, and every label a record claims
    /// membership of was actually declared.
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
        var declared = new HashSet<string>(StringComparer.Ordinal);
        var documents = new List<JsonObject>(labels?.Count ?? 0);

        if (labels is { Count: > 0 })
        {
            var sequenceByObservation = new Dictionary<string, long>(records.Count, StringComparer.Ordinal);
            foreach (JsonObject record in records)
            {
                sequenceByObservation[(string)record["observationId"]!] = (long)record["streamSequence"]!;
            }

            List<LabelSegment> ordered = labels
                .OrderBy(segment => segment.StartStreamSequence)
                .ThenBy(segment => segment.LabelId, StringComparer.Ordinal)
                .ToList();

            foreach (LabelSegment segment in ordered)
            {
                if (!declared.Add(segment.LabelId))
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
        }

        RequireDeclaredLabelRefs(records, declared);
        return documents;
    }

    /// <summary>
    /// Orders the committed artifacts by identity and proves, before anything is written, that each
    /// one is what it says it is: it belongs to this capture, its bytes are on disk under their own
    /// digest, and every reference it makes — and every reference a record makes to it — resolves
    /// inside this capture.
    /// </summary>
    /// <remarks>
    /// The same reasoning as the label check applies, only harder: an artifact is the one archive
    /// document whose truth lives outside the JSON. A blob that is absent, truncated, or no longer
    /// hashes to its own name turns the whole archive into a claim nobody can verify, and the
    /// producer that lost the bytes is the only party that can still say why. Sorting by identity is
    /// not cosmetic either — it is the order the commit's <c>artifactSetDigest</c> hashes.
    /// </remarks>
    private static IReadOnlyList<CommittedArtifact> ArtifactDocuments(
        ArchiveIdentity ids,
        IReadOnlyList<JsonObject> records,
        IReadOnlyList<JsonObject> labels,
        IReadOnlyList<CommittedArtifact>? artifacts)
    {
        var declared = new HashSet<string>(StringComparer.Ordinal);
        var ordered = new List<CommittedArtifact>(artifacts?.Count ?? 0);

        if (artifacts is { Count: > 0 })
        {
            var observationIds = new HashSet<string>(
                records.Select(record => (string)record["observationId"]!),
                StringComparer.Ordinal);
            var labelIds = new HashSet<string>(
                labels.Select(label => (string)label["labelId"]!),
                StringComparer.Ordinal);

            ordered.AddRange(artifacts.OrderBy(
                artifact => (string?)artifact.Document["artifactId"],
                StringComparer.Ordinal));

            foreach (CommittedArtifact artifact in ordered)
            {
                JsonObject document = artifact.Document;
                var artifactId = (string?)document["artifactId"]
                    ?? throw new ArgumentException("an artifact has no identity", nameof(artifacts));

                if (!declared.Add(artifactId))
                {
                    throw new ArgumentException(
                        $"artifact '{artifactId}' is declared twice",
                        nameof(artifacts));
                }

                if (!string.Equals((string?)document["captureId"], ids.CaptureId, StringComparison.Ordinal))
                {
                    throw new ArgumentException(
                        $"artifact '{artifactId}' belongs to capture '{(string?)document["captureId"]}', not '{ids.CaptureId}'",
                        nameof(artifacts));
                }

                RequireContentAddressedBytes(artifactId, document, artifact.SourcePath);

                foreach (JsonNode? node in document["observationRefs"] as JsonArray ?? new JsonArray())
                {
                    var observationId = (string?)node;
                    if (observationId is not null && !observationIds.Contains(observationId))
                    {
                        throw new ArgumentException(
                            $"artifact '{artifactId}' references observation '{observationId}', which this capture did not retain",
                            nameof(artifacts));
                    }
                }

                foreach (JsonNode? node in document["labelRefs"] as JsonArray ?? new JsonArray())
                {
                    var labelId = (string?)node;
                    if (labelId is not null && !labelIds.Contains(labelId))
                    {
                        throw new ArgumentException(
                            $"artifact '{artifactId}' references label '{labelId}', which this capture did not declare",
                            nameof(artifacts));
                    }
                }
            }
        }

        RequireDeclaredArtifactRefs(records, declared);
        RequireDeclaredNarrationRefs(labels, declared);
        return ordered;
    }

    /// <summary>
    /// Proves every review decision is about something this archive actually contains, and returns
    /// the overlay in the order the reviewer made it.
    /// </summary>
    /// <remarks>
    /// <para>
    /// An assertion is the one document whose whole content is a reference: strip the target and the
    /// author and nothing is left but an opinion about nothing. The contract validator resolves each
    /// of them — target, author, superseded link, provenance sources — and so does this, for the same
    /// reason the label and artifact checks exist: the producer is the last party who can still say
    /// why a reference went missing, and an archive whose review overlay dangles is one a reader
    /// cannot use to tell a confirmed capture from an unreviewed one.
    /// </para>
    /// <para>
    /// The author must be the recorder rather than merely a known actor, because the manifest of an
    /// MVP archive declares exactly one: an assertion naming anybody else is claiming a reviewer this
    /// archive never had. Order is the reviewer's own — the chain is resolved structurally through
    /// <c>supersedes</c>, so the file reads in the order decisions were taken rather than being
    /// re-sorted into an order nobody experienced.
    /// </para>
    /// </remarks>
    private static IReadOnlyList<JsonObject> AssertionDocuments(
        ArchiveIdentity ids,
        IReadOnlyList<JsonObject> records,
        IReadOnlyList<JsonObject> labels,
        IReadOnlyList<CommittedArtifact> artifacts,
        IReadOnlyList<JsonObject>? assertions)
    {
        if (assertions is not { Count: > 0 })
        {
            return Array.Empty<JsonObject>();
        }

        var declared = new HashSet<string>(StringComparer.Ordinal);
        var documents = new List<JsonObject>(assertions.Count);
        foreach (JsonObject assertion in assertions)
        {
            var assertionId = (string?)assertion["assertionId"]
                ?? throw new ArgumentException("an assertion has no identity", nameof(assertions));

            if (!declared.Add(assertionId))
            {
                throw new ArgumentException(
                    $"assertion '{assertionId}' is declared twice",
                    nameof(assertions));
            }

            documents.Add((JsonObject)assertion.DeepClone());
        }

        var targets = new Dictionary<string, IReadOnlySet<string>>(StringComparer.Ordinal)
        {
            [ArchiveDocuments.ArchiveTargetKind] = new HashSet<string>(new[] { ids.ArchiveId }, StringComparer.Ordinal),
            ["capture"] = new HashSet<string>(new[] { ids.CaptureId }, StringComparer.Ordinal),
            ["label"] = new HashSet<string>(
                labels.Select(label => (string)label["labelId"]!),
                StringComparer.Ordinal),
            ["observation"] = new HashSet<string>(
                records.Select(record => (string)record["observationId"]!),
                StringComparer.Ordinal),
            ["artifact"] = new HashSet<string>(
                artifacts.Select(artifact => (string)artifact.Document["artifactId"]!),
                StringComparer.Ordinal),
            ["assertion"] = declared,
        };

        foreach (JsonObject assertion in documents)
        {
            var assertionId = (string)assertion["assertionId"]!;
            JsonObject target = assertion["target"] as JsonObject
                ?? throw new ArgumentException(
                    $"assertion '{assertionId}' is about nothing",
                    nameof(assertions));
            var kind = (string?)target["kind"];
            var id = (string?)target["id"];

            if (kind is null
                || id is null
                || !targets.TryGetValue(kind, out IReadOnlySet<string>? known)
                || !known.Contains(id))
            {
                throw new ArgumentException(
                    $"assertion '{assertionId}' targets {kind} '{id}', which this archive does not contain",
                    nameof(assertions));
            }

            var author = (string?)assertion["authoredByActorId"];
            if (!string.Equals(author, ids.ActorId, StringComparison.Ordinal))
            {
                throw new ArgumentException(
                    $"assertion '{assertionId}' is authored by '{author}', who is not this archive's recorder",
                    nameof(assertions));
            }

            if ((string?)assertion["supersedes"] is { } supersedes && !declared.Contains(supersedes))
            {
                throw new ArgumentException(
                    $"assertion '{assertionId}' supersedes '{supersedes}', which this archive does not contain",
                    nameof(assertions));
            }

            foreach (JsonNode? node in assertion["provenance"]?["sources"] as JsonArray ?? new JsonArray())
            {
                var sourceId = (string?)node;
                if (sourceId is not null && !string.Equals(sourceId, ids.SourceId, StringComparison.Ordinal))
                {
                    throw new ArgumentException(
                        $"assertion '{assertionId}' cites source '{sourceId}', which this archive does not declare",
                        nameof(assertions));
                }
            }
        }

        return documents;
    }

    /// <summary>
    /// Rejects a label that cites a narration clip this capture never committed.
    /// </summary>
    /// <remarks>
    /// The label/artifact reference is written in both directions, and the two have to agree: the
    /// artifact loop above proves every <c>labelRefs</c> entry names a declared segment, and this
    /// proves every <c>narrationArtifactRefs</c> entry names a committed artifact. Only checking one
    /// would let a capture publish a segment pointing at audio that was never ingested — the
    /// contract validator rejects that as "label references unknown narration artifact", long after
    /// the producer that lost the bytes could say why.
    /// </remarks>
    private static void RequireDeclaredNarrationRefs(
        IReadOnlyList<JsonObject> labels,
        IReadOnlySet<string> declared)
    {
        foreach (JsonObject label in labels)
        {
            foreach (JsonNode? node in label["narrationArtifactRefs"] as JsonArray ?? new JsonArray())
            {
                var artifactId = (string?)node;
                if (artifactId is not null && !declared.Contains(artifactId))
                {
                    throw new ArgumentException(
                        $"label '{(string?)label["labelId"]}' references narration artifact '{artifactId}', which this capture did not commit",
                        "artifacts");
                }
            }
        }
    }

    /// <summary>
    /// Proves the bytes behind one artifact are the bytes it describes, and that they are stored
    /// under their own digest as ANNEX-ARCHIVE section 2.2 requires.
    /// </summary>
    private static void RequireContentAddressedBytes(string artifactId, JsonObject document, string sourcePath)
    {
        JsonObject content = document["content"] as JsonObject
            ?? throw new ArgumentException($"artifact '{artifactId}' has no content block", nameof(document));
        var digest = (string?)content["sha256"];
        var byteLength = (long?)content["byteLength"];

        if (digest is null || byteLength is null)
        {
            throw new ArgumentException($"artifact '{artifactId}' has an incomplete content block", nameof(document));
        }

        if (!string.Equals(ContentPath(document), ArtifactFingerprint.BlobPath(digest), StringComparison.Ordinal))
        {
            throw new ArgumentException(
                $"artifact '{artifactId}' is not stored at the path its digest requires",
                nameof(document));
        }

        if (!File.Exists(sourcePath))
        {
            throw new ArgumentException(
                $"artifact '{artifactId}' has no bytes at '{sourcePath}'",
                nameof(document));
        }

        if (new FileInfo(sourcePath).Length != byteLength
            || !string.Equals(JazzArchiveContainer.Sha256File(sourcePath), digest, StringComparison.Ordinal))
        {
            throw new ArgumentException(
                $"artifact '{artifactId}' does not describe the bytes at '{sourcePath}'",
                nameof(document));
        }
    }

    /// <summary>
    /// Rejects a record that cites an artifact this capture never committed — the converse of the
    /// check above, for the same reason the label pair exists: a dangling <c>artifactRefs</c> entry
    /// is caught here rather than by the validator long after the bytes went missing.
    /// </summary>
    private static void RequireDeclaredArtifactRefs(
        IReadOnlyList<JsonObject> records,
        IReadOnlySet<string> declared)
    {
        foreach (JsonObject record in records)
        {
            if (record["artifactRefs"] is not JsonArray artifactRefs)
            {
                continue;
            }

            foreach (JsonNode? node in artifactRefs)
            {
                var artifactId = (string?)(node as JsonObject)?["artifactId"];
                if (artifactId is not null && !declared.Contains(artifactId))
                {
                    throw new ArgumentException(
                        $"observation '{(string?)record["observationId"]}' references artifact '{artifactId}', which this capture did not commit",
                        "artifacts");
                }
            }
        }
    }

    private static string ContentPath(JsonObject artifact) =>
        (string?)artifact["content"]?["path"]
        ?? throw new ArgumentException("an artifact has no content path", nameof(artifact));

    /// <summary>
    /// Rejects a record that claims membership of a label this capture never declared.
    /// </summary>
    /// <remarks>
    /// The boundary check above proves each declaration lands on a real record; it proves nothing
    /// about a record pointing the other way. No live caller can produce that today — the engine
    /// hands its records and its segments over together — but a crash-recovery finalization replaying
    /// journal records without the in-memory labels would, and the archive it wrote would be rejected
    /// by the contract validator as "observation references unknown label" some time later, by which
    /// point the producer that lost the segment is long gone. Failing at write time keeps the
    /// diagnosis next to its cause, and keeps a broken archive from being published at all.
    /// </remarks>
    private static void RequireDeclaredLabelRefs(
        IReadOnlyList<JsonObject> records,
        IReadOnlySet<string> declared)
    {
        foreach (JsonObject record in records)
        {
            if (record["labelRefs"] is not JsonArray labelRefs)
            {
                continue;
            }

            foreach (JsonNode? node in labelRefs)
            {
                var labelId = (string?)node;
                if (labelId is not null && !declared.Contains(labelId))
                {
                    throw new ArgumentException(
                        $"observation '{(string?)record["observationId"]}' references label '{labelId}', which this capture did not declare",
                        "labels");
                }
            }
        }
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
