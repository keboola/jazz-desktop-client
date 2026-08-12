using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using JazzCaptureCore;
using JazzCaptureCore.Archive;
using JazzCaptureCore.Journal;
using JazzCaptureCore.Json;
using JazzCaptureCoreTests.Support;

namespace JazzCaptureCoreTests;

/// <summary>
/// Exercises the finalized-archive writer. The last test is the outer gate: the produced directory
/// is handed to <c>contract/archive/validate_archives.py</c>, which is the normative authority on
/// schemas, references, inventory closure, and commit digests.
/// </summary>
public sealed class ArchiveWriterTests : IDisposable
{
    private const string StartedAt = "2026-07-22T08:00:00Z";
    private const string EndedAt = "2026-07-22T08:01:00Z";
    private const string ConsentedAt = "2026-07-22T07:59:59Z";
    private const string PolicyVersion = "consent-v1";
    private const string FirstArtifactId = "art-00000000-0000-7000-8000-00000000f000";
    private const string SecondArtifactId = "art-00000000-0000-7000-8000-00000000f001";

    /// <summary>
    /// A neutral artifact kind. The two kinds that exist are <c>screenshot</c> and
    /// <c>narration_audio</c>; the first drags in a mandatory evidence profile, and this pipeline is
    /// deliberately proven without it.
    /// </summary>
    private const string ArtifactKind = "attachment";

    private static readonly byte[] Payload = { 0x6a, 0x61, 0x7a, 0x7a };

    private readonly string _root = Path.Combine(
        Path.GetTempPath(),
        "jazz-archive-writer-" + Guid.NewGuid().ToString("n"));

    public void Dispose()
    {
        if (Directory.Exists(_root))
        {
            Directory.Delete(_root, recursive: true);
        }
    }

    [Fact]
    public void WriteFinalizedProducesTheFiveCanonicalDocuments()
    {
        ArchiveIdentity ids = ArchiveIdentity.Mint();
        string archiveDir = Write(ids, DeterministicObservationIds());

        Assert.True(File.Exists(Path.Combine(archiveDir, "manifest.json")));
        Assert.True(File.Exists(Path.Combine(archiveDir, "inventory.json")));
        string sessionDir = Path.Combine(archiveDir, "sessions", ids.SessionId);
        Assert.True(File.Exists(Path.Combine(sessionDir, "session.json")));
        Assert.True(File.Exists(Path.Combine(sessionDir, "commit.json")));
        Assert.True(File.Exists(Path.Combine(sessionDir, "records.ndjson")));
    }

    [Fact]
    public void RecordsNdjsonIsLineFeedTerminatedWithoutByteOrderMark()
    {
        ArchiveIdentity ids = ArchiveIdentity.Mint();
        string archiveDir = Write(ids, DeterministicObservationIds());
        byte[] bytes = File.ReadAllBytes(
            Path.Combine(archiveDir, "sessions", ids.SessionId, "records.ndjson"));

        Assert.NotEqual(0xEF, bytes[0]);
        Assert.Equal((byte)'\n', bytes[^1]);
        Assert.DoesNotContain((byte)'\r', bytes);
    }

    [Fact]
    public void RecordsAreSortedByStreamThenSequenceAndCapabilitiesFollowTheJournal()
    {
        ArchiveIdentity ids = ArchiveIdentity.Mint();
        string archiveDir = Write(ids, DeterministicObservationIds());

        IReadOnlyList<JsonObject> written = ReadRecords(
            Path.Combine(archiveDir, "sessions", ids.SessionId, "records.ndjson"));

        Assert.Equal(3, written.Count);
        Assert.Equal(new long[] { 0, 1, 2 }, written.Select(Sequence).ToArray());
        Assert.Equal(ArchiveContracts.ActivityEventRecordType, (string?)written[0]["recordType"]);
        Assert.Equal(ArchiveContracts.ActivityEventRecordType, (string?)written[1]["recordType"]);
        Assert.Equal(
            CapabilityObservation.RecordType,
            (string?)written[2]["recordType"]);
    }

    [Fact]
    public void ManifestBindsTheCommitInventoryAndContentDigests()
    {
        ArchiveIdentity ids = ArchiveIdentity.Mint();
        string archiveDir = Write(ids, DeterministicObservationIds());

        JsonObject manifest = ReadDocument(Path.Combine(archiveDir, "manifest.json"));
        JsonObject inventory = ReadDocument(Path.Combine(archiveDir, "inventory.json"));
        JsonObject session = ReadDocument(
            Path.Combine(archiveDir, "sessions", ids.SessionId, "session.json"));
        JsonObject commit = ReadDocument(
            Path.Combine(archiveDir, "sessions", ids.SessionId, "commit.json"));

        Assert.Equal(
            JsonCanonicalizer.Sha256Hex(inventory),
            (string?)manifest["inventory"]!["digest"]);

        var commitRef = Assert.IsType<JsonObject>(
            Assert.IsType<JsonArray>(manifest["captureCommits"])[0]);
        Assert.Equal(JsonCanonicalizer.Sha256Hex(commit), (string?)commitRef["digest"]);
        Assert.True(JsonDeepComparer.DeepEquals(commitRef, session["captureCommit"]));

        var withoutContentDigest = (JsonObject)manifest.DeepClone();
        withoutContentDigest.Remove("contentDigest");
        Assert.Equal(
            JsonCanonicalizer.Sha256Hex(withoutContentDigest),
            (string?)manifest["contentDigest"]);
        Assert.Equal("contentDigest", manifest.Last().Key);
    }

