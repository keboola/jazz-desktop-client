using System.Text;
using System.Text.Json.Nodes;
using JazzCaptureCore.Archive;
using JazzCaptureCore.Json;
using JazzCaptureCoreTests.Support;

namespace JazzCaptureCoreTests;

/// <summary>
/// End-to-end import: the real contract fixtures packaged by the writer and read back, every digest
/// tampering case, idempotence, conflict, and the ingest bounds.
/// </summary>
/// <remarks>
/// Import is entirely portable, so nothing here is deferred to a Windows host. The fixtures are the
/// same bytes the macOS client and the Python validator agree on, which makes acceptance a real
/// cross-implementation claim rather than a self-consistency check between this reader and this
/// writer.
/// </remarks>
public sealed class JazzArchiveImporterTests : IDisposable
{
    private readonly string _workspace = Path.Combine(
        Path.GetTempPath(),
        "jazz-importer-tests",
        Guid.NewGuid().ToString("n"));

    public JazzArchiveImporterTests() => Directory.CreateDirectory(_workspace);

    public void Dispose() => JazzArchiveImporter.RemoveTree(_workspace);

    [Theory]
    [InlineData("01-minimal-desktop")]
    [InlineData("02-labeled-narration")]
    [InlineData("03-capture-coach")]
    [InlineData("04-meeting-screen-share")]
    public void ImportsEveryContractFixture(string fixture)
    {
        var importer = new JazzArchiveImporter(Store());

        JazzArchiveImportResult result = importer.Import(PackageOf(fixture));

        JsonObject manifest = ArchiveFixtures.Read(ArchiveFixtures.Directory(fixture), "manifest.json");
        Assert.Equal(JazzArchiveImportDisposition.Imported, result.Disposition);
        Assert.Equal((string?)manifest["archiveId"], result.Snapshot.ArchiveId);
        Assert.Equal((string?)manifest["contentDigest"], result.Snapshot.ContentDigest);
        Assert.NotEmpty(result.Snapshot.Captures);
        Assert.All(result.Snapshot.Captures, capture => Assert.NotEmpty(capture.Records));
    }

    /// <summary>
    /// Export a fixture, import it back, and prove the published snapshot is the fixture: the same
    /// files, byte for byte, minus the <c>sync/</c> working state a producer must never ship.
    /// </summary>
    [Fact]
    public void RoundTripsAFixtureThroughTheWriterAndBack()
    {
        const string Fixture = "02-labeled-narration";
        var importer = new JazzArchiveImporter(Store());

        JazzArchiveImportResult result = importer.Import(PackageOf(Fixture));

        string source = ArchiveFixtures.Directory(Fixture);
        List<string> expected = Directory
            .EnumerateFiles(source, "*", SearchOption.AllDirectories)
            .Select(path => Path.GetRelativePath(source, path).Replace(Path.DirectorySeparatorChar, '/'))
            .Where(name => !name.StartsWith("sync/", StringComparison.Ordinal))
            .OrderBy(name => name, StringComparer.Ordinal)
            .ToList();

        Assert.Equal(
            expected,
            result.Snapshot.FileFingerprints.Keys.OrderBy(name => name, StringComparer.Ordinal).ToList());

        foreach (string name in expected)
        {
            string published = Path.Combine(
                result.Snapshot.DirectoryPath,
                name.Replace('/', Path.DirectorySeparatorChar));
            Assert.Equal(
                JazzArchiveContainer.Sha256File(Path.Combine(source, name.Replace('/', Path.DirectorySeparatorChar))),
                JazzArchiveContainer.Sha256File(published));
        }

        // Re-verifying the published directory from scratch re-runs every digest against the bytes
        // that actually landed, not against the ones that were staged.
        JazzArchiveSnapshotVerifier.Verify(
            result.Snapshot.DirectoryPath,
            result.Snapshot.ArchiveId,
            new JazzArchiveImportLimits());
    }

    [Fact]
    public void PublishesTheSnapshotAsAReadOnlyDirectory()
    {
        var importer = new JazzArchiveImporter(Store());

        JazzArchiveImportResult result = importer.Import(PackageOf("01-minimal-desktop"));

        Assert.EndsWith(
            result.Snapshot.ArchiveId + JazzArchiveImporter.FinalizedSuffix,
            result.Snapshot.DirectoryPath,
            StringComparison.Ordinal);

        foreach (string path in Directory.EnumerateFiles(result.Snapshot.DirectoryPath, "*", SearchOption.AllDirectories))
        {
            Assert.True(IsReadOnly(path), path + " is writable");
        }

        Assert.True(IsReadOnly(result.PackagePath), "the retained package is writable");
    }

