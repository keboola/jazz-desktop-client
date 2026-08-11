namespace JasnostCaptureCore;

/// <summary>
/// The stable identity of the application an event belongs to, as the host resolved it.
/// </summary>
/// <remarks>
/// Windows has no single application identifier: packaged apps have an AUMID, everything else only
/// has an executable path. The namespace travels with the value so a consumer never has to guess
/// which of the two it is looking at.
/// </remarks>
/// <param name="Namespace">Identifier namespace; one of the constants on this type.</param>
/// <param name="Value">The identifier itself. Also forms the event's <c>app://</c> URL.</param>
/// <param name="Name">Human-readable application name, if known.</param>
/// <param name="Version">File version of the owning executable, if known.</param>
public sealed record AppIdentity(
    string Namespace,
    string Value,
    string? Name = null,
    string? Version = null)
{
    /// <summary>Namespace of an Application User Model ID (packaged apps).</summary>
    public const string AumidNamespace = "windows.aumid";

    /// <summary>Namespace of a normalized executable path (everything else).</summary>
    public const string ExecutablePathNamespace = "windows.exe-path";

    /// <summary>Whether the host actually resolved an owner. Blank identities are never captured.</summary>
    public bool IsResolved =>
        !string.IsNullOrWhiteSpace(Namespace) && !string.IsNullOrWhiteSpace(Value);
}

/// <summary>
/// The <c>detail</c> strings the engine attaches to the gaps it creates. A dropped event is always
/// an explicit interval in the capture commit, never a silent omission, and the detail is what tells
/// a reader which rule dropped it.
/// </summary>
public static class CaptureGapDetails
{
    /// <summary>The owning application is on the frozen capture policy's denylist.</summary>
    public const string ApplicationDenylist = "application denylist";

    /// <summary>Neither the hit test nor the foreground tracker produced an owner.</summary>
    public const string OwnerUnavailable = "actual application owner unavailable";

    /// <summary>The event belonged to the capture client's own windows.</summary>
    public const string DesktopClientUi = "desktop client UI";
}

/// <summary>Externally observable phase of a <see cref="CaptureEngine"/>.</summary>
public enum EngineState
{
    /// <summary>Hooks are live; the engine admits host events.</summary>
    Recording,

    /// <summary>The capture commit exists; the archive awaits a review decision.</summary>
    Committed,

    /// <summary>The archive was finalized and exported to the delivery queue.</summary>
    Confirmed,

    /// <summary>The archive was rejected during local review; nothing was queued.</summary>
    Rejected,
}

/// <summary>
/// Everything a capture engine needs to know before the first hook is installed. The policy is
/// frozen for the whole capture: nothing in here may change while recording.
/// </summary>
/// <param name="RootDir">Directory that holds the journal claim, the archives and the review decisions.</param>
/// <param name="User">The captured user; projected as <c>enduser.id</c> by the OTLP mapper.</param>
/// <param name="InstanceName">The recording machine; projected as <c>host.name</c>.</param>
/// <param name="ProducerVersion">Version of the capture client writing the archive.</param>
/// <param name="ExcludedApplications">
/// Application identifiers the policy excludes. Matched case-insensitively against
/// <see cref="AppIdentity.Value"/>; a match becomes an explicit gap, never a silent drop.
/// </param>
/// <param name="ScreenshotsEnabled">
/// Whether the screen-capture modality is enabled. False in the MVP, which makes
/// <c>screen.capture</c> a policy-disabled capability rather than a failed one.
/// </param>
/// <param name="Clock">
/// Source of every timestamp the engine stamps. Injected so a test can make a capture deterministic.
/// </param>
public sealed record EngineConfig(
    string RootDir,
    string User,
    string InstanceName,
    string ProducerVersion,
    IReadOnlyList<string> ExcludedApplications,
    bool ScreenshotsEnabled,
    Func<DateTimeOffset> Clock)
{
    /// <summary>Whether narration recording is enabled. Always false in the MVP.</summary>
    public bool NarrationEnabled { get; init; }

    /// <summary>Whether the capture policy admitted business data.</summary>
    public bool BusinessDataCapture { get; init; }

    /// <summary>Producer name written to the manifest and the source.</summary>
    public string ProducerName { get; init; } = "Jazz Capture (.NET)";

    /// <summary>Producer platform written to the manifest; omitted when null.</summary>
    public string? ProducerPlatform { get; init; } = "Windows";

    /// <summary>Producer build written to the manifest; omitted when null.</summary>
    public string? ProducerBuild { get; init; }

    /// <summary>Source kind token of the capture source.</summary>
    public string SourceKind { get; init; } = "windows.capture-controller";

    /// <summary>Consent policy version stamped on every record's privacy block.</summary>
    public string PolicyVersion { get; init; } = "consent-v1";

    /// <summary>When the capture policy was consented to; defaults to the session start.</summary>
    public string? ConsentedAt { get; init; }

    /// <summary>Consented modality tokens; must be sorted and free of duplicates.</summary>
    public IReadOnlyList<string> Modalities { get; init; } =
        new[] { "accessibility", "keyboard", "pointer" };

    /// <summary>Length bound applied to every free-text field the engine emits.</summary>
    public int MaxTextLength { get; init; } = Redaction.DefaultMaxLength;
}