    [Fact]
    public void ManifestDeclaresOnlyTheContractsActuallyPresent()
    {
        ArchiveIdentity ids = ArchiveIdentity.Mint();
        string archiveDir = Write(ids, DeterministicObservationIds(), withCapabilities: false);

        JsonObject manifest = ReadDocument(Path.Combine(archiveDir, "manifest.json"));
        var contracts = Assert.IsType<JsonArray>(manifest["contracts"]);

        JsonObject only = Assert.IsType<JsonObject>(Assert.Single(contracts));
        Assert.Equal(ArchiveContracts.ActivityEventRecordType, (string?)only["recordType"]);
        Assert.Equal(1L, (long?)only["schemaVersion"]);
    }

    [Fact]
    public void InventoryCoversEveryFileExceptTheManifestAndItself()
    {
        ArchiveIdentity ids = ArchiveIdentity.Mint();
        string archiveDir = Write(ids, DeterministicObservationIds());

        JsonObject inventory = ReadDocument(Path.Combine(archiveDir, "inventory.json"));
        string[] paths = Assert.IsType<JsonArray>(inventory["entries"])
            .Select(entry => (string)((JsonObject)entry!)["path"]!)
            .ToArray();

        Assert.Equal(
            new[]
            {
                "sessions/" + ids.SessionId + "/commit.json",
                "sessions/" + ids.SessionId + "/records.ndjson",
                "sessions/" + ids.SessionId + "/session.json",
            },
            paths);

        foreach (JsonNode? entry in Assert.IsType<JsonArray>(inventory["entries"]))
        {
            var value = Assert.IsType<JsonObject>(entry);
            string file = Path.Combine(archiveDir, ((string)value["path"]!).Replace('/', Path.DirectorySeparatorChar));
            Assert.Equal(new FileInfo(file).Length, (long?)value["byteLength"]);
            Assert.Equal(JazzArchiveContainer.Sha256File(file), (string?)value["sha256"]);
        }
    }

    [Fact]
    public void GapsReachTheCommitDocument()
    {
        ArchiveIdentity ids = ArchiveIdentity.Mint();
        var gaps = new[]
        {
            new GapEntry(ids.StreamId, 1, 1, GapReasons.RecoveryTruncation, "producer terminated"),
        };
        string archiveDir = ArchiveWriter.WriteFinalized(
            _root,
            ids,
            Metadata(),
            new[] { ActivityRecord(ids, "00000000d000", 0, StartedAt, 0),
                ActivityRecord(ids, "00000000d002", 2, EndedAt, 2), },
            gaps,
            Array.Empty<CapabilityObservation>(),
            JournalSessionStatus.Recovered,
            DeterministicObservationIds());

        JsonObject commit = ReadDocument(
            Path.Combine(archiveDir, "sessions", ids.SessionId, "commit.json"));
        JsonObject session = ReadDocument(
            Path.Combine(archiveDir, "sessions", ids.SessionId, "session.json"));

        var gap = Assert.IsType<JsonObject>(Assert.Single(Assert.IsType<JsonArray>(commit["gaps"])));
        Assert.Equal(GapReasons.RecoveryTruncation, (string?)gap["reason"]);
        Assert.Equal("producer terminated", (string?)gap["detail"]);

        var summary = Assert.IsType<JsonObject>(
            Assert.Single(Assert.IsType<JsonArray>(commit["streamSummaries"])));
        Assert.Equal(0L, (long?)summary["firstSequence"]);
        Assert.Equal(2L, (long?)summary["lastSequence"]);
        Assert.Equal(2L, (long?)summary["observationCount"]);
        Assert.Equal(JournalSessionStatus.Recovered, (string?)session["status"]);
    }

    [Fact]
    public void WritingTwiceProducesTheSameContentDigest()
    {
        ArchiveIdentity ids = ArchiveIdentity.Mint();
        string first = Write(ids, DeterministicObservationIds(), subdirectory: "first");
        string second = Write(ids, DeterministicObservationIds(), subdirectory: "second");

        JsonObject firstManifest = ReadDocument(Path.Combine(first, "manifest.json"));
        JsonObject secondManifest = ReadDocument(Path.Combine(second, "manifest.json"));

        Assert.Equal(
            (string?)firstManifest["contentDigest"],
            (string?)secondManifest["contentDigest"]);
        Assert.Equal(
            (string?)firstManifest["inventory"]!["digest"],
            (string?)secondManifest["inventory"]!["digest"]);
        Assert.Equal(
            JazzArchiveContainer.Sha256File(Path.Combine(first, "manifest.json")),
            JazzArchiveContainer.Sha256File(Path.Combine(second, "manifest.json")));
    }

    [Fact]
    public void WritingIntoAnExistingArchiveDirectoryIsRefused()
    {
        ArchiveIdentity ids = ArchiveIdentity.Mint();
        Write(ids, DeterministicObservationIds());

        Assert.Throws<IOException>(() => Write(ids, DeterministicObservationIds()));
    }

