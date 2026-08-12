using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization.Metadata;
using JazzCaptureCore.Journal;

namespace JazzCaptureCore.Archive;

/// <summary>
/// The append-only review overlay of one archive while it is still a draft.
/// </summary>
/// <remarks>
/// <para>
/// A review decision is a contract assertion, and the place a contract assertion belongs is
/// <c>sessions/&lt;dir&gt;/assertions.ndjson</c> inside the archive. A finalized archive is sealed by
/// its own inventory and content digest, so the decision has to exist <em>before</em> finalization
/// rather than being appended to a sealed package afterwards — and a capture the reviewer refuses is
/// never finalized at all, so its decision needs somewhere to live regardless. This is that place:
/// the same documents, in the same NDJSON format, under the same file name, beside the draft they
/// are about. Finalization copies the lines into the archive verbatim, which is why the two can
/// never disagree.
/// </para>
/// <para>
/// The log is append-only in the sense the contract means: nothing is ever edited or removed, and a
/// reviewer who changes their mind adds a link to the <c>supersedes</c> chain instead. The whole set
/// is republished atomically on each append because it is at most a handful of lines, and a torn
/// review overlay is a worse outcome than rewriting a few hundred bytes.
/// </para>
/// </remarks>
public sealed class ArchiveReviewLog
{
    /// <summary>File name of the overlay, identical to the one inside the archive.</summary>
    public const string FileName = ArchiveWriter.AssertionsFileName;

    private static readonly UTF8Encoding Utf8 = new(encoderShouldEmitUTF8Identifier: false);

    private static readonly JsonSerializerOptions Compact = new()
    {
        WriteIndented = false,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        TypeInfoResolver = new DefaultJsonTypeInfoResolver(),
    };

    private readonly string _path;
    private readonly List<JsonObject> _assertions = new();

    /// <summary>Opens the overlay of the draft held in <paramref name="directory"/>.</summary>
    /// <param name="directory">The draft's own directory; created when absent.</param>
    public ArchiveReviewLog(string directory)
    {
        ArgumentException.ThrowIfNullOrEmpty(directory);
        _path = Path.Combine(directory, FileName);
    }

    /// <summary>Every decision taken so far, oldest first.</summary>
    public IReadOnlyList<JsonObject> Assertions => _assertions;

    /// <summary>
    /// The head of the archive-scoped chain — the decision a new one would supersede — or
    /// <see langword="null"/> while nobody has decided anything.
    /// </summary>
    /// <remarks>
    /// The head is the last link rather than the newest timestamp: two decisions taken inside the
    /// same clock tick would order arbitrarily by time, and the chain is what the contract resolves.
    /// </remarks>
    public string? Head { get; private set; }

    /// <summary>
    /// Appends one decision and makes it durable before returning.
    /// </summary>
    /// <param name="assertion">
    /// An archive-scoped assertion, normally from
    /// <see cref="ArchiveDocuments.ArchiveReviewAssertion"/>.
    /// </param>
    /// <exception cref="ArgumentException">
    /// The assertion has no identity, repeats one already taken, or does not continue the chain.
    /// </exception>
    public void Append(JsonObject assertion)
    {
        ArgumentNullException.ThrowIfNull(assertion);

        var assertionId = (string?)assertion["assertionId"]
            ?? throw new ArgumentException("an assertion has no identity", nameof(assertion));

        if (_assertions.Any(existing => (string?)existing["assertionId"] == assertionId))
        {
            throw new ArgumentException(
                $"assertion '{assertionId}' is already recorded",
                nameof(assertion));
        }

        // A decision that does not continue from the current head is a branch, and a branched
        // overlay has two answers to "what was decided": the contract resolves exactly one head, so
        // the fork is refused here rather than published and rejected later.
        if ((string?)assertion["supersedes"] != Head)
        {
            throw new ArgumentException(
                $"assertion '{assertionId}' does not supersede the current review head",
                nameof(assertion));
        }

        _assertions.Add((JsonObject)assertion.DeepClone());
        Head = assertionId;
        Publish();
    }

    private void Publish()
    {
        var text = new StringBuilder();
        foreach (JsonObject assertion in _assertions)
        {
            text.Append(assertion.ToJsonString(Compact)).Append('\n');
        }

        Durability.ReplaceAtomic(_path, Utf8.GetBytes(text.ToString()));
    }
}
