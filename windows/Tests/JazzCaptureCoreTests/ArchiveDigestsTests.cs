using System.Text.Json.Nodes;
using JazzCaptureCore.Archive;
using JazzCaptureCore.Journal;
using JazzCaptureCore.Json;

namespace JazzCaptureCoreTests;

/// <summary>
/// Pins the four archive digests against the worked minimal archive of ANNEX-ARCHIVE section 4.2.
/// The commit digest is the value a validator recomputes from the bytes on disk, so reproducing it
/// here fixes both the digest algorithms and the document builders that feed them.
/// </summary>
public sealed class ArchiveDigestsTests
{
    private const string ArchiveId = "ar-00000000-0000-7000-8000-00000000a001";
    private const string OriginId = "origin-00000000-0000-7000-8000-00000000a002";
    private const string CaptureId = "cap-00000000-0000-7000-8000-00000000a003";
    private const string StreamId = "stream-00000000-0000-7000-8000-00000000a004";
    private const string ObservationId = "obs-00000000-0000-7000-8000-00000000a005";
    private const string ActorId = "actor-00000000-0000-7000-8000-00000000a006";
    private const string SourceId = "src-00000000-0000-7000-8000-00000000a007";
    private const string CommitId = "cmt-00000000-0000-7000-8000-00000000a008";
    private const string SessionId = "s-00000000-0000-7000-8000-00000000a009";

    private const string EmptySha256 =
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

    private static ArchiveIdentity Identity() => new(
        ArchiveId,
        OriginId,
        CaptureId,
        StreamId,
        SessionId,
        ActorId,
        SourceId,
        CommitId);

    [Fact]
    public void TextDigestOfNoLinesIsTheEmptyStringDigest()
    {
        Assert.Equal(EmptySha256, ArchiveDigests.TextDigest(Array.Empty<string>()));
    }

    [Fact]
    public void TextDigestTerminatesEveryLineIncludingTheLast()
    {
        // sha256("a\nb\n") — the final line carries a trailing newline just like the others.
        Assert.Equal(
            "911169ddaaf146aff539f58c26c489af3b892dff0fe283c1c264c65ae5aa59a2",
            ArchiveDigests.TextDigest(new[] { "a", "b" }));
    }

    [Fact]
    public void ArtifactSetDigestOfNoArtifactsIsTheEmptyStringDigest()
    {
        Assert.Equal(EmptySha256, ArchiveDigests.ArtifactSetDigest(Array.Empty<JsonObject>()));
    }

    [Fact]
    public void ArtifactSetDigestOrdersByArtifactId()
    {
        JsonObject first = Artifact("art-00000000-0000-7000-8000-00000000b001", new string('1', 64));
        JsonObject second = Artifact("art-00000000-0000-7000-8000-00000000b002", new string('2', 64));

        Assert.Equal(
            ArchiveDigests.ArtifactSetDigest(new[] { first, second }),
            ArchiveDigests.ArtifactSetDigest(new[] { second, first }));
    }

    [Fact]
    public void OrderedObservationDigestReproducesTheWorkedMinimalArchive()
    {
        JsonObject record = MinimalRecord();

        Assert.Equal(
            "73616818e3891db9b8662adf47c43f92da2fd42a2999fc0267fd64951865b264",
            ArchiveDigests.OrderedObservationDigest(new[] { record }));
    }

    [Fact]
    public void MinimalCommitCanonicalDigestReproducesTheWorkedMinimalArchive()
    {
        JsonObject commit = MinimalCommit();

        Assert.Equal(
            "b2cd59aa0380c74e58617150d9a885fbfa5198cf634859bd19c60cfe7bc35c94",
            JsonCanonicalizer.Sha256Hex(commit));
    }

    [Fact]
    public void MinimalCommitCarriesTheContractKeysInSchemaOrder()
    {
        JsonObject commit = MinimalCommit();

        Assert.Equal(
            new[]
            {
                "schemaVersion",
                "commitId",
                "captureId",
                "revision",
                "endedAt",
                "streamSummaries",
                "orderedObservationDigest",
                "artifactCount",
                "artifactSetDigest",
                "gaps",
            },
            commit.Select(pair => pair.Key).ToArray());
    }

