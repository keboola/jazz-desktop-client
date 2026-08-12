using System.Buffers.Binary;
using System.Text;
using JazzCaptureCore.Archive;
using JazzCaptureCoreTests.Support;

namespace JazzCaptureCoreTests;

/// <summary>
/// The v1 container profile from the receiving side: what the reader accepts, and one test per
/// forbidden feature proving it does not.
/// </summary>
/// <remarks>
/// Every rejection case builds the malformed bytes explicitly rather than asserting on a message
/// from some library. A reader that quietly tolerated a ZIP64 sentinel, a prefix, an extra field or a
/// trailing byte would still pass every positive test in this file; only a negative test that hands
/// it exactly that byte sequence can show the hole is closed.
/// </remarks>
public sealed class JazzArchiveContainerReaderTests : IDisposable
{
    private readonly string _workspace = Path.Combine(
        Path.GetTempPath(),
        "jazz-container-reader-tests",
        Guid.NewGuid().ToString("n"));

    public JazzArchiveContainerReaderTests() => Directory.CreateDirectory(_workspace);

    public void Dispose() => JazzArchiveImporter.RemoveTree(_workspace);

    [Fact]
    public void ReadsTheCanonicalContainerFixture()
    {
        string destination = NewDirectory("canonical");

        IReadOnlyDictionary<string, JazzArchiveFileFingerprint> entries =
            JazzArchiveContainerReader.Extract(CanonicalContainerFixturePath(), destination, Limits());

        Assert.Contains("manifest.json", entries.Keys);
        Assert.Contains("inventory.json", entries.Keys);
        Assert.DoesNotContain(entries.Keys, name => name.StartsWith("sync/", StringComparison.Ordinal));

        foreach ((string name, JazzArchiveFileFingerprint fingerprint) in entries)
        {
            string path = Path.Combine(destination, name.Replace('/', Path.DirectorySeparatorChar));
            Assert.Equal(fingerprint.ByteLength, new FileInfo(path).Length);
            Assert.Equal(fingerprint.Sha256, JazzArchiveContainer.Sha256File(path));
        }
    }

    [Fact]
    public void ReadsEveryEntryTheWriterEmitted()
    {
        string source = FixtureDirectory("02-labeled-narration");
        string package = Path.Combine(_workspace, "round-trip.jazz-archive");
        JazzArchiveContainer.Export(source, package);
        string destination = NewDirectory("round-trip");

        IReadOnlyDictionary<string, JazzArchiveFileFingerprint> entries =
            JazzArchiveContainerReader.Extract(package, destination, Limits());

        List<string> expected = Directory
            .EnumerateFiles(source, "*", SearchOption.AllDirectories)
            .Select(path => Path.GetRelativePath(source, path).Replace(Path.DirectorySeparatorChar, '/'))
            .Where(name => !name.StartsWith("sync/", StringComparison.Ordinal))
            .OrderBy(name => name, StringComparer.Ordinal)
            .ToList();

        Assert.Equal(expected, entries.Keys.OrderBy(name => name, StringComparer.Ordinal).ToList());
    }

    [Fact]
    public void AcceptsAFabricatedCanonicalPackage()
    {
        IReadOnlyDictionary<string, JazzArchiveFileFingerprint> entries = Read(Zip32Fabricator.Minimal().Build());

        Assert.Equal(2, entries.Count);
    }

    [Fact]
    public void RejectsAZip64EndOfCentralDirectoryLocator()
    {
        Zip32Fabricator fabricator = Zip32Fabricator.Minimal();
        fabricator.AfterCentralDirectory = Zip32Fabricator.Zip64Locator();

        AssertRefused(
            JazzArchiveImportFailure.UnsupportedZipFeature,
            "ZIP64 end of central directory locator",
            fabricator.Build());
    }

    [Fact]
    public void RejectsAZip64EndOfCentralDirectoryRecord()
    {
        Zip32Fabricator fabricator = Zip32Fabricator.Minimal();
        fabricator.AfterCentralDirectory = Zip32Fabricator
            .Zip64EndOfCentralDirectory()
            .Concat(Zip32Fabricator.Zip64Locator())
            .ToArray();

        AssertRefused(
            JazzArchiveImportFailure.UnsupportedZipFeature,
            "ZIP64 end of central directory locator",
            fabricator.Build());
    }

