using System.Diagnostics;
using System.Text;
using System.Text.Json.Nodes;
using JazzCaptureCore;
using JazzCaptureCore.Archive;
using JazzCaptureCore.Journal;
using JazzCaptureCore.Json;
using JazzCaptureCoreTests.Support;

namespace JazzCaptureCoreTests;

/// <summary>
/// Exercises the capture engine end to end: journal admission, event projection, redaction,
/// denylist gaps, and the review decision that turns a committed capture into a container.
/// </summary>
/// <remarks>
/// The outer gate is <c>contract/archive/validate_archives.py</c> run over the directory the engine
/// finalizes; everything else in here only pins behaviour the validator cannot see.
/// </remarks>
public sealed class CaptureEngineTests : IDisposable
{
    private const string Browser = "Contoso.Browser";
    private const string Editor = "Contoso.Editor";
    private const string SecretApp = "Contoso.Vault";

    private readonly string _root = Path.Combine(
        Path.GetTempPath(),
        "jazz-capture-engine-" + Guid.NewGuid().ToString("n"));

    private readonly TestClock _clock = new();

    public void Dispose()
    {
        if (Directory.Exists(_root))
        {
            Directory.Delete(_root, recursive: true);
        }
    }

    [Fact]
    public void StartAppendsSessionStartAndTheInitialCapabilityObservations()
    {
        CaptureEngine engine = CaptureEngine.Start(Config());
        engine.Stop();
        engine.ConfirmAndExport(QueueDir());

        IReadOnlyList<JsonObject> records = Records(engine);
        JsonObject first = Assert.IsType<JsonObject>(records[0]["payload"]);
        Assert.Equal("session_start", (string?)first["eventType"]);
        Assert.Equal("app://session", (string?)first["url"]);
        Assert.Equal(
            new[] { "sessionId", "eventId", "sequence", "timestamp", "eventType", "url" },
            first.Select(pair => pair.Key).ToArray());

        JsonObject[] capabilities = records
            .Where(record => (string?)record["recordType"] == CapabilityObservation.RecordType)
            .Select(record => (JsonObject)record["payload"]!)
            .ToArray();

        Assert.Equal(
            new[]
            {
                "pointer.capture", "keyboard.capture", "accessibility.context",
                "screen.capture", "audio.capture",
            },
            capabilities.Select(payload => (string?)payload["capability"]).ToArray());

        foreach (JsonObject payload in capabilities.Take(3))
        {
            Assert.Equal(CapabilityAuthorization.Granted, (string?)payload["authorizationStatus"]);
            Assert.Equal(CapabilityAvailability.Available, (string?)payload["availability"]);
            Assert.Equal(CapabilityReason.PermissionGranted, (string?)payload["reason"]);
            Assert.Equal(CapabilityTransition.Initial, (string?)payload["transition"]);
        }

        foreach (JsonObject payload in capabilities.Skip(3))
        {
            // A policy-disabled modality keeps its authorization and only loses availability.
            Assert.Equal(CapabilityAuthorization.Granted, (string?)payload["authorizationStatus"]);
            Assert.Equal(CapabilityAvailability.Unavailable, (string?)payload["availability"]);
            Assert.Equal(CapabilityReason.CaptureDisabledByPolicy, (string?)payload["reason"]);
        }
    }

    [Fact]
    public void SequencesAreStrictlyIncreasingBetweenTheSessionBoundaries()
    {
        CaptureEngine engine = CaptureEngine.Start(Config());
        engine.Observe(Click(1));
        engine.Observe(Click(2));
        engine.Observe(Click(1));
        StopResult stopped = engine.Stop();
        engine.ConfirmAndExport(QueueDir());

        JsonObject[] events = ActivityPayloads(engine);

        Assert.Equal(5, events.Length);
        Assert.Equal("session_start", (string?)events[0]["eventType"]);
        Assert.Equal("session_end", (string?)events[^1]["eventType"]);
        Assert.Equal(new long[] { 0, 1, 2, 3, 4 }, events.Select(e => (long)e["sequence"]!).ToArray());

        foreach (JsonObject payload in events)
        {
            Assert.Equal(
                Identifiers.EventId(engine.Identity.SessionId, (long)payload["sequence"]!),
                (string?)payload["eventId"]);
        }

        Assert.Equal(JournalSessionStatus.Closed, stopped.Status);
        Assert.Equal(5, stopped.ObservationCount);
        Assert.Equal(0, stopped.GapCount);
        Assert.Equal(5, stopped.CapabilityObservationCount);
    }

