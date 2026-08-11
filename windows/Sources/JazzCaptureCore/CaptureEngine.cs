using System.Text;
using System.Text.Json.Nodes;
using JazzCaptureCore.Archive;
using JazzCaptureCore.Journal;

namespace JazzCaptureCore;

/// <summary>
/// Turns host-normalized input observations into one reviewable Jazz Archive.
/// </summary>
/// <remarks>
/// <para>
/// The engine is the only place that knows the session lifecycle of ANNEX-HOST section 5:
/// <c>starting → recording → closing_input → draining → committed → confirmed | rejected</c>. It
/// owns exactly one <see cref="CaptureJournal"/>, mints the archive identity before the first hook
/// exists, and never lets an observation reach the archive without first reserving a durable stream
/// position for it — which is what makes a dropped event an explicit gap instead of a renumbering.
/// </para>
/// <para>
/// Two rules shape everything below. First, an event the policy refuses is still evidence: a
/// denylisted application or an unresolvable owner consumes its reserved sequence and resolves to a
/// gap with a reason. Second, nothing is finalized before a human decides: <see cref="Stop"/> writes
/// the capture commit and stops there, and only <see cref="ConfirmAndExport"/> writes the archive
/// directory and the container.
/// </para>
/// <para>
/// An observation may bring bytes with it — <see cref="ObserveWithArtifact"/> is how a screenshot or
/// a narration clip reaches the archive. The engine binds the two together: the artifact names the
/// observation it belongs to, the record cites the artifact, and the bytes are durable before either
/// claim exists. The host says what the payload is; the engine says what it belongs to.
/// </para>
/// <para>
/// The MVP processes events synchronously on the calling thread under one lock. Hosts call from hook
/// threads, so every public member is serialized; the asynchronous enrichment pipeline of the macOS
/// client (screenshot plus UI Automation racing a deferred click timer) is the host's job, and it
/// hands the engine only completed observations.
/// </para>
/// </remarks>
public sealed class CaptureEngine
{
    /// <summary>URL carried by session and label events, which belong to no application.</summary>
    public const string SessionUrl = "app://session";

    /// <summary>Scheme prefix of an application-scoped event URL.</summary>
    public const string ApplicationUrlPrefix = "app://";

    /// <summary>Prefix required by the schema's <c>gestureId</c> pattern.</summary>
    public const string GestureIdPrefix = "gesture-";

    /// <summary>Capability token every capture supplies by construction.</summary>
    public const string SessionBoundariesCapability = "session_boundaries";

    /// <summary>Subdirectory of the capture root that receives finalized archive directories.</summary>
    public const string ArchivesDirectoryName = "archives";

    /// <summary>Subdirectory of the capture root that records review decisions.</summary>
    public const string ReviewsDirectoryName = "reviews";

    /// <summary>File extension of an exported container.</summary>
    public const string ContainerExtension = ".jazz-archive";

    /// <summary>Review decision recorded when the archive is confirmed.</summary>
    public const string ConfirmDecision = "confirm";

    /// <summary>Review decision recorded when the archive is rejected.</summary>
    public const string RejectDecision = "reject";

    private const string SessionStartEventType = "session_start";
    private const string SessionEndEventType = "session_end";
    private const string LabelStartEventType = "label_start";
    private const string LabelEndEventType = "label_end";
    private const string ObservationIdPrefix = "obs";
    private const int ReviewDecisionSchemaVersion = 1;

    private static readonly UTF8Encoding Utf8NoBom = new(encoderShouldEmitUTF8Identifier: false);

    private readonly object _gate = new();
    private readonly EngineConfig _config;
    private readonly CaptureJournal _journal;
    private readonly CapabilityStateMachine _capabilityStates = new();
    private readonly List<CapabilityObservation> _capabilityObservations = new();
    private readonly Dictionary<Capability, CapabilitySample> _latestSamples = new();
    private readonly HashSet<string> _denylist;
    private readonly string _startedAt;

    /// <summary>
    /// Every label declared during this capture, in declaration order. The list is state, not a
    /// second durable store: each entry is a reduction over two observations that are already on the
    /// stream, so it is rebuilt at finalization rather than persisted alongside the journal.
    /// </summary>
    private readonly List<LabelSegment> _labels = new();

    private long _eventSequence;

    /// <summary>Index into <see cref="_labels"/> of the open segment, or -1 when none is open.</summary>
    private int _openLabelIndex = -1;

    private CommitResult? _commit;
    private string? _archiveDirectory;

    private CaptureEngine(EngineConfig config, ArchiveIdentity identity, CaptureJournal journal, string startedAt)
    {
        _config = config;
        _journal = journal;
        _startedAt = startedAt;
        _denylist = new HashSet<string>(config.ExcludedApplications, StringComparer.OrdinalIgnoreCase);
        Identity = identity;
        State = EngineState.Recording;
    }