    [Fact]
    public void LabelsAreWrittenInStreamOrderRegardlessOfHowTheyArrive()
    {
        ArchiveIdentity ids = ArchiveIdentity.Mint();
        string archiveDir = Write(
            ids,
            DeterministicObservationIds(),
            labels: new[] { Label("b001", 1, 1), Label("b000", 0, 0) });

        IReadOnlyList<JsonObject> labels = ReadRecords(
            Path.Combine(archiveDir, "sessions", ids.SessionId, ArchiveWriter.LabelsFileName));

        Assert.Equal(
            new long[] { 0, 1 },
            labels.Select(label => (long)label["interval"]!["startStreamSequence"]!).ToArray());
    }

    [Fact]
    public void AnOpenLabelIsWrittenAsInterruptedWithNoEndPair()
    {
        ArchiveIdentity ids = ArchiveIdentity.Mint();
        string archiveDir = Write(
            ids,
            DeterministicObservationIds(),
            labels: new[]
            {
                new LabelSegment("l-00000000-0000-7000-8000-00000000b000", "Never finished", StartedAt, ObservationId(0), 0),
            });

        JsonObject label = Assert.Single(ReadRecords(
            Path.Combine(archiveDir, "sessions", ids.SessionId, ArchiveWriter.LabelsFileName)));

        // A capture that died inside a segment still says where the segment began; claiming it
        // closed would be a claim about evidence that does not exist.
        Assert.Equal("interrupted", (string?)label["status"]);
        var interval = Assert.IsType<JsonObject>(label["interval"]);
        Assert.False(interval.ContainsKey("endObservationId"));
        Assert.False(interval.ContainsKey("endStreamSequence"));
    }

    [Fact]
    public void ALabelWhoseIntervalDoesNotResolveIsRefused()
    {
        ArchiveIdentity ids = ArchiveIdentity.Mint();

        // A boundary that names an observation this capture never retained.
        Assert.Throws<ArgumentException>(() => Write(
            ids,
            DeterministicObservationIds(),
            subdirectory: "dangling",
            labels: new[]
            {
                new LabelSegment(
                    "l-00000000-0000-7000-8000-00000000b000",
                    "Ghost",
                    StartedAt,
                    "obs-00000000-0000-7000-8000-0000000f0000",
                    0),
            }));

        // A boundary that resolves, but not at the sequence the interval claims.
        Assert.Throws<ArgumentException>(() => Write(
            ids,
            DeterministicObservationIds(),
            subdirectory: "misplaced",
            labels: new[]
            {
                new LabelSegment("l-00000000-0000-7000-8000-00000000b000", "Shifted", StartedAt, ObservationId(0), 1),
            }));

        // An interval that runs backwards.
        Assert.Throws<ArgumentException>(() => Write(
            ids,
            DeterministicObservationIds(),
            subdirectory: "reversed",
            labels: new[]
            {
                new LabelSegment(
                    "l-00000000-0000-7000-8000-00000000b000",
                    "Backwards",
                    StartedAt,
                    ObservationId(1),
                    1,
                    ObservationId(0),
                    0),
            }));

        // Two segments claiming one identity.
        Assert.Throws<ArgumentException>(() => Write(
            ids,
            DeterministicObservationIds(),
            subdirectory: "duplicated",
            labels: new[] { Label("b000", 0, 0), Label("b000", 1, 1) }));
    }

    /// <summary>
    /// The converse of <see cref="ALabelWhoseIntervalDoesNotResolveIsRefused"/>: a record that claims
    /// membership of a label nobody declared. No live caller can produce one — the engine hands its
    /// records and its segments over together — but a crash-recovery finalization replaying journal
    /// records without the in-memory labels would, and the archive would then be rejected by the
    /// contract validator ("observation references unknown label") long after the fact. The writer
    /// refuses it up front instead.
    /// </summary>
    [Fact]
    public void ARecordReferencingAnUndeclaredLabelIsRefused()
    {
        ArchiveIdentity ids = ArchiveIdentity.Mint();
        const string orphaned = "l-00000000-0000-7000-8000-00000000b0ff";

        ArgumentException noLabelsAtAll = Assert.Throws<ArgumentException>(() => WriteWithLabelRefs(
            ids,
            subdirectory: "orphaned-no-labels",
            labelRefs: new[] { orphaned },
            labels: null));
        Assert.Contains(orphaned, noLabelsAtAll.Message, StringComparison.Ordinal);
        Assert.Contains("did not declare", noLabelsAtAll.Message, StringComparison.Ordinal);

        // One label declared, but not the one the record names.
        Assert.Throws<ArgumentException>(() => WriteWithLabelRefs(
            ids,
            subdirectory: "orphaned-wrong-label",
            labelRefs: new[] { orphaned },
            labels: new[] { Label("b000", 0, 1) }));
    }