    [Fact]
    public void ClickCarriesTargetGestureAndDocumentContext()
    {
        CaptureEngine engine = CaptureEngine.Start(Config());
        engine.Observe(new ClickEvent
        {
            OccurredAt = _clock.Next(),
            Application = new AppIdentity(AppIdentity.AumidNamespace, Browser, "Contoso Browser", "3.2.1"),
            System = "Contoso Browser",
            TargetRole = "Button",
            TargetAccessibleName = "  Save  ",
            TargetText = "Save",
            TargetBoundingBox = new BoundingBox(10, 20, 80, 24),
            SelectedText = "quarterly",
            PageTitle = "Invoices",
            DocumentUrl = "https://contoso.example/invoices",
            ClickCount = 2,
        });
        engine.Stop();
        engine.ConfirmAndExport(QueueDir());

        JsonObject click = ActivityPayloads(engine)[1];

        Assert.Equal("click", (string?)click["eventType"]);
        Assert.Equal("app://" + Browser, (string?)click["url"]);
        Assert.Equal(2L, (long?)click["clickCount"]);
        Assert.Equal("quarterly", (string?)click["selectedText"]);
        Assert.Equal("Invoices", (string?)click["pageTitle"]);
        Assert.Equal("https://contoso.example/invoices", (string?)click["documentURL"]);
        Assert.Matches(
            "^gesture-[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
            (string?)click["gestureId"]);

        var target = Assert.IsType<JsonObject>(click["target"]);
        Assert.Equal("Button", (string?)target["tag"]);
        Assert.Equal("Button", (string?)target["role"]);
        Assert.Equal("Save", (string?)target["accessibleName"]);
        // A whole coordinate round-trips through canonical JSON as an integer literal.
        Assert.Equal(80L, (long?)target["boundingBox"]!["width"]);

        var application = Assert.IsType<JsonObject>(click["application"]);
        Assert.Equal(AppIdentity.AumidNamespace, (string?)application["namespace"]);
        Assert.Equal(Browser, (string?)application["value"]);
        Assert.Equal("3.2.1", (string?)application["version"]);
    }

    [Fact]
    public void SensitiveTargetsDropTheirTextSelectionAndClipboard()
    {
        CaptureEngine engine = CaptureEngine.Start(Config());
        engine.Observe(new PasteEvent
        {
            OccurredAt = _clock.Next(),
            Application = new AppIdentity(AppIdentity.AumidNamespace, Editor),
            TargetRole = "Edit",
            TargetAccessibleName = "Password",
            TargetText = "hunter2",
            SelectedText = "hunter2",
            ClipboardText = "hunter2",
            IsSensitive = true,
        });
        engine.Stop();
        engine.ConfirmAndExport(QueueDir());

        JsonObject paste = ActivityPayloads(engine)[1];

        Assert.Equal("paste", (string?)paste["eventType"]);
        Assert.True((bool?)paste["isSensitive"]);
        Assert.False(paste.ContainsKey("clipboardText"));
        Assert.False(paste.ContainsKey("selectedText"));
        Assert.False(Assert.IsType<JsonObject>(paste["target"]).ContainsKey("text"));
    }

    [Fact]
    public void TypedInputIsRedactedAndFlaggedAsMasked()
    {
        CaptureEngine engine = CaptureEngine.Start(Config());
        engine.Observe(new InputEvent
        {
            OccurredAt = _clock.Next(),
            Application = new AppIdentity(AppIdentity.AumidNamespace, Editor),
            RawText = "john@doe.com 12345678",
            TargetRole = "Edit",
            TargetAccessibleName = "Recipient",
            TargetBoundingBox = new BoundingBox(0, 0, 100, 20),
        });
        engine.Stop();
        engine.ConfirmAndExport(QueueDir());

        JsonObject input = ActivityPayloads(engine)[1];

        Assert.Equal("input", (string?)input["eventType"]);
        Assert.Equal("•••@••• ••••••••", (string?)input["value"]);
        Assert.True((bool?)input["inputMasked"]);

        var target = Assert.IsType<JsonObject>(input["target"]);
        Assert.Equal("Edit", (string?)target["role"]);
        Assert.Equal("Recipient", (string?)target["accessibleName"]);
        Assert.False(target.ContainsKey("boundingBox"));
    }