    /// <summary>Every identifier this capture writes. Minted once, before recording began.</summary>
    public ArchiveIdentity Identity { get; }

    /// <summary>Current lifecycle phase.</summary>
    public EngineState State { get; private set; }

    /// <summary>Activity events retained so far; the tray host shows this as the event count.</summary>
    public long EventCount
    {
        get
        {
            lock (_gate)
            {
                return _eventSequence;
            }
        }
    }

    /// <summary>
    /// The bracketed label the user currently has open, or <see langword="null"/> when they have
    /// declared none. The tray host shows its text and offers to end it.
    /// </summary>
    public LabelSegment? OpenLabel
    {
        get
        {
            lock (_gate)
            {
                return _openLabelIndex < 0 ? null : _labels[_openLabelIndex];
            }
        }
    }

    /// <summary>
    /// The finalized archive directory, or <see langword="null"/> until the archive is confirmed.
    /// Rejection never produces one.
    /// </summary>
    public string? ArchiveDirectory
    {
        get
        {
            lock (_gate)
            {
                return _archiveDirectory;
            }
        }
    }

    /// <summary>
    /// Mints an archive identity, claims its journal, and begins recording with
    /// <c>session_start</c> plus the initial capability observations.
    /// </summary>
    /// <param name="config">The frozen capture policy and producer facts.</param>
    /// <exception cref="ArgumentException">The configuration is incomplete.</exception>
    /// <exception cref="CaptureJournalException">The journal could not be claimed.</exception>
    public static CaptureEngine Start(EngineConfig config)
    {
        ArgumentNullException.ThrowIfNull(config);
        ArgumentException.ThrowIfNullOrWhiteSpace(config.RootDir, nameof(config));
        ArgumentException.ThrowIfNullOrWhiteSpace(config.ProducerVersion, nameof(config));
        ArgumentException.ThrowIfNullOrWhiteSpace(config.ProducerName, nameof(config));
        ArgumentException.ThrowIfNullOrWhiteSpace(config.PolicyVersion, nameof(config));
        ArgumentException.ThrowIfNullOrWhiteSpace(config.SourceKind, nameof(config));
        ArgumentNullException.ThrowIfNull(config.User);
        ArgumentNullException.ThrowIfNull(config.InstanceName);
        ArgumentNullException.ThrowIfNull(config.ExcludedApplications);
        ArgumentNullException.ThrowIfNull(config.Modalities);
        ArgumentNullException.ThrowIfNull(config.Clock);

        ArchiveIdentity identity = ArchiveIdentity.Mint();
        DateTimeOffset now = config.Clock();
        Directory.CreateDirectory(config.RootDir);

        // The claim precedes every hook: an archive identity is never reused, even after a crash
        // between this line and the first observation.
        CaptureJournal journal = CaptureJournal.Prepare(
            config.RootDir,
            identity.ArchiveId,
            identity.CaptureId,
            identity.StreamId);
        journal.StartRecording();

        var engine = new CaptureEngine(config, identity, journal, Timestamps.IsoMillisUtc(now));
        engine.AppendSessionEvent(SessionStartEventType, now);
        engine.SeedCapabilities(now);
        return engine;
    }

    /// <summary>
    /// Admits one host observation. The owner gate runs first: an unresolved or denylisted
    /// application consumes a stream position and resolves to a gap rather than disappearing.
    /// </summary>
    /// <param name="hostEvent">The normalized observation.</param>
    /// <exception cref="InvalidOperationException">The engine is no longer recording.</exception>
    public void Observe(HostEvent hostEvent)
    {
        ArgumentNullException.ThrowIfNull(hostEvent);

        lock (_gate)
        {
            Admit(hostEvent, attachment: null);
        }
    }

    /// <summary>
    /// Admits one host observation together with the bytes it produced — a screenshot of the click,
    /// the narration recorded over it — and returns the artifact identity the archive will carry.
    /// </summary>
    /// <param name="hostEvent">The normalized observation.</param>
    /// <param name="attachment">The payload and everything the archive says about it.</param>
    /// <returns>
    /// The artifact identity, or <see langword="null"/> when the owner gate refused the event. A
    /// refused event has no observation for the artifact to belong to, so nothing is ingested: the
    /// bytes would otherwise outlive the evidence that explains them, which is precisely the
    /// material the policy just declined to keep.
    /// </returns>
    /// <remarks>
    /// The attachment is validated before any reservation is made. A declaration that could never
    /// become a valid document must not leave a reservation behind, because an unresolved
    /// reservation blocks the commit until recovery clears it — an argument mistake would then cost
    /// the whole capture rather than one call.
    /// </remarks>
    /// <exception cref="InvalidOperationException">The engine is no longer recording.</exception>
    /// <exception cref="ArgumentException">The attachment cannot produce a valid artifact.</exception>
    public string? ObserveWithArtifact(HostEvent hostEvent, ArtifactAttachment attachment)
    {
        ArgumentNullException.ThrowIfNull(hostEvent);
        ArgumentNullException.ThrowIfNull(attachment);

        lock (_gate)
        {
            attachment.Declare(Array.Empty<string>(), Array.Empty<string>()).Validate();
            return Admit(hostEvent, attachment);
        }
    }