    [Fact]
    public void GapWithoutDetailOmitsTheKey()
    {
        JsonObject commit = ArchiveDocuments.Commit(
            Identity(),
            revision: 1,
            endedAt: "2026-07-22T08:01:00Z",
            summaries: new[] { new StreamSummary(StreamId, 0, 3, 2) },
            orderedObservationDigest: EmptySha256,
            artifactCount: 0,
            artifactSetDigest: EmptySha256,
            gaps: new[]
            {
                new GapEntry(StreamId, 1, 2, GapReasons.RecoveryTruncation, null),
            });

        var gap = Assert.IsType<JsonObject>(Assert.IsType<JsonArray>(commit["gaps"])[0]);
        Assert.False(gap.ContainsKey("detail"));
        Assert.Equal(GapReasons.RecoveryTruncation, (string?)gap["reason"]);
    }

    [Fact]
    public void GapWithDetailKeepsTheKey()
    {
        JsonObject commit = ArchiveDocuments.Commit(
            Identity(),
            revision: 1,
            endedAt: "2026-07-22T08:01:00Z",
            summaries: new[] { new StreamSummary(StreamId, 0, 3, 2) },
            orderedObservationDigest: EmptySha256,
            artifactCount: 0,
            artifactSetDigest: EmptySha256,
            gaps: new[]
            {
                new GapEntry(StreamId, 1, 2, GapReasons.RecoveryTruncation, "producer terminated"),
            });

        var gap = Assert.IsType<JsonObject>(Assert.IsType<JsonArray>(commit["gaps"])[0]);
        Assert.Equal("producer terminated", (string?)gap["detail"]);
    }

    [Fact]
    public void MintedIdentityUsesTheContractPrefixes()
    {
        ArchiveIdentity identity = ArchiveIdentity.Mint();

        Assert.StartsWith("ar-", identity.ArchiveId, StringComparison.Ordinal);
        Assert.StartsWith("origin-", identity.OriginId, StringComparison.Ordinal);
        Assert.StartsWith("cap-", identity.CaptureId, StringComparison.Ordinal);
        Assert.StartsWith("stream-", identity.StreamId, StringComparison.Ordinal);
        Assert.StartsWith("s-", identity.SessionId, StringComparison.Ordinal);
        Assert.StartsWith("actor-", identity.ActorId, StringComparison.Ordinal);
        Assert.StartsWith("src-", identity.SourceId, StringComparison.Ordinal);
        Assert.StartsWith("cmt-", identity.CommitId, StringComparison.Ordinal);
        Assert.NotEqual(ArchiveIdentity.Mint().ArchiveId, identity.ArchiveId);
    }

    private static JsonObject MinimalCommit() => ArchiveDocuments.Commit(
        Identity(),
        revision: 1,
        endedAt: "2026-07-22T08:01:00Z",
        summaries: new[] { new StreamSummary(StreamId, 0, 0, 1) },
        orderedObservationDigest: ArchiveDigests.OrderedObservationDigest(new[] { MinimalRecord() }),
        artifactCount: 0,
        artifactSetDigest: EmptySha256,
        gaps: Array.Empty<GapEntry>());

    private static JsonObject MinimalRecord() => ArchiveDocuments.Record(
        Identity(),
        observationId: ObservationId,
        streamSequence: 0,
        capturedAt: "2026-07-22T08:00:00Z",
        recordType: ArchiveContracts.ActivityEventRecordType,
        payloadSchema: ArchiveContracts.ActivityEventPayloadSchema,
        sourceRole: ArchiveContracts.TriggerRole,
        payload: new JsonObject
        {
            ["sessionId"] = SessionId,
            ["eventId"] = SessionId + "-0",
            ["timestamp"] = "2026-07-22T08:00:00Z",
            ["eventType"] = "session_start",
            ["url"] = "app://session",
        },
        policyVersion: "consent-v1");

    private static JsonObject Artifact(string artifactId, string sha256) => new()
    {
        ["artifactId"] = artifactId,
        ["content"] = new JsonObject { ["sha256"] = sha256 },
    };
}
