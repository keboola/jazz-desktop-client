using System.IO;

namespace JazzCapture;

/// <summary>
/// The operational bounds for the durable event spool and its OTLP delivery to the legacy Keboola
/// Data Stream sink.
/// </summary>
/// <remarks>
/// <para>
/// Unlike <see cref="ScreenshotDeliverySettings"/>, this area exists precisely because it <b>is</b>
/// durable and is never wiped at launch: an OTLP request body needs no credential to be re-sent
/// later -- the capability is the stream URL path, not a short-lived federation token -- so a body
/// that survives a crash or a relaunch is still fully deliverable. This mirrors the precedent macOS
/// already set for its own narration spool
/// (<c>macos/Sources/JazzCaptureCore/NarrationSpool.swift:18-20</c>): a durable spool that is never
/// swept at process start is a deliberate design, not an oversight or a leak.
/// </para>
/// <para>
/// <b>The spool holds captured user content at rest, in a new place.</b> One spooled file is the
/// exact <c>/v1/logs</c> request body, and that body carries <c>selected_text</c>,
/// <c>clipboard_text</c>, <c>page_title</c> and <c>target.accessibleName</c>
/// (<c>OtlpMapper.cs</c>'s attribute list) -- the same sanitized, masked values the archive journal
/// already recorded, never anything unmasked. That is why <see cref="SpoolDirectory"/>'s root is
/// ACL-protected by <c>CurrentUserOnlyAcl.ApplyDirectory</c>, following the newer precedent
/// <c>ScreenshotStagingArea</c> set rather than the older, unprotected
/// <c>%LOCALAPPDATA%\Jazz\captures</c> journal directory -- a pre-existing gap this change does not
/// widen and does not attempt to close.
/// </para>
/// <para>
/// <b>The accepted consequence of the two bounds below, stated in plain words.</b>
/// <see cref="SpoolByteCeiling"/> (32 MiB) and <see cref="SpoolRetention"/> (48 hours) are
/// deliberately small: a machine that records while unprovisioned -- the ordinary case issue #53
/// scope 4 describes, where capture starts before a device bundle ever arrives -- will begin
/// discarding its <b>oldest</b> spooled activity once either bound is exceeded, well before a whole
/// week has passed. A bundle that arrives on a Monday for a machine that has been recording,
/// unprovisioned, since the previous Friday will not recover everything from that Friday: the
/// oldest entries are evicted first (see <c>EventSpool.EvictOldestLocked</c>), and every eviction or
/// refusal is counted into the tray's sticky <c>N undelivered</c> tally so the loss is visible
/// rather than silent. This is the accepted trade for a small, bounded on-disk footprint on every
/// deployed machine, not an oversight -- see the "Decisions on the plan's open questions" comment on
/// issue #48 for the product decision behind these exact numbers.
/// </para>
/// <para>
/// None of these are user preferences: they do not appear in the settings window, are not part of
/// <see cref="HostSettings"/>, and never round-trip through <c>settings.json</c> (#62 constraint 2).
/// They are compiled-in operational defaults, validated once at startup by <see cref="Validate"/> so
/// a bad value fails fast rather than surfacing as a mystery at the first spooled event.
/// </para>
/// </remarks>
public sealed record EventDeliverySettings
{
    /// <summary>
    /// Directory that holds one file per spooled event -- the exact <c>/v1/logs</c> request body --
    /// organized as one subdirectory per capture session. See this type's own remarks for why this
    /// area is durable and never cleaned at launch, unlike <see cref="ScreenshotDeliverySettings.StagingDirectory"/>.
    /// </summary>
    public string SpoolDirectory { get; init; } =
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Jazz",
            "spool",
            "events");

    /// <summary>
    /// Total bytes, across every spooled event plus outstanding deletion debt, that the spool may
    /// hold before its oldest entries are evicted. Amended from the plan's original 128 MiB proposal
    /// to 32 MiB (roughly 5,000-15,000 events at a few kilobytes each) -- see this type's own remarks
    /// on the accepted consequence.
    /// </summary>
    public long SpoolByteCeiling { get; init; } = 32L * 1024 * 1024;

    /// <summary>
    /// Longest an event may sit undelivered before it is evicted regardless of the byte ceiling.
    /// Amended from the plan's original 7-day proposal to 48 hours -- see this type's own remarks on
    /// the accepted consequence. Compared against a clock, not handed to a timer API, so it is
    /// deliberately not checked against <see cref="ScreenshotDeliverySettings.MaximumTimerDuration"/>
    /// in <see cref="Validate"/> -- the same carve-out <c>ScreenshotDeliverySettings.StagingRetention</c>
    /// documents.
    /// </summary>
    public TimeSpan SpoolRetention { get; init; } = TimeSpan.FromHours(48);

    /// <summary>
    /// The largest single event body the spool will admit. An OTLP body for one observation is a few
    /// kilobytes (39 attributes at most; see <c>OtlpMapper.GenericAttributes</c>), so this is a
    /// generous ceiling against a producer defect, not a size this client expects to approach.
    /// </summary>
    public long MaximumBodyBytes { get; init; } = 1L * 1024 * 1024;

    /// <summary>
    /// Wall-clock ceiling on one <c>/v1/logs</c> POST attempt, enforced by
    /// <see cref="MvpStreamSender.SendBodyAsync"/> through a linked <see cref="CancellationTokenSource"/>.
    /// This is the only deadline in force: <see cref="RedirectSafeHttpClient"/> disables
    /// <see cref="HttpClient"/>'s own hidden 100-second default so this budget is never silently cut
    /// short by a limit that appears in no setting.
    /// </summary>
    public TimeSpan SendCallBudget { get; init; } = TimeSpan.FromSeconds(30);

    /// <summary>
    /// Delay before the first retry of a retryable send failure. The schedule doubles from here,
    /// before <see cref="EventStreamRetryPolicy"/> applies jitter and clamps to
    /// <see cref="SendBackoffCeiling"/>.
    /// </summary>
    /// <remarks>
    /// These defaults (2 s initial, 5 min ceiling) are <see cref="JazzCaptureCore.Delivery.ArchiveDeliveryRetryPolicy"/>'s
    /// numbers, not <see cref="ScreenshotUploadRetryPolicy"/>'s: an event has no attempt budget (see
    /// <see cref="EventStreamRetryPolicy"/>'s own remarks), so its schedule must settle into a poll
    /// that can survive a multi-hour outage rather than a screenshot's much shorter one.
    /// </remarks>
    public TimeSpan SendBackoffInitial { get; init; } = TimeSpan.FromSeconds(2);

    /// <summary>Cap on the doubling of the send backoff, applied before jitter.</summary>
    public TimeSpan SendBackoffCeiling { get; init; } = TimeSpan.FromMinutes(5);

    /// <summary>
    /// Validates every bound, throwing on the first one that cannot work. See
    /// <see cref="ScreenshotDeliverySettings.Validate"/> for why every timer-bound value is checked
    /// against <see cref="ScreenshotDeliverySettings.MaximumTimerDuration"/> here too.
    /// </summary>
    /// <exception cref="ArgumentOutOfRangeException">A bound is out of range for its own meaning.</exception>
    /// <exception cref="ArgumentException"><see cref="SpoolDirectory"/> is missing or not rooted.</exception>
    public void Validate()
    {
        static void RejectPastTimerLimit(string name, TimeSpan value)
        {
            if (value > ScreenshotDeliverySettings.MaximumTimerDuration)
            {
                throw new ArgumentOutOfRangeException(
                    name,
                    value,
                    "This bound becomes a timeout, and cannot be longer than int.MaxValue "
                        + "milliseconds (about 24.8 days), which is all the timeout APIs it is "
                        + "handed to can represent.");
            }
        }

        if (string.IsNullOrWhiteSpace(SpoolDirectory))
        {
            throw new ArgumentException(
                "The event spool directory must be a non-empty path.",
                nameof(SpoolDirectory));
        }

        if (!Path.IsPathFullyQualified(SpoolDirectory))
        {
            throw new ArgumentException(
                "The event spool directory must be a fully qualified path.",
                nameof(SpoolDirectory));
        }

        if (SpoolByteCeiling <= 0)
        {
            throw new ArgumentOutOfRangeException(
                nameof(SpoolByteCeiling),
                SpoolByteCeiling,
                "The spool byte ceiling must be a positive number of bytes.");
        }

        if (SpoolRetention <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(
                nameof(SpoolRetention),
                SpoolRetention,
                "The spool retention window must be a positive duration.");
        }

        // Deliberately not RejectPastTimerLimit-checked: SpoolRetention is compared against a clock,
        // never handed to a timer API. See this type's own remarks and ScreenshotDeliverySettings'
        // identical carve-out for StagingRetention.

        if (MaximumBodyBytes <= 0)
        {
            throw new ArgumentOutOfRangeException(
                nameof(MaximumBodyBytes),
                MaximumBodyBytes,
                "The maximum body size must be a positive number of bytes.");
        }

        if (SendCallBudget <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(
                nameof(SendCallBudget),
                SendCallBudget,
                "The send call budget must be a positive duration.");
        }

        RejectPastTimerLimit(nameof(SendCallBudget), SendCallBudget);

        if (SendBackoffInitial <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(
                nameof(SendBackoffInitial),
                SendBackoffInitial,
                "The initial send backoff must be a positive duration.");
        }

        if (SendBackoffCeiling < SendBackoffInitial)
        {
            throw new ArgumentOutOfRangeException(
                nameof(SendBackoffCeiling),
                SendBackoffCeiling,
                "The send backoff ceiling cannot be shorter than the initial backoff.");
        }

        // Checked explicitly even though it is also transitively implied by the two checks just
        // above (SendBackoffInitial <= SendBackoffCeiling, ordering; SendBackoffCeiling <=
        // MaximumTimerDuration, the very next line): the plan names all three timer-bound values,
        // and an explicit check here means this stays true even if either of those two is ever
        // relaxed independently of this one.
        RejectPastTimerLimit(nameof(SendBackoffInitial), SendBackoffInitial);
        RejectPastTimerLimit(nameof(SendBackoffCeiling), SendBackoffCeiling);

        // Mirrors ScreenshotDeliverySettings' identical guard against a sub-millisecond initial
        // backoff that would truncate to a zero-delay hot loop in the drain scheduler's own
        // exception path -- see EventStreamRetryPolicy.MinimumFirstAttemptDelay.
        if (EventStreamRetryPolicy.MinimumFirstAttemptDelay(this) <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(
                nameof(SendBackoffInitial),
                SendBackoffInitial,
                "The initial send backoff must be large enough that, even after the worst-case "
                    + "jitter, the first retry delay does not truncate to zero.");
        }
    }
}