    [Fact]
    public void RejectsAZip64SentinelInTheEndOfCentralDirectory()
    {
        Zip32Fabricator fabricator = Zip32Fabricator.Minimal();
        fabricator.CentralSizeOverride = 0xFFFF_FFFF;

        AssertRefused(
            JazzArchiveImportFailure.UnsupportedZipFeature,
            "ZIP64 sentinel in EOCD",
            fabricator.Build());
    }

    [Fact]
    public void RejectsAZip64SentinelInACentralHeader()
    {
        Zip32Fabricator fabricator = Zip32Fabricator.Minimal();
        fabricator.Add("blobs/x", "x", entry =>
        {
            entry.CompressedSize = 0xFFFF_FFFF;
            entry.ExpandedSize = 0xFFFF_FFFF;
        });

        AssertRefused(
            JazzArchiveImportFailure.UnsupportedZipFeature,
            "ZIP64 sentinel in central header",
            fabricator.Build());
    }

    [Fact]
    public void RejectsAPrefixBeforeTheFirstLocalHeader()
    {
        Zip32Fabricator fabricator = Zip32Fabricator.Minimal();
        fabricator.Prefix = Encoding.ASCII.GetBytes("MZ self-extracting stub");

        AssertRefused(
            JazzArchiveImportFailure.MalformedZip,
            "non-contiguous local entries",
            fabricator.Build());
    }

    [Fact]
    public void RejectsAGapBetweenEntriesAndTheCentralDirectory()
    {
        Zip32Fabricator fabricator = Zip32Fabricator.Minimal();
        fabricator.Gap = new byte[8];

        AssertRefused(JazzArchiveImportFailure.MalformedZip, "orphan local bytes", fabricator.Build());
    }

    [Fact]
    public void RejectsADataDescriptorFlag()
    {
        Zip32Fabricator fabricator = Zip32Fabricator.Minimal();
        fabricator.Add("blobs/x", "x", entry => entry.Flags |= 0x0008);

        AssertRefused(
            JazzArchiveImportFailure.UnsupportedZipFeature,
            "central header profile",
            fabricator.Build());
    }

    [Fact]
    public void RejectsDataDescriptorBytesAfterAnEntry()
    {
        var payload = Encoding.UTF8.GetBytes("x");
        Zip32Fabricator fabricator = Zip32Fabricator.Minimal();
        fabricator.Add("blobs/x", "x", entry => entry.DataDescriptor = Zip32Fabricator.DataDescriptor(payload));

        AssertRefused(JazzArchiveImportFailure.MalformedZip, string.Empty, fabricator.Build());
    }

    /// <summary>
    /// A real archive comment sits after the EOCD, so the record stops being the final 22 bytes. A
    /// lenient reader scans backwards for the signature and carries on; this one does not, which is
    /// the whole point of pinning the EOCD to the end of the file.
    /// </summary>
    [Fact]
    public void RejectsAnArchiveComment()
    {
        Zip32Fabricator fabricator = Zip32Fabricator.Minimal();
        fabricator.ArchiveComment = Encoding.ASCII.GetBytes("packaged by hand");

        AssertRefused(JazzArchiveImportFailure.MalformedZip, "EOCD signature", fabricator.Build());
    }

    /// <summary>A declared comment length with no comment behind it is refused by name.</summary>
    [Fact]
    public void RejectsADeclaredArchiveCommentLength()
    {
        byte[] package = Zip32Fabricator.Minimal().Build();
        BinaryPrimitives.WriteUInt16LittleEndian(package.AsSpan(package.Length - 2, 2), 16);

        AssertRefused(JazzArchiveImportFailure.UnsupportedZipFeature, "archive comment", package);
    }

    [Fact]
    public void RejectsAnEntryComment()
    {
        Zip32Fabricator fabricator = Zip32Fabricator.Minimal();
        fabricator.Add("blobs/x", "x", entry => entry.CentralComment = Encoding.ASCII.GetBytes("note"));

        AssertRefused(JazzArchiveImportFailure.UnsupportedZipFeature, "entry comment", fabricator.Build());
    }

    [Fact]
    public void RejectsACentralExtraField()
    {
        Zip32Fabricator fabricator = Zip32Fabricator.Minimal();
        fabricator.Add("blobs/x", "x", entry => entry.CentralExtraField = new byte[] { 0x55, 0x54, 0x01, 0x00 });

        AssertRefused(JazzArchiveImportFailure.UnsupportedZipFeature, "central extra field", fabricator.Build());
    }

