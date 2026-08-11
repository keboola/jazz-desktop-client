using System.Text.Json.Nodes;
using JazzCaptureCore;
using JazzCaptureCore.Archive;
using JazzCaptureCore.Journal;
using JazzCaptureCore.Json;

namespace JazzCaptureCoreTests;

/// <summary>
/// The artifact document builder. Two consumers exist for it — screenshots and narration — and
/// neither is implemented yet, so these tests hold the builder to what those two will need rather
/// than to what today's single neutral kind happens to use.
/// </summary>
public sealed class ArchiveArtifactTests
{
    private const string PolicyVersion = "consent-v1";
    private const string ArtifactId = "art-00000000-0000-7000-8000-00000000f000";
    private const string MediaType = "application/octet-stream";

    /// <summary>Neutral on purpose: <c>screenshot</c> would drag in its whole evidence profile.</summary>
    private const string Kind = "attachment";

    private static readonly byte[] Payload = { 0x6a, 0x61, 0x7a, 0x7a };

    /// <summary>sha256("jazz"), so the fan-out is checked against a digest nobody derived here.</summary>
    private const string PayloadDigest = "c301f75ab52fa076c827231e613bbc976e26b2c1f7ddd01a319b2832b8ecdf9a";

    [Fact]
    public void TheFingerprintIsContentAddressedWithATwoCharacterFanOut()
    {
        ArtifactFingerprint fingerprint = ArtifactFingerprint.ForBytes(Payload);

        Assert.Equal(PayloadDigest, fingerprint.Sha256);
        Assert.Equal(Payload.Length, fingerprint.ByteLength);
        Assert.Equal("blobs/sha256/" + fingerprint.Sha256[..2] + "/" + fingerprint.Sha256, fingerprint.ContentPath);
        Assert.Equal(fingerprint.Sha256, fingerprint.ContentPath.Split('/')[^1]);
        Assert.Throws<ArgumentException>(() => ArtifactFingerprint.BlobPath("NOTADIGEST"));
        Assert.Throws<ArgumentException>(() => ArtifactFingerprint.BlobPath(fingerprint.Sha256.ToUpperInvariant()));
    }

    [Fact]
    public void TheDocumentEmitsSchemaOrderAndOmitsEveryAbsentOptional()
    {
        JsonObject artifact = Build(new ArtifactDeclaration(Kind, MediaType));

        Assert.Equal(
            new[]
            {
                "schemaVersion",
                "artifactId",
                "captureId",
                "origin",
                "kind",
                "content",
                "sourceRefs",
                "actorRefs",
                "labelRefs",
                "observationRefs",
                "provenance",
                "quality",
                "privacy",
            },
            artifact.Select(pair => pair.Key).ToArray());

        // An absent optional is absent, never a JSON null: the format checks reject the latter.
        Assert.False(artifact.ContainsKey("contentSchema"));
        Assert.False(artifact.ContainsKey("captureInterval"));
        Assert.False(artifact.ContainsKey("derivation"));
        Assert.False(artifact.ContainsKey("extensions"));
        Assert.False(((JsonObject)artifact["quality"]!).ContainsKey("timingErrorMillis"));

        Assert.Equal(ArtifactOrigins.Captured, (string?)artifact["origin"]);
        Assert.Equal("observed", (string?)artifact["provenance"]!["factClass"]);
        Assert.Equal("captured", (string?)artifact["privacy"]!["status"]);
        Assert.Equal(PolicyVersion, (string?)artifact["privacy"]!["policyVersion"]);
        Assert.Equal(MediaType, (string?)artifact["content"]!["mediaType"]);
    }

