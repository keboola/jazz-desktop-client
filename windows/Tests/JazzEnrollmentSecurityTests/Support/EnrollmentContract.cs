using System.Text;
using System.Text.Json.Nodes;
using JazzCaptureCore.Json;

namespace JazzEnrollmentSecurityTests.Support;

/// <summary>
/// Locates and loads the shared <c>contract/enrollment/</c> vectors from a test binary.
/// </summary>
/// <remarks>
/// These are the same files <c>contract/validate_schemas.py</c> validates and the same files the
/// macOS tests read. Copying them into the test project would let the two platforms drift apart
/// silently, which is exactly the failure this module exists to prevent.
/// </remarks>
public static class EnrollmentContract
{
    private const int MaxParentWalk = 8;

    private static readonly string[] MarkerSegments = { "contract", "enrollment", "schema" };

    /// <summary>The repository root, found by walking up from the test binary.</summary>
    public static string Root()
    {
        DirectoryInfo? current = new(AppContext.BaseDirectory);
        for (int level = 0; level <= MaxParentWalk && current is not null; level++)
        {
            string candidate = Path.Combine(new[] { current.FullName }.Concat(MarkerSegments).ToArray());
            if (Directory.Exists(candidate))
            {
                return current.FullName;
            }

            current = current.Parent;
        }

        throw new DirectoryNotFoundException(
            $"Could not locate 'contract/enrollment/schema' within {MaxParentWalk} parents of '{AppContext.BaseDirectory}'.");
    }

    /// <summary>Absolute path under <c>contract/enrollment/</c>.</summary>
    public static string Path_(params string[] segments) =>
        Path.Combine(new[] { Root(), "contract", "enrollment" }.Concat(segments).ToArray());

    /// <summary>Every signed-bundle golden fixture file name, sorted ordinally.</summary>
    public static IReadOnlyList<string> SignedFixtureNames() => SortedJsonNames(Path_("fixtures"));

    /// <summary>Every MVP handoff fixture file name, sorted ordinally.</summary>
    public static IReadOnlyList<string> MvpFixtureNames() => SortedJsonNames(Path_("mvp-fixtures"));

    /// <summary>Reads and strictly parses a contract document.</summary>
    public static JsonObject ReadObject(params string[] segments)
    {
        byte[] bytes = File.ReadAllBytes(Path_(segments));
        return JsonStrictParser.Parse(bytes) as JsonObject
            ?? throw new FormatException($"'{string.Join('/', segments)}' is not a JSON object.");
    }

    /// <summary>
    /// Serializes <paramref name="value"/> the way the server and the macOS client do: canonical
    /// JSON, UTF-8, no padding whitespace.
    /// </summary>
    public static byte[] Canonical(JsonNode? value) =>
        new UTF8Encoding(false).GetBytes(JsonCanonicalizer.Canonicalize(value));

    /// <summary>Canonical bytes of <paramref name="value"/> as text.</summary>
    public static string CanonicalText(JsonNode? value) => JsonCanonicalizer.Canonicalize(value);

    private static IReadOnlyList<string> SortedJsonNames(string directory)
    {
        List<string> names = Directory
            .EnumerateFiles(directory, "*.json", SearchOption.TopDirectoryOnly)
            .Select(path => System.IO.Path.GetFileName(path)!)
            .ToList();
        names.Sort(StringComparer.Ordinal);
        return names;
    }
}
