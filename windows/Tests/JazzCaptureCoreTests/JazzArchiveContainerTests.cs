using System.Text;

using JazzCaptureCore.Archive;

namespace JazzCaptureCoreTests;

/// <summary>
/// Byte-level conformance for the ".jazz-archive" container profile v1.
/// The golden vector pins every container rule at once: struct layout, entry order,
/// the excluded "sync/" subtree, and the absence of ZIP64/data-descriptor/extra fields.
/// </summary>
public sealed class JazzArchiveContainerTests : IDisposable
{
    private const string GoldenSha256 = "49453bce721306d13da8befa69fc9632351a9ef477017aac2f3e4a1c375aaeda";
    private const int GoldenByteCount = 25072;
    private const int MaxContractRootDepth = 8;

    private readonly string _workspace = Path.Combine(
        Path.GetTempPath(),
        "jazz-container-tests",
        Guid.NewGuid().ToString("n"));

    public JazzArchiveContainerTests() => Directory.CreateDirectory(_workspace);

    public void Dispose()
    {
        if (Directory.Exists(_workspace))
        {
            Directory.Delete(_workspace, recursive: true);
        }
    }

    [Fact]
    public void ExportReproducesTheCanonicalContainerFixtureByteForByte()
    {
        string output = Path.Combine(_workspace, "export.jazz-archive");

        JazzArchiveContainer.Export(LabeledNarrationFixtureDirectory(), output);

        byte[] produced = File.ReadAllBytes(output);
        byte[] golden = File.ReadAllBytes(CanonicalContainerFixturePath());
        Assert.Equal(GoldenByteCount, golden.Length);
        AssertBytesEqual(golden, produced);
        Assert.Equal(GoldenByteCount, produced.Length);
        Assert.Equal(GoldenSha256, JazzArchiveContainer.Sha256File(output));
    }

    [Fact]
    public void ExportIsDeterministicAcrossRuns()
    {
        string source = LabeledNarrationFixtureDirectory();
        string first = Path.Combine(_workspace, "first.jazz-archive");
        string second = Path.Combine(_workspace, "second.jazz-archive");

        JazzArchiveContainer.Export(source, first);
        JazzArchiveContainer.Export(source, second);

        AssertBytesEqual(File.ReadAllBytes(first), File.ReadAllBytes(second));
        Assert.Equal(
            JazzArchiveContainer.Sha256File(first),
            JazzArchiveContainer.Sha256File(second));
    }

    [Fact]
    public void ExportOverwritesAnExistingOutputFile()
    {
        string output = Path.Combine(_workspace, "existing.jazz-archive");
        File.WriteAllBytes(output, new byte[] { 1, 2, 3 });

        JazzArchiveContainer.Export(LabeledNarrationFixtureDirectory(), output);

        Assert.Equal(GoldenSha256, JazzArchiveContainer.Sha256File(output));
    }

    [Theory]
    [InlineData("manifest.json")]
    [InlineData("inventory.json")]
    [InlineData("sessions/s-1/records.ndjson")]
    [InlineData("blobs/sha256/ed/edeaaff3f1774ad2888673770c6d64097e391bc362d7d6fb34982ddf0efd18cb")]
    [InlineData("a-b_c.d/E9")]
    public void PortableNamesAreAccepted(string name)
    {
        Assert.True(JazzArchiveContainer.IsPortableEntryName(name));
    }

    [Theory]
    [InlineData("sessions\\s-1\\records.ndjson")]
    [InlineData("manifest\\.json")]
    [InlineData("..")]
    [InlineData("../manifest.json")]
    [InlineData("sessions/../manifest.json")]
    [InlineData("/manifest.json")]
    [InlineData("sessions/")]
    [InlineData("sessions//records.ndjson")]
    [InlineData(".")]
    [InlineData("sessions/./records.ndjson")]
    [InlineData("")]
    [InlineData("bad name.json")]
    [InlineData("café.json")]
    [InlineData("manifest\0.json")]
    public void NonPortableNamesAreRejected(string name)
    {
        Assert.False(JazzArchiveContainer.IsPortableEntryName(name));
    }