    /// <summary>
    /// The importer's identity is a receipt beside the package, never a rewrite of the manifest: the
    /// captured-by facts and the content digest belong to whoever recorded the evidence.
    /// </summary>
    [Fact]
    public void RecordsTheImporterBesideThePackageAndNeverInsideIt()
    {
        const string Fixture = "01-minimal-desktop";
        var importer = new JazzArchiveImporter(Store());
        var context = new JazzArchiveImportContext
        {
            ImportedBy = new JazzArchiveExternalIdentity("jazz.user", "petr@example.test"),
            ImportingOriginId = "origin-01890a5d-ac96-774b-bcce-b302099a8057",
            ImportingSourceId = "src-01890a5d-ac96-774b-bcce-b302099a8058",
            ImportingDevice = new JazzArchiveExternalIdentity("jazz.device", "windows-workstation-7"),
        };

        JazzArchiveImportResult result = importer.Import(
            PackageOf(Fixture),
            context,
            importedAt: "2026-08-12T09:30:00.000Z");

        Assert.Single(result.Provenance.Receipts);
        JazzArchiveImportReceipt receipt = result.Provenance.Receipts[0];
        Assert.Equal(context.ImportedBy, receipt.ImportedBy);
        Assert.Equal(context.ImportingDevice, receipt.ImportingDevice);
        Assert.Equal(context.ImportingOriginId, receipt.ImportingOriginId);
        Assert.Equal("2026-08-12T09:30:00.000Z", receipt.ImportedAt);
        Assert.Equal(JazzArchiveImportAcquisition.UserSelectedFile, receipt.Acquisition);
        Assert.Equal(
            JazzArchivePackageProvenance.PackageIdFor(result.Provenance.PackageSha256),
            receipt.PackageId);

        // The published manifest is the fixture's manifest, unchanged.
        Assert.Equal(
            JazzArchiveContainer.Sha256File(Path.Combine(ArchiveFixtures.Directory(Fixture), "manifest.json")),
            JazzArchiveContainer.Sha256File(Path.Combine(result.Snapshot.DirectoryPath, "manifest.json")));

        string published = File.ReadAllText(Path.Combine(result.Snapshot.DirectoryPath, "manifest.json"));
        Assert.DoesNotContain("petr@example.test", published, StringComparison.Ordinal);
        Assert.DoesNotContain("windows-workstation-7", published, StringComparison.Ordinal);

        // The retained package still hashes to what the receipt claims.
        Assert.Equal(
            result.Provenance.PackageSha256,
            JazzArchiveContainer.Sha256File(result.PackagePath));
    }

    [Fact]
    public void ReimportingTheSameBytesIsIdempotent()
    {
        string package = PackageOf("02-labeled-narration");
        var importer = new JazzArchiveImporter(Store());

        JazzArchiveImportResult first = importer.Import(package, importedAt: "2026-08-12T09:00:00.000Z");
        string manifestDigest = JazzArchiveContainer.Sha256File(
            Path.Combine(first.Snapshot.DirectoryPath, "manifest.json"));

        JazzArchiveImportResult second = importer.Import(package, importedAt: "2026-08-12T10:00:00.000Z");

        Assert.Equal(JazzArchiveImportDisposition.Imported, first.Disposition);
        Assert.Equal(JazzArchiveImportDisposition.AlreadyPresent, second.Disposition);
        Assert.Equal(first.Snapshot.ArchiveId, second.Snapshot.ArchiveId);
        Assert.Equal(first.Snapshot.ContentDigest, second.Snapshot.ContentDigest);
        Assert.Equal(first.Provenance.PackageId, second.Provenance.PackageId);

        // One package, two acquisition facts: the second import appends rather than replacing.
        Assert.Equal(2, second.Provenance.Receipts.Count);
        Assert.Equal(first.Provenance.Receipts[0].ReceiptId, second.Provenance.Receipts[0].ReceiptId);
        Assert.Equal(
            new[] { "2026-08-12T09:00:00.000Z", "2026-08-12T10:00:00.000Z" },
            second.Provenance.Receipts.Select(receipt => receipt.ImportedAt).OrderBy(value => value).ToArray());

        Assert.Equal(
            manifestDigest,
            JazzArchiveContainer.Sha256File(Path.Combine(second.Snapshot.DirectoryPath, "manifest.json")));
        Assert.Single(Directory.EnumerateDirectories(Store(), "*" + JazzArchiveImporter.FinalizedSuffix));
    }

