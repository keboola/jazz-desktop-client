using System.Diagnostics;
using System.Text;
using System.Text.Json.Nodes;
using JasnostCaptureCore;
using JasnostCaptureCore.Archive;
using JasnostCaptureCore.Journal;
using JasnostCaptureCore.Json;
using JasnostCaptureCoreTests.Support;

namespace JasnostCaptureCoreTests;

/// <summary>
/// Exercises the finalized-archive writer. The last test is the outer gate: the produced directory
/// is handed to <c>contract/archive/validate_archives.py</c>, which is the normative authority on
/// schemas, references, inventory closure, and commit digests.
/// </summary>
public sealed class ArchiveWriterTests : IDisposable
{
    private const string StartedAt = "2026-07-22T08:00:00Z";
    private const string EndedAt = "2026-07-22T08:01:00Z";
    private const string ConsentedAt = "2026-07-22T07:59:59Z";
    private const string PolicyVersion = "consent-v1";

    private readonly string _root = Path.Combine(
        Path.GetTempPath(),
        "jasnost-archive-writer-" + Guid.NewGuid().ToString("n"));

    public void Dispose()
    {
        if (Directory.Exists(_root))
        {
            Directory.Delete(_root, recursive: true);
        }
    }

    [Fact]
    public void WriteFinalizedProducesTheFiveCanonicalDocuments()
    {
        ArchiveIdentity ids = ArchiveIdentity.Mint();
        string archiveDir = Write(ids, DeterministicObservationIds());

        Assert.True(File.Exists(Path.Combine(archiveDir, "manifest.json")));
        Assert.True(File.Exists(Path.Combine(archiveDir, "inventory.json")));
        string sessionDir = Path.Combine(archiveDir, "sessions", ids.SessionId);
        Assert.True(File.Exists(Path.Combine(sessionDir, "session.json")));
        Assert.True(File.Exists(Path.Combine(sessionDir, "commit.json")));
        Assert.True(File.Exists(Path.Combine(sessionDir, "records.ndjson")));
    }

    [Fact]
    public void RecordsNdjsonIsLineFeedTerminatedWithoutByteOrderMark()
    {
        ArchiveIdentity ids = ArchiveIdentity.Mint();
        string archiveDir = Write(ids, DeterministicObservationIds());
        byte[] bytes = File.ReadAllBytes(
            Path.Combine(archiveDir, "sessions", ids.SessionId, "records.ndjson"));

        Assert.NotEqual(0xEF, bytes[0]);
        Assert.Equal((byte)'\n', bytes[^1]);
        Assert.DoesNotContain((byte)'\r', bytes);
    }

    [Fact]
    public void RecordsAreSortedByStreamThenSequenceAndCapabilitiesFollowTheJournal()
    {
        ArchiveIdentity ids = ArchiveIdentity.Mint();
        string archiveDir = Write(ids, DeterministicObservationIds());

        IReadOnlyList<JsonObject> written = ReadRecords(
            Path.Combine(archiveDir, "sessions", ids.SessionId, "records.ndjson"));

        Assert.Equal(3, written.Count);
        Assert.Equal(new long[] { 0, 1, 2 }, written.Select(Sequence).ToArray());
        Assert.Equal(ArchiveContracts.ActivityEventRecordType, (string?)written[0]["recordType"]);
        Assert.Equal(ArchiveContracts.ActivityEventRecordType, (string?)written[1]["recordType"]);
        Assert.Equal(
            CapabilityObservation.RecordType,
            (string?)written[2]["recordType"]);
    }