    [Fact]
    public void UnmaskedTypedInputOmitsTheInputMaskedFlag()
    {
        CaptureEngine engine = CaptureEngine.Start(Config());
        engine.Observe(new InputEvent
        {
            OccurredAt = _clock.Next(),
            Application = new AppIdentity(AppIdentity.AumidNamespace, Editor),
            RawText = "quarterly report",
            TargetRole = "Edit",
        });
        engine.Observe(new InputEvent
        {
            OccurredAt = _clock.Next(),
            Application = new AppIdentity(AppIdentity.AumidNamespace, Editor),
            RawText = "    ",
            TargetRole = "Edit",
        });
        engine.Stop();
        engine.ConfirmAndExport(QueueDir());

        JsonObject[] events = ActivityPayloads(engine);

        // The blank run produces no event at all, so only three remain.
        Assert.Equal(3, events.Length);
        Assert.Equal("quarterly report", (string?)events[1]["value"]);
        Assert.False(events[1].ContainsKey("inputMasked"));
    }

    [Fact]
    public void KeydownCarriesTheComboAsValueAndNoTarget()
    {
        CaptureEngine engine = CaptureEngine.Start(Config());
        engine.Observe(new KeydownEvent
        {
            OccurredAt = _clock.Next(),
            Application = new AppIdentity(AppIdentity.AumidNamespace, Editor),
            ComboName = "Ctrl+S",
        });
        engine.Stop();
        engine.ConfirmAndExport(QueueDir());

        JsonObject keydown = ActivityPayloads(engine)[1];

        Assert.Equal("keydown", (string?)keydown["eventType"]);
        Assert.Equal("Ctrl+S", (string?)keydown["value"]);
        Assert.False(keydown.ContainsKey("target"));
        Assert.False(keydown.ContainsKey("inputMasked"));
    }

    [Fact]
    public void ScrollOmitsClickCountAndGestureIdentity()
    {
        CaptureEngine engine = CaptureEngine.Start(Config());
        engine.Observe(new ScrollEvent
        {
            OccurredAt = _clock.Next(),
            Application = new AppIdentity(AppIdentity.AumidNamespace, Browser),
            TargetRole = "Document",
            PageTitle = "Invoices",
            DocumentUrl = "https://contoso.example/invoices",
        });
        engine.Stop();
        engine.ConfirmAndExport(QueueDir());

        JsonObject scroll = ActivityPayloads(engine)[1];

        Assert.Equal("scroll", (string?)scroll["eventType"]);
        Assert.True(scroll.ContainsKey("target"));
        Assert.Equal("Invoices", (string?)scroll["pageTitle"]);
        Assert.False(scroll.ContainsKey("clickCount"));
        Assert.False(scroll.ContainsKey("gestureId"));
    }

    [Fact]
    public void DragCarriesItsReleasePoint()
    {
        CaptureEngine engine = CaptureEngine.Start(Config());
        engine.Observe(new DragEvent
        {
            OccurredAt = _clock.Next(),
            Application = new AppIdentity(AppIdentity.AumidNamespace, Editor),
            TargetRole = "Text",
            DragEndX = 420.5,
            DragEndY = 96,
        });
        engine.Stop();
        engine.ConfirmAndExport(QueueDir());

        JsonObject drag = ActivityPayloads(engine)[1];

        Assert.Equal("drag", (string?)drag["eventType"]);
        Assert.Equal(420.5d, (double?)drag["dragEnd"]!["x"]);
        Assert.Equal(96L, (long?)drag["dragEnd"]!["y"]);
        Assert.Equal(1L, (long?)drag["clickCount"]);
    }

    [Fact]
    public void NavigateCarriesNoTargetPageTitleOrDocumentUrl()
    {
        CaptureEngine engine = CaptureEngine.Start(Config());
        engine.Observe(new NavigateEvent
        {
            OccurredAt = _clock.Next(),
            Application = new AppIdentity(AppIdentity.AumidNamespace, Browser, "Contoso Browser"),
            System = "Contoso Browser",
        });
        engine.Stop();
        engine.ConfirmAndExport(QueueDir());

        JsonObject navigate = ActivityPayloads(engine)[1];

        Assert.Equal("navigate", (string?)navigate["eventType"]);
        Assert.Equal("app://" + Browser, (string?)navigate["url"]);
        Assert.Equal("Contoso Browser", (string?)navigate["system"]);
        Assert.False(navigate.ContainsKey("target"));
        Assert.False(navigate.ContainsKey("pageTitle"));
        Assert.False(navigate.ContainsKey("documentURL"));
    }

