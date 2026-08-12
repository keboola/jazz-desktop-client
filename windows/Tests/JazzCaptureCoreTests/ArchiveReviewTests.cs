using System.Text;
using System.Text.Json.Nodes;
using JazzCaptureCore;
using JazzCaptureCore.Archive;
using JazzCaptureCore.Json;

namespace JazzCaptureCoreTests;

/// <summary>
/// Exercises the review overlay on its own: the decision table of ANNEX-HOST section 5 as the
/// assertion factory enforces it, and the append-only chain the log keeps beside a draft.
/// </summary>
public sealed class ArchiveReviewTests : IDisposable
{
    private const string AuthoredAt = "2026-07-22T08:01:00.000Z";
    private const string FirstAssertionId = "asrt-00000000-0000-7000-8000-00000000d000";
    private const string SecondAssertionId = "asrt-00000000-0000-7000-8000-00000000d001";

    private readonly ArchiveIdentity _ids = ArchiveIdentity.Mint();

    private readonly string _root = Path.Combine(
        Path.GetTempPath(),
        "jazz-archive-review-" + Guid.NewGuid().ToString("n"));

    public void Dispose()
    {
        if (Directory.Exists(_root))
        {
            Directory.Delete(_root, recursive: true);
        }
    }

    /// <summary>
    /// A confirmation says one thing: this archive is accepted as it stands. A reason or a corrected
    /// value attached to it would pass the JSON Schema and still describe a decision the reviewer
    /// never took, so the factory refuses both.
    /// </summary>
    [Fact]
    public void AConfirmationStatesNothingBeyondTheDecision()
    {
        JsonObject confirmation = Assertion(ArchiveDocuments.ConfirmDecision);

        Assert.Equal("confirm", (string?)confirmation["decision"]);
        Assert.False(confirmation.ContainsKey("reason"));
        Assert.False(confirmation.ContainsKey("value"));
        Assert.Equal("declared", (string?)confirmation["provenance"]!["factClass"]);
        Assert.Empty(Assert.IsType<JsonArray>(confirmation["provenance"]!["sources"]));

        Assert.Throws<ArgumentException>(() =>
            Assertion(ArchiveDocuments.ConfirmDecision, reason: "looks fine"));
        Assert.Throws<ArgumentException>(() =>
            Assertion(ArchiveDocuments.ConfirmDecision, value: "something else"));
    }

    /// <summary>
    /// A rejection is a decision about delivery, so it has to say why and cannot correct anything.
    /// The host substitutes standing text when the reviewer typed none, which is what keeps the
    /// reason non-empty without inventing a justification.
    /// </summary>
    [Fact]
    public void ARejectionCarriesItsReasonAndCorrectsNothing()
    {
        JsonObject rejection = Assertion(
            ArchiveDocuments.RejectDecision,
            reason: "Rejected during local review");

        Assert.Equal("reject", (string?)rejection["decision"]);
        Assert.Equal("Rejected during local review", (string?)rejection["reason"]);
        Assert.False(rejection.ContainsKey("value"));
        Assert.False(((JsonObject)rejection["target"]!).ContainsKey("path"));
        Assert.Equal("declared", (string?)rejection["provenance"]!["factClass"]);

        Assert.ThrowsAny<ArgumentException>(() => Assertion(ArchiveDocuments.RejectDecision));
        Assert.Throws<ArgumentException>(() =>
            Assertion(ArchiveDocuments.RejectDecision, reason: " "));
        Assert.Throws<ArgumentException>(() =>
            Assertion(ArchiveDocuments.RejectDecision, reason: "wrong", value: "right"));
    }

    /// <summary>
    /// A correction is filed under its own path with the corrected reading attached, and its fact
    /// class says the claim revises the evidence rather than merely commenting on it.
    /// </summary>
    [Fact]
    public void ACorrectionIsFiledUnderItsOwnPathWithTheCorrectedReading()
    {
        JsonObject correction = Assertion(
            ArchiveDocuments.CorrectDecision,
            reason: "the amount was misread",
            value: "the amount was misread");

        Assert.Equal("correct", (string?)correction["decision"]);
        Assert.Equal("/review/correction", (string?)correction["target"]!["path"]);
        Assert.Equal("the amount was misread", (string?)correction["value"]);
        Assert.Equal("the amount was misread", (string?)correction["reason"]);
        Assert.Equal("corrected", (string?)correction["provenance"]!["factClass"]);

        // A correction with nothing to correct is not a correction.
        Assert.ThrowsAny<ArgumentException>(() =>
            Assertion(ArchiveDocuments.CorrectDecision, reason: "wrong"));
    }