    [Fact]
    public void ManifestBindsTheCommitInventoryAndContentDigests()
    {
        ArchiveIdentity ids = ArchiveIdentity.Mint();
        string archiveDir = Write(ids, DeterministicObservationIds());

        JsonObject manifest = ReadDocument(Path.Combine(archiveDir, "manifest.json"));
        JsonObject inventory = ReadDocument(Path.Combine(archiveDir, "inventory.json"));
        JsonObject session = ReadDocument(
            Path.Combine(archiveDir, "sessions", ids.SessionId, "session.json"));
        JsonObject commit = ReadDocument(
            Path.Combine(archiveDir, "sessions", ids.SessionId, "commit.json"));

        Assert.Equal(
            JsonCanonicalizer.Sha256Hex(inventory),
            (string?)manifest["inventory"]!["digest"]);

        var commitRef = Assert.IsType<JsonObject>(
            Assert.IsType<JsonArray>(manifest["captureCommits"])[0]);
        Assert.Equal(JsonCanonicalizer.Sha256Hex(commit), (string?)commitRef["digest"]);
        Assert.True(JsonDeepComparer.DeepEquals(commitRef, session["captureCommit"]));

        var withoutContentDigest = (JsonObject)manifest.DeepClone();
        withoutContentDigest.Remove("contentDigest");
        Assert.Equal(
            JsonCanonicalizer.Sha256Hex(withoutContentDigest),
            (string?)manifest["contentDigest"]);
        Assert.Equal("contentDigest", manifest.Last().Key);
    }

    [Fact]
    public void ManifestDeclaresOnlyTheContractsActuallyPresent()
    {
        ArchiveIdentity ids = ArchiveIdentity.Mint();
        string archiveDir = Write(ids, DeterministicObservationIds(), withCapabilities: false);

        JsonObject manifest = ReadDocument(Path.Combine(archiveDir, "manifest.json"));
        var contracts = Assert.IsType<JsonArray>(manifest["contracts"]);

        JsonObject only = Assert.IsType<JsonObject>(Assert.Single(contracts));
        Assert.Equal(ArchiveContracts.ActivityEventRecordType, (string?)only["recordType"]);
        Assert.Equal(1L, (long?)only["schemaVersion"]);
    }

    [Fact]
    public void InventoryCoversEveryFileExceptTheManifestAndItself()
    {
        ArchiveIdentity ids = ArchiveIdentity.Mint();
        string archiveDir = Write(ids, DeterministicObservationIds());

        JsonObject inventory = ReadDocument(Path.Combine(archiveDir, "inventory.json"));
        string[] paths = Assert.IsType<JsonArray>(inventory["entries"])
            .Select(entry => (string)((JsonObject)entry!)["path"]!)
            .ToArray();

        Assert.Equal(
            new[]
            {
                "sessions/" + ids.SessionId + "/commit.json",
                "sessions/" + ids.SessionId + "/records.ndjson",
                "sessions/" + ids.SessionId + "/session.json",
            },
            paths);

        foreach (JsonNode? entry in Assert.IsType<JsonArray>(inventory["entries"]))
        {
            var value = Assert.IsType<JsonObject>(entry);
            string file = Path.Combine(archiveDir, ((string)value["path"]!).Replace('/', Path.DirectorySeparatorChar));
            Assert.Equal(new FileInfo(file).Length, (long?)value["byteLength"]);
            Assert.Equal(JazzArchiveContainer.Sha256File(file), (string?)value["sha256"]);
        }
    }

    [Fact]
    public void GapsReachTheCommitDocument()
    {
        ArchiveIdentity ids = ArchiveIdentity.Mint();
        var gaps = new[]
        {
            new GapEntry(ids.StreamId, 1, 1, GapReasons.RecoveryTruncation, "producer terminated"),
        };
        string archiveDir = ArchiveWriter.WriteFinalized(
            _root,
            ids,
            Metadata(),
            new[] { ActivityRecord(ids, "00000000d000", 0, StartedAt, 0),
                ActivityRecord(ids, "00000000d002", 2, EndedAt, 2), },
            gaps,
            Array.Empty<CapabilityObservation>(),
            JournalSessionStatus.Recovered,
            DeterministicObservationIds());

        JsonObject commit = ReadDocument(
            Path.Combine(archiveDir, "sessions", ids.SessionId, "commit.json"));
        JsonObject session = ReadDocument(
            Path.Combine(archiveDir, "sessions", ids.SessionId, "session.json"));

        var gap = Assert.IsType<JsonObject>(Assert.Single(Assert.IsType<JsonArray>(commit["gaps"])));
        Assert.Equal(GapReasons.RecoveryTruncation, (string?)gap["reason"]);
        Assert.Equal("producer terminated", (string?)gap["detail"]);

        var summary = Assert.IsType<JsonObject>(
            Assert.Single(Assert.IsType<JsonArray>(commit["streamSummaries"])));
        Assert.Equal(0L, (long?)summary["firstSequence"]);
        Assert.Equal(2L, (long?)summary["lastSequence"]);
        Assert.Equal(2L, (long?)summary["observationCount"]);
        Assert.Equal(JournalSessionStatus.Recovered, (string?)session["status"]);
    }