    [Fact]
    public void RejectsALocalExtraField()
    {
        Zip32Fabricator fabricator = Zip32Fabricator.Minimal();
        fabricator.Add("blobs/x", "x", entry => entry.LocalExtraFieldLength = 4);

        AssertRefused(
            JazzArchiveImportFailure.UnsupportedZipFeature,
            "local extra field",
            fabricator.Build());
    }

    [Fact]
    public void RejectsADigitalSignatureRecord()
    {
        Zip32Fabricator fabricator = Zip32Fabricator.Minimal();
        fabricator.AfterCentralDirectory = Zip32Fabricator.DigitalSignatureRecord();
        fabricator.CountAfterCentralDirectory = true;
        fabricator.EntryCountOverride = 3;

        AssertRefused(
            JazzArchiveImportFailure.UnsupportedZipFeature,
            "central header signature 0x05054b50",
            fabricator.Build());
    }

    [Fact]
    public void RejectsTrailingBytesAfterTheEndOfCentralDirectory()
    {
        Zip32Fabricator fabricator = Zip32Fabricator.Minimal();
        fabricator.Trailer = Encoding.ASCII.GetBytes("appended");

        AssertRefused(JazzArchiveImportFailure.MalformedZip, "EOCD signature", fabricator.Build());
    }

    [Fact]
    public void RejectsADirectoryEntry()
    {
        Zip32Fabricator fabricator = Zip32Fabricator.Minimal();
        fabricator.Add("blobs/", string.Empty, entry => entry.ExternalAttributes = Zip32Profile.DirectoryAttributes);

        AssertRefused(JazzArchiveImportFailure.UnsafeEntry, "external attributes", fabricator.Build());
    }

    [Fact]
    public void RejectsADirectoryNameEvenWithRegularFileAttributes()
    {
        Zip32Fabricator fabricator = Zip32Fabricator.Minimal();
        fabricator.Add("blobs/", string.Empty);

        AssertRefused(JazzArchiveImportFailure.UnsafeEntry, "blobs/", fabricator.Build());
    }

    [Fact]
    public void RejectsASymlinkEntry()
    {
        Zip32Fabricator fabricator = Zip32Fabricator.Minimal();
        fabricator.Add("blobs/link", "../../etc/passwd", entry =>
            entry.ExternalAttributes = Zip32Profile.SymlinkAttributes);

        AssertRefused(JazzArchiveImportFailure.UnsafeEntry, "external attributes", fabricator.Build());
    }

    [Fact]
    public void RejectsAnEncryptedEntry()
    {
        Zip32Fabricator fabricator = Zip32Fabricator.Minimal();
        fabricator.Add("blobs/x", "x", entry => entry.Flags |= 0x0001);

        AssertRefused(
            JazzArchiveImportFailure.UnsupportedZipFeature,
            "central header profile",
            fabricator.Build());
    }

    [Fact]
    public void RejectsADeflatedEntry()
    {
        Zip32Fabricator fabricator = Zip32Fabricator.Minimal();
        fabricator.Add("blobs/x", "x", entry => entry.Method = 8);

        AssertRefused(
            JazzArchiveImportFailure.UnsupportedZipFeature,
            "central header profile",
            fabricator.Build());
    }

    [Fact]
    public void RejectsUnequalCompressedAndExpandedSizes()
    {
        Zip32Fabricator fabricator = Zip32Fabricator.Minimal();
        fabricator.Add("blobs/x", "xyz", entry => entry.CompressedSize = 2);

        AssertRefused(JazzArchiveImportFailure.UnsupportedZipFeature, "compressed entry", fabricator.Build());
    }

    [Fact]
    public void RejectsADuplicateEntryName()
    {
        Zip32Fabricator fabricator = Zip32Fabricator.Minimal();
        fabricator.Add("blobs/x", "one");
        fabricator.Add("blobs/x", "two");

        AssertRefused(JazzArchiveImportFailure.DuplicateEntry, "blobs/x", fabricator.Build());
    }

    [Fact]
    public void RejectsCaseCollidingEntryNames()
    {
        Zip32Fabricator fabricator = Zip32Fabricator.Minimal();
        fabricator.Add("blobs/Report", "one");
        fabricator.Add("blobs/report", "two");

        AssertRefused(JazzArchiveImportFailure.DuplicateEntry, "blobs/report", fabricator.Build());
    }

    [Theory]
    [InlineData("sessions\\s-1\\records.ndjson")]
    [InlineData("../manifest.json")]
    [InlineData("/manifest.json")]
    [InlineData("sessions/../manifest.json")]
    [InlineData("sessions//records.ndjson")]
    [InlineData("bad name.json")]
    [InlineData("sync/delivery.ndjson")]
    public void RejectsANonPortableEntryName(string name)
    {
        Zip32Fabricator fabricator = Zip32Fabricator.Minimal();
        fabricator.Add(name, "x");

        AssertRefused(JazzArchiveImportFailure.UnsafeEntry, string.Empty, fabricator.Build());
    }