    /// <summary>
    /// The owner gate shared by both entry points, and the only place a host observation becomes
    /// either a record or a gap.
    /// </summary>
    private string? Admit(HostEvent hostEvent, ArtifactAttachment? attachment)
    {
        RequireState(EngineState.Recording);

        AppIdentity? application = hostEvent.Application;
        if (application is null || !application.IsResolved)
        {
            ReserveGap(GapReasons.IntentionallyOmitted, CaptureGapDetails.OwnerUnavailable);
            return null;
        }

        if (_denylist.Contains(application.Value))
        {
            ReserveGap(GapReasons.IntentionallyOmitted, CaptureGapDetails.ApplicationDenylist);
            return null;
        }

        // A typing run whose redaction leaves nothing behind never becomes an event, so it must
        // not consume a stream position either: there is no evidence to declare missing.
        if (hostEvent is InputEvent input && Redaction.RedactTyped(input.RawText, _config.MaxTextLength).Value is null)
        {
            return null;
        }

        return Append(
            sequence => Project(hostEvent, application, sequence),
            hostEvent.OccurredAt,
            attachment).ArtifactId;
    }

    /// <summary>
    /// Records that an interaction landed on the capture client's own UI. The gesture reached the
    /// hooks and was deliberately not retained, so it consumes a stream position and resolves to a
    /// gap rather than disappearing: the reviewer sees an explicit interval with a reason instead of
    /// an unexplained silence in the stream.
    /// </summary>
    /// <exception cref="InvalidOperationException">The engine is no longer recording.</exception>
    public void ObserveOwnWindowInteraction()
    {
        lock (_gate)
        {
            RequireState(EngineState.Recording);
            ReserveGap(GapReasons.IntentionallyOmitted, CaptureGapDetails.DesktopClientUi);
        }
    }

    /// <summary>
    /// Reduces one capability poll. Unchanged pairs are silent; a changed pair becomes a canonical
    /// observation that is appended to the stream when the archive is finalized.
    /// </summary>
    /// <param name="sample">The polled capability state.</param>
    /// <exception cref="InvalidOperationException">
    /// The engine is no longer recording, or the sample is not a legal capability state.
    /// </exception>
    public void ObserveCapability(CapabilitySample sample)
    {
        ArgumentNullException.ThrowIfNull(sample);

        lock (_gate)
        {
            RequireState(EngineState.Recording);
            RecordCapability(sample, _config.Clock());
        }
    }

    /// <summary>
    /// Opens a bracketed label: the user's own declaration of what they are doing. Everything the
    /// engine retains from here until the segment closes carries the label, which is what turns an
    /// undifferentiated event stream into named process steps.
    /// </summary>
    /// <param name="text">The declared task name; trimmed and length-bounded before it is written.</param>
    /// <remarks>
    /// Exactly one label is open at a time, so an already-open segment is closed first — the
    /// declaration itself is the boundary between the two, and nesting would make the interval of
    /// the outer one meaningless.
    /// </remarks>
    /// <exception cref="InvalidOperationException">The engine is no longer recording.</exception>
    /// <exception cref="ArgumentException">The text is blank.</exception>
    public void StartLabel(string text)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(text);