    [Fact]
    public void WritingTwiceProducesTheSameContentDigest()
    {
        ArchiveIdentity ids = ArchiveIdentity.Mint();
        string first = Write(ids, DeterministicObservationIds(), subdirectory: "first");
        string second = Write(ids, DeterministicObservationIds(), subdirectory: "second");

        JsonObject firstManifest = ReadDocument(Path.Combine(first, "manifest.json"));
        JsonObject secondManifest = ReadDocument(Path.Combine(second, "manifest.json"));

        Assert.Equal(
            (string?)firstManifest["contentDigest"],
            (string?)secondManifest["contentDigest"]);
        Assert.Equal(
            (string?)firstManifest["inventory"]!["digest"],
            (string?)secondManifest["inventory"]!["digest"]);
        Assert.Equal(
            JazzArchiveContainer.Sha256File(Path.Combine(first, "manifest.json")),
            JazzArchiveContainer.Sha256File(Path.Combine(second, "manifest.json")));
    }

    [Fact]
    public void WritingIntoAnExistingArchiveDirectoryIsRefused()
    {
        ArchiveIdentity ids = ArchiveIdentity.Mint();
        Write(ids, DeterministicObservationIds());

        Assert.Throws<IOException>(() => Write(ids, DeterministicObservationIds()));
    }

    [Fact]
    public void ProducedArchivePassesTheContractValidator()
    {
        string? uv = FindUv();
        if (uv is null)
        {
            // xUnit 2.5 cannot skip at run time; the outer gate simply cannot run without uv.
            Console.WriteLine(
                "SKIPPED ProducedArchivePassesTheContractValidator: uv is not installed, so "
                    + "contract/archive/validate_archives.py cannot be executed.");
            return;
        }

        ArchiveIdentity ids = ArchiveIdentity.Mint();
        string archiveDir = Write(ids, DeterministicObservationIds());

        // validate_archives.py takes no arguments: it validates every directory inside the
        // fixtures directory next to itself. The contract tree is therefore copied into a
        // scratch root and the produced archive is added as one more fixture.
        string harness = Path.Combine(_root, "validator");
        string contractCopy = Path.Combine(harness, "contract");
        CopyDirectory(Path.Combine(ContractPaths.Root(), "contract"), contractCopy);
        CopyDirectory(archiveDir, Path.Combine(contractCopy, "archive", "fixtures", "90-windows-writer"));

        (int exitCode, string output) = Run(
            uv,
            new[] { "run", "--script", Path.Combine(contractCopy, "archive", "validate_archives.py") },
            harness);

        Assert.True(exitCode == 0, "validate_archives.py failed:\n" + output);
        Assert.Contains("ok    90-windows-writer", output, StringComparison.Ordinal);
    }

    private string Write(
        ArchiveIdentity ids,
        Func<string> observationIds,
        bool withCapabilities = true,
        string? subdirectory = null)
    {
        string outputDir = subdirectory is null ? _root : Path.Combine(_root, subdirectory);
        return ArchiveWriter.WriteFinalized(
            outputDir,
            ids,
            Metadata(),
            new[]
            {
                ActivityRecord(ids, "00000000e000", 0, StartedAt, 0),
                ActivityRecord(ids, "00000000e001", 1, EndedAt, 1),
            },
            Array.Empty<GapEntry>(),
            withCapabilities
                ? new[]
                {
                    new CapabilityObservation(
                        Capability.PointerCapture,
                        CapabilityAuthorization.Granted,
                        CapabilityAvailability.Available,
                        CapabilityTransition.Initial,
                        CapabilityReason.PermissionGranted,
                        StartedAt),
                }
                : Array.Empty<CapabilityObservation>(),
            JournalSessionStatus.Closed,
            observationIds);
    }