    [Fact]
    public void RejectsEntriesOutOfAscendingOrder()
    {
        var fabricator = new Zip32Fabricator { PreserveOrder = true };
        fabricator.Add("manifest.json", "{}");
        fabricator.Add("inventory.json", "{}");

        AssertRefused(JazzArchiveImportFailure.MalformedZip, "entry order", fabricator.Build());
    }

    [Fact]
    public void RejectsALocalHeaderThatDisagreesWithItsCentralHeader()
    {
        Zip32Fabricator fabricator = Zip32Fabricator.Minimal();
        fabricator.Add("blobs/x", "x", entry => entry.LocalCrc32 = 0x1234_5678);

        AssertRefused(
            JazzArchiveImportFailure.MalformedZip,
            "local and central headers disagree",
            fabricator.Build());
    }

    [Fact]
    public void RejectsALocalNameThatDisagreesWithItsCentralName()
    {
        Zip32Fabricator fabricator = Zip32Fabricator.Minimal();
        fabricator.Add("blobs/x", "x", entry => entry.LocalNameBytes = Encoding.UTF8.GetBytes("blobs/y"));

        AssertRefused(
            JazzArchiveImportFailure.MalformedZip,
            "local and central filenames disagree",
            fabricator.Build());
    }

    [Fact]
    public void RejectsAnEntryWhoseBytesDoNotMatchItsCrc()
    {
        Zip32Fabricator fabricator = Zip32Fabricator.Minimal();
        byte[] package = fabricator.Build();

        // The first local entry is "inventory.json"; its body starts after the 30-byte header and
        // the 14-byte name. Flipping one payload byte leaves every header field intact, so nothing
        // but the CRC can catch it.
        int payload = 30 + "inventory.json".Length;
        package[payload] ^= 0xFF;

        AssertRefused(JazzArchiveImportFailure.IntegrityMismatch, "CRC-32 inventory.json", package);
    }

    [Fact]
    public void RejectsAPackageWithoutAManifest()
    {
        var fabricator = new Zip32Fabricator();
        fabricator.Add("inventory.json", "{}");

        AssertRefused(
            JazzArchiveImportFailure.InvalidArchive,
            "missing manifest.json",
            fabricator.Build());
    }

    [Fact]
    public void RejectsAMultiDiskEndOfCentralDirectory()
    {
        Zip32Fabricator fabricator = Zip32Fabricator.Minimal();
        fabricator.DiskNumberOverride = 1;

        AssertRefused(JazzArchiveImportFailure.UnsupportedZipFeature, "multi-disk EOCD", fabricator.Build());
    }

    [Fact]
    public void RejectsDisagreeingEndOfCentralDirectoryCounts()
    {
        Zip32Fabricator fabricator = Zip32Fabricator.Minimal();
        fabricator.EntriesOnDiskOverride = 1;

        AssertRefused(JazzArchiveImportFailure.UnsupportedZipFeature, "multi-disk EOCD", fabricator.Build());
    }

    [Fact]
    public void RejectsAnEmptyPackage()
    {
        AssertRefused(JazzArchiveImportFailure.ArchiveTooLarge, "0 bytes", Array.Empty<byte>());
    }

    [Fact]
    public void RejectsAPackageShorterThanAnEndOfCentralDirectory()
    {
        AssertRefused(JazzArchiveImportFailure.MalformedZip, "missing EOCD", new byte[10]);
    }

    [Fact]
    public void RejectsAnEntryCountAboveTheLimit()
    {
        Zip32Fabricator fabricator = Zip32Fabricator.Minimal();

        JazzArchiveImportException error = Assert.Throws<JazzArchiveImportException>(
            () => Read(fabricator.Build(), Limits() with { MaxEntries = 1 }));

        Assert.Equal(JazzArchiveImportFailure.EntryLimitExceeded, error.Failure);
        Assert.Contains("entry count", error.Message, StringComparison.Ordinal);
    }