    /// <summary>
    /// The schema allows eight decisions; this client can author three. Emitting one of the other
    /// five — exclude, split, merge, redact, delete — would claim work no part of this client does.
    /// </summary>
    [Fact]
    public void ADecisionThisClientCannotTakeIsRefused()
    {
        foreach (string decision in new[] { "exclude", "split", "merge", "redact", "delete", "" })
        {
            Assert.ThrowsAny<ArgumentException>(() => Assertion(decision, reason: "because"));
        }
    }

    /// <summary>
    /// The log is the draft's review overlay, in the archive's own format under the archive's own
    /// file name: NDJSON, line feeds only, UTF-8 with no byte order mark.
    /// </summary>
    [Fact]
    public void AppendedDecisionsArePublishedAsCanonicalNdjson()
    {
        var log = new ArchiveReviewLog(_root);
        Assert.Null(log.Head);

        log.Append(Assertion(ArchiveDocuments.RejectDecision, reason: "contains a password"));
        Assert.Equal(FirstAssertionId, log.Head);

        byte[] bytes = File.ReadAllBytes(Path.Combine(_root, ArchiveReviewLog.FileName));
        Assert.Equal("assertions.ndjson", ArchiveReviewLog.FileName);
        Assert.DoesNotContain((byte)'\r', bytes);
        Assert.Equal((byte)'\n', bytes[^1]);
        Assert.NotEqual(Encoding.UTF8.GetPreamble(), bytes.Take(3).ToArray());

        string[] lines = Encoding.UTF8.GetString(bytes).Split('\n', StringSplitOptions.RemoveEmptyEntries);
        JsonObject written = (JsonObject)JsonStrictParser.Parse(Assert.Single(lines))!;
        Assert.Equal("reject", (string?)written["decision"]);
        Assert.Equal(_ids.ArchiveId, (string?)written["target"]!["id"]);
    }

    /// <summary>
    /// The overlay only ever grows, and each decision links to the one it replaces. A second decision
    /// that does not continue from the head would fork the chain, leaving two answers to "what was
    /// decided"; the contract resolves exactly one head, so the fork is refused before it is written.
    /// </summary>
    [Fact]
    public void TheChainOnlyGrowsAndNeverForks()
    {
        var log = new ArchiveReviewLog(_root);
        JsonObject correction = Assertion(
            ArchiveDocuments.CorrectDecision,
            reason: "misread",
            value: "misread");
        log.Append(correction);

        // A decision that ignores the head, and one that repeats an identity already taken.
        Assert.Throws<ArgumentException>(() =>
            log.Append(Assertion(ArchiveDocuments.ConfirmDecision, assertionId: SecondAssertionId)));
        Assert.Throws<ArgumentException>(() => log.Append(correction));

        log.Append(Assertion(
            ArchiveDocuments.ConfirmDecision,
            assertionId: SecondAssertionId,
            supersedes: FirstAssertionId));

        Assert.Equal(SecondAssertionId, log.Head);
        Assert.Equal(
            new[] { "correct", "confirm" },
            log.Assertions.Select(item => (string?)item["decision"]).ToArray());

        // The published file is the whole chain, in the order the reviewer decided.
        string[] lines = File.ReadAllLines(Path.Combine(_root, ArchiveReviewLog.FileName));
        Assert.Equal(2, lines.Length);
        Assert.Contains("\"correct\"", lines[0], StringComparison.Ordinal);
        Assert.Contains("\"confirm\"", lines[1], StringComparison.Ordinal);
    }

    /// <summary>A caller cannot reach into the log and edit a decision it already recorded.</summary>
    [Fact]
    public void ARecordedDecisionIsNotTheCallersToChange()
    {
        var log = new ArchiveReviewLog(_root);
        JsonObject confirmation = Assertion(ArchiveDocuments.ConfirmDecision);
        log.Append(confirmation);

        confirmation["decision"] = "reject";

        Assert.Equal("confirm", (string?)Assert.Single(log.Assertions)["decision"]);
    }

    private JsonObject Assertion(
        string decision,
        string? reason = null,
        string? value = null,
        string? assertionId = null,
        string? supersedes = null) => ArchiveDocuments.ArchiveReviewAssertion(
        _ids,
        assertionId ?? FirstAssertionId,
        decision,
        AuthoredAt,
        ArchiveDocuments.InitialRevision,
        reason,
        value,
        supersedes);
}