    /// <summary>A record naming a declared label is exactly what the writer is for.</summary>
    [Fact]
    public void ARecordReferencingADeclaredLabelIsWritten()
    {
        ArchiveIdentity ids = ArchiveIdentity.Mint();
        const string declared = "l-00000000-0000-7000-8000-00000000b000";

        string archiveDir = WriteWithLabelRefs(
            ids,
            subdirectory: "declared",
            labelRefs: new[] { declared },
            labels: new[] { Label("b000", 0, 1) });

        IReadOnlyList<JsonObject> records = ReadRecords(
            Path.Combine(archiveDir, "sessions", ids.SessionId, ArchiveWriter.RecordsFileName));
        Assert.Equal(
            new[] { declared },
            ((JsonArray)records[0]["labelRefs"]!).Select(node => (string?)node).ToArray());
    }

    [Fact]
    public void ACaptureThatAttachedNothingWritesNoArtifactFileAndNoBlobs()
    {
        ArchiveIdentity ids = ArchiveIdentity.Mint();
        string archiveDir = Write(ids, DeterministicObservationIds());

        Assert.False(File.Exists(
            Path.Combine(archiveDir, "sessions", ids.SessionId, ArchiveWriter.ArtifactsFileName)));
        Assert.False(Directory.Exists(Path.Combine(archiveDir, "blobs")));

        JsonObject commit = ReadDocument(Path.Combine(archiveDir, "sessions", ids.SessionId, "commit.json"));
        Assert.Equal(0L, (long?)commit["artifactCount"]);
        Assert.Equal(
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            (string?)commit["artifactSetDigest"]);
    }

    [Fact]
    public void ArtifactsAndTheirBlobsReachTheArchiveAndItsDigests()
    {
        ArchiveIdentity ids = ArchiveIdentity.Mint();
        CommittedArtifact artifact = Artifact(ids, Payload, observationRefs: new[] { ObservationId(0) });
        string archiveDir = Write(ids, DeterministicObservationIds(), artifacts: new[] { artifact });

        string digest = ArtifactFingerprint.ForBytes(Payload).Sha256;
        string blobPath = "blobs/sha256/" + digest[..2] + "/" + digest;
        string blob = Path.Combine(archiveDir, blobPath.Replace('/', Path.DirectorySeparatorChar));

        Assert.True(File.Exists(blob));
        Assert.Equal(Payload, File.ReadAllBytes(blob));
        Assert.Equal(digest, Path.GetFileName(blob));

        JsonObject written = Assert.Single(ReadRecords(
            Path.Combine(archiveDir, "sessions", ids.SessionId, ArchiveWriter.ArtifactsFileName)));
        Assert.Equal(blobPath, (string?)written["content"]!["path"]);
        Assert.Equal(
            new[] { ObservationId(0) },
            ((JsonArray)written["observationRefs"]!).Select(node => (string?)node).ToArray());

        JsonObject commit = ReadDocument(Path.Combine(archiveDir, "sessions", ids.SessionId, "commit.json"));
        Assert.Equal(1L, (long?)commit["artifactCount"]);
        Assert.Equal(
            ArchiveDigests.TextDigest(new[] { (string?)written["artifactId"] + ":" + digest }),
            (string?)commit["artifactSetDigest"]);

        // The blob is an ordinary canonical file, so it is inventoried like every other one and
        // therefore reaches the content digest without the writer treating it specially.
        JsonObject inventory = ReadDocument(Path.Combine(archiveDir, "inventory.json"));
        string[] paths = Assert.IsType<JsonArray>(inventory["entries"])
            .Select(entry => (string)((JsonObject)entry!)["path"]!)
            .ToArray();
        Assert.Contains(blobPath, paths);
        Assert.Contains("sessions/" + ids.SessionId + "/" + ArchiveWriter.ArtifactsFileName, paths);
        Assert.Equal(paths.OrderBy(path => path, StringComparer.Ordinal).ToArray(), paths);
    }

    [Fact]
    public void ArtifactsAreWrittenOrderedByIdentityRegardlessOfHowTheyArrive()
    {
        ArchiveIdentity ids = ArchiveIdentity.Mint();
        string archiveDir = Write(
            ids,
            DeterministicObservationIds(),
            artifacts: new[]
            {
                Artifact(ids, new byte[] { 2 }, artifactId: SecondArtifactId),
                Artifact(ids, new byte[] { 1 }, artifactId: FirstArtifactId),
            });

        IReadOnlyList<JsonObject> written = ReadRecords(
            Path.Combine(archiveDir, "sessions", ids.SessionId, ArchiveWriter.ArtifactsFileName));

        Assert.Equal(
            new[] { FirstArtifactId, SecondArtifactId },
            written.Select(artifact => (string?)artifact["artifactId"]).ToArray());
    }