    [Fact]
    public void DenylistedApplicationsBecomeExplicitGaps()
    {
        CaptureEngine engine = CaptureEngine.Start(Config(SecretApp));
        engine.Observe(new NavigateEvent
        {
            OccurredAt = _clock.Next(),
            Application = new AppIdentity(AppIdentity.AumidNamespace, "contoso.VAULT"),
        });
        engine.Observe(Click(1));
        StopResult stopped = engine.Stop();
        engine.ConfirmAndExport(QueueDir());

        Assert.Equal(1, stopped.GapCount);
        Assert.Equal(3, stopped.ObservationCount);

        JsonObject commit = ReadDocument(Path.Combine(SessionDir(engine), "commit.json"));
        var gap = Assert.IsType<JsonObject>(Assert.Single(Assert.IsType<JsonArray>(commit["gaps"])));
        Assert.Equal(GapReasons.IntentionallyOmitted, (string?)gap["reason"]);
        Assert.Equal(CaptureGapDetails.ApplicationDenylist, (string?)gap["detail"]);
        Assert.Equal(1L, (long?)gap["firstSequence"]);
        Assert.Equal(1L, (long?)gap["lastSequence"]);
    }

    [Fact]
    public void EventsWithoutAnApplicationOwnerBecomeExplicitGaps()
    {
        CaptureEngine engine = CaptureEngine.Start(Config());
        engine.Observe(new ClickEvent { OccurredAt = _clock.Next(), TargetRole = "Button" });
        engine.Observe(new ClickEvent
        {
            OccurredAt = _clock.Next(),
            Application = new AppIdentity(AppIdentity.AumidNamespace, "   "),
        });
        StopResult stopped = engine.Stop();
        engine.ConfirmAndExport(QueueDir());

        // Two adjacent single-position gaps that agree are coalesced into one interval.
        Assert.Equal(1, stopped.GapCount);

        JsonObject commit = ReadDocument(Path.Combine(SessionDir(engine), "commit.json"));
        var gap = Assert.IsType<JsonObject>(Assert.Single(Assert.IsType<JsonArray>(commit["gaps"])));

        Assert.Equal(GapReasons.IntentionallyOmitted, (string?)gap["reason"]);
        Assert.Equal(CaptureGapDetails.OwnerUnavailable, (string?)gap["detail"]);
        Assert.Equal(1L, (long?)gap["firstSequence"]);
        Assert.Equal(2L, (long?)gap["lastSequence"]);
    }

    [Fact]
    public void InteractionsWithTheCaptureClientsOwnUiBecomeExplicitGaps()
    {
        CaptureEngine engine = CaptureEngine.Start(Config());
        engine.Observe(Click(1));
        engine.ObserveOwnWindowInteraction();
        engine.Observe(Click(1));
        StopResult stopped = engine.Stop();
        engine.ConfirmAndExport(QueueDir());

        Assert.Equal(1, stopped.GapCount);
        Assert.Equal(4, stopped.ObservationCount);

        JsonObject commit = ReadDocument(Path.Combine(SessionDir(engine), "commit.json"));
        var gap = Assert.IsType<JsonObject>(Assert.Single(Assert.IsType<JsonArray>(commit["gaps"])));
        Assert.Equal(GapReasons.IntentionallyOmitted, (string?)gap["reason"]);
        Assert.Equal(CaptureGapDetails.DesktopClientUi, (string?)gap["detail"]);

        // The gap sits between the two retained clicks, so the omission is positioned, not just noted.
        Assert.Equal(2L, (long?)gap["firstSequence"]);
        Assert.Equal(2L, (long?)gap["lastSequence"]);
    }

    [Fact]
    public void OwnWindowGapsAreRefusedAfterStop()
    {
        CaptureEngine engine = CaptureEngine.Start(Config());
        engine.Stop();

        Assert.Throws<InvalidOperationException>(() => engine.ObserveOwnWindowInteraction());
    }