    /// <summary>
    /// The same archive id carrying different bytes is the conflict the contract says to quarantine.
    /// The published snapshot must survive untouched and the refused package must be kept.
    /// </summary>
    [Fact]
    public void ReimportingDifferentBytesUnderTheSameArchiveIdIsRefusedAndQuarantined()
    {
        const string Fixture = "01-minimal-desktop";
        var importer = new JazzArchiveImporter(Store());
        JazzArchiveImportResult published = importer.Import(PackageOf(Fixture));

        string forged = ArchiveFixtures.CopyTo(Fixture, Path.Combine(_workspace, "forged"));
        ArchiveFixtures.ResealManifest(forged, manifest => manifest["snapshotAt"] = "2026-07-22T09:99:00Z");
        string forgedPackage = ArchiveFixtures.Package(forged, Path.Combine(_workspace, "forged.jazz-archive"));

        JazzArchiveImportException error = Assert.Throws<JazzArchiveImportException>(
            () => importer.Import(forgedPackage));

        Assert.Equal(JazzArchiveImportFailure.ArchiveConflict, error.Failure);
        Assert.Contains(published.Snapshot.ArchiveId, error.Message, StringComparison.Ordinal);

        // The first import is intact: same content digest, same package, one receipt.
        JazzArchiveFinalizedSnapshot survivor = JazzArchiveSnapshotVerifier.Verify(
            published.Snapshot.DirectoryPath,
            published.Snapshot.ArchiveId,
            new JazzArchiveImportLimits());
        Assert.Equal(published.Snapshot.ContentDigest, survivor.ContentDigest);
        Assert.Single(importer.Provenance(published.Snapshot.ArchiveId)!.Receipts);

        // The refused bytes were set aside rather than dropped.
        string quarantine = Path.Combine(
            Store(),
            JazzArchiveImporter.QuarantineDirectoryName,
            published.Snapshot.ArchiveId);
        Assert.True(Directory.Exists(quarantine));
        string quarantined = Assert.Single(Directory.EnumerateFiles(quarantine, "*.jazz-archive"));
        Assert.Equal(
            JazzArchiveContainer.Sha256File(forgedPackage),
            JazzArchiveContainer.Sha256File(quarantined));
    }