    /// <summary>
    /// Two artifacts holding the same bytes — an unchanged screen shot twice — share one blob,
    /// because the path is the digest. Both are still their own artifact with their own identity,
    /// and the commit counts both.
    /// </summary>
    [Fact]
    public void TwoArtifactsWithIdenticalBytesShareOneBlob()
    {
        ArchiveIdentity ids = ArchiveIdentity.Mint();
        string archiveDir = Write(
            ids,
            DeterministicObservationIds(),
            artifacts: new[]
            {
                Artifact(ids, Payload, artifactId: FirstArtifactId),
                Artifact(ids, Payload, artifactId: SecondArtifactId),
            });

        string digest = ArtifactFingerprint.ForBytes(Payload).Sha256;
        Assert.Equal(
            new[] { digest },
            Directory.GetFiles(Path.Combine(archiveDir, "blobs"), "*", SearchOption.AllDirectories)
                .Select(Path.GetFileName)
                .ToArray());

        JsonObject commit = ReadDocument(Path.Combine(archiveDir, "sessions", ids.SessionId, "commit.json"));
        Assert.Equal(2L, (long?)commit["artifactCount"]);
        Assert.Equal(
            ArchiveDigests.TextDigest(new[] { FirstArtifactId + ":" + digest, SecondArtifactId + ":" + digest }),
            (string?)commit["artifactSetDigest"]);
    }

    [Fact]
    public void AnArtifactWhoseBytesDoNotMatchItsContentBlockIsRefused()
    {
        ArchiveIdentity ids = ArchiveIdentity.Mint();
        CommittedArtifact artifact = Artifact(ids, Payload);

        // The bytes behind a content-addressed document are the one part of an archive that lives
        // outside the JSON, so the writer re-reads them instead of trusting the block.
        File.WriteAllBytes(artifact.SourcePath, new byte[] { 0xff, 0xff, 0xff, 0xff });

        ArgumentException error = Assert.Throws<ArgumentException>(() => Write(
            ids,
            DeterministicObservationIds(),
            subdirectory: "tampered",
            artifacts: new[] { artifact }));
        Assert.Contains("does not describe the bytes", error.Message, StringComparison.Ordinal);

        File.Delete(artifact.SourcePath);
        Assert.Contains(
            "has no bytes",
            Assert.Throws<ArgumentException>(() => Write(
                ids,
                DeterministicObservationIds(),
                subdirectory: "missing",
                artifacts: new[] { artifact })).Message,
            StringComparison.Ordinal);
    }

    [Fact]
    public void AnArtifactReferencingSomethingThisCaptureDidNotRetainIsRefused()
    {
        ArchiveIdentity ids = ArchiveIdentity.Mint();

        Assert.Contains(
            "which this capture did not retain",
            Assert.Throws<ArgumentException>(() => Write(
                ids,
                DeterministicObservationIds(),
                subdirectory: "dangling-observation",
                artifacts: new[]
                {
                    Artifact(
                        ids,
                        Payload,
                        observationRefs: new[] { "obs-00000000-0000-7000-8000-0000000f0000" }),
                })).Message,
            StringComparison.Ordinal);

        Assert.Contains(
            "which this capture did not declare",
            Assert.Throws<ArgumentException>(() => Write(
                ids,
                DeterministicObservationIds(),
                subdirectory: "dangling-label",
                artifacts: new[]
                {
                    Artifact(ids, Payload, labelRefs: new[] { "l-00000000-0000-7000-8000-00000000b0ff" }),
                })).Message,
            StringComparison.Ordinal);
    }

    /// <summary>
    /// The converse: a record citing an artifact the capture never committed. Crash-recovery
    /// finalization is the caller that could produce one, and the archive it wrote would be rejected
    /// by the validator long after the bytes went missing.
    /// </summary>
    [Fact]
    public void ARecordReferencingAnUncommittedArtifactIsRefused()
    {
        ArchiveIdentity ids = ArchiveIdentity.Mint();
        JsonObject record = ActivityRecord(ids, "00000000e000", 0, StartedAt, 0);
        record["artifactRefs"] = new JsonArray
        {
            new JsonObject
            {
                ["artifactId"] = FirstArtifactId,
                ["role"] = "attachment",
            },
        };

        ArgumentException error = Assert.Throws<ArgumentException>(() => ArchiveWriter.WriteFinalized(
            Path.Combine(_root, "orphaned-artifact"),
            ids,
            Metadata(),
            new[] { record },
            Array.Empty<GapEntry>(),
            Array.Empty<CapabilityObservation>(),
            JournalSessionStatus.Closed,
            DeterministicObservationIds()));

        Assert.Contains(FirstArtifactId, error.Message, StringComparison.Ordinal);
        Assert.Contains("did not commit", error.Message, StringComparison.Ordinal);
    }

    /// <summary>
    /// An archive nobody reviewed carries no overlay at all, on the same terms as the labels and the
    /// artifacts: an absent document is how the format says "no decisions", and it keeps the
    /// inventory — and therefore the content digest — identical to an archive written before the
    /// overlay existed.
    /// </summary>
    [Fact]
    public void ACaptureNobodyReviewedWritesNoAssertionFile()
    {
        ArchiveIdentity ids = ArchiveIdentity.Mint();
        string archiveDir = Write(ids, DeterministicObservationIds());

        Assert.False(File.Exists(
            Path.Combine(archiveDir, "sessions", ids.SessionId, ArchiveWriter.AssertionsFileName)));

        JsonObject inventory = ReadDocument(Path.Combine(archiveDir, "inventory.json"));
        Assert.DoesNotContain(
            Assert.IsType<JsonArray>(inventory["entries"]).Select(entry => (string?)entry!["path"]),
            path => path!.EndsWith(ArchiveWriter.AssertionsFileName, StringComparison.Ordinal));
    }