    /// <summary>
    /// A tiny package that <em>declares</em> a half-gigabyte entry is refused on the declaration.
    /// Nothing is allocated, no body is read, and the file on disk stays a few hundred bytes.
    /// </summary>
    [Fact]
    public void RejectsADeclaredEntrySizeAboveTheLimitWithoutReadingIt()
    {
        Zip32Fabricator fabricator = Zip32Fabricator.Minimal();
        fabricator.Add("blobs/huge", "x", entry =>
        {
            entry.CompressedSize = 1_000_000_000;
            entry.ExpandedSize = 1_000_000_000;
        });

        byte[] package = fabricator.Build();
        Assert.True(package.Length < 1024);

        AssertRefused(JazzArchiveImportFailure.EntryLimitExceeded, "entry bytes 1000000000", package);
    }

    /// <summary>
    /// Nine entries, each declaring 500 MiB — every one inside the per-entry bound, together past the
    /// 4 GiB expanded total. The running sum is what stops it.
    /// </summary>
    [Fact]
    public void RejectsADeclaredExpandedTotalAboveTheLimit()
    {
        const uint HalfGigabyte = 500 * 1024 * 1024;
        Zip32Fabricator fabricator = Zip32Fabricator.Minimal();
        for (int index = 0; index < 9; index++)
        {
            fabricator.Add("blobs/entry-" + index, "x", entry =>
            {
                entry.CompressedSize = HalfGigabyte;
                entry.ExpandedSize = HalfGigabyte;
            });
        }

        byte[] package = fabricator.Build();
        Assert.True(package.Length < 2048);

        AssertRefused(JazzArchiveImportFailure.EntryLimitExceeded, "total expanded bytes", package);
    }

    [Fact]
    public void RejectsAJsonDocumentAboveTheLimit()
    {
        Zip32Fabricator fabricator = Zip32Fabricator.Minimal();
        fabricator.Add("sessions/s-1/session.json", "x", entry =>
        {
            entry.CompressedSize = 64 * 1024 * 1024;
            entry.ExpandedSize = 64 * 1024 * 1024;
        });

        AssertRefused(
            JazzArchiveImportFailure.EntryLimitExceeded,
            "sessions/s-1/session.json",
            fabricator.Build());
    }

    [Fact]
    public void RejectsAPackageAboveTheArchiveLimit()
    {
        byte[] package = Zip32Fabricator.Minimal().Build();

        JazzArchiveImportException error = Assert.Throws<JazzArchiveImportException>(
            () => Read(package, Limits() with { MaxArchiveBytes = 16 }));

        Assert.Equal(JazzArchiveImportFailure.ArchiveTooLarge, error.Failure);
    }

    [Fact]
    public void RejectsACentralOffsetThatDoesNotCloseTheLayout()
    {
        Zip32Fabricator fabricator = Zip32Fabricator.Minimal();
        byte[] package = fabricator.Build();

        // Move the declared central directory forward by four bytes without moving anything else.
        int offsetField = package.Length - 22 + 16;
        uint declared = BinaryPrimitives.ReadUInt32LittleEndian(package.AsSpan(offsetField, 4));
        BinaryPrimitives.WriteUInt32LittleEndian(package.AsSpan(offsetField, 4), declared + 4);

        AssertRefused(JazzArchiveImportFailure.MalformedZip, "central directory", package);
    }

    private void AssertRefused(JazzArchiveImportFailure failure, string messageFragment, byte[] package)
    {
        JazzArchiveImportException error = Assert.Throws<JazzArchiveImportException>(() => Read(package));

        Assert.Equal(failure, error.Failure);
        if (messageFragment.Length > 0)
        {
            Assert.Contains(messageFragment, error.Message, StringComparison.Ordinal);
        }
    }

    private IReadOnlyDictionary<string, JazzArchiveFileFingerprint> Read(
        byte[] package,
        JazzArchiveImportLimits? limits = null)
    {
        string name = Guid.NewGuid().ToString("n");
        string path = Path.Combine(_workspace, name + ".jazz-archive");
        File.WriteAllBytes(path, package);
        return JazzArchiveContainerReader.Extract(path, NewDirectory(name), limits ?? Limits());
    }

    private string NewDirectory(string name)
    {
        string path = Path.Combine(_workspace, "out-" + name);
        Directory.CreateDirectory(path);
        return path;
    }

    private static JazzArchiveImportLimits Limits() => new();

    private static string FixtureDirectory(string name) =>
        Path.Combine(ContractPaths.Root(), "contract", "archive", "fixtures", name);

    private static string CanonicalContainerFixturePath() => Path.Combine(
        ContractPaths.Root(),
        "contract",
        "archive",
        "container",
        "fixtures",
        "01-canonical-v1.jazz-archive");
}