    private static SessionMetadata Metadata() => new(
        StartedAt,
        EndedAt,
        ConsentedAt,
        PolicyVersion,
        new[] { "pointer", "keyboard" },
        Array.Empty<string>(),
        "Jazz Capture (.NET)",
        "1.0.0",
        "windows.capture-controller",
        new[] { "pointer.capture", "keyboard.capture", "session_boundaries" },
        new[] { new UnavailableCapability("screen.capture", "disabled_by_policy", "MVP does not capture screenshots") })
    {
        ProducerPlatform = "Windows",
    };

    private static JsonObject ActivityRecord(
        ArchiveIdentity ids,
        string suffix,
        long sequence,
        string capturedAt,
        long eventSequence) => ArchiveDocuments.Record(
        ids,
        observationId: "obs-00000000-0000-7000-8000-" + suffix,
        streamSequence: sequence,
        capturedAt: capturedAt,
        recordType: ArchiveContracts.ActivityEventRecordType,
        payloadSchema: ArchiveContracts.ActivityEventPayloadSchema,
        sourceRole: ArchiveContracts.TriggerRole,
        payload: new JsonObject
        {
            ["sessionId"] = ids.SessionId,
            ["eventId"] = Identifiers.EventId(ids.SessionId, eventSequence),
            ["timestamp"] = capturedAt,
            ["eventType"] = eventSequence == 0 ? "session_start" : "session_end",
            ["url"] = "app://session",
        },
        policyVersion: PolicyVersion);

    private static Func<string> DeterministicObservationIds()
    {
        var counter = 0;
        return () => "obs-00000000-0000-7000-8000-" + (0xc000 + counter++).ToString("x12");
    }

    private static long Sequence(JsonObject record) => (long)record["streamSequence"]!;

    private static JsonObject ReadDocument(string path) =>
        (JsonObject)JsonStrictParser.Parse(File.ReadAllText(path, Encoding.UTF8))!;

    private static IReadOnlyList<JsonObject> ReadRecords(string path) =>
        File.ReadAllLines(path)
            .Where(line => line.Length > 0)
            .Select(line => (JsonObject)JsonStrictParser.Parse(line)!)
            .ToArray();

    private static void CopyDirectory(string source, string destination)
    {
        Directory.CreateDirectory(destination);
        foreach (string directory in Directory.GetDirectories(source))
        {
            CopyDirectory(directory, Path.Combine(destination, Path.GetFileName(directory)));
        }

        foreach (string file in Directory.GetFiles(source))
        {
            File.Copy(file, Path.Combine(destination, Path.GetFileName(file)));
        }
    }

    private static string? FindUv()
    {
        string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        foreach (string candidate in new[]
                 {
                     "/opt/homebrew/bin/uv",
                     "/usr/local/bin/uv",
                     Path.Combine(home, ".local", "bin", "uv"),
                     Path.Combine(home, ".cargo", "bin", "uv"),
                 })
        {
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        return null;
    }

    private static (int ExitCode, string Output) Run(string fileName, string[] arguments, string workingDirectory)
    {
        Directory.CreateDirectory(workingDirectory);
        var info = new ProcessStartInfo(fileName)
        {
            WorkingDirectory = workingDirectory,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        };
        foreach (string argument in arguments)
        {
            info.ArgumentList.Add(argument);
        }

        using var process = Process.Start(info)
            ?? throw new InvalidOperationException("could not start " + fileName);
        string standardOutput = process.StandardOutput.ReadToEnd();
        string standardError = process.StandardError.ReadToEnd();
        process.WaitForExit();
        return (process.ExitCode, standardOutput + standardError);
    }
}