    /// <summary>
    /// A screenshot is an interval with a known timing error, a mandatory reason token, a privacy
    /// block bound to the frozen capture policy, and a versioned extension profile. None of that is
    /// implemented here, but a builder that could not express it would have to be rewritten by the
    /// change that does.
    /// </summary>
    [Fact]
    public void TheDocumentCarriesWhatScreenshotsAndNarrationWillNeed()
    {
        var extensions = new JsonObject
        {
            ["dev.jazz.capture.screenshot.v1.scope"] = "display",
            ["dev.jazz.capture.screenshot.v1.monotonicDurationMillis"] = 125,
            ["dev.jazz.capture.screenshot.v1.excludedApplicationBundleIds"] = new JsonArray { "com.example.vault" },
        };

        JsonObject artifact = Build(new ArtifactDeclaration(Kind, MediaType)
        {
            CaptureInterval = new ArtifactCaptureInterval("2026-07-22T08:00:10.000Z", "2026-07-22T08:00:10.125Z"),
            Quality = new ArtifactQuality(
                ArtifactQualityStatus.Partial,
                new[] { "dev.jazz.capture.screenshot.v1.temporal_interval" },
                TimingErrorMillis: 125),
            Privacy = new ArtifactPrivacy(
                ArtifactPrivacyStatus.Masked,
                "consent-v2",
                new[] { new ArtifactRedaction("/pixels", ArtifactRedaction.Masked, "sensitive_window") }),
            ActorRefs = new[] { new ArtifactActorRef("performer", ArtifactActorRef.DeclaredBasis, "session_recorder") },
            ContentSchema = "https://jazz.dev/schema/example.schema.json",
            Extensions = extensions,
        });

        Assert.Equal("2026-07-22T08:00:10.000Z", (string?)artifact["captureInterval"]!["startedAt"]);
        Assert.Equal("2026-07-22T08:00:10.125Z", (string?)artifact["captureInterval"]!["endedAt"]);
        Assert.Equal("partial", (string?)artifact["quality"]!["status"]);
        Assert.Equal(125L, (long?)artifact["quality"]!["timingErrorMillis"]);
        Assert.Equal(
            new[] { "dev.jazz.capture.screenshot.v1.temporal_interval" },
            ((JsonArray)artifact["quality"]!["reasons"]!).Select(node => (string?)node).ToArray());

        // The policy version travels with the artifact rather than being stamped on at write time,
        // because the screenshot profile cross-checks it against the session's frozen policy.
        Assert.Equal("consent-v2", (string?)artifact["privacy"]!["policyVersion"]);
        JsonObject redaction = Assert.IsType<JsonObject>(
            Assert.Single((JsonArray)artifact["privacy"]!["redactions"]!));
        Assert.Equal("/pixels", (string?)redaction["path"]);

        JsonObject actorRef = Assert.IsType<JsonObject>(Assert.Single((JsonArray)artifact["actorRefs"]!));
        Assert.Equal("performer", (string?)actorRef["role"]);
        Assert.Equal("session_recorder", (string?)actorRef["method"]);

        // Verbatim, including the array: the profile's cross-field invariants are checked against
        // exactly these bytes.
        Assert.Equal(
            JsonCanonicalizer.Sha256Hex(extensions),
            JsonCanonicalizer.Sha256Hex((JsonObject)artifact["extensions"]!));
    }

    [Fact]
    public void ADerivedArtifactCarriesItsDerivationAndDerivedProvenance()
    {
        JsonObject artifact = Build(new ArtifactDeclaration(Kind, MediaType)
        {
            Origin = ArtifactOrigins.Derived,
            Derivation = new ArtifactDerivation(
                "Jazz Capture (.NET)",
                "1.0.0",
                "2026-07-22T08:01:00Z",
                new[] { new ArtifactInputRef("observation", "obs-00000000-0000-7000-8000-00000000e000") },
                ParametersDigest: new string('a', 64)),
        });

        Assert.Equal("derived", (string?)artifact["origin"]);
        Assert.Equal("derived", (string?)artifact["provenance"]!["factClass"]);
        Assert.Equal("2026-07-22T08:01:00Z", (string?)artifact["derivation"]!["computedAt"]);
        Assert.Equal("Jazz Capture (.NET)", (string?)artifact["derivation"]!["producer"]!["name"]);
        JsonObject input = Assert.IsType<JsonObject>(Assert.Single((JsonArray)artifact["derivation"]!["inputRefs"]!));
        Assert.Equal("observation", (string?)input["kind"]);
    }