/// <summary>
/// One host-normalized observation handed to <see cref="CaptureEngine.Observe"/>.
/// </summary>
/// <remarks>
/// The hierarchy is closed: the engine maps each concrete type onto exactly one contract event type
/// with a fixed field set, so a host cannot invent a shape the archive has no rule for. Hosts
/// construct these with object initializers; every member is optional except the ones the concrete
/// type documents as required.
/// </remarks>
public abstract record HostEvent
{
    private protected HostEvent()
    {
    }

    /// <summary>
    /// When the physical interaction happened — for pointer events the mouse-up, never the moment
    /// enrichment finished. This becomes both the event timestamp and the record's <c>capturedAt</c>.
    /// </summary>
    public DateTimeOffset OccurredAt { get; init; }

    /// <summary>
    /// The owning application. An unresolved owner is an explicit gap, so this is effectively
    /// required for anything the archive should retain.
    /// </summary>
    public AppIdentity? Application { get; init; }

    /// <summary>Human-readable application name for the legacy <c>system</c> display hint.</summary>
    public string? System { get; init; }
}

/// <summary>
/// A host event that carries a resolved UI element. Pointer and clipboard events share this shape;
/// which of the members actually reach the archive depends on the concrete event type.
/// </summary>
public abstract record TargetedHostEvent : HostEvent
{
    private protected TargetedHostEvent()
    {
    }

    /// <summary>UI Automation control type name; becomes both <c>target.tag</c> and <c>target.role</c>.</summary>
    public string? TargetRole { get; init; }

    /// <summary>Accessible name of the element; sanitized before emission.</summary>
    public string? TargetAccessibleName { get; init; }

    /// <summary>The element's full value; dropped entirely when <see cref="IsSensitive"/> is set.</summary>
    public string? TargetText { get; init; }

    /// <summary>Element rectangle in screen coordinates.</summary>
    public BoundingBox? TargetBoundingBox { get; init; }

    /// <summary>The current selection, which is not the element's full value.</summary>
    public string? SelectedText { get; init; }

    /// <summary>Window or document title at event time.</summary>
    public string? PageTitle { get; init; }

    /// <summary>Sanitized document context of a browser-like application.</summary>
    public string? DocumentUrl { get; init; }

    /// <summary>Whether the field was classified sensitive; suppresses every content field.</summary>
    public bool IsSensitive { get; init; }
}

/// <summary>One completed left-click gesture, published on mouse-up after coalescing.</summary>
public sealed record ClickEvent : TargetedHostEvent
{
    /// <summary>OS click multiplicity: 1 single, 2 double, 3 triple.</summary>
    public int ClickCount { get; init; } = 1;
}

