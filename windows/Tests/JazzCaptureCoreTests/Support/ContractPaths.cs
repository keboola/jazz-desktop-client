namespace JazzCaptureCoreTests.Support;

/// <summary>
/// Locates the shared <c>contract/</c> tree from a test binary.
/// </summary>
/// <remarks>
/// The tests run from <c>bin/&lt;config&gt;/&lt;tfm&gt;/</c>, which sits six directories below the
/// repository root. Walking a bounded number of parents keeps the lookup independent of the
/// build configuration, the target framework moniker, and the checkout location (a git worktree
/// is not the primary checkout, so no path may be hardcoded).
/// </remarks>
public static class ContractPaths
{
    /// <summary>Maximum number of parent directories inspected before giving up.</summary>
    private const int MaxParentWalk = 8;

    /// <summary>Marker that identifies the repository root: it must contain the fixture directory.</summary>
    private static readonly string[] MarkerSegments = { "contract", "conformance", "fixtures" };

    /// <summary>The repository root — the directory that contains <c>contract/</c>.</summary>
    /// <exception cref="DirectoryNotFoundException">
    /// Thrown when no ancestor within <see cref="MaxParentWalk"/> levels contains
    /// <c>contract/conformance/fixtures</c>.
    /// </exception>
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
            $"Could not locate 'contract/conformance/fixtures' within {MaxParentWalk} parents of '{AppContext.BaseDirectory}'.");
    }

    /// <summary>Absolute path of <c>contract/conformance/fixtures</c>.</summary>
    public static string ConformanceFixturesDirectory() =>
        Path.Combine(new[] { Root() }.Concat(MarkerSegments).ToArray());

    /// <summary>Every conformance fixture file name (not a full path), sorted ordinally.</summary>
    public static IReadOnlyList<string> ConformanceFixtureNames()
    {
        string directory = ConformanceFixturesDirectory();
        List<string> names = Directory
            .EnumerateFiles(directory, "*.json", SearchOption.TopDirectoryOnly)
            .Select(Path.GetFileName)
            .Select(name => name!)
            .ToList();

        names.Sort(StringComparer.Ordinal);
        return names;
    }
}
