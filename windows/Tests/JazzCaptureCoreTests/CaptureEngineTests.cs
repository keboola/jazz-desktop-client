using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using JazzCaptureCore;
using JazzCaptureCore.Archive;
using JazzCaptureCore.Audio;
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
    private const string ArtifactKind = "attachment";
    private const string FixtureName = "91-windows-engine";

    /// <summary>How long the fixture screenshot took to acquire; also its timing error.</summary>
    private const long ScreenshotDurationMillis = 125;

    private static readonly byte[] Payload = { 0x6a, 0x61, 0x7a, 0x7a };

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
    public void ALongSelectionIsBoundedAndAnEmptyOneIsOmitted()
    {
        // The Windows host now reads real selections through TextPattern, capped at 4000 characters
        // on the way out of the provider. This is the second bound, the one the archive relies on: a
        // user can select a whole document, and no single field may inflate a record without limit.
        CaptureEngine engine = CaptureEngine.Start(Config());
        engine.Observe(new ClickEvent
        {
            OccurredAt = _clock.Next(),
            Application = new AppIdentity(AppIdentity.AumidNamespace, Editor),
            TargetRole = "Document",
            SelectedText = new string('s', 4000),
        });
        engine.Observe(new CopyEvent
        {
            OccurredAt = _clock.Next(),
            Application = new AppIdentity(AppIdentity.AumidNamespace, Editor),
            TargetRole = "Edit",
            SelectedText = "   \n  ",
        });
        engine.Stop();
        engine.ConfirmAndExport(QueueDir());

        IReadOnlyList<JsonObject> payloads = ActivityPayloads(engine);

        string selection = Assert.IsType<string>((string?)payloads[1]["selectedText"]);
        Assert.Equal(Redaction.DefaultMaxLength + Redaction.TruncationSuffix.Length, selection.Length);
        Assert.EndsWith(Redaction.TruncationSuffix, selection, StringComparison.Ordinal);

        // A selection of nothing but whitespace is no selection: the key is omitted rather than
        // written as an empty string or a null.
        Assert.False(payloads[2].ContainsKey("selectedText"));
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

    /// <summary>
    /// A long page URL survives whole. The free-text sanitizer would cut it at
    /// <see cref="Redaction.DefaultMaxLength"/> and append an ellipsis, producing an address that
    /// resolves to nothing while still looking like a location — and disagreeing with the macOS
    /// client, which applies no length bound at all. Both the click and the scroll path are checked,
    /// because both carry the field and each projects it separately.
    /// </summary>
    [Fact]
    public void ALongDocumentUrlIsCarriedWholeRatherThanTruncated()
    {
        string url = "https://contoso.example/invoices/"
            + new string('a', Redaction.DefaultMaxLength)
            + "/detail";
        Assert.True(url.Length > Redaction.DefaultMaxLength);

        CaptureEngine engine = CaptureEngine.Start(Config());
        engine.Observe(new ClickEvent
        {
            OccurredAt = _clock.Next(),
            Application = new AppIdentity(AppIdentity.AumidNamespace, Browser),
            TargetRole = "Button",
            DocumentUrl = url,
        });
        engine.Observe(new ScrollEvent
        {
            OccurredAt = _clock.Next(),
            Application = new AppIdentity(AppIdentity.AumidNamespace, Browser),
            TargetRole = "Document",
            DocumentUrl = url,
        });
        engine.Stop();
        engine.ConfirmAndExport(QueueDir());

        JsonObject[] events = ActivityPayloads(engine);
        foreach (JsonObject payload in events.Skip(1).Take(2))
        {
            Assert.Equal(url, (string?)payload["documentURL"]);
            Assert.DoesNotContain(Redaction.TruncationSuffix, (string?)payload["documentURL"]);
        }
    }

    /// <summary>An empty or whitespace-only URL is still absent rather than blank.</summary>
    [Fact]
    public void ABlankDocumentUrlIsOmittedEntirely()
    {
        CaptureEngine engine = CaptureEngine.Start(Config());
        engine.Observe(new ClickEvent
        {
            OccurredAt = _clock.Next(),
            Application = new AppIdentity(AppIdentity.AumidNamespace, Browser),
            TargetRole = "Button",
            DocumentUrl = "   ",
        });
        engine.Stop();
        engine.ConfirmAndExport(QueueDir());

        Assert.False(ActivityPayloads(engine)[1].ContainsKey("documentURL"));
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
    public void ALabelStampsEveryObservationBetweenItsBoundaries()
    {
        CaptureEngine engine = CaptureEngine.Start(Config());
        engine.Observe(Click(1));
        engine.StartLabel("  Approve the invoice  ");
        LabelSegment open = Assert.IsType<LabelSegment>(engine.OpenLabel);
        engine.Observe(Click(1));
        engine.EndLabel();
        engine.Observe(Click(1));
        engine.Stop();
        engine.ConfirmAndExport(QueueDir());

        Assert.Null(engine.OpenLabel);
        Assert.Matches("^l-[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", open.LabelId);
        // The declared text is trimmed, which is also what reaches the label document.
        Assert.Equal("Approve the invoice", open.Text);

        JsonObject[] events = ActivityPayloads(engine);
        Assert.Equal(
            new[]
            {
                "session_start", "click", "label_start", "click", "label_end", "click", "session_end",
            },
            events.Select(payload => (string?)payload["eventType"]).ToArray());

        // Only the events inside the brackets carry the label; the ones outside must stay unbound.
        Assert.Equal(
            new bool[] { false, false, true, true, true, false, false },
            events.Select(payload => payload.ContainsKey("labelId")).ToArray());

        foreach (JsonObject inside in events[2..5])
        {
            Assert.Equal(open.LabelId, (string?)inside["labelId"]);
            Assert.Equal("Approve the invoice", (string?)inside["label"]);
        }
    }

    [Fact]
    public void LabelBoundariesBelongToTheSessionAndNameOnlyTheirLabel()
    {
        CaptureEngine engine = CaptureEngine.Start(Config());
        engine.StartLabel("Reconcile the ledger");
        engine.EndLabel();
        engine.Stop();
        engine.ConfirmAndExport(QueueDir());

        JsonObject[] events = ActivityPayloads(engine);
        foreach (JsonObject boundary in new[] { events[1], events[2] })
        {
            Assert.Equal(CaptureEngine.SessionUrl, (string?)boundary["url"]);
            Assert.Equal(
                new[]
                {
                    "sessionId", "eventId", "sequence", "timestamp", "eventType", "url",
                    "labelId", "label",
                },
                boundary.Select(pair => pair.Key).ToArray());
        }

        Assert.Equal("label_start", (string?)events[1]["eventType"]);
        Assert.Equal("label_end", (string?)events[2]["eventType"]);
    }

    [Fact]
    public void DeclaringASecondLabelClosesTheFirstOne()
    {
        CaptureEngine engine = CaptureEngine.Start(Config());
        engine.StartLabel("Open the case");
        string? first = engine.OpenLabel?.LabelId;
        engine.StartLabel("Bill the case");
        string? second = engine.OpenLabel?.LabelId;
        engine.Stop();
        engine.ConfirmAndExport(QueueDir());

        Assert.NotNull(first);
        Assert.NotEqual(first, second);

        JsonObject[] events = ActivityPayloads(engine);
        Assert.Equal(
            new[] { "session_start", "label_start", "label_end", "label_start", "label_end", "session_end" },
            events.Select(payload => (string?)payload["eventType"]).ToArray());

        // The closing boundary of the first label precedes the opening boundary of the second, so
        // the two segments abut rather than nest.
        Assert.Equal(first, (string?)events[2]["labelId"]);
        Assert.Equal(second, (string?)events[3]["labelId"]);

        JsonObject[] labels = Labels(engine);
        Assert.Equal(new[] { first, second }, labels.Select(label => (string?)label["labelId"]).ToArray());
        Assert.All(labels, label => Assert.Equal("closed", (string?)label["status"]));
    }

    [Fact]
    public void StopClosesAnOpenLabelBeforeTheSessionEnds()
    {
        CaptureEngine engine = CaptureEngine.Start(Config());
        engine.StartLabel("Fix the mismatch");
        engine.Observe(Click(1));
        engine.Stop();
        engine.ConfirmAndExport(QueueDir());

        Assert.Null(engine.OpenLabel);

        JsonObject[] events = ActivityPayloads(engine);
        Assert.Equal(
            new[] { "session_start", "label_start", "click", "label_end", "session_end" },
            events.Select(payload => (string?)payload["eventType"]).ToArray());

        // Auto-closing is what keeps the segment 'closed' rather than 'interrupted': a capture the
        // user stopped normally never leaves a label dangling.
        JsonObject label = Assert.Single(Labels(engine));
        Assert.Equal("closed", (string?)label["status"]);
    }

    [Fact]
    public void EndingALabelWithoutOneOpenChangesNothing()
    {
        CaptureEngine engine = CaptureEngine.Start(Config());
        engine.EndLabel();
        engine.StartLabel("Only label");
        engine.EndLabel();
        engine.EndLabel();
        engine.Stop();
        engine.ConfirmAndExport(QueueDir());

        Assert.Equal(
            new[] { "session_start", "label_start", "label_end", "session_end" },
            ActivityPayloads(engine).Select(payload => (string?)payload["eventType"]).ToArray());
        Assert.Single(Labels(engine));
    }

    [Fact]
    public void ALabelledArchiveResolvesEveryIntervalEndpointToARealObservation()
    {
        CaptureEngine engine = CaptureEngine.Start(Config());
        engine.StartLabel("Post the journal entry");
        engine.Observe(Click(1));
        engine.EndLabel();
        engine.Stop();
        engine.ConfirmAndExport(QueueDir());

        IReadOnlyList<JsonObject> records = Records(engine);
        JsonObject label = Assert.Single(Labels(engine));

        Assert.Equal(1L, (long?)label["schemaVersion"]);
        Assert.Equal(engine.Identity.CaptureId, (string?)label["captureId"]);
        Assert.Equal("closed", (string?)label["status"]);

        var declaration = Assert.IsType<JsonObject>(label["declaration"]);
        Assert.Equal("Post the journal entry", (string?)declaration["text"]);
        Assert.Equal(engine.Identity.ActorId, (string?)declaration["declaredByActorId"]);
        Assert.Equal("free_text", (string?)declaration["mode"]);

        var provenance = Assert.IsType<JsonObject>(label["provenance"]);
        Assert.Equal("declared", (string?)provenance["factClass"]);
        Assert.Equal(
            new[] { engine.Identity.SourceId },
            Assert.IsType<JsonArray>(provenance["sources"]).Select(node => (string?)node).ToArray());
        Assert.Empty(Assert.IsType<JsonArray>(label["narrationArtifactRefs"]));

        // Both endpoints must be observations of this capture sitting at exactly the sequence the
        // interval claims — the invariant the contract validator enforces.
        var interval = Assert.IsType<JsonObject>(label["interval"]);
        JsonObject start = Endpoint(records, (string?)interval["startObservationId"]);
        JsonObject end = Endpoint(records, (string?)interval["endObservationId"]);
        Assert.Equal((long?)interval["startStreamSequence"], (long?)start["streamSequence"]);
        Assert.Equal((long?)interval["endStreamSequence"], (long?)end["streamSequence"]);
        Assert.True((long)interval["endStreamSequence"]! >= (long)interval["startStreamSequence"]!);
        Assert.Equal("label_start", (string?)start["payload"]!["eventType"]);
        Assert.Equal("label_end", (string?)end["payload"]!["eventType"]);
    }

    [Fact]
    public void LabelledObservationsCarryTheLabelOnTheirEnvelopeToo()
    {
        CaptureEngine engine = CaptureEngine.Start(Config());
        engine.Observe(Click(1));
        engine.StartLabel("Attach the receipt");
        engine.Observe(Click(1));
        engine.EndLabel();
        engine.Stop();
        engine.ConfirmAndExport(QueueDir());

        string labelId = (string)Assert.Single(Labels(engine))["labelId"]!;
        JsonObject[] activity = Records(engine)
            .Where(record => (string?)record["recordType"] == ArchiveContracts.ActivityEventRecordType)
            .ToArray();

        Assert.Equal(
            new[]
            {
                Array.Empty<string>(),
                Array.Empty<string>(),
                new[] { labelId },
                new[] { labelId },
                new[] { labelId },
                Array.Empty<string>(),
            },
            activity
                .Select(record => Assert.IsType<JsonArray>(record["labelRefs"])
                    .Select(node => (string)node!)
                    .ToArray())
                .ToArray());
    }

    [Fact]
    public void AnUnlabelledCaptureWritesNoLabelDocumentAtAll()
    {
        CaptureEngine engine = CaptureEngine.Start(Config());
        engine.Observe(Click(1));
        engine.Stop();
        engine.ConfirmAndExport(QueueDir());

        // An absent file is how the format says "nothing was declared"; an empty one would still
        // enter the inventory and change the content digest of an otherwise identical capture.
        Assert.False(File.Exists(Path.Combine(SessionDir(engine), ArchiveWriter.LabelsFileName)));

        JsonObject inventory = ReadDocument(Path.Combine(engine.ArchiveDirectory!, "inventory.json"));
        Assert.DoesNotContain(
            Assert.IsType<JsonArray>(inventory["entries"]).Select(entry => (string?)entry!["path"]),
            path => path!.EndsWith(ArchiveWriter.LabelsFileName, StringComparison.Ordinal));
    }

    [Fact]
    public void LabelsEnterTheInventoryAndThereforeTheContentDigest()
    {
        CaptureEngine engine = CaptureEngine.Start(Config());
        engine.StartLabel("Close the period");
        engine.Stop();
        engine.ConfirmAndExport(QueueDir());

        string relative = "sessions/" + engine.Identity.SessionId + "/" + ArchiveWriter.LabelsFileName;
        JsonObject inventory = ReadDocument(Path.Combine(engine.ArchiveDirectory!, "inventory.json"));
        JsonObject entry = Assert.Single(
            Assert.IsType<JsonArray>(inventory["entries"]).Select(node => (JsonObject)node!),
            candidate => (string?)candidate["path"] == relative);

        string file = Path.Combine(SessionDir(engine), ArchiveWriter.LabelsFileName);
        Assert.Equal(JazzArchiveContainer.Sha256File(file), (string?)entry["sha256"]);

        byte[] bytes = File.ReadAllBytes(file);
        Assert.NotEqual(0xEF, bytes[0]);
        Assert.Equal((byte)'\n', bytes[^1]);
        Assert.DoesNotContain((byte)'\r', bytes);
    }

    [Fact]
    public void BlankLabelTextIsRefusedAndLabelsNeedARecordingCapture()
    {
        CaptureEngine engine = CaptureEngine.Start(Config());
        Assert.Throws<ArgumentException>(() => engine.StartLabel("   "));
        Assert.Throws<ArgumentException>(() => engine.StartLabel(string.Empty));
        engine.Stop();

        Assert.Throws<InvalidOperationException>(() => engine.StartLabel("too late"));
        Assert.Throws<InvalidOperationException>(() => engine.EndLabel());
    }

    [Fact]
    public void LongLabelTextIsBoundedLikeEveryOtherFreeTextField()
    {
        CaptureEngine engine = CaptureEngine.Start(Config());
        engine.StartLabel(new string('x', Redaction.DefaultMaxLength + 40));
        engine.Stop();
        engine.ConfirmAndExport(QueueDir());

        var declared = (string)Assert.Single(Labels(engine))["declaration"]!["text"]!;
        Assert.Equal(Redaction.DefaultMaxLength + Redaction.TruncationSuffix.Length, declared.Length);
        Assert.EndsWith(Redaction.TruncationSuffix, declared, StringComparison.Ordinal);
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
    public void AnAttachedArtifactIsCitedByItsObservationAndCitesItBack()
    {
        CaptureEngine engine = CaptureEngine.Start(Config());
        engine.StartLabel("Enter the supplier invoice");
        string? artifactId = engine.ObserveWithArtifact(Click(1), Attachment());
        engine.EndLabel();
        StopResult stopped = engine.Stop();
        engine.ConfirmAndExport(QueueDir());

        Assert.NotNull(artifactId);
        Assert.StartsWith("art-", artifactId, StringComparison.Ordinal);
        Assert.Equal(1, stopped.ArtifactCount);

        JsonObject artifact = Assert.Single(Artifacts(engine));
        Assert.Equal(artifactId, (string?)artifact["artifactId"]);
        Assert.Equal(engine.Identity.CaptureId, (string?)artifact["captureId"]);
        Assert.Equal(ArtifactKind, (string?)artifact["kind"]);

        JsonObject citing = Assert.Single(
            Records(engine),
            record => ((JsonArray)record["artifactRefs"]!).Count > 0);
        JsonObject reference = Assert.IsType<JsonObject>(Assert.Single((JsonArray)citing["artifactRefs"]!));
        Assert.Equal(artifactId, (string?)reference["artifactId"]);
        Assert.Equal(ArtifactKind, (string?)reference["role"]);

        // Both directions: the record cites the artifact, and the artifact names the observation it
        // belongs to plus the label that was open when the bytes were produced.
        Assert.Equal(
            new[] { (string?)citing["observationId"] },
            ((JsonArray)artifact["observationRefs"]!).Select(node => (string?)node).ToArray());
        Assert.Equal(
            ((JsonArray)citing["labelRefs"]!).Select(node => (string?)node).ToArray(),
            ((JsonArray)artifact["labelRefs"]!).Select(node => (string?)node).ToArray());
        Assert.Single((JsonArray)artifact["labelRefs"]!);
    }

    [Fact]
    public void AnEventTheOwnerGateRefusesIngestsNoBytes()
    {
        CaptureEngine engine = CaptureEngine.Start(Config(SecretApp));

        string? denylisted = engine.ObserveWithArtifact(
            new ClickEvent
            {
                OccurredAt = _clock.Next(),
                Application = new AppIdentity(AppIdentity.AumidNamespace, SecretApp),
            },
            Attachment());
        string? unowned = engine.ObserveWithArtifact(
            new ClickEvent { OccurredAt = _clock.Next() },
            Attachment());

        StopResult stopped = engine.Stop();
        engine.ConfirmAndExport(QueueDir());

        // The refusal is still evidence — both events consumed a stream position and became gaps —
        // but the payload the policy just declined to keep never reached the disk.
        Assert.Null(denylisted);
        Assert.Null(unowned);
        Assert.Equal(0, stopped.ArtifactCount);
        Assert.Equal(2, stopped.GapCount);
        Assert.False(Directory.Exists(Path.Combine(engine.ArchiveDirectory!, "blobs")));
        Assert.False(File.Exists(Path.Combine(SessionDir(engine), ArchiveWriter.ArtifactsFileName)));
    }

    [Fact]
    public void AnAttachmentTheArchiveCouldNotAcceptIsRefusedBeforeAnythingIsReserved()
    {
        CaptureEngine engine = CaptureEngine.Start(Config());

        Assert.Throws<ArgumentException>(() => engine.ObserveWithArtifact(
            Click(1),
            new ArtifactAttachment("Screenshot", "image/jpeg", Payload)));

        // The rejected call left no reservation behind, so the capture still commits: an argument
        // mistake must not cost the whole recording.
        engine.Observe(Click(1));
        StopResult stopped = engine.Stop();
        Assert.Equal(0, stopped.ArtifactCount);
        Assert.Equal(0, stopped.GapCount);
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

        CaptureEngine engine = Recorded();
        string zip = engine.ConfirmAndExport(QueueDir());

        Assert.True(File.Exists(zip));

        JsonObject[] labels = Labels(engine);
        Assert.Equal(2, labels.Length);
        Assert.All(labels, label => Assert.Equal("closed", (string?)label["status"]));

        string fixture = Validate(engine, out int exitCode, out string output);

        Assert.True(exitCode == 0, "validate_archives.py failed:\n" + output);
        Assert.Contains("ok    " + FixtureName, output, StringComparison.Ordinal);

        // The fixture the validator just accepted really did carry the labels and a real artifact
        // with its blob, so the pass is evidence about archives that have them rather than about an
        // archive that happened to have none.
        Assert.True(File.Exists(Path.Combine(
            fixture,
            "sessions",
            engine.Identity.SessionId,
            ArchiveWriter.LabelsFileName)));
        Assert.True(File.Exists(Path.Combine(
            fixture,
            "sessions",
            engine.Identity.SessionId,
            ArchiveWriter.ArtifactsFileName)));
        Assert.All(Blobs(fixture), blob => Assert.True(File.Exists(blob)));

        // A narration clip is in there too, and the validator resolves references in both
        // directions: the clip names its label, and the label names the clip back. A one-way link
        // would pass a shape check and still leave a reader unable to tell which task was narrated.
        JsonObject[] narration = Artifacts(engine)
            .Where(artifact => (string?)artifact["kind"] == NarrationAudioV1.Kind)
            .ToArray();

        // One clip per label, because the microphone runs inside a label and nowhere else.
        Assert.Equal(labels.Length, narration.Length);
        Assert.All(narration, clip =>
        {
            Assert.Equal(NarrationWave.MediaType, (string?)clip["content"]?["mediaType"]);

            // Both sides are arrays of bare identifiers, not ref objects.
            string narratedLabel = Assert.Single(
                Assert.IsType<JsonArray>(clip["labelRefs"]).Select(id => (string?)id))!;
            JsonObject owner = Assert.Single(
                labels,
                label => (string?)label["labelId"] == narratedLabel);
            Assert.Contains(
                Assert.IsType<JsonArray>(owner["narrationArtifactRefs"]).Select(id => (string?)id),
                artifactId => artifactId == (string?)clip["artifactId"]);
        });

        // And one of those artifacts is a screenshot carrying the whole evidence profile, so the
        // pass covers the conditional rules the validator only reaches once a v1 key is present.
        JsonObject screenshot = Assert.Single(
            Artifacts(engine),
            artifact => (string?)artifact["kind"] == ScreenshotEvidenceV1.Kind);
        var extensions = Assert.IsType<JsonObject>(screenshot["extensions"]);
        Assert.Equal(
            new[]
            {
                ScreenshotEvidenceV1.RequestStartedAtKey,
                ScreenshotEvidenceV1.FrameCompletedAtKey,
                ScreenshotEvidenceV1.MonotonicDurationMillisKey,
                ScreenshotEvidenceV1.ScopeKey,
                ScreenshotEvidenceV1.OwnerBundleIdKey,
                ScreenshotEvidenceV1.WindowIdKey,
            },
            extensions.Select(pair => pair.Key).ToArray());
        Assert.Equal("image/jpeg", (string?)screenshot["content"]!["mediaType"]);
        Assert.Equal("partial", (string?)screenshot["quality"]!["status"]);
        Assert.Equal(ScreenshotDurationMillis, (long?)screenshot["quality"]!["timingErrorMillis"]);

        // The frozen capture policy admits the modality the profile cross-checks against, and the
        // citing observation is partial for the same reason the artifact is.
        JsonObject session = ReadDocument(Path.Combine(
            fixture,
            "sessions",
            engine.Identity.SessionId,
            "session.json"));
        Assert.Contains(
            "screenshots",
            Assert.IsType<JsonArray>(session["capturePolicy"]!["modalities"])
                .Select(node => (string?)node));

        JsonObject citing = Assert.Single(
            Records(engine),
            record => ((JsonArray)record["artifactRefs"]!)
                .Any(node => (string?)node!["role"] == ScreenshotEvidenceV1.Role));
        Assert.Equal("partial", (string?)citing["quality"]!["status"]);
        Assert.Equal(
            new[] { ScreenshotEvidenceV1.TemporalIntervalReason },
            Assert.IsType<JsonArray>(citing["quality"]!["reasons"]).Select(node => (string?)node).ToArray());
    }

    /// <summary>
    /// The other half of the gate. The archive is internally consistent — every digest checks out,
    /// the blob hashes to its own name — and it is still rejected, because the screenshot's declared
    /// interval is one millisecond wider than the monotonic duration it claims to have measured.
    /// That is the whole point of the profile: two producers must not be able to disagree about when
    /// a frame was taken while both look locally well-formed.
    /// </summary>
    [Fact]
    public void TheContractValidatorRejectsAnInconsistentScreenshotProfile()
    {
        string? uv = FindUv();
        if (uv is null)
        {
            Console.WriteLine(
                "SKIPPED TheContractValidatorRejectsAnInconsistentScreenshotProfile: uv is not "
                    + "installed, so contract/archive/validate_archives.py cannot be executed.");
            return;
        }

        CaptureEngine engine = CaptureEngine.Start(Config(screenshots: true));

        // Built by hand rather than through ScreenshotEvidence.Attach, which refuses this: the
        // engine deliberately does not second-guess a host's evidence profile, so a producer that
        // skips the builder can reach the archive with a broken one.
        ScreenshotEvidence sound = Screenshot();
        var broken = new ArtifactAttachment(
            ScreenshotEvidenceV1.Kind,
            ScreenshotEvidenceV1.MediaType,
            ScreenshotBytes.TinyJpeg)
        {
            Role = ScreenshotEvidenceV1.Role,
            SourceRole = ScreenshotEvidenceV1.SourceRole,
            CaptureInterval = sound.CaptureInterval(),
            Quality = new ArtifactQuality(
                ArtifactQualityStatus.Partial,
                new[] { ScreenshotEvidenceV1.TemporalIntervalReason },
                ScreenshotDurationMillis - 1),
            Privacy = ArtifactPrivacy.Captured("consent-v1"),
            Extensions = Extensions(sound, ScreenshotDurationMillis - 1),
        };

        Assert.NotEmpty(ScreenshotEvidenceProfile.Errors(broken, engine.CapturePolicy));

        engine.ObserveWithArtifact(Click(1), broken, broken.Quality);
        engine.Stop();
        engine.ConfirmAndExport(QueueDir());

        (int exitCode, string output) = RunValidator(uv, Stage(engine));

        Assert.True(
            exitCode != 0,
            "validate_archives.py accepted an inconsistent screenshot profile:\n" + output);
        Assert.Contains(
            "screenshot interval differs from its monotonic duration",
            output,
            StringComparison.Ordinal);
    }

    /// <summary>
    /// The narration counterpart. A clip that names a label the archive does not contain is the
    /// failure mode a one-way reference check would miss: the artifact is well-formed, its bytes
    /// hash correctly, and every digest still agrees. Only resolving the reference catches it, and
    /// a reader who cannot resolve it cannot say which task was narrated.
    /// </summary>
    [Fact]
    public void TheContractValidatorRejectsNarrationBoundToAnAbsentLabel()
    {
        string? uv = FindUv();
        if (uv is null)
        {
            Console.WriteLine(
                "SKIPPED TheContractValidatorRejectsNarrationBoundToAnAbsentLabel: uv is not "
                    + "installed, so contract/archive/validate_archives.py cannot be executed.");
            return;
        }

        CaptureEngine engine = Recorded();
        engine.ConfirmAndExport(QueueDir());
        string fixture = Stage(engine);

        // Repoint one clip at a label id that never existed, then reseal every digest around the
        // edit the way a determined producer would, so the reference is the only thing left wrong.
        string labels = Path.Combine(fixture, "sessions", engine.Identity.SessionId, ArchiveWriter.LabelsFileName);
        string artifacts = Path.Combine(fixture, "sessions", engine.Identity.SessionId, ArchiveWriter.ArtifactsFileName);
        string absent = "l-00000000-0000-7000-8000-0000000000ff";

        string[] lines = File.ReadAllLines(artifacts);
        var rewritten = new List<string>(lines.Length);
        var repointed = false;
        foreach (string line in lines)
        {
            JsonObject artifact = (JsonObject)JsonStrictParser.Parse(line)!;
            if (!repointed && (string?)artifact["kind"] == NarrationAudioV1.Kind)
            {
                artifact["labelRefs"] = new JsonArray(absent);
                repointed = true;
            }

            rewritten.Add(artifact.ToJsonString());
        }

        Assert.True(repointed, "the recorded archive carried no narration clip to repoint");
        File.WriteAllText(artifacts, string.Join("\n", rewritten) + "\n", new UTF8Encoding(false));
        ArchiveFixtures.ResealInventoryAndManifest(fixture);

        (int exitCode, string output) = RunValidator(uv, fixture);

        Assert.True(
            exitCode != 0,
            "validate_archives.py accepted a narration clip bound to an absent label:\n" + output);

        // Naming the reason matters: without it this would still pass if the reseal had left some
        // unrelated digest wrong, and the test would prove nothing about reference resolution.
        Assert.Contains("references unknown label", output, StringComparison.Ordinal);
        Assert.True(
            File.Exists(labels),
            "the labels file the clip should have referenced is missing from the fixture");
    }

    /// <summary>
    /// Proves the gate above has teeth. The archive is byte-identical to the one the validator just
    /// accepted except for a single flipped bit inside the blob, and that has to be enough: an
    /// artifact whose bytes no longer hash to their own name is exactly the failure the
    /// content-addressed layout exists to catch.
    /// </summary>
    [Fact]
    public void TheContractValidatorRejectsAnArchiveWhoseBlobWasCorrupted()
    {
        string? uv = FindUv();
        if (uv is null)
        {
            Console.WriteLine(
                "SKIPPED TheContractValidatorRejectsAnArchiveWhoseBlobWasCorrupted: uv is not "
                    + "installed, so contract/archive/validate_archives.py cannot be executed.");
            return;
        }

        CaptureEngine engine = Recorded();
        engine.ConfirmAndExport(QueueDir());

        string fixture = Stage(engine);
        string blob = Blobs(fixture)[0];
        byte[] bytes = File.ReadAllBytes(blob);
        bytes[0] ^= 0x01;
        File.WriteAllBytes(blob, bytes);

        (int exitCode, string output) = RunValidator(uv, fixture);

        Assert.True(exitCode != 0, "validate_archives.py accepted a corrupted blob:\n" + output);
        Assert.Contains("content sha256 differs", output, StringComparison.Ordinal);
    }

    /// <summary>
    /// The capture the validator tests run against: a denylisted click, two bracketed segments —
    /// one the user closed by hand, one Stop had to close for them — one observation that produced
    /// neutral bytes, and one click that produced a real screenshot with its whole evidence profile.
    /// </summary>
    /// <summary>
    /// A recorder that seals one clip per label, which is the only shape narration takes: the
    /// microphone runs inside a label and nowhere else.
    /// </summary>
    private FakeNarrationSource Narrator()
    {
        var source = new FakeNarrationSource();
        for (var clip = 0; clip < 2; clip++)
        {
            source.ThenStart(NarrationStartResult.Started)
                .ThenSeal(NarrationSealResult.Sealed(new NarrationClip(
                    _clock.Next().ToString("yyyy-MM-ddTHH:mm:ss.fffZ", CultureInfo.InvariantCulture),
                    _clock.Next().ToString("yyyy-MM-ddTHH:mm:ss.fffZ", CultureInfo.InvariantCulture),
                    NarrationWave.Wrap(new byte[320]),
                    NarrationWave.MediaType)));
        }

        return source;
    }

    private CaptureEngine Recorded()
    {
        EngineConfig config = Config(screenshots: true, SecretApp) with
        {
            NarrationEnabled = true,
            NarrationSource = Narrator(),
        };
        CaptureEngine engine = CaptureEngine.Start(config);
        engine.Observe(Click(1));
        engine.Observe(Click(2));
        engine.Observe(new ClickEvent
        {
            OccurredAt = _clock.Next(),
            Application = new AppIdentity(AppIdentity.AumidNamespace, SecretApp),
        });

        engine.StartLabel("Enter the supplier invoice");
        engine.Observe(new InputEvent
        {
            OccurredAt = _clock.Next(),
            Application = new AppIdentity(AppIdentity.AumidNamespace, Editor),
            RawText = "invoice for john@doe.com",
            TargetRole = "Edit",
            TargetAccessibleName = "To",
        });
        engine.ObserveWithArtifact(Click(1), Attachment());

        ScreenshotEvidence screenshot = Screenshot();
        ArtifactAttachment frame = screenshot.Attach(ScreenshotBytes.TinyJpeg, engine.CapturePolicy);
        engine.ObserveWithArtifact(Click(1), frame, frame.Quality);

        engine.EndLabel();
        engine.StartLabel("Check it against the purchase order");
        engine.Observe(new NavigateEvent
        {
            OccurredAt = _clock.Next(),
            Application = new AppIdentity(AppIdentity.AumidNamespace, Browser, "Contoso Browser", "3.2.1"),
            System = "Contoso Browser",
        });
        engine.Stop();
        return engine;
    }

    /// <summary>
    /// Copies the contract tree into a scratch root and adds the finalized archive as one more
    /// fixture. validate_archives.py takes no arguments: it validates every directory inside the
    /// fixtures directory next to itself.
    /// </summary>
    private string Stage(CaptureEngine engine)
    {
        string contractCopy = Path.Combine(_root, "validator", "contract");
        if (!Directory.Exists(contractCopy))
        {
            CopyDirectory(Path.Combine(ContractPaths.Root(), "contract"), contractCopy);
        }

        string fixture = Path.Combine(contractCopy, "archive", "fixtures", FixtureName);
        CopyDirectory(engine.ArchiveDirectory!, fixture);
        return fixture;
    }

    private string Validate(CaptureEngine engine, out int exitCode, out string output)
    {
        string fixture = Stage(engine);
        (exitCode, output) = RunValidator(FindUv()!, fixture);
        return fixture;
    }

    private (int ExitCode, string Output) RunValidator(string uv, string fixture)
    {
        string harness = Path.Combine(_root, "validator");
        return Run(
            uv,
            new[] { "run", "--script", Path.Combine(harness, "contract", "archive", "validate_archives.py") },
            harness);
    }

    /// <summary>Every blob of the archive at <paramref name="archiveDir"/>, in a stable order.</summary>
    private static string[] Blobs(string archiveDir) =>
        Directory.GetFiles(Path.Combine(archiveDir, "blobs"), "*", SearchOption.AllDirectories)
            .OrderBy(path => path, StringComparer.Ordinal)
            .ToArray();

    /// <summary>
    /// A neutral payload, proving the artifact pipeline works for a kind that drags in no evidence
    /// profile of its own.
    /// </summary>
    private static ArtifactAttachment Attachment() => new(ArtifactKind, "application/octet-stream", Payload);

    /// <summary>One window-scope screenshot's acquisition evidence, at a fixed point in the capture.</summary>
    private static ScreenshotEvidence Screenshot() => ScreenshotEvidence.FromMonotonicDuration(
        new DateTimeOffset(2026, 7, 22, 8, 0, 10, TimeSpan.Zero),
        ScreenshotDurationMillis,
        new ScreenshotWindowScope(Editor, 4242));

    /// <summary>
    /// The evidence's extensions with a caller-chosen duration, so a test can write one that
    /// disagrees with the interval it sits next to.
    /// </summary>
    private static JsonObject Extensions(ScreenshotEvidence evidence, long durationMillis)
    {
        JsonObject extensions = evidence.Extensions();
        extensions[ScreenshotEvidenceV1.MonotonicDurationMillisKey] = durationMillis;
        return extensions;
    }

    private EngineConfig Config(params string[] excludedApplications) =>
        Config(screenshots: false, excludedApplications);

    private EngineConfig Config(bool screenshots, params string[] excludedApplications) => new(
        _root,
        "petr",
        "WIN-DEV-01",
        "1.0.0",
        excludedApplications,
        ScreenshotsEnabled: screenshots,
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

    private static JsonObject[] Artifacts(CaptureEngine engine) =>
        File.ReadAllLines(Path.Combine(SessionDir(engine), ArchiveWriter.ArtifactsFileName))
            .Where(line => line.Length > 0)
            .Select(line => (JsonObject)JsonStrictParser.Parse(line)!)
            .ToArray();

    private static JsonObject[] Labels(CaptureEngine engine) =>
        File.ReadAllLines(Path.Combine(SessionDir(engine), ArchiveWriter.LabelsFileName))
            .Where(line => line.Length > 0)
            .Select(line => (JsonObject)JsonStrictParser.Parse(line)!)
            .ToArray();

    /// <summary>The record an interval endpoint names, or a failure naming the dangling reference.</summary>
    private static JsonObject Endpoint(IReadOnlyList<JsonObject> records, string? observationId)
    {
        Assert.NotNull(observationId);
        return Assert.Single(records, record => (string?)record["observationId"] == observationId);
    }

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