    [Fact]
    public void RejectsATamperedBlob()
    {
        string tampered = ArchiveFixtures.CopyTo("01-minimal-desktop", Path.Combine(_workspace, "blob-tamper"));
        string blob = Directory
            .EnumerateFiles(Path.Combine(tampered, "blobs"), "*", SearchOption.AllDirectories)
            .OrderBy(path => path, StringComparer.Ordinal)
            .First();
        string relative = Path.GetRelativePath(tampered, blob).Replace(Path.DirectorySeparatorChar, '/');
        ArchiveFixtures.FlipByte(tampered, relative, 4);

        JazzArchiveImportException error = AssertRefused(tampered, "blob-tamper");

        Assert.Equal(JazzArchiveImportFailure.IntegrityMismatch, error.Failure);
        Assert.Contains(relative, error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void RejectsTamperedRecords()
    {
        string tampered = ArchiveFixtures.CopyTo("02-labeled-narration", Path.Combine(_workspace, "records-tamper"));
        string relative = RecordsPath(tampered);
        ArchiveFixtures.FlipByte(tampered, relative, 3);

        JazzArchiveImportException error = AssertRefused(tampered, "records-tamper");

        Assert.Equal(JazzArchiveImportFailure.IntegrityMismatch, error.Failure);
        Assert.Contains(relative, error.Message, StringComparison.Ordinal);
    }

    /// <summary>
    /// The same tampering, with the inventory and the content digest repaired around it — which is
    /// what an attacker who owns the file would do. The commit's closure hash is the link that has
    /// to catch it, and it names itself when it does.
    /// </summary>
    [Fact]
    public void RejectsTamperedRecordsEvenWhenTheInventoryIsResealed()
    {
        string tampered = ArchiveFixtures.CopyTo("02-labeled-narration", Path.Combine(_workspace, "resealed"));
        string relative = RecordsPath(tampered);
        string path = Path.Combine(tampered, relative.Replace('/', Path.DirectorySeparatorChar));

        string[] lines = File.ReadAllText(path).Split('\n');
        JsonObject first = (JsonObject)JsonStrictParser.Parse(lines[0])!;
        first["capturedAt"] = "2031-01-01T00:00:00Z";
        lines[0] = first.ToJsonString();
        File.WriteAllBytes(
            path,
            new UTF8Encoding(false).GetBytes(string.Join('\n', lines)));

        ArchiveFixtures.ResealInventoryAndManifest(tampered);

        JazzArchiveImportException error = AssertRefused(tampered, "resealed");

        Assert.Equal(JazzArchiveImportFailure.IntegrityMismatch, error.Failure);
        Assert.Contains("orderedObservationDigest", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void RejectsATamperedManifest()
    {
        string tampered = ArchiveFixtures.CopyTo("01-minimal-desktop", Path.Combine(_workspace, "manifest-tamper"));
        string path = Path.Combine(tampered, "manifest.json");
        string text = File.ReadAllText(path);
        Assert.Contains("\"revision\": 1", text, StringComparison.Ordinal);
        File.WriteAllText(path, text.Replace("\"revision\": 1", "\"revision\": 2", StringComparison.Ordinal));

        JazzArchiveImportException error = AssertRefused(tampered, "manifest-tamper");

        Assert.Equal(JazzArchiveImportFailure.IntegrityMismatch, error.Failure);
        Assert.Contains("manifest.contentDigest", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void RejectsAManifestWhoseInventoryDigestIsWrong()
    {
        string tampered = ArchiveFixtures.CopyTo("01-minimal-desktop", Path.Combine(_workspace, "inventory-digest"));
        ArchiveFixtures.ResealManifest(
            tampered,
            manifest => manifest["inventory"]!["digest"] = new string('0', 64));

        JazzArchiveImportException error = AssertRefused(tampered, "inventory-digest");

        Assert.Equal(JazzArchiveImportFailure.IntegrityMismatch, error.Failure);
        Assert.Contains("manifest.inventory.digest", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void RejectsAFileTheInventoryDoesNotList()
    {
        string tampered = ArchiveFixtures.CopyTo("01-minimal-desktop", Path.Combine(_workspace, "unlisted"));
        File.WriteAllText(Path.Combine(tampered, "extra.json"), "{}\n");

        JazzArchiveImportException error = AssertRefused(tampered, "unlisted");

        Assert.Equal(JazzArchiveImportFailure.InvalidArchive, error.Failure);
        Assert.Contains("unlisted extra.json", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void RejectsATamperedCaptureCommit()
    {
        string tampered = ArchiveFixtures.CopyTo("01-minimal-desktop", Path.Combine(_workspace, "commit-tamper"));
        string relative = SessionRelativePath(tampered, "commit.json");
        JsonObject commit = ArchiveFixtures.Read(tampered, relative);
        commit["artifactCount"] = 7;
        ArchiveFixtures.Write(tampered, relative, commit);
        ArchiveFixtures.ResealInventoryAndManifest(tampered);

        JazzArchiveImportException error = AssertRefused(tampered, "commit-tamper");

        Assert.Equal(JazzArchiveImportFailure.IntegrityMismatch, error.Failure);
        Assert.Contains(relative, error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void LeavesNothingBehindWhenAPackageIsRefused()
    {
        string store = Store();
        Directory.CreateDirectory(store);
        string tampered = ArchiveFixtures.CopyTo("01-minimal-desktop", Path.Combine(_workspace, "nothing-behind"));
        ArchiveFixtures.FlipByte(tampered, "sessions/s-11111111-1111-7111-8111-111111111111/records.ndjson", 2);

        AssertRefused(tampered, "nothing-behind");

        // No snapshot, no package, no receipt, and no staging directory left over.
        Assert.Empty(Directory.EnumerateFileSystemEntries(store));
    }

    [Fact]
    public void RefusesAPackageLargerThanTheConfiguredBound()
    {
        var importer = new JazzArchiveImporter(Store(), new JazzArchiveImportLimits { MaxArchiveBytes = 512 });

        JazzArchiveImportException error = Assert.Throws<JazzArchiveImportException>(
            () => importer.Import(PackageOf("01-minimal-desktop")));

        Assert.Equal(JazzArchiveImportFailure.ArchiveTooLarge, error.Failure);
        Assert.False(Directory.Exists(Store()) && Directory.EnumerateFileSystemEntries(Store()).Any());
    }

    /// <summary>
    /// A package whose central directory declares more entries than the envelope allows is refused on
    /// the declaration, before a byte of any entry body is read or a staging file is created.
    /// </summary>
    [Fact]
    public void RefusesADeclaredEntryCountAboveTheBoundBeforeExpanding()
    {
        var importer = new JazzArchiveImporter(Store(), new JazzArchiveImportLimits { MaxEntries = 2 });

        JazzArchiveImportException error = Assert.Throws<JazzArchiveImportException>(
            () => importer.Import(PackageOf("01-minimal-desktop")));

        Assert.Equal(JazzArchiveImportFailure.EntryLimitExceeded, error.Failure);
        Assert.Contains("entry count", error.Message, StringComparison.Ordinal);
        Assert.Empty(Directory.EnumerateFileSystemEntries(Store()));
    }

    [Fact]
    public void RefusesAnNdjsonRecordCountAboveTheBound()
    {
        var importer = new JazzArchiveImporter(Store(), new JazzArchiveImportLimits { MaxNdjsonRecords = 2 });

        JazzArchiveImportException error = Assert.Throws<JazzArchiveImportException>(
            () => importer.Import(PackageOf("03-capture-coach")));

        Assert.Equal(JazzArchiveImportFailure.EntryLimitExceeded, error.Failure);
        Assert.Contains("NDJSON record count", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void RefusesAnNdjsonLineAboveTheBound()
    {
        var importer = new JazzArchiveImporter(Store(), new JazzArchiveImportLimits { MaxNdjsonLineBytes = 32 });

        JazzArchiveImportException error = Assert.Throws<JazzArchiveImportException>(
            () => importer.Import(PackageOf("01-minimal-desktop")));

        Assert.Equal(JazzArchiveImportFailure.EntryLimitExceeded, error.Failure);
        Assert.Contains("NDJSON line", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void RefusesInvalidLimits()
    {
        var importer = new JazzArchiveImporter(Store(), new JazzArchiveImportLimits { MaxEntries = 0 });

        JazzArchiveImportException error = Assert.Throws<JazzArchiveImportException>(
            () => importer.Import(PackageOf("01-minimal-desktop")));

        Assert.Equal(JazzArchiveImportFailure.InvalidLimits, error.Failure);
    }

    [Fact]
    public void RefusesASelectionThatIsNotARegularFile()
    {
        var importer = new JazzArchiveImporter(Store());

        Assert.Equal(
            JazzArchiveImportFailure.SourceNotRegularFile,
            Assert.Throws<JazzArchiveImportException>(
                () => importer.Import(Path.Combine(_workspace, "absent.jazz-archive"))).Failure);

        string empty = Path.Combine(_workspace, "empty.jazz-archive");
        File.WriteAllBytes(empty, Array.Empty<byte>());
        Assert.Equal(
            JazzArchiveImportFailure.SourceNotRegularFile,
            Assert.Throws<JazzArchiveImportException>(() => importer.Import(empty)).Failure);
    }

    [Fact]
    public void RefusesADownloadWithoutItsAuthorization()
    {
        var importer = new JazzArchiveImporter(Store());
        var context = new JazzArchiveImportContext
        {
            Acquisition = JazzArchiveImportAcquisition.JazzServerDownload,
        };

        JazzArchiveImportException error = Assert.Throws<JazzArchiveImportException>(
            () => importer.Import(PackageOf("01-minimal-desktop"), context));

        Assert.Equal(JazzArchiveImportFailure.InvalidArchive, error.Failure);
        Assert.Contains("download authorization", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void RecordsADownloadAcquisition()
    {
        var importer = new JazzArchiveImporter(Store());
        var context = new JazzArchiveImportContext
        {
            Acquisition = JazzArchiveImportAcquisition.JazzServerDownload,
            DownloadOperationId = "dop-01890a5d-ac96-774b-bcce-b302099a8059",
            DownloadAuthorizationId = "grant-2026-08-12",
        };

        JazzArchiveImportResult result = importer.Import(PackageOf("01-minimal-desktop"), context);

        JazzArchiveImportReceipt receipt = result.Provenance.Receipts[0];
        Assert.Equal(JazzArchiveImportAcquisition.JazzServerDownload, receipt.Acquisition);
        Assert.Equal(context.DownloadOperationId, receipt.DownloadOperationId);
        Assert.Equal(context.DownloadAuthorizationId, receipt.DownloadAuthorizationId);
    }

    [Fact]
    public void RefusesAPackageThatDoesNotMatchItsDownloadGrant()
    {
        string package = PackageOf("01-minimal-desktop");
        var importer = new JazzArchiveImporter(Store());

        Assert.Equal(
            JazzArchiveImportFailure.IntegrityMismatch,
            Assert.Throws<JazzArchiveImportException>(() => importer.Import(
                package,
                expectedPackageFingerprint: new JazzArchiveFileFingerprint(new string('0', 64), 10))).Failure);

        Assert.Equal(
            JazzArchiveImportFailure.IntegrityMismatch,
            Assert.Throws<JazzArchiveImportException>(() => importer.Import(
                package,
                expectedArchiveId: "ar-01890a5d-ac96-774b-bcce-b302099a8050")).Failure);

        Assert.Equal(
            JazzArchiveImportFailure.IntegrityMismatch,
            Assert.Throws<JazzArchiveImportException>(() => importer.Import(
                package,
                expectedContentDigest: new string('0', 64))).Failure);
    }

    /// <summary>
    /// An absent optional is absent from the document, never a JSON <c>null</c>. Canonical JSON has
    /// no way to say "declared unknown" that a digest can tell apart from "not declared", so writing
    /// one would make two different receipts hash the same.
    /// </summary>
    [Fact]
    public void OmitsAbsentOptionalReceiptFieldsRatherThanWritingNull()
    {
        var importer = new JazzArchiveImporter(Store());
        JazzArchiveImportResult result = importer.Import(PackageOf("01-minimal-desktop"));

        string packageDirectory = Path.GetDirectoryName(result.PackagePath)!;
        string receipt = Path.Combine(
            packageDirectory,
            JazzArchiveImporter.ReceiptsDirectoryName,
            result.Provenance.Receipts[0].ReceiptId + ".json");

        string text = File.ReadAllText(receipt);
        Assert.DoesNotContain("null", text, StringComparison.Ordinal);
        Assert.DoesNotContain("importedBy", text, StringComparison.Ordinal);
        Assert.DoesNotContain("downloadOperationId", text, StringComparison.Ordinal);

        // Both stored documents are exactly their own canonical form.
        Assert.Equal(JsonCanonicalizer.Canonicalize(JsonStrictParser.Parse(text)), text);
        string provenance = File.ReadAllText(
            Path.Combine(packageDirectory, JazzArchiveImporter.ProvenanceFileName));
        Assert.Equal(JsonCanonicalizer.Canonicalize(JsonStrictParser.Parse(provenance)), provenance);
    }

    [Fact]
    public void KeepsTwoDifferentArchivesSideBySide()
    {
        var importer = new JazzArchiveImporter(Store());

        JazzArchiveImportResult first = importer.Import(PackageOf("01-minimal-desktop"));
        JazzArchiveImportResult second = importer.Import(PackageOf("04-meeting-screen-share"));

        Assert.NotEqual(first.Snapshot.ArchiveId, second.Snapshot.ArchiveId);
        Assert.Equal(
            2,
            Directory.EnumerateDirectories(Store(), "*" + JazzArchiveImporter.FinalizedSuffix).Count());
        Assert.NotNull(importer.Provenance(first.Snapshot.ArchiveId));
        Assert.NotNull(importer.Provenance(second.Snapshot.ArchiveId));
    }

    [Fact]
    public void ReportsNoProvenanceBeforeAnImport()
    {
        var importer = new JazzArchiveImporter(Store());

        Assert.Null(importer.Provenance("ar-01890a5d-ac96-774b-bcce-b302099a8051"));
    }

    [Fact]
    public void ReadsBackTheStoredProvenance()
    {
        var importer = new JazzArchiveImporter(Store());
        JazzArchiveImportResult result = importer.Import(PackageOf("02-labeled-narration"));

        JazzArchivePackageProvenance? stored = importer.Provenance(result.Snapshot.ArchiveId);

        Assert.NotNull(stored);
        Assert.Equal(result.Provenance.PackageId, stored!.PackageId);
        Assert.Equal(result.Provenance.ContentDigest, stored.ContentDigest);
        Assert.Equal(result.Provenance.PackageSha256, stored.PackageSha256);
        Assert.Equal(result.Provenance.PackageByteLength, stored.PackageByteLength);
        Assert.Equal(
            result.Provenance.Receipts.Select(receipt => receipt.ReceiptId),
            stored.Receipts.Select(receipt => receipt.ReceiptId));
    }

    /// <summary>
    /// A published archive whose manifest was edited in place is not readable back. Nothing may
    /// depend on a snapshot being immutable in fact; it has to be re-provable.
    /// </summary>
    [Fact]
    public void RefusesToReadBackAPublishedSnapshotThatWasEditedInPlace()
    {
        var importer = new JazzArchiveImporter(Store());
        JazzArchiveImportResult result = importer.Import(PackageOf("01-minimal-desktop"));

        string manifest = Path.Combine(result.Snapshot.DirectoryPath, "manifest.json");
        MakeWritable(manifest);
        string text = File.ReadAllText(manifest);
        File.WriteAllText(manifest, text.Replace("\"revision\": 1", "\"revision\": 3", StringComparison.Ordinal));

        JazzArchiveImportException error = Assert.Throws<JazzArchiveImportException>(
            () => importer.Provenance(result.Snapshot.ArchiveId));

        Assert.Equal(JazzArchiveImportFailure.IntegrityMismatch, error.Failure);
        Assert.Contains("manifest.contentDigest", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void RefusesAnArchiveIdWithALocalDraft()
    {
        string store = Store();
        JsonObject manifest = ArchiveFixtures.Read(ArchiveFixtures.Directory("01-minimal-desktop"), "manifest.json");
        Directory.CreateDirectory(Path.Combine(
            store,
            (string)manifest["archiveId"]! + JazzArchiveImporter.DraftSuffix));

        JazzArchiveImportException error = Assert.Throws<JazzArchiveImportException>(
            () => new JazzArchiveImporter(store).Import(PackageOf("01-minimal-desktop")));

        Assert.Equal(JazzArchiveImportFailure.ArchiveConflict, error.Failure);
    }

    private JazzArchiveImportException AssertRefused(string archiveDirectory, string label)
    {
        string package = ArchiveFixtures.Package(
            archiveDirectory,
            Path.Combine(_workspace, label + ".jazz-archive"));

        return Assert.Throws<JazzArchiveImportException>(
            () => new JazzArchiveImporter(Store()).Import(package));
    }

    private string PackageOf(string fixture) => ArchiveFixtures.Package(
        ArchiveFixtures.Directory(fixture),
        Path.Combine(_workspace, fixture + ".jazz-archive"));

    private string Store() => Path.Combine(_workspace, "store");

    private static string RecordsPath(string archiveDirectory) =>
        SessionRelativePath(archiveDirectory, "records.ndjson");

    private static string SessionRelativePath(string archiveDirectory, string name)
    {
        string path = Directory
            .EnumerateFiles(Path.Combine(archiveDirectory, "sessions"), name, SearchOption.AllDirectories)
            .Single();
        return Path.GetRelativePath(archiveDirectory, path).Replace(Path.DirectorySeparatorChar, '/');
    }

    private static bool IsReadOnly(string path) => OperatingSystem.IsWindows()
        ? File.GetAttributes(path).HasFlag(FileAttributes.ReadOnly)
        : !File.GetUnixFileMode(path).HasFlag(UnixFileMode.UserWrite);

    private static void MakeWritable(string path)
    {
        if (OperatingSystem.IsWindows())
        {
            File.SetAttributes(path, File.GetAttributes(path) & ~FileAttributes.ReadOnly);
            return;
        }

        File.SetUnixFileMode(
            Path.GetDirectoryName(path)!,
            UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
    }
}