    [Fact]
    public void TheDerivationAndTheOriginMustAgree()
    {
        ArtifactDerivation derivation = new(
            "Jazz Capture (.NET)",
            "1.0.0",
            "2026-07-22T08:01:00Z",
            new[] { new ArtifactInputRef("observation", "obs-00000000-0000-7000-8000-00000000e000") });

        // Derived without a derivation, and a derivation without a derived origin: the schema binds
        // the two, so the builder refuses both rather than emitting a document nobody will accept.
        Assert.Throws<ArgumentException>(() => Build(new ArtifactDeclaration(Kind, MediaType)
        {
            Origin = ArtifactOrigins.Derived,
        }));
        Assert.Throws<ArgumentException>(() => Build(new ArtifactDeclaration(Kind, MediaType)
        {
            Derivation = derivation,
        }));
        Assert.Throws<ArgumentException>(() => Build(new ArtifactDeclaration(Kind, MediaType)
        {
            Origin = ArtifactOrigins.Derived,
            Derivation = derivation with { InputRefs = Array.Empty<ArtifactInputRef>() },
        }));
    }

    [Fact]
    public void ADeclarationTheSchemaWouldRejectIsRefusedWhileItsProducerIsStillOnTheStack()
    {
        Assert.Throws<ArgumentException>(() => Build(new ArtifactDeclaration("Screenshot", MediaType)));
        Assert.Throws<ArgumentException>(() => Build(new ArtifactDeclaration(Kind, "not-a-media-type")));
        Assert.Throws<ArgumentException>(() => Build(new ArtifactDeclaration(Kind, MediaType) { Origin = "invented" }));
        Assert.Throws<ArgumentException>(() => Build(new ArtifactDeclaration(Kind, MediaType) { SourceRole = "Capture" }));
        Assert.Throws<ArgumentException>(() => Build(new ArtifactDeclaration(Kind, MediaType)
        {
            Quality = new ArtifactQuality("excellent", Array.Empty<string>()),
        }));
        Assert.Throws<ArgumentException>(() => Build(new ArtifactDeclaration(Kind, MediaType)
        {
            Quality = new ArtifactQuality(ArtifactQualityStatus.Partial, new[] { "one", "one" }),
        }));
        Assert.Throws<ArgumentException>(() => Build(new ArtifactDeclaration(Kind, MediaType)
        {
            Quality = new ArtifactQuality(ArtifactQualityStatus.Partial, Array.Empty<string>(), TimingErrorMillis: -1),
        }));
        Assert.Throws<ArgumentException>(() => Build(new ArtifactDeclaration(Kind, MediaType)
        {
            Privacy = new ArtifactPrivacy(
                ArtifactPrivacyStatus.Masked,
                PolicyVersion,
                new[] { new ArtifactRedaction("pixels", ArtifactRedaction.Masked, "no leading slash") }),
        }));
        Assert.Throws<ArgumentException>(() => Build(new ArtifactDeclaration(Kind, MediaType)
        {
            ActorRefs = new[] { new ArtifactActorRef("performer", "guessed") },
        }));
        Assert.Throws<ArgumentException>(() => Build(new ArtifactDeclaration(Kind, MediaType)
        {
            ObservationRefs = new[] { "obs-1", "obs-1" },
        }));
    }

    private static JsonObject Build(ArtifactDeclaration declaration) => ArchiveDocuments.Artifact(
        ArchiveIdentity.Mint(),
        ArtifactId,
        ArtifactFingerprint.ForBytes(Payload),
        declaration,
        PolicyVersion);
}