    /// <summary>
    /// The overlay is inventoried like every other canonical file, so the content digest closes over
    /// the review — but it is deliberately outside the capture commit. The commit proves what was
    /// observed, and a human decision taken afterwards must not be able to alter that proof.
    /// </summary>
    [Fact]
    public void TheReviewOverlayIsInventoriedButLeavesTheCommitAlone()
    {
        ArchiveIdentity ids = ArchiveIdentity.Mint();
        string reviewed = Write(
            ids,
            DeterministicObservationIds(),
            subdirectory: "reviewed",
            assertions: new[] { Assertion(ids, "d000") });
        string unreviewed = Write(ids, DeterministicObservationIds(), subdirectory: "unreviewed");

        string relative = "sessions/" + ids.SessionId + "/" + ArchiveWriter.AssertionsFileName;
        JsonObject inventory = ReadDocument(Path.Combine(reviewed, "inventory.json"));
        string[] paths = Assert.IsType<JsonArray>(inventory["entries"])
            .Select(entry => (string)((JsonObject)entry!)["path"]!)
            .ToArray();
        Assert.Contains(relative, paths);
        Assert.Equal(paths.OrderBy(path => path, StringComparer.Ordinal).ToArray(), paths);

        JsonObject decision = Assert.Single(ReadRecords(
            Path.Combine(reviewed, relative.Replace('/', Path.DirectorySeparatorChar))));
        Assert.Equal("confirm", (string?)decision["decision"]);
        Assert.Equal(ids.ActorId, (string?)decision["authoredByActorId"]);

        // Same evidence, same closure proof; only the overlay and the digests above it differ.
        Assert.Equal(
            File.ReadAllBytes(Path.Combine(unreviewed, "sessions", ids.SessionId, "commit.json")),
            File.ReadAllBytes(Path.Combine(reviewed, "sessions", ids.SessionId, "commit.json")));
        Assert.NotEqual(
            (string?)ReadDocument(Path.Combine(unreviewed, "manifest.json"))["contentDigest"],
            (string?)ReadDocument(Path.Combine(reviewed, "manifest.json"))["contentDigest"]);
    }

    /// <summary>
    /// An assertion is nothing but references, so the writer resolves all of them before publishing:
    /// a decision about an archive this is not, an author nobody declared, or a superseded link that
    /// does not exist would each leave a reader unable to say what was decided, or by whom, long
    /// after the producer that lost the reference could explain it.
    /// </summary>
    [Fact]
    public void AnAssertionWhoseReferencesDoNotResolveIsRefused()
    {
        ArchiveIdentity ids = ArchiveIdentity.Mint();

        JsonObject elsewhere = Assertion(ids, "d000");
        elsewhere["target"]!["id"] = "ar-00000000-0000-7000-8000-0000000000ff";
        ArgumentException wrongArchive = Assert.Throws<ArgumentException>(() => Write(
            ids,
            DeterministicObservationIds(),
            subdirectory: "wrong-archive",
            assertions: new[] { elsewhere }));
        Assert.Contains("does not contain", wrongArchive.Message, StringComparison.Ordinal);

        JsonObject stranger = Assertion(ids, "d001");
        stranger["authoredByActorId"] = "actor-00000000-0000-7000-8000-0000000000ff";
        ArgumentException unknownAuthor = Assert.Throws<ArgumentException>(() => Write(
            ids,
            DeterministicObservationIds(),
            subdirectory: "unknown-author",
            assertions: new[] { stranger }));
        Assert.Contains("recorder", unknownAuthor.Message, StringComparison.Ordinal);

        ArgumentException danglingChain = Assert.Throws<ArgumentException>(() => Write(
            ids,
            DeterministicObservationIds(),
            subdirectory: "dangling-chain",
            assertions: new[]
            {
                Assertion(ids, "d002", supersedes: "asrt-00000000-0000-7000-8000-0000000000ff"),
            }));
        Assert.Contains("supersedes", danglingChain.Message, StringComparison.Ordinal);

        ArgumentException twice = Assert.Throws<ArgumentException>(() => Write(
            ids,
            DeterministicObservationIds(),
            subdirectory: "declared-twice",
            assertions: new[] { Assertion(ids, "d003"), Assertion(ids, "d003") }));
        Assert.Contains("declared twice", twice.Message, StringComparison.Ordinal);
    }

    /// <summary>
    /// A decision about a label of this capture is as legitimate as one about the package: the
    /// contract lets a reviewer aim at anything the archive contains, and the writer resolves the
    /// target against the documents it just built rather than assuming the archive-wide case.
    /// </summary>
    [Fact]
    public void AnAssertionTargetingADeclaredLabelIsWritten()
    {
        ArchiveIdentity ids = ArchiveIdentity.Mint();
        LabelSegment segment = Label("b000", 0, 1);

        JsonObject aboutTheLabel = Assertion(
            ids,
            "d000",
            ArchiveDocuments.RejectDecision,
            reason: "this segment was mislabelled");
        aboutTheLabel["target"]!["kind"] = "label";
        aboutTheLabel["target"]!["id"] = segment.LabelId;

        string archiveDir = Write(
            ids,
            DeterministicObservationIds(),
            labels: new[] { segment },
            assertions: new[] { aboutTheLabel });

        JsonObject written = Assert.Single(ReadRecords(Path.Combine(
            archiveDir,
            "sessions",
            ids.SessionId,
            ArchiveWriter.AssertionsFileName)));
        Assert.Equal(segment.LabelId, (string?)written["target"]!["id"]);
    }