        lock (_gate)
        {
            RequireState(EngineState.Recording);

            string declared = Sanitize(text)
                ?? throw new ArgumentException("Label text is empty once sanitized.", nameof(text));

            DateTimeOffset now = _config.Clock();
            CloseOpenLabel(now);

            string labelId = Identifiers.Prefixed(LabelSegment.IdPrefix);
            Appended anchor = AppendLabelEvent(LabelStartEventType, labelId, declared, now);

            _openLabelIndex = _labels.Count;
            _labels.Add(new LabelSegment(
                labelId,
                declared,
                Timestamps.IsoMillisUtc(now),
                anchor.ObservationId,
                anchor.StreamSequence));
        }
    }

    /// <summary>
    /// Closes the open bracketed label, anchoring its interval to the <c>label_end</c> observation.
    /// Does nothing when no label is open.
    /// </summary>
    /// <exception cref="InvalidOperationException">The engine is no longer recording.</exception>
    public void EndLabel()
    {
        lock (_gate)
        {
            RequireState(EngineState.Recording);

            if (_openLabelIndex < 0)
            {
                return;
            }

            CloseOpenLabel(_config.Clock());
        }
    }

    /// <summary>
    /// Closes input, drains, and writes the capture commit. Nothing is finalized and nothing leaves
    /// the machine: the archive still needs a review decision.
    /// </summary>
    /// <exception cref="InvalidOperationException">The engine is no longer recording.</exception>
    public StopResult Stop()
    {
        lock (_gate)
        {
            RequireState(EngineState.Recording);

            DateTimeOffset now = _config.Clock();

            // A label left open at Stop is closed before the session ends, never by the session
            // ending: the segment has to be bounded by its own boundary observation, and
            // session_end must stay the last activity event of the capture.
            CloseOpenLabel(now);
            AppendSessionEvent(SessionEndEventType, now);

            _journal.CloseInput();
            _journal.BeginDraining();
            CommitResult commit = _journal.Commit(Timestamps.IsoMillisUtc(now));

            _commit = commit;
            State = EngineState.Committed;

            return new StopResult(
                Identity.ArchiveId,
                Identity.CaptureId,
                Identity.SessionId,
                _startedAt,
                commit.EndedAt,
                commit.Status,
                commit.Records.Count,
                commit.Gaps.Count,
                _capabilityObservations.Count,
                commit.Artifacts.Count);
        }
    }

    /// <summary>
    /// Accepts the archive: writes the finalized directory, records the decision, and exports the
    /// container into the delivery queue. This is the first moment anything may leave the capture
    /// root.
    /// </summary>
    /// <param name="queueDir">Directory the container is written to; created when absent.</param>
    /// <returns>Absolute path of the exported container.</returns>
    /// <remarks>
    /// Repeating the call is deliberately cheap and byte-identical: the archive is finalized exactly
    /// once and remembered, so a retry after a failed hand-off re-exports the same directory rather
    /// than minting a second revision.
    /// </remarks>
    /// <exception cref="InvalidOperationException">The capture is not committed, or was rejected.</exception>
    public string ConfirmAndExport(string queueDir)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(queueDir);

        lock (_gate)
        {
            RequireState(EngineState.Committed, EngineState.Confirmed);

            if (_archiveDirectory is null)
            {
                _archiveDirectory = ArchiveWriter.WriteFinalized(
                    Path.Combine(_config.RootDir, ArchivesDirectoryName),
                    Identity,
                    Metadata(),
                    _commit!,
                    _capabilityObservations,
                    labels: _labels);

                WriteReviewDecision(ConfirmDecision, reason: null);
            }

            string zipPath = Path.Combine(queueDir, Identity.ArchiveId + ContainerExtension);
            JazzArchiveContainer.Export(_archiveDirectory, zipPath);
            State = EngineState.Confirmed;
            return zipPath;
        }
    }

    /// <summary>
    /// Refuses the archive during local review. Nothing is finalized and nothing is queued, but the
    /// evidence stays on disk: a rejection is a decision about delivery, not an erasure.
    /// </summary>
    /// <param name="reason">Free text explaining the rejection.</param>
    /// <exception cref="InvalidOperationException">The capture is not committed.</exception>
    public void Reject(string reason)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(reason);

        lock (_gate)
        {
            RequireState(EngineState.Committed);
            WriteReviewDecision(RejectDecision, reason);
            State = EngineState.Rejected;
        }
    }

    /// <summary>
    /// Emits the initial observation of all five modalities. A modality the frozen policy switched
    /// off keeps its granted authorization and only loses availability — the OS never refused it.
    /// </summary>
    private void SeedCapabilities(DateTimeOffset now)
    {
        RecordCapability(Supplying(Capability.PointerCapture), now);
        RecordCapability(Supplying(Capability.KeyboardCapture), now);
        RecordCapability(Supplying(Capability.AccessibilityContext), now);
        RecordCapability(
            _config.ScreenshotsEnabled
                ? Supplying(Capability.ScreenCapture)
                : DisabledByPolicy(Capability.ScreenCapture),
            now);
        RecordCapability(
            _config.NarrationEnabled
                ? Supplying(Capability.AudioCapture)
                : DisabledByPolicy(Capability.AudioCapture),
            now);
    }

    private static CapabilitySample Supplying(Capability capability) => new(
        capability,
        CapabilityAuthorization.Granted,
        CapabilityAvailability.Available,
        CapabilityReason.PermissionGranted);

    private static CapabilitySample DisabledByPolicy(Capability capability) => new(
        capability,
        CapabilityAuthorization.Granted,
        CapabilityAvailability.Unavailable,
        CapabilityReason.CaptureDisabledByPolicy);

    private void RecordCapability(CapabilitySample sample, DateTimeOffset observedAt)
    {
        CapabilityObservation? observation = _capabilityStates.Observe(
            sample,
            Timestamps.IsoMillisUtc(observedAt));

        _latestSamples[sample.Capability] = sample;
        if (observation is not null)
        {
            _capabilityObservations.Add(observation);
        }
    }

    /// <summary>Appends a session boundary: the required fields and nothing else.</summary>
    /// <remarks>
    /// No label fields here, and none are possible: <c>session_start</c> precedes any declaration
    /// and <see cref="Stop"/> closes an open label before <c>session_end</c>.
    /// </remarks>
    private void AppendSessionEvent(string eventType, DateTimeOffset occurredAt) => Append(
        sequence => new ActivityEvent
        {
            SessionId = Identity.SessionId,
            EventId = Identifiers.EventId(Identity.SessionId, sequence),
            Sequence = checked((int)sequence),
            Timestamp = Timestamps.IsoMillisUtc(occurredAt),
            EventType = eventType,
            Url = SessionUrl,
        },
        occurredAt);

    /// <summary>
    /// Appends a label boundary. Like a session boundary it belongs to no application, and it names
    /// its own label explicitly rather than being stamped: at <c>label_start</c> the segment is not
    /// open yet, and at <c>label_end</c> it is the segment being closed.
    /// </summary>
    private Appended AppendLabelEvent(
        string eventType,
        string labelId,
        string label,
        DateTimeOffset occurredAt) => Append(
        sequence => new ActivityEvent
        {
            SessionId = Identity.SessionId,
            EventId = Identifiers.EventId(Identity.SessionId, sequence),
            Sequence = checked((int)sequence),
            Timestamp = Timestamps.IsoMillisUtc(occurredAt),
            EventType = eventType,
            Url = SessionUrl,
            LabelId = labelId,
            Label = label,
        },
        occurredAt);

    /// <summary>
    /// Emits the closing boundary of the open label and binds it to the segment. A no-op when no
    /// label is open, which is what makes ending one idempotent.
    /// </summary>
    private void CloseOpenLabel(DateTimeOffset occurredAt)
    {
        if (_openLabelIndex < 0)
        {
            return;
        }

        LabelSegment open = _labels[_openLabelIndex];
        Appended boundary = AppendLabelEvent(LabelEndEventType, open.LabelId, open.Text, occurredAt);

        _labels[_openLabelIndex] = open with
        {
            EndObservationId = boundary.ObservationId,
            EndStreamSequence = boundary.StreamSequence,
        };
        _openLabelIndex = -1;
    }

    /// <summary>
    /// Reserves the next durable stream position, builds the record around the projected event, and
    /// resolves the reservation. The reservation happens first so the sequence exists on disk before
    /// the record does.
    /// </summary>
    /// <returns>Where the observation landed, so a label can anchor its interval to it.</returns>
    private Appended Append(
        Func<long, ActivityEvent> project,
        DateTimeOffset occurredAt,
        ArtifactAttachment? attachment = null)
    {
        ReservationToken token = _journal.Reserve();
        ActivityEvent activityEvent = project(_eventSequence);
        string observationId = Identifiers.Prefixed(ObservationIdPrefix);

        // The envelope repeats the payload's label so a reader can segment the stream from the
        // record headers alone, without knowing this producer's payload contract.
        string[] labelRefs = activityEvent.LabelId is { } labelId
            ? new[] { labelId }
            : Array.Empty<string>();

        // The bytes are made durable before the record that cites them is: an observation claiming
        // an artifact that does not exist would be a dangling reference in the archive, while an
        // artifact whose observation never resolved is simply dropped by recovery.
        ArtifactRef[] artifactRefs = attachment is null
            ? Array.Empty<ArtifactRef>()
            : new[] { new ArtifactRef(Attach(attachment, observationId, labelRefs), attachment.Role ?? attachment.Kind) };

        JsonObject record = ArchiveDocuments.Record(
            Identity,
            observationId,
            token.StreamSequence,
            Timestamps.IsoMillisUtc(occurredAt),
            ArchiveContracts.ActivityEventRecordType,
            ArchiveContracts.ActivityEventPayloadSchema,
            ArchiveContracts.TriggerRole,
            Payload(activityEvent),
            _config.PolicyVersion,
            labelRefs,
            artifactRefs);

        _journal.ResolveObservation(token, record);
        _eventSequence++;
        return new Appended(
            observationId,
            token.StreamSequence,
            artifactRefs.Length == 0 ? null : artifactRefs[0].ArtifactId);
    }

    /// <summary>
    /// Reserves an artifact identity, ingests the bytes under it, and returns the identity the
    /// citing record will carry.
    /// </summary>
    private string Attach(
        ArtifactAttachment attachment,
        string observationId,
        IReadOnlyList<string> labelRefs)
    {
        ArtifactReservationToken token = _journal.ReserveArtifact();
        ArtifactDeclaration declaration = attachment.Declare(new[] { observationId }, labelRefs);

        _journal.IngestArtifact(
            token,
            attachment.Bytes,
            fingerprint => ArchiveDocuments.Artifact(
                Identity,
                token.ArtifactId,
                fingerprint,
                declaration,
                _config.PolicyVersion));

        return token.ArtifactId;
    }

    /// <summary>Where one appended observation landed on the stream, and what it produced.</summary>
    private readonly record struct Appended(string ObservationId, long StreamSequence, string? ArtifactId = null);

    private void ReserveGap(string reason, string detail) =>
        _journal.ResolveGap(_journal.Reserve(), reason, detail);

    /// <summary>
    /// Maps one host event onto its contract event type and field set (ANNEX-HOST section 1). Which
    /// keys appear is part of the contract, so each branch names them explicitly rather than
    /// copying a superset and pruning it afterwards.
    /// </summary>
    /// <remarks>
    /// The open label is stamped on the shared base, so it reaches every event type without each
    /// branch having to remember it. Both keys are absent when nothing is declared.
    /// </remarks>
    private ActivityEvent Project(HostEvent hostEvent, AppIdentity application, long sequence)
    {
        LabelSegment? open = _openLabelIndex < 0 ? null : _labels[_openLabelIndex];
        var projected = new ActivityEvent
        {
            SessionId = Identity.SessionId,
            EventId = Identifiers.EventId(Identity.SessionId, sequence),
            Sequence = checked((int)sequence),
            Timestamp = Timestamps.IsoMillisUtc(hostEvent.OccurredAt),
            Url = ApplicationUrlPrefix + application.Value,
            Application = new ApplicationRef(
                application.Namespace,
                application.Value,
                Sanitize(application.Name),
                Sanitize(application.Version)),
            System = Sanitize(hostEvent.System),
            LabelId = open?.LabelId,
            Label = open?.Text,
        };

        return hostEvent switch
        {
            ClickEvent click => Pointer(projected, click, "click") with
            {
                ClickCount = click.ClickCount,
            },
            DragEvent drag => Pointer(projected, drag, "drag") with
            {
                ClickCount = drag.ClickCount,
                DragEnd = new DragEnd(drag.DragEndX, drag.DragEndY),
            },
            ContextMenuEvent menu => Pointer(projected, menu, "contextmenu") with
            {
                ClickCount = menu.ClickCount,
            },
            ScrollEvent scroll => projected with
            {
                EventType = "scroll",
                Target = Target(scroll, withBoundingBox: true),
                DocumentUrl = DocumentUrl(scroll.DocumentUrl),
                PageTitle = Sanitize(scroll.PageTitle),
            },
            PasteEvent paste => Clipboard(projected, paste, "paste") with
            {
                // A sensitive destination keeps the fact of the paste and drops its payload.
                ClipboardText = paste.IsSensitive ? null : Sanitize(paste.ClipboardText),
            },
            CopyEvent copy => Clipboard(projected, copy, "copy"),
            CutEvent cut => Clipboard(projected, cut, "cut"),
            InputEvent input => Typed(projected, input),
            KeydownEvent keydown => projected with
            {
                EventType = "keydown",
                Value = Sanitize(keydown.ComboName),
            },
            NavigateEvent => projected with
            {
                EventType = "navigate",
            },
            _ => throw new ArgumentOutOfRangeException(
                nameof(hostEvent),
                hostEvent,
                "unsupported host event type"),
        };
    }

    /// <summary>Click, drag and context menu share one field set; only the type and extras differ.</summary>
    private ActivityEvent Pointer(ActivityEvent projected, TargetedHostEvent source, string eventType) =>
        projected with
        {
            EventType = eventType,
            Target = Target(source, withBoundingBox: true),
            SelectedText = source.IsSensitive ? null : Sanitize(source.SelectedText),
            GestureId = GestureIdPrefix + Identifiers.UuidV7(),
            IsSensitive = source.IsSensitive ? true : null,
            DocumentUrl = DocumentUrl(source.DocumentUrl),
            PageTitle = Sanitize(source.PageTitle),
        };

    /// <summary>
    /// Copy, cut and paste report the focused element and its selection. The clipboard is read only
    /// for paste: at a copy key-down the pasteboard still holds the previous transfer.
    /// </summary>
    private ActivityEvent Clipboard(ActivityEvent projected, TargetedHostEvent source, string eventType) =>
        projected with
        {
            EventType = eventType,
            Target = Target(source, withBoundingBox: true),
            SelectedText = source.IsSensitive ? null : Sanitize(source.SelectedText),
            IsSensitive = source.IsSensitive ? true : null,
        };

    /// <summary>
    /// A committed typing run. The rectangle is deliberately absent — a typing run is not a point —
    /// and <c>inputMasked</c> appears only when redaction actually replaced content.
    /// </summary>
    private ActivityEvent Typed(ActivityEvent projected, InputEvent input)
    {
        (string? value, bool wasMasked) = Redaction.RedactTyped(input.RawText, _config.MaxTextLength);

        return projected with
        {
            EventType = "input",
            Value = value,
            Target = TargetOf(
                Sanitize(input.TargetRole),
                Sanitize(input.TargetAccessibleName),
                text: null,
                boundingBox: null),
            InputMasked = wasMasked ? true : null,
        };
    }

    private EventTarget? Target(TargetedHostEvent source, bool withBoundingBox) => TargetOf(
        Sanitize(source.TargetRole),
        Sanitize(source.TargetAccessibleName),
        source.IsSensitive ? null : Sanitize(source.TargetText),
        withBoundingBox ? source.TargetBoundingBox : null);

    /// <summary>
    /// The UI Automation control type is the only role Windows offers, so it fills both
    /// <c>tag</c> and <c>role</c>. An entirely empty target is omitted rather than emitted blank.
    /// </summary>
    private static EventTarget? TargetOf(string? role, string? accessibleName, string? text, BoundingBox? boundingBox)
    {
        if (role is null && accessibleName is null && text is null && boundingBox is null)
        {
            return null;
        }

        return new EventTarget
        {
            Tag = role,
            Role = role,
            AccessibleName = accessibleName,
            Text = text,
            BoundingBox = boundingBox,
        };
    }

    private string? Sanitize(string? value) => Redaction.Sanitize(value, _config.MaxTextLength);

    /// <summary>
    /// The document URL, kept out of the free-text sanitizer on purpose.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <see cref="Sanitize"/> is a truncator: past <c>maxTextLength</c> it cuts and appends an
    /// ellipsis, which is the right answer for prose and the wrong one for an address. A page URL is
    /// not a sample of a longer text — it either resolves or it does not — so a cut one is worse
    /// evidence than no URL at all: it looks like a location while pointing nowhere, and a reader has
    /// no way to tell the two apart.
    /// </para>
    /// <para>
    /// No length bound is applied here, because the macOS client applies none either
    /// (<c>CaptureController</c> passes <c>ObservedDocumentURL.sanitize</c> straight into the event),
    /// and this port exists so both clients emit the same bytes for the same page. The value arrives
    /// already normalized by <see cref="ObservedDocumentUrl.Sanitize"/>, which has dropped userinfo,
    /// query and fragment — the parts that make an address long as well as the parts that make it
    /// sensitive — leaving scheme, host, port and path. Should a pathological provider ever make an
    /// absolute ceiling necessary, it belongs in <see cref="ObservedDocumentUrl"/> next to its macOS
    /// twin so the two clients keep agreeing, and it must omit the field rather than truncate it.
    /// </para>
    /// </remarks>
    private static string? DocumentUrl(string? value)
    {
        string? trimmed = value?.Trim();
        return string.IsNullOrEmpty(trimmed) ? null : trimmed;
    }

    /// <summary>
    /// Serializes an activity event into its archive payload. Keys are emitted in one fixed order
    /// and absent members are omitted entirely: a JSON <c>null</c> fails the schema, and stable
    /// ordering keeps the records file byte-identical across runs.
    /// </summary>
    private static JsonObject Payload(ActivityEvent value)
    {
        var payload = new JsonObject
        {
            ["sessionId"] = value.SessionId,
            ["eventId"] = value.EventId,
        };

        if (value.Sequence is { } sequence)
        {
            payload["sequence"] = sequence;
        }

        payload["timestamp"] = value.Timestamp;
        payload["eventType"] = value.EventType;
        payload["url"] = value.Url;

        if (value.Application is { } application)
        {
            var reference = new JsonObject
            {
                ["namespace"] = application.Namespace,
                ["value"] = application.Value,
            };

            if (application.Name is { } name)
            {
                reference["name"] = name;
            }

            if (application.Version is { } version)
            {
                reference["version"] = version;
            }

            payload["application"] = reference;
        }

        Put(payload, "system", value.System);

        if (value.Target is { } target)
        {
            var element = new JsonObject();
            Put(element, "tag", target.Tag);
            Put(element, "role", target.Role);
            Put(element, "accessibleName", target.AccessibleName);
            Put(element, "text", target.Text);

            if (target.BoundingBox is { } box)
            {
                element["boundingBox"] = new JsonObject
                {
                    ["x"] = box.X,
                    ["y"] = box.Y,
                    ["width"] = box.Width,
                    ["height"] = box.Height,
                };
            }

            payload["target"] = element;
        }

        Put(payload, "value", value.Value);
        Put(payload, "selectedText", value.SelectedText);
        Put(payload, "clipboardText", value.ClipboardText);

        if (value.ClickCount is { } clickCount)
        {
            payload["clickCount"] = clickCount;
        }

        if (value.DragEnd is { } dragEnd)
        {
            payload["dragEnd"] = new JsonObject
            {
                ["x"] = dragEnd.X,
                ["y"] = dragEnd.Y,
            };
        }

        Put(payload, "gestureId", value.GestureId);

        if (value.InputMasked is { } inputMasked)
        {
            payload["inputMasked"] = inputMasked;
        }

        if (value.IsSensitive is { } isSensitive)
        {
            payload["isSensitive"] = isSensitive;
        }

        Put(payload, "documentURL", value.DocumentUrl);
        Put(payload, "pageTitle", value.PageTitle);
        Put(payload, "screenshotId", value.ScreenshotId);
        Put(payload, "audioFileId", value.AudioFileId);
        Put(payload, "labelId", value.LabelId);
        Put(payload, "label", value.Label);
        Put(payload, "processId", value.ProcessId);
        Put(payload, "process", value.Process);

        return payload;
    }

    private static void Put(JsonObject target, string key, string? value)
    {
        if (value is not null)
        {
            target[key] = value;
        }
    }

    /// <summary>
    /// Builds the frozen policy and producer facts, with the capability reduction of ANNEX-HOST
    /// section 5: what the source actually supplied, and what it could not, with a reason.
    /// </summary>
    private SessionMetadata Metadata()
    {
        var supplied = new List<string>();
        var unavailable = new List<UnavailableCapability>();

        foreach (Capability capability in Enum.GetValues<Capability>())
        {
            if (!_latestSamples.TryGetValue(capability, out CapabilitySample? sample))
            {
                continue;
            }

            if (sample.Availability == CapabilityAvailability.Available)
            {
                supplied.Add(capability.Token());
                continue;
            }

            unavailable.Add(new UnavailableCapability(
                capability.Token(),
                ManifestReason(sample.Reason),
                sample.Detail));
        }

        supplied.Add(SessionBoundariesCapability);

        return new SessionMetadata(
            _startedAt,
            _commit!.EndedAt,
            _config.ConsentedAt ?? _startedAt,
            _config.PolicyVersion,
            _config.Modalities,
            _config.ExcludedApplications,
            _config.ProducerName,
            _config.ProducerVersion,
            _config.SourceKind,
            supplied,
            unavailable)
        {
            BusinessDataCapture = _config.BusinessDataCapture,
            ProducerPlatform = _config.ProducerPlatform,
            ProducerBuild = _config.ProducerBuild,
        };
    }

    /// <summary>
    /// Projects a capability observation reason onto the manifest's coarser vocabulary. A suppressed
    /// or failed source is temporarily unavailable: it may come back within the same capture.
    /// </summary>
    private static string ManifestReason(string capabilityReason) => capabilityReason switch
    {
        CapabilityReason.CaptureDisabledByPolicy => "disabled_by_policy",
        CapabilityReason.PermissionDenied => "permission_denied",
        CapabilityReason.PermissionNotDetermined => "not_requested",
        CapabilityReason.SourceFailure => "temporarily_unavailable",
        CapabilityReason.EventTapTimeout => "temporarily_unavailable",
        CapabilityReason.EventTapUserInput => "temporarily_unavailable",
        CapabilityReason.SecureInput => "temporarily_unavailable",
        _ => "unknown",
    };

    /// <summary>
    /// Records the review decision beside the archive rather than inside it. The finalized directory
    /// is sealed by its own inventory and content digest, so appending to it after the fact would
    /// invalidate the archive; keeping the decision in the capture root leaves both intact.
    /// </summary>
    private void WriteReviewDecision(string decision, string? reason)
    {
        var document = new JsonObject
        {
            ["schemaVersion"] = ReviewDecisionSchemaVersion,
            ["archiveId"] = Identity.ArchiveId,
            ["captureId"] = Identity.CaptureId,
            ["actorId"] = Identity.ActorId,
            ["decision"] = decision,
            ["decidedAt"] = Timestamps.IsoMillisUtc(_config.Clock()),
        };

        if (reason is not null)
        {
            document["reason"] = reason;
        }

        string directory = Path.Combine(_config.RootDir, ReviewsDirectoryName);
        Directory.CreateDirectory(directory);
        File.WriteAllBytes(
            Path.Combine(directory, Identity.ArchiveId + ".json"),
            Utf8NoBom.GetBytes(document.ToJsonString() + "\n"));
    }

    private void RequireState(params EngineState[] allowed)
    {
        if (Array.IndexOf(allowed, State) < 0)
        {
            throw new InvalidOperationException(
                "Capture engine is " + State + "; expected " + string.Join(" or ", allowed) + ".");
        }
    }
}