/// <summary>One completed press-drag-release; the target is the press point.</summary>
public sealed record DragEvent : TargetedHostEvent
{
    /// <summary>OS click multiplicity of the gesture the drag replaced.</summary>
    public int ClickCount { get; init; } = 1;

    /// <summary>Screen x coordinate of the release point.</summary>
    public double DragEndX { get; init; }

    /// <summary>Screen y coordinate of the release point.</summary>
    public double DragEndY { get; init; }
}

/// <summary>One right-click.</summary>
public sealed record ContextMenuEvent : TargetedHostEvent
{
    /// <summary>OS click multiplicity: 1 single, 2 double, 3 triple.</summary>
    public int ClickCount { get; init; } = 1;
}

/// <summary>One throttled scroll sample. Carries no gesture identity and no click multiplicity.</summary>
public sealed record ScrollEvent : TargetedHostEvent;

/// <summary>A copy shortcut. The clipboard is deliberately not read; the selection is the evidence.</summary>
public sealed record CopyEvent : TargetedHostEvent;

/// <summary>A cut shortcut, with the same evidence rules as <see cref="CopyEvent"/>.</summary>
public sealed record CutEvent : TargetedHostEvent;

/// <summary>A paste shortcut. The clipboard payload is transfer evidence, not proof of success.</summary>
public sealed record PasteEvent : TargetedHostEvent
{
    /// <summary>Observed clipboard text; dropped entirely when the destination is sensitive.</summary>
    public string? ClipboardText { get; init; }
}

/// <summary>
/// One committed typing run: the host has already reconciled the key buffer with the field's
/// rendered value and decided the flush boundary. The engine only redacts and emits.
/// </summary>
public sealed record InputEvent : HostEvent
{
    /// <summary>The reconciled, still-unmasked text of the run.</summary>
    public string RawText { get; init; } = string.Empty;

    /// <summary>Control type of the field; becomes <c>target.tag</c> and <c>target.role</c>.</summary>
    public string? TargetRole { get; init; }

    /// <summary>Accessible name of the field.</summary>
    public string? TargetAccessibleName { get; init; }

    /// <summary>
    /// Never emitted: an input event's target deliberately carries no rectangle. Present only so a
    /// host can reuse one target snapshot for pointer and typing events without branching.
    /// </summary>
    public BoundingBox? TargetBoundingBox { get; init; }

    /// <summary>Whether the field was classified sensitive.</summary>
    public bool FieldIsSensitive { get; init; }
}

/// <summary>
/// One named key or modifier chord, recorded regardless of field sensitivity because the key
/// identity is behaviour rather than content.
/// </summary>
public sealed record KeydownEvent : HostEvent
{
    /// <summary>The key or chord name, for example <c>Enter</c> or <c>Ctrl+S</c>.</summary>
    public string ComboName { get; init; } = string.Empty;
}

/// <summary>An application or window switch, observed from the foreground-change hook.</summary>
public sealed record NavigateEvent : HostEvent;

/// <summary>
/// What one capture produced, as of the moment its commit was written. Finalization and export are a
/// separate, reviewer-gated step, so no archive directory exists yet.
/// </summary>
/// <param name="ArchiveId">Archive identity of the capture.</param>
/// <param name="CaptureId">Capture identity.</param>
/// <param name="SessionId">Legacy session identity; also the session directory name.</param>
/// <param name="StartedAt">Session start (RFC 3339).</param>
/// <param name="EndedAt">Session and commit end (RFC 3339).</param>
/// <param name="Status">
/// <c>closed</c> when the producer finished the capture itself, <c>recovered</c> after crash recovery.
/// </param>
/// <param name="ObservationCount">Activity events retained on the stream.</param>
/// <param name="GapCount">Coalesced gap intervals on the stream.</param>
/// <param name="CapabilityObservationCount">Capability observations appended at finalization.</param>
public sealed record StopResult(
    string ArchiveId,
    string CaptureId,
    string SessionId,
    string StartedAt,
    string EndedAt,
    string Status,
    int ObservationCount,
    int GapCount,
    int CapabilityObservationCount);