    [Fact]
    public void ProducedArchivePassesTheContractValidator()
    {
        string? uv = FindUv();
        if (uv is null)
        {
            // xUnit 2.5 cannot skip at run time; the outer gate simply cannot run without uv.
            Console.WriteLine(
                "SKIPPED ProducedArchivePassesTheContractValidator: uv is not installed, so "
                    + "contract/archive/validate_archives.py cannot be executed.");
            return;
        }

        ArchiveIdentity ids = ArchiveIdentity.Mint();
        // The fixture carries a label so the validator's label rules — interval endpoints resolving
        // to records of this capture at the sequences claimed, a known declaring actor, known
        // provenance sources — are exercised on bytes this writer actually produced.
        string archiveDir = Write(ids, DeterministicObservationIds(), labels: new[] { Label("b000", 0, 1) });

        // validate_archives.py takes no arguments: it validates every directory inside the
        // fixtures directory next to itself. The contract tree is therefore copied into a
        // scratch root and the produced archive is added as one more fixture.
        string harness = Path.Combine(_root, "validator");
        string contractCopy = Path.Combine(harness, "contract");
        CopyDirectory(Path.Combine(ContractPaths.Root(), "contract"), contractCopy);
        CopyDirectory(archiveDir, Path.Combine(contractCopy, "archive", "fixtures", "90-windows-writer"));

        (int exitCode, string output) = Run(
            uv,
            new[] { "run", "--script", Path.Combine(contractCopy, "archive", "validate_archives.py") },
            harness);

        Assert.True(exitCode == 0, "validate_archives.py failed:\n" + output);
        Assert.Contains("ok    90-windows-writer", output, StringComparison.Ordinal);
    }

    private string Write(
        ArchiveIdentity ids,
        Func<string> observationIds,
        bool withCapabilities = true,
        string? subdirectory = null,
        IReadOnlyList<LabelSegment>? labels = null,
        IReadOnlyList<CommittedArtifact>? artifacts = null,
        IReadOnlyList<JsonObject>? assertions = null)
    {
        string outputDir = subdirectory is null ? _root : Path.Combine(_root, subdirectory);
        return ArchiveWriter.WriteFinalized(
            outputDir,
            ids,
            Metadata(),
            new[]
            {
                ActivityRecord(ids, "00000000e000", 0, StartedAt, 0),
                ActivityRecord(ids, "00000000e001", 1, EndedAt, 1),
            },
            Array.Empty<GapEntry>(),
            withCapabilities
                ? new[]
                {
                    new CapabilityObservation(
                        Capability.PointerCapture,
                        CapabilityAuthorization.Granted,
                        CapabilityAvailability.Available,
                        CapabilityTransition.Initial,
                        CapabilityReason.PermissionGranted,
                        StartedAt),
                }
                : Array.Empty<CapabilityObservation>(),
            JournalSessionStatus.Closed,
            observationIds,
            labels,
            artifacts,
            assertions);
    }

    /// <summary>One archive-scoped review decision, with a deterministic identity.</summary>
    private static JsonObject Assertion(
        ArchiveIdentity ids,
        string suffix,
        string decision = ArchiveDocuments.ConfirmDecision,
        string? reason = null,
        string? value = null,
        string? supersedes = null) => ArchiveDocuments.ArchiveReviewAssertion(
        ids,
        "asrt-00000000-0000-7000-8000-00000000" + suffix,
        decision,
        EndedAt,
        ArchiveDocuments.InitialRevision,
        reason,
        value,
        supersedes);

    /// <summary>
    /// One committed artifact, with its bytes staged in a scratch draft exactly the way the journal
    /// stages them: content-addressed, at the path the document names.
    /// </summary>
    private CommittedArtifact Artifact(
        ArchiveIdentity ids,
        byte[] bytes,
        string? artifactId = null,
        IReadOnlyList<string>? observationRefs = null,
        IReadOnlyList<string>? labelRefs = null)
    {
        ArtifactFingerprint fingerprint = ArtifactFingerprint.ForBytes(bytes);
        string draftPath = Path.Combine(
            _root,
            "draft",
            fingerprint.ContentPath.Replace('/', Path.DirectorySeparatorChar));
        Directory.CreateDirectory(Path.GetDirectoryName(draftPath)!);
        File.WriteAllBytes(draftPath, bytes);

        JsonObject document = ArchiveDocuments.Artifact(
            ids,
            artifactId ?? FirstArtifactId,
            fingerprint,
            new ArtifactDeclaration(ArtifactKind, "application/octet-stream")
            {
                ObservationRefs = observationRefs ?? Array.Empty<string>(),
                LabelRefs = labelRefs ?? Array.Empty<string>(),
            },
            PolicyVersion);

        return new CommittedArtifact(document, draftPath);
    }

