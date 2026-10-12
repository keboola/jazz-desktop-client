namespace JazzCaptureCore;

/// <summary>
/// The closed <c>screenshot.status</c> vocabulary: why an exported record has, or lacks, a
/// <c>screenshot_id</c>. Mirrors <c>screenshotStatuses</c> in <c>contract/identifiers.json</c>.
/// </summary>
/// <remarks>
/// A status names a cause and nothing else — never a path, a window title, an identity or an
/// exception message. Interactions refused at the owner gate (unresolved or denylisted owner) are
/// gaps, not records, so they have no status.
/// </remarks>
public static class ScreenshotStatus
{
    /// <summary>A frame was captured and a screenshot id assigned.</summary>
    public const string Captured = "captured";

    /// <summary>A frame was captured, but no delivery preparer or credential exists to give it an id.</summary>
    public const string DeliveryNotConfigured = "delivery_not_configured";

    /// <summary>A frame was captured, but the preparer returned no id or threw.</summary>
    public const string DeliveryPrepareFailed = "delivery_prepare_failed";

    /// <summary>This event or path deliberately takes no screenshot.</summary>
    public const string NotAttempted = "not_attempted";

    /// <summary>Screenshots are switched off for the session.</summary>
    public const string Disabled = "disabled";

    /// <summary>An earlier capture still held the process-wide slot.</summary>
    public const string Busy = "busy";

    /// <summary>The capture did not return within its budget.</summary>
    public const string Timeout = "timeout";

    /// <summary>No window of the owning application contains the target.</summary>
    public const string NoWindowAtTarget = "no_window_at_target";

    /// <summary>The captured window belongs to another application than the event's owner.</summary>
    public const string OwnerMismatch = "owner_mismatch";

    /// <summary>The OS refused the capture or the frame could not be encoded.</summary>
    public const string SourceUnavailable = "source_unavailable";

    /// <summary>A frame was captured but its evidence could not be described honestly, so it was not kept.</summary>
    public const string EvidenceRejected = "evidence_rejected";

    /// <summary>The outcome is not known, e.g. a record from before the status existed.</summary>
    public const string Unknown = "unknown";

    /// <summary>The whole vocabulary, in manifest order.</summary>
    public static IReadOnlyList<string> All { get; } = new[]
    {
        Captured,
        DeliveryNotConfigured,
        DeliveryPrepareFailed,
        NotAttempted,
        Disabled,
        Busy,
        Timeout,
        NoWindowAtTarget,
        OwnerMismatch,
        SourceUnavailable,
        EvidenceRejected,
        Unknown,
    };
}