    [Fact]
    public void ExportRejectsANonPortableEntryName()
    {
        string source = Path.Combine(_workspace, "non-portable");
        WriteFile(source, "manifest.json", "{}");
        WriteFile(source, "inventory.json", "{}");
        WriteFile(source, "bad name.json", "{}");

        InvalidOperationException error = Assert.Throws<InvalidOperationException>(
            () => JazzArchiveContainer.Export(source, Path.Combine(_workspace, "out.jazz-archive")));

        Assert.Contains("bad name.json", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void ExportRequiresManifestAndInventoryAtTheRoot()
    {
        string source = Path.Combine(_workspace, "incomplete");
        WriteFile(source, "manifest.json", "{}");

        Assert.Throws<InvalidOperationException>(
            () => JazzArchiveContainer.Export(source, Path.Combine(_workspace, "out.jazz-archive")));
    }

    [Fact]
    public void ExportSkipsTheSyncSubtree()
    {
        string source = Path.Combine(_workspace, "with-sync");
        WriteFile(source, "manifest.json", "{}");
        WriteFile(source, "inventory.json", "{}");
        string withoutSync = Path.Combine(_workspace, "without-sync.jazz-archive");
        JazzArchiveContainer.Export(source, withoutSync);

        WriteFile(source, Path.Combine("sync", "delivery.ndjson"), "{\"a\":1}\n");
        string withSync = Path.Combine(_workspace, "with-sync.jazz-archive");
        JazzArchiveContainer.Export(source, withSync);

        AssertBytesEqual(File.ReadAllBytes(withoutSync), File.ReadAllBytes(withSync));
    }

    [Fact]
    public void ExportRejectsAnEmptyArchiveDirectory()
    {
        string source = Path.Combine(_workspace, "empty");
        Directory.CreateDirectory(source);

        Assert.Throws<InvalidOperationException>(
            () => JazzArchiveContainer.Export(source, Path.Combine(_workspace, "out.jazz-archive")));
    }

    [Fact]
    public void ExportRejectsAMissingArchiveDirectory()
    {
        Assert.Throws<DirectoryNotFoundException>(
            () => JazzArchiveContainer.Export(
                Path.Combine(_workspace, "absent"),
                Path.Combine(_workspace, "out.jazz-archive")));
    }

    [Fact]
    public void Sha256FileMatchesTheCommittedSidecarOfTheGoldenFixture()
    {
        Assert.Equal(GoldenSha256, JazzArchiveContainer.Sha256File(CanonicalContainerFixturePath()));
    }

    private static void AssertBytesEqual(byte[] expected, byte[] actual)
    {
        int shared = Math.Min(expected.Length, actual.Length);
        for (int index = 0; index < shared; index++)
        {
            if (expected[index] != actual[index])
            {
                Assert.Fail(
                    $"container bytes diverge at offset {index}: expected 0x{expected[index]:x2}, got 0x{actual[index]:x2}");
            }
        }

        Assert.Equal(expected.Length, actual.Length);
    }

    private static void WriteFile(string root, string relativePath, string content)
    {
        string path = Path.Combine(root, relativePath);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, content, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
    }

    private static string LabeledNarrationFixtureDirectory() =>
        Path.Combine(ContractRoot(), "archive", "fixtures", "02-labeled-narration");

    private static string CanonicalContainerFixturePath() =>
        Path.Combine(ContractRoot(), "archive", "container", "fixtures", "01-canonical-v1.jazz-archive");

    /// <summary>
    /// Locates the repository "contract" directory by walking up at most
    /// <see cref="MaxContractRootDepth"/> parents from the test assembly location.
    /// </summary>
    private static string ContractRoot()
    {
        DirectoryInfo? directory = new(AppContext.BaseDirectory);
        for (int depth = 0; depth <= MaxContractRootDepth && directory is not null; depth++)
        {
            string candidate = Path.Combine(directory.FullName, "contract");
            if (Directory.Exists(Path.Combine(candidate, "archive", "container", "fixtures")))
            {
                return candidate;
            }

            directory = directory.Parent;
        }

        throw new DirectoryNotFoundException(
            $"contract/archive/container/fixtures not found within {MaxContractRootDepth} parents of {AppContext.BaseDirectory}");
    }
}