    [Fact]
    public void CapabilityTransitionsAreRecordedOnceAndShapeTheManifestSource()
    {
        CaptureEngine engine = CaptureEngine.Start(Config());
        var failed = new CapabilitySample(
            Capability.AccessibilityContext,
            CapabilityAuthorization.Granted,
            CapabilityAvailability.Unavailable,
            CapabilityReason.SourceFailure,
            "UI Automation timed out");
        engine.ObserveCapability(failed);
        engine.ObserveCapability(failed);
        engine.Stop();
        engine.ConfirmAndExport(QueueDir());

        JsonObject[] capabilities = Records(engine)
            .Where(record => (string?)record["recordType"] == CapabilityObservation.RecordType)
            .Select(record => (JsonObject)record["payload"]!)
            .ToArray();

        Assert.Equal(6, capabilities.Length);
        Assert.Equal(CapabilityTransition.SourceFailed, (string?)capabilities[^1]["transition"]);

        JsonObject manifest = ReadDocument(Path.Combine(engine.ArchiveDirectory!, "manifest.json"));
        var source = Assert.IsType<JsonObject>(Assert.IsType<JsonArray>(manifest["sources"])[0]);

        Assert.Equal(
            new[] { "pointer.capture", "keyboard.capture", "session_boundaries" },
            Assert.IsType<JsonArray>(source["capabilities"]).Select(node => (string?)node).ToArray());

        (string? Capability, string? Reason)[] unavailable = Assert
            .IsType<JsonArray>(source["unavailableCapabilities"])
            .Select(node => ((string?)node!["capability"], (string?)node["reason"]))
            .ToArray();

        Assert.Equal(
            new (string?, string?)[]
            {
                ("accessibility.context", "temporarily_unavailable"),
                ("screen.capture", "disabled_by_policy"),
                ("audio.capture", "disabled_by_policy"),
            },
            unavailable);
    }

    [Fact]
    public void RejectFinalizesNothingAndQueuesNothing()
    {
        CaptureEngine engine = CaptureEngine.Start(Config());
        engine.Observe(Click(1));
        engine.Stop();
        engine.Reject("contains a customer password");

        string queue = QueueDir();
        Directory.CreateDirectory(queue);

        Assert.Equal(EngineState.Rejected, engine.State);
        Assert.Null(engine.ArchiveDirectory);
        Assert.Empty(Directory.GetFiles(queue, "*", SearchOption.AllDirectories));
        Assert.False(Directory.Exists(Path.Combine(_root, "archives")));

        // The evidence itself is retained: the journal claim survives a rejection.
        Assert.True(Directory.Exists(
            Path.Combine(_root, CaptureJournal.StateRootName, engine.Identity.ArchiveId)));

        JsonObject decision = ReadDocument(
            Path.Combine(_root, "reviews", engine.Identity.ArchiveId + ".json"));
        Assert.Equal("reject", (string?)decision["decision"]);
        Assert.Equal("contains a customer password", (string?)decision["reason"]);

        Assert.Throws<InvalidOperationException>(() => engine.ConfirmAndExport(queue));
    }

    [Fact]
    public void ConfirmAndExportTwiceProducesIdenticalContainerBytes()
    {
        CaptureEngine engine = CaptureEngine.Start(Config());
        engine.Observe(Click(1));
        engine.Stop();

        string queue = QueueDir();
        string first = engine.ConfirmAndExport(queue);
        byte[] firstBytes = File.ReadAllBytes(first);
        string second = engine.ConfirmAndExport(queue);

        Assert.Equal(first, second);
        Assert.Equal(firstBytes, File.ReadAllBytes(second));
        Assert.Equal(EngineState.Confirmed, engine.State);
        Assert.EndsWith(".jazz-archive", second, StringComparison.Ordinal);

        JsonObject decision = ReadDocument(
            Path.Combine(_root, "reviews", engine.Identity.ArchiveId + ".json"));
        Assert.Equal("confirm", (string?)decision["decision"]);
        Assert.False(decision.ContainsKey("reason"));
    }

    [Fact]
    public void ObservingAfterStopIsRefused()
    {
        CaptureEngine engine = CaptureEngine.Start(Config());
        engine.Stop();

        Assert.Throws<InvalidOperationException>(() => engine.Observe(Click(1)));
        Assert.Throws<InvalidOperationException>(() => engine.Stop());
    }

