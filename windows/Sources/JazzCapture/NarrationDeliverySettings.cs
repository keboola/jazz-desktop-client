using System.IO;
using JazzCaptureCore.Audio;

namespace JazzCapture;

/// <summary>
/// The operational bounds for the durable narration clip spool and its upload-then-emit delivery to
/// Keboola Files.
/// </summary>
/// <remarks>
/// <para>
/// Like <see cref="EventDeliverySettings"/>, and unlike <see cref="ScreenshotDeliverySettings"/>,
/// this area <b>is</b> durable and is <b>never</b> wiped at launch: a clip that survives a crash or a
/// relaunch is still exactly as deliverable as it was the instant it was sealed, because re-preparing
/// it mints a fresh, short-lived federation credential rather than depending on one that died with
/// the previous process. This mirrors the precedent macOS already set for its own narration spool
/// (<c>macos/Sources/JazzCaptureCore/NarrationSpool.swift:18-20</c>): never cleaned at launch because
/// a leftover blob there is the whole point.
/// </para>
/// <para>
/// <b>The spool holds captured audio at rest, in a new place.</b> A think-aloud clip is exactly the
/// kind of content <c>ScreenshotStagingArea</c>'s and <c>EventSpool</c>'s own remarks already flag:
/// this is why <see cref="SpoolDirectory"/>'s root is ACL-protected by
/// <c>CurrentUserOnlyAcl.ApplyDirectory</c>, following the same newer precedent rather than the
/// older, unprotected <c>%LOCALAPPDATA%\Jazz\captures</c> journal directory that already holds a
/// second, unbounded copy of the same audio (issue #12) -- a pre-existing gap this change does not
/// widen and does not attempt to close.
/// </para>
/// <para>
/// <b>The two bounds below, and the accepted consequence, stated in plain words (issue #84,
/// amendment 1 -- the plan's own §2.2 proposed these same numbers and the decision comment accepted
/// them as written).</b> <see cref="SpoolByteCeiling"/> is <b>512 MiB</b>: roughly nine maximal
/// clips (<see cref="MaximumClipBytes"/> below), about 4 hours 39 minutes of continuously narrated
/// labels. <see cref="SpoolRetention"/> is <b>48 hours</b>, deliberately equal to
/// <see cref="EventDeliverySettings.SpoolRetention"/> -- a narration event, once it is finally
/// emitted, immediately falls under the <em>event</em> spool's own 48-hour window, so holding a clip
/// longer than that would eventually produce a row describing a label whose surrounding
/// <c>label_start</c>/<c>label_end</c> activity had already aged out of the event spool days
/// earlier. A machine that records narration while unprovisioned -- the ordinary case issue #53
/// scope 4 describes -- begins discarding its <b>oldest</b> clips once either bound is exceeded, and
/// a discarded clip means no narration row is ever emitted for that label: the audio is gone, not
/// merely undelivered. Every eviction is counted into the tray's sticky <c>N undelivered</c> tally so
/// this is visible rather than silent, exactly as slice 1 (issue #48) was made to do for events.
/// </para>
/// <para>
/// None of these are user preferences: they do not appear in the settings window, are not part of
/// <see cref="HostSettings"/>, and never round-trip through <c>settings.json</c> (#62 constraint 2).
/// They are compiled-in operational defaults, validated once at startup by <see cref="Validate"/> so
/// a bad value fails fast rather than surfacing as a mystery at the first closed label.
/// </para>
/// </remarks>
public sealed record NarrationDeliverySettings
{
    /// <summary>
    /// Directory that holds one blob-plus-sidecar pair per pending narration clip, organized as one
    /// subdirectory per capture session, exactly like <see cref="EventDeliverySettings.SpoolDirectory"/>'s
    /// layout idiom.
    /// </summary>
    public string SpoolDirectory { get; init; } =
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Jazz",
            "spool",
            "narration");

    /// <summary>
    /// The largest single narration clip the spool will admit.
    /// </summary>
    /// <remarks>
    /// <see cref="Settings.NarrationClipByteCeiling"/> already bounds a sealed clip at 30 minutes of
    /// 16 kHz mono PCM plus a 44-byte RIFF header -- 57,600,044 bytes, about 54.93 MiB. This ceiling
    /// must clear that with headroom or a maximal (30-minute) label is refused every single time;
    /// 64 MiB clears it by roughly 16%. Pinned by a test asserting
    /// <c>Settings.NarrationClipByteCeiling + NarrationWave.HeaderLength &lt;= MaximumClipBytes</c>,
    /// so the two numbers cannot silently drift apart.
    /// </remarks>
    public long MaximumClipBytes { get; init; } = 64L * 1024 * 1024;

    /// <summary>
    /// Total bytes, across every staged clip plus outstanding deletion debt, that the spool may hold
    /// before its oldest entries are evicted. See this type's own remarks for the accepted
    /// consequence of this exact number.
    /// </summary>
    public long SpoolByteCeiling { get; init; } = 512L * 1024 * 1024;

    /// <summary>
    /// Longest a clip may sit undelivered before it is evicted regardless of the byte ceiling. See
    /// this type's own remarks for why this is deliberately equal to
    /// <see cref="EventDeliverySettings.SpoolRetention"/>. Compared directly against a clock in
    /// <see cref="NarrationSpool"/>'s own eviction sweep, so -- like
    /// <see cref="EventDeliverySettings.SpoolRetention"/> -- this is deliberately not checked against
    /// <see cref="ScreenshotDeliverySettings.MaximumTimerDuration"/> in <see cref="Validate"/>.
    /// </summary>
    public TimeSpan SpoolRetention { get; init; } = TimeSpan.FromHours(48);

    /// <summary>
    /// Wall-clock ceiling on the capture-path <c>files/prepare</c> call the narration stager never
    /// actually makes -- <see cref="NarrationDeliveryStager"/> makes no network call at all -- but
    /// this budget is still the one <see cref="NarrationDeliveryWorker"/>'s own prepare step uses on
    /// its background task, matching <see cref="ScreenshotDeliverySettings.PrepareBudget"/>'s
    /// meaning for the one Files call this shares in shape with the screenshot path.
    /// </summary>
    public TimeSpan PrepareBudget { get; init; } = TimeSpan.FromSeconds(10);

    /// <summary>
    /// Ceiling on the best-effort <c>DELETE /v2/storage/files/{id}</c> issued when a narration upload
    /// fails after prepare already minted a Files allocation -- the dangling-allocation cleanup rule
    /// that issue #84 (§2.6, citing macOS's own fixed duplicate-record bug) requires and that
    /// screenshot delivery deliberately does not perform.
    /// </summary>
    public TimeSpan PrepareCleanupBudget { get; init; } = TimeSpan.FromSeconds(5);

    /// <summary>
    /// Ceiling on a single narration clip's GCS PUT.
    /// </summary>
    /// <remarks>
    /// <b>Twenty times <see cref="ScreenshotDeliverySettings.UploadCallBudget"/> (30 s), and that
    /// is the point, not an oversight (amendment 4 to the #84 plan's open question 4).</b> A
    /// screenshot is a few hundred kilobytes; a maximal narration clip is 54.93 MiB. Finishing that
    /// upload inside 30 seconds needs roughly 15 Mbps of sustained throughput, which this client
    /// cannot assume of every deployed machine's uplink. Ten minutes is what a maximal clip needs to
    /// complete at a much more modest ~100 KB/s. This is still a hard deadline on a linked
    /// <see cref="CancellationTokenSource"/>, <see cref="Validate"/>-checked against
    /// <see cref="ScreenshotDeliverySettings.MaximumTimerDuration"/> exactly like every other timer
    /// bound here -- not an unbounded wait -- and it is deliberately the largest budget anywhere in
    /// this client's Files transport, which a self-review pass is expected to flag; this remark is
    /// the answer to that flag, not evidence that it was missed.
    /// </remarks>
    public TimeSpan UploadCallBudget { get; init; } = TimeSpan.FromMinutes(10);

    /// <summary>
    /// Delay before the first retry of a retryable upload failure. The schedule doubles from here,
    /// before <see cref="NarrationUploadRetryPolicy"/> applies jitter and clamps to
    /// <see cref="UploadBackoffCeiling"/>.
    /// </summary>
    public TimeSpan UploadBackoffInitial { get; init; } = TimeSpan.FromSeconds(10);

    /// <summary>Cap on the doubling of the upload backoff, applied before jitter.</summary>
    public TimeSpan UploadBackoffCeiling { get; init; } = TimeSpan.FromMinutes(15);

    /// <summary>
    /// Validates every bound, throwing on the first one that cannot work. See
    /// <see cref="ScreenshotDeliverySettings.Validate"/> for why every timer-bound value is checked
    /// against <see cref="ScreenshotDeliverySettings.MaximumTimerDuration"/> here too, and why
    /// <see cref="SpoolRetention"/> is the one deliberate carve-out.
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
                "The narration spool directory must be a non-empty path.",
                nameof(SpoolDirectory));
        }

        if (!Path.IsPathFullyQualified(SpoolDirectory))
        {
            throw new ArgumentException(
                "The narration spool directory must be a fully qualified path.",
                nameof(SpoolDirectory));
        }

        if (MaximumClipBytes <= 0)
        {
            throw new ArgumentOutOfRangeException(
                nameof(MaximumClipBytes),
                MaximumClipBytes,
                "The maximum clip size must be a positive number of bytes.");
        }

        // Pins MaximumClipBytes against the real ceiling a sealed clip can reach, so the two numbers
        // cannot silently drift apart -- see this type's own remarks on MaximumClipBytes.
        long maximalSealedClip = (long)NarrationWave.BytesPerSecond * 60 * 30 + NarrationWave.HeaderLength;
        if (MaximumClipBytes < maximalSealedClip)
        {
            throw new ArgumentOutOfRangeException(
                nameof(MaximumClipBytes),
                MaximumClipBytes,
                "The maximum clip size must admit a maximal (30-minute, 16 kHz mono PCM) sealed "
                    + "clip, or a full-length label would be refused every time.");
        }

        if (SpoolByteCeiling <= 0)
        {
            throw new ArgumentOutOfRangeException(
                nameof(SpoolByteCeiling),
                SpoolByteCeiling,
                "The spool byte ceiling must be a positive number of bytes.");
        }

        // The plan's §2.2 floor is hard, not a suggestion: "under ~110 MiB two maximal clips cannot
        // coexist" -- a ceiling that admits only one maximal clip at a time means every second
        // full-length label thrashes the spool (admits, immediately evicts the first to make room,
        // reports it undelivered) instead of the two genuinely coexisting the way the default
        // 512 MiB / 64 MiB pair does. Pinned here, the same way MaximumClipBytes is pinned against
        // the real maximal sealed clip above, so the two configured numbers cannot silently drift
        // into a combination that defeats its own purpose.
        // Written as a division, not "2 * MaximumClipBytes" (review finding): MaximumClipBytes is
        // only checked to be positive above, and a sufficiently large custom value would overflow a
        // signed 64-bit multiplication into a negative number, which a tiny SpoolByteCeiling would
        // then wrongly satisfy.
        if (MaximumClipBytes > SpoolByteCeiling / 2)
        {
            throw new ArgumentOutOfRangeException(
                nameof(SpoolByteCeiling),
                SpoolByteCeiling,
                "The spool byte ceiling must admit at least two maximal clips at once, or the "
                    + "spool would thrash -- evicting one maximal clip to admit the very next one --"
                    + " on every long label.");
        }

        if (SpoolRetention <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(
                nameof(SpoolRetention),
                SpoolRetention,
                "The spool retention window must be a positive duration.");
        }

        if (PrepareBudget <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(
                nameof(PrepareBudget),
                PrepareBudget,
                "The prepare budget must be a positive duration.");
        }

        RejectPastTimerLimit(nameof(PrepareBudget), PrepareBudget);

        if (PrepareCleanupBudget <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(
                nameof(PrepareCleanupBudget),
                PrepareCleanupBudget,
                "The prepare cleanup budget must be a positive duration.");
        }

        RejectPastTimerLimit(nameof(PrepareCleanupBudget), PrepareCleanupBudget);

        if (UploadCallBudget <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(
                nameof(UploadCallBudget),
                UploadCallBudget,
                "The upload call budget must be a positive duration.");
        }

        RejectPastTimerLimit(nameof(UploadCallBudget), UploadCallBudget);

        if (UploadBackoffInitial <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(
                nameof(UploadBackoffInitial),
                UploadBackoffInitial,
                "The initial upload backoff must be a positive duration.");
        }

        if (UploadBackoffCeiling < UploadBackoffInitial)
        {
            throw new ArgumentOutOfRangeException(
                nameof(UploadBackoffCeiling),
                UploadBackoffCeiling,
                "The upload backoff ceiling cannot be shorter than the initial backoff.");
        }

        RejectPastTimerLimit(nameof(UploadBackoffInitial), UploadBackoffInitial);
        RejectPastTimerLimit(nameof(UploadBackoffCeiling), UploadBackoffCeiling);

        if (NarrationUploadRetryPolicy.MinimumFirstAttemptDelay(this) <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(
                nameof(UploadBackoffInitial),
                UploadBackoffInitial,
                "The initial upload backoff must be large enough that, even after the worst-case "
                    + "jitter, the first retry delay does not truncate to zero.");
        }
    }
}
