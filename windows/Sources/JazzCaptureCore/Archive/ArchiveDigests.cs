using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using JazzCaptureCore.Json;

namespace JazzCaptureCore.Archive;

/// <summary>
/// The closure digests of a capture commit (ANNEX-ARCHIVE section 3.2/3.3).
/// </summary>
/// <remarks>
/// Two of the archive's four digests hash raw file bytes; these two hash a newline-terminated line
/// list built from the RFC 8785 canonical form of the parsed documents. Because the lines are
/// derived from canonical JSON rather than from the bytes on disk, a producer may format
/// <c>records.ndjson</c> however it likes and still agree with the validator.
/// </remarks>
public static class ArchiveDigests
{
    private const string StreamIdKey = "streamId";
    private const string StreamSequenceKey = "streamSequence";
    private const string ObservationIdKey = "observationId";
    private const string ArtifactIdKey = "artifactId";
    private const string ContentKey = "content";
    private const string Sha256Key = "sha256";

    /// <summary>
    /// SHA-256 of the UTF-8 concatenation of <paramref name="lines"/>, each terminated by a single
    /// line feed — the last line included. An empty sequence hashes the empty byte string.
    /// </summary>
    public static string TextDigest(IEnumerable<string> lines)
    {
        ArgumentNullException.ThrowIfNull(lines);

        var text = new StringBuilder();
        foreach (string line in lines)
        {
            text.Append(line).Append('\n');
        }

        return Hex(SHA256.HashData(new UTF8Encoding(false).GetBytes(text.ToString())));
    }

    /// <summary>
    /// The capture commit's <c>orderedObservationDigest</c>: one
    /// <c>streamId:streamSequence:observationId:sha256(JCS(record))</c> line per record, ordered by
    /// stream identifier and then by stream sequence.
    /// </summary>
    /// <exception cref="ArgumentException">A record is missing an identity field.</exception>
    public static string OrderedObservationDigest(IReadOnlyList<JsonObject> records)
    {
        ArgumentNullException.ThrowIfNull(records);

        List<JsonObject> ordered = records
            .OrderBy(record => Text(record, StreamIdKey), StringComparer.Ordinal)
            .ThenBy(record => Number(record, StreamSequenceKey))
            .ToList();

        return TextDigest(ordered.Select(record => string.Join(
            ':',
            Text(record, StreamIdKey),
            Number(record, StreamSequenceKey).ToString(CultureInfo.InvariantCulture),
            Text(record, ObservationIdKey),
            JsonCanonicalizer.Sha256Hex(record))));
    }

    /// <summary>
    /// The capture commit's <c>artifactSetDigest</c>: one <c>artifactId:content.sha256</c> line per
    /// artifact, ordered by artifact identifier. The empty set hashes the empty byte string.
    /// </summary>
    /// <exception cref="ArgumentException">An artifact is missing its identity or content digest.</exception>
    public static string ArtifactSetDigest(IReadOnlyList<JsonObject> artifacts)
    {
        ArgumentNullException.ThrowIfNull(artifacts);

        List<JsonObject> ordered = artifacts
            .OrderBy(artifact => Text(artifact, ArtifactIdKey), StringComparer.Ordinal)
            .ToList();

        return TextDigest(ordered.Select(artifact => string.Concat(
            Text(artifact, ArtifactIdKey),
            ":",
            Text(Child(artifact, ContentKey), Sha256Key))));
    }

    private static JsonObject Child(JsonObject value, string key) =>
        value[key] as JsonObject
        ?? throw new ArgumentException($"archive document is missing object '{key}'", nameof(value));

    private static string Text(JsonObject value, string key) =>
        value[key] is JsonValue node && node.TryGetValue(out string? text)
            ? text
            : throw new ArgumentException($"archive document is missing string '{key}'", nameof(value));

    private static long Number(JsonObject value, string key) =>
        value[key] is JsonValue node && node.TryGetValue(out long number)
            ? number
            : throw new ArgumentException($"archive document is missing integer '{key}'", nameof(value));

    private static string Hex(byte[] bytes) => Convert.ToHexString(bytes).ToLowerInvariant();
}