    /// <summary>
    /// The same two fixture records as <see cref="Write"/>, except that the first one carries
    /// <c>labelRefs</c>. Kept separate so the ordinary fixture stays label-free.
    /// </summary>
    private string WriteWithLabelRefs(
        ArchiveIdentity ids,
        string subdirectory,
        IReadOnlyList<string> labelRefs,
        IReadOnlyList<LabelSegment>? labels) => ArchiveWriter.WriteFinalized(
        Path.Combine(_root, subdirectory),
        ids,
        Metadata(),
        new[]
        {
            ActivityRecord(ids, "00000000e000", 0, StartedAt, 0, labelRefs),
            ActivityRecord(ids, "00000000e001", 1, EndedAt, 1),
        },
        Array.Empty<GapEntry>(),
        Array.Empty<CapabilityObservation>(),
        JournalSessionStatus.Closed,
        DeterministicObservationIds(),
        labels);

    /// <summary>The observation id the fixture records carry at a given stream position.</summary>
    private static string ObservationId(long streamSequence) =>
        "obs-00000000-0000-7000-8000-00000000e00" + streamSequence.ToString(CultureInfo.InvariantCulture);

    /// <summary>A closed segment bracketing the two fixture records at the given positions.</summary>
    private static LabelSegment Label(string suffix, long startSequence, long endSequence) => new(
        "l-00000000-0000-7000-8000-00000000" + suffix,
        "Segment " + suffix,
        StartedAt,
        ObservationId(startSequence),
        startSequence,
        ObservationId(endSequence),
        endSequence);

    private static SessionMetadata Metadata() => new(
        StartedAt,
        EndedAt,
        ConsentedAt,
        PolicyVersion,
        new[] { "pointer", "keyboard" },
        Array.Empty<string>(),
        "Jazz Capture (.NET)",
        "1.0.0",
        "windows.capture-controller",
        new[] { "pointer.capture", "keyboard.capture", "session_boundaries" },
        new[] { new UnavailableCapability("screen.capture", "disabled_by_policy", "MVP does not capture screenshots") })
    {
        ProducerPlatform = "Windows",
    };

    private static JsonObject ActivityRecord(
        ArchiveIdentity ids,
        string suffix,
        long sequence,
        string capturedAt,
        long eventSequence,
        IReadOnlyList<string>? labelRefs = null) => ArchiveDocuments.Record(
        ids,
        observationId: "obs-00000000-0000-7000-8000-" + suffix,
        streamSequence: sequence,
        capturedAt: capturedAt,
        recordType: ArchiveContracts.ActivityEventRecordType,
        payloadSchema: ArchiveContracts.ActivityEventPayloadSchema,
        sourceRole: ArchiveContracts.TriggerRole,
        payload: new JsonObject
        {
            ["sessionId"] = ids.SessionId,
            ["eventId"] = Identifiers.EventId(ids.SessionId, eventSequence),
            ["timestamp"] = capturedAt,
            ["eventType"] = eventSequence == 0 ? "session_start" : "session_end",
            ["url"] = "app://session",
        },
        policyVersion: PolicyVersion,
        labelRefs: labelRefs);

    private static Func<string> DeterministicObservationIds()
    {
        var counter = 0;
        return () => "obs-00000000-0000-7000-8000-" + (0xc000 + counter++).ToString("x12");
    }

    private static long Sequence(JsonObject record) => (long)record["streamSequence"]!;

    private static JsonObject ReadDocument(string path) =>
        (JsonObject)JsonStrictParser.Parse(File.ReadAllText(path, Encoding.UTF8))!;

    private static IReadOnlyList<JsonObject> ReadRecords(string path) =>
        File.ReadAllLines(path)
            .Where(line => line.Length > 0)
            .Select(line => (JsonObject)JsonStrictParser.Parse(line)!)
            .ToArray();

    private static void CopyDirectory(string source, string destination)
    {
        Directory.CreateDirectory(destination);
        foreach (string directory in Directory.GetDirectories(source))
        {
            CopyDirectory(directory, Path.Combine(destination, Path.GetFileName(directory)));
        }

        foreach (string file in Directory.GetFiles(source))
        {
            File.Copy(file, Path.Combine(destination, Path.GetFileName(file)));
        }
    }

    private static string? FindUv()
    {
        string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        foreach (string candidate in new[]
                 {
                     "/opt/homebrew/bin/uv",
                     "/usr/local/bin/uv",
                     Path.Combine(home, ".local", "bin", "uv"),
                     Path.Combine(home, ".cargo", "bin", "uv"),
                 })
        {
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        return null;
    }

    private static (int ExitCode, string Output) Run(string fileName, string[] arguments, string workingDirectory)
    {
        Directory.CreateDirectory(workingDirectory);
        var info = new ProcessStartInfo(fileName)
        {
            WorkingDirectory = workingDirectory,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        };
        foreach (string argument in arguments)
        {
            info.ArgumentList.Add(argument);
        }

        using var process = Process.Start(info)
            ?? throw new InvalidOperationException("could not start " + fileName);
        string standardOutput = process.StandardOutput.ReadToEnd();
        string standardError = process.StandardError.ReadToEnd();
        process.WaitForExit();
        return (process.ExitCode, standardOutput + standardError);
    }
}