    [Fact]
    public void ConfirmedArchivePassesTheContractValidator()
    {
        string? uv = FindUv();
        if (uv is null)
        {
            // xUnit 2.5 cannot skip at run time; the outer gate simply cannot run without uv.
            Console.WriteLine(
                "SKIPPED ConfirmedArchivePassesTheContractValidator: uv is not installed, so "
                    + "contract/archive/validate_archives.py cannot be executed.");
            return;
        }

        CaptureEngine engine = CaptureEngine.Start(Config(SecretApp));
        engine.Observe(Click(1));
        engine.Observe(Click(2));
        engine.Observe(new ClickEvent
        {
            OccurredAt = _clock.Next(),
            Application = new AppIdentity(AppIdentity.AumidNamespace, SecretApp),
        });
        engine.Observe(new InputEvent
        {
            OccurredAt = _clock.Next(),
            Application = new AppIdentity(AppIdentity.AumidNamespace, Editor),
            RawText = "invoice for john@doe.com",
            TargetRole = "Edit",
            TargetAccessibleName = "To",
        });
        engine.Observe(new NavigateEvent
        {
            OccurredAt = _clock.Next(),
            Application = new AppIdentity(AppIdentity.AumidNamespace, Browser, "Contoso Browser", "3.2.1"),
            System = "Contoso Browser",
        });
        engine.Stop();
        string zip = engine.ConfirmAndExport(QueueDir());

        Assert.True(File.Exists(zip));

        string harness = Path.Combine(_root, "validator");
        string contractCopy = Path.Combine(harness, "contract");
        CopyDirectory(Path.Combine(ContractPaths.Root(), "contract"), contractCopy);
        CopyDirectory(
            engine.ArchiveDirectory!,
            Path.Combine(contractCopy, "archive", "fixtures", "91-windows-engine"));

        (int exitCode, string output) = Run(
            uv,
            new[] { "run", "--script", Path.Combine(contractCopy, "archive", "validate_archives.py") },
            harness);

        Assert.True(exitCode == 0, "validate_archives.py failed:\n" + output);
        Assert.Contains("ok    91-windows-engine", output, StringComparison.Ordinal);
    }

    private EngineConfig Config(params string[] excludedApplications) => new(
        _root,
        "petr",
        "WIN-DEV-01",
        "1.0.0",
        excludedApplications,
        ScreenshotsEnabled: false,
        _clock.Next);

    private ClickEvent Click(int clickCount) => new()
    {
        OccurredAt = _clock.Next(),
        Application = new AppIdentity(AppIdentity.AumidNamespace, Editor, "Contoso Editor", "2.0"),
        System = "Contoso Editor",
        TargetRole = "Button",
        TargetAccessibleName = "Save",
        TargetBoundingBox = new BoundingBox(4, 8, 60, 20),
        ClickCount = clickCount,
    };

    private string QueueDir() => Path.Combine(_root, "queue");

    private static string SessionDir(CaptureEngine engine) =>
        Path.Combine(engine.ArchiveDirectory!, "sessions", engine.Identity.SessionId);

    private static IReadOnlyList<JsonObject> Records(CaptureEngine engine) =>
        File.ReadAllLines(Path.Combine(SessionDir(engine), ArchiveWriter.RecordsFileName))
            .Where(line => line.Length > 0)
            .Select(line => (JsonObject)JsonStrictParser.Parse(line)!)
            .ToArray();

    private static JsonObject[] ActivityPayloads(CaptureEngine engine) => Records(engine)
        .Where(record => (string?)record["recordType"] == ArchiveContracts.ActivityEventRecordType)
        .Select(record => (JsonObject)record["payload"]!)
        .ToArray();

    private static JsonObject ReadDocument(string path) =>
        (JsonObject)JsonStrictParser.Parse(File.ReadAllText(path, Encoding.UTF8))!;

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

    /// <summary>A monotonic injected clock: every read advances the capture by one second.</summary>
    private sealed class TestClock
    {
        private DateTimeOffset _now = new(2026, 7, 22, 8, 0, 0, TimeSpan.Zero);

        public DateTimeOffset Next()
        {
            DateTimeOffset value = _now;
            _now = _now.AddSeconds(1);
            return value;
        }
    }
}
