using System.IO;

namespace JazzCapture;

/// <summary>
/// The operational bounds for prepare-early screenshot delivery to Keboola Files.
/// </summary>
/// <remarks>
/// <para>
/// Prepare-early accepts eventual inconsistency by design: the capture path calls
/// <c>POST /v2/storage/files/prepare</c> under <see cref="PrepareBudget"/>, and on success stamps the
/// returned Files id on the event while staging the bytes for a background uploader; on failure or
/// budget exhaustion the event goes out with no screenshot id and nothing is staged. Every value here
/// exists to protect the capture path and the local disk, not to guarantee that a screenshot is ever
/// delivered — a terminally failed upload simply leaves a dangling <c>screenshot_id</c> that the Jazz
/// processor already tolerates by dropping a failed screenshot download and continuing.
/// </para>
/// <para>
/// None of these are user preferences: they do not appear in the settings window, are not part of
/// <see cref="HostSettings"/>, and never round-trip through <c>settings.json</c>. They are compiled-in
/// operational defaults, validated once at startup by <see cref="Validate"/> so a bad value fails fast
/// rather than surfacing as a mystery at the first screenshot.
/// </para>
/// </remarks>
public sealed record ScreenshotDeliverySettings
{
    /// <summary>
    /// Wall-clock ceiling on the capture-path <c>files/prepare</c> call.
    /// </summary>
    /// <remarks>
    /// This is the whole point of the budget: a slow or failing network must never hold an event back.
    /// When the budget elapses, the capture path abandons the prepare and emits the event with no
    /// screenshot id, exactly as it would on an outright prepare failure. macOS records the same
    /// design intent for its own click path in
    /// <c>macos/Sources/JazzCapture/CaptureController.swift:146-148</c> (<c>prepareBudget</c>, 3
    /// seconds).
    /// </remarks>
    public TimeSpan PrepareBudget { get; init; } = TimeSpan.FromSeconds(3);

    /// <summary>
    /// Total attempts for the background GCS upload of one staged screenshot, including the first.
    /// </summary>
    public int UploadAttempts { get; init; } = 5;

    /// <summary>
    /// Delay before the first retry of a failed upload. The schedule doubles from here on each
    /// subsequent failure, before <see cref="ScreenshotUploadRetryPolicy"/> applies jitter and clamps
    /// to <see cref="UploadBackoffCeiling"/>.
    /// </summary>
    /// <remarks>
    /// With the default <see cref="UploadBackoffCeiling"/> this produces the same 1/2/4/8 second
    /// progression across five attempts that the macOS uploader uses.
    /// </remarks>
    public TimeSpan UploadBackoffInitial { get; init; } = TimeSpan.FromSeconds(1);

    /// <summary>
    /// Cap on the doubling of the upload backoff, applied before jitter.
    /// </summary>
    public TimeSpan UploadBackoffCeiling { get; init; } = TimeSpan.FromSeconds(8);

    /// <summary>
    /// Ceiling on a single GCS upload call (the PUT of one screenshot's bytes).
    /// </summary>
    /// <remarks>
    /// The closed screenshot-Files branch set no timeout of its own inside the Files client and
    /// relied entirely on the shared <see cref="HttpClient"/>'s default, which is effectively
    /// unbounded for a single call of this kind. This value replaces that omission: an upload call
    /// that runs longer than this is abandoned and counted as a failed attempt against
    /// <see cref="UploadAttempts"/>.
    /// </remarks>
    public TimeSpan UploadCallBudget { get; init; } = TimeSpan.FromSeconds(30);

    /// <summary>
    /// Margin added to <see cref="PrepareBudget"/> when the capture path waits synchronously for the
    /// asynchronous prepare to come back.
    /// </summary>
    /// <remarks>
    /// The transport already enforces <see cref="PrepareBudget"/> internally and is documented to
    /// report a failure rather than hang past it, so this is not a second deadline competing with the
    /// first — it is only the slack the already-elapsed internal timeout needs to unwind and be
    /// observed on the waiting thread. Waiting for exactly <see cref="PrepareBudget"/> would race
    /// that unwind and turn a prepare that did finish in time into a capture-path timeout.
    /// </remarks>
    public TimeSpan PrepareWaitGrace { get; init; } = TimeSpan.FromSeconds(2);

    /// <summary>
    /// Ceiling on the best-effort <c>DELETE /v2/storage/files/{id}</c> issued when a prepare produced
    /// a Files allocation this client can never upload to — a non-<c>gcp</c> provider, or a malformed
    /// <c>gcsUploadParams</c> — or when the capture path is cancelled mid-prepare.
    /// </summary>
    /// <remarks>
    /// The closed screenshot-Files branch hardcoded exactly two seconds for this at
    /// <c>KeboolaFilesClient.cs:644</c>; this moves the same bound into configuration. Cleanup is
    /// best-effort: it never blocks the capture path beyond this budget, and its failure is silently
    /// tolerated because a leaked, never-uploaded Files allocation costs storage, not correctness.
    /// </remarks>
    public TimeSpan PrepareCleanupBudget { get; init; } = TimeSpan.FromSeconds(2);

    /// <summary>
    /// Directory that holds screenshot bytes staged for the background uploader, keyed by the
    /// artifact id each screenshot belongs to (see <c>ScreenshotStagingArea.PathFor</c>/<c>Key</c>),
    /// not by the Files id a successful prepare returns.
    /// </summary>
    /// <remarks>
    /// This area is deliberately not durable: it is cleaned at process launch, in explicit contrast
    /// to the narration spool, which macOS states is never cleaned at launch precisely because a
    /// leftover blob there is the whole point (<c>macos/Sources/JazzCaptureCore/NarrationSpool.swift:18-20</c>).
    /// A screenshot is cheap to lose and expensive to keep around indefinitely as a durable
    /// obligation, and this design accepts three distinct crash windows rather than paying that
    /// cost -- none of them is a defect, and none is fixed by a durable spool, a journal of delivery
    /// intents, a startup reconciliation sweep, or an idempotent Files lookup, all of which issue
    /// #73 explicitly forbids. The bytes for one screenshot land in this directory (<c>Stage</c>
    /// returns <see cref="ScreenshotStageResult.Staged"/>) strictly before
    /// <c>ScreenshotDeliveryPreparer.Prepare</c> wakes the background uploader and returns the Files
    /// id for the capture engine to stamp onto the outgoing event and emit -- see
    /// <see cref="ScreenshotDeliveryPreparer"/>'s own remarks for that exact sequencing. A crash can
    /// therefore land in any of three places. Before <c>Stage</c> ever completes, the prepare call
    /// has already allocated a Files id remotely but nothing has been staged and no event went out,
    /// so a crash here leaves an unused Files allocation that nothing will ever reference or clean
    /// up -- a staging *refusal* (as opposed to a crash) does delete that allocation with a bounded
    /// best-effort call, but a crash has no such opportunity. After <c>Stage</c> succeeds but before
    /// the event is emitted, the background uploader has already been woken and may be uploading, or
    /// may even finish uploading, entirely concurrently with the capture thread stamping and emitting
    /// that same screenshot's event -- a crash in this window yields either the same unused
    /// allocation as above, or, if the upload actually won that race, an orphan object in Keboola
    /// Files that no emitted event will ever reference, the mirror image of a dangling id. Only after
    /// the event has been emitted does the familiar case apply: a crash that then loses the
    /// still-staged bytes leaves that already-emitted event's <c>screenshot_id</c> permanently
    /// dangling, which the Jazz processor already tolerates by dropping a failed screenshot download
    /// and continuing. This path is a separate, non-durable location from the closed branch's
    /// durable spool (which lived under <c>spool\screenshots</c>); reusing that name here would
    /// misleadingly suggest the same durability guarantee.
    /// </remarks>
    public string StagingDirectory { get; init; } =
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Jazz",
            "staging",
            "screenshots");

    /// <summary>
    /// Total size, across every staged screenshot, that the staging directory may hold before the
    /// oldest entries are evicted.
    /// </summary>
    /// <remarks>
    /// Bounds the disk cost of an extended offline stretch, during which prepares keep succeeding and
    /// bytes keep staging but nothing can upload.
    /// </remarks>
    public long StagingByteCeiling { get; init; } = 256L * 1024 * 1024;

    /// <summary>
    /// Longest a staged screenshot may sit unuploaded before it is evicted regardless of the total
    /// size bound.
    /// </summary>
    /// <remarks>
    /// Age is bounded independently of size because a small number of screenshots stuck retrying
    /// against a persistently failing endpoint should not linger forever just because they never add
    /// up to <see cref="StagingByteCeiling"/>.
    /// </remarks>
    public TimeSpan StagingRetention { get; init; } = TimeSpan.FromHours(24);

    /// <summary>
    /// The longest duration the timeout APIs these bounds are handed to can represent.
    /// <see cref="CancellationTokenSource.CancelAfter(TimeSpan)"/>, the
    /// <see cref="CancellationTokenSource"/> timed constructor and <see cref="Task.Wait(TimeSpan)"/>
    /// all reject anything past <see cref="int.MaxValue"/> milliseconds (about 24.8 days), which is
    /// the tightest limit involved -- <see cref="Task.Delay(TimeSpan)"/> allows roughly twice that.
    /// </summary>
    /// <remarks>
    /// <b>Why (Finding 1, #74 review, thirteenth pass).</b> <see cref="Validate"/> used to accept
    /// durations the runtime then refuses at the point of use, so startup reported the configuration
    /// as good and the failure surfaced later -- at the first prepare, the first upload, or the
    /// scheduler's first backoff -- which is exactly the "mystery at the first screenshot" this
    /// method exists to prevent. <see cref="StagingRetention"/> is deliberately not checked against
    /// this: it is compared against a clock and never handed to a timer, so a retention window
    /// longer than 24.8 days is unusual but not broken, and capping it here would reject a
    /// configuration that works. <see cref="UploadBackoffInitial"/> needs no check of its own
    /// either, since it can never exceed <see cref="UploadBackoffCeiling"/>, which is checked.
    /// </remarks>
    internal static readonly TimeSpan MaximumTimerDuration = TimeSpan.FromMilliseconds(int.MaxValue);

    /// <summary>
    /// Validates every bound, throwing on the first one that cannot work.
    /// </summary>
    /// <exception cref="ArgumentOutOfRangeException">A bound is out of range for its own meaning.</exception>
    /// <exception cref="ArgumentException"><see cref="StagingDirectory"/> is missing or not rooted.</exception>
    public void Validate()
    {
        // Finding 1 (#74 review, thirteenth pass): every bound below that ends up as a timeout goes
        // through this, so a duration the runtime will refuse is rejected here instead of at the
        // first screenshot. See MaximumTimerDuration for which bounds are in scope and why the two
        // that are not are left out.
        static void RejectPastTimerLimit(string name, TimeSpan value)
        {
            if (value > MaximumTimerDuration)
            {
                throw new ArgumentOutOfRangeException(
                    name,
                    value,
                    "This bound becomes a timeout, and cannot be longer than int.MaxValue "
                        + "milliseconds (about 24.8 days), which is all the timeout APIs it is "
                        + "handed to can represent.");
            }
        }

        if (PrepareBudget <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(
                nameof(PrepareBudget),
                PrepareBudget,
                "The prepare budget must be a positive duration.");
        }

        RejectPastTimerLimit(nameof(PrepareBudget), PrepareBudget);

        if (UploadAttempts < 1)
        {
            throw new ArgumentOutOfRangeException(
                nameof(UploadAttempts),
                UploadAttempts,
                "There must be at least one upload attempt.");
        }

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

        RejectPastTimerLimit(nameof(UploadBackoffCeiling), UploadBackoffCeiling);

        // Finding 3 (#74 review, second pass): ScreenshotUploadRetryPolicy.Delay truncates to
        // whole milliseconds before applying jitter, so a sub-millisecond UploadBackoffInitial (or
        // one just barely above zero) can compute a zero delay for the very first retry. A zero
        // delay in ScreenshotDeliveryScheduler's exception path means the drain loop retries with
        // no backoff at all -- a hot loop, not a retry schedule. This is expressed against the
        // policy's own worst-case computation (see ScreenshotUploadRetryPolicy.MinimumFirstAttemptDelay)
        // rather than a hardcoded millisecond floor, so the check cannot drift out of sync if the
        // jitter constants themselves ever change.
        if (ScreenshotUploadRetryPolicy.MinimumFirstAttemptDelay(this) <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(
                nameof(UploadBackoffInitial),
                UploadBackoffInitial,
                "The initial upload backoff must be large enough that, even after the worst-case "
                    + "jitter, the first retry delay does not truncate to zero.");
        }

        if (UploadCallBudget <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(
                nameof(UploadCallBudget),
                UploadCallBudget,
                "The upload call budget must be a positive duration.");
        }

        RejectPastTimerLimit(nameof(UploadCallBudget), UploadCallBudget);

        if (PrepareWaitGrace <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(
                nameof(PrepareWaitGrace),
                PrepareWaitGrace,
                "The prepare wait grace must be a positive duration.");
        }

        RejectPastTimerLimit(nameof(PrepareWaitGrace), PrepareWaitGrace);

        // Both operands are within the timer limit by now, so this addition cannot overflow --
        // but their sum can still exceed what ScreenshotDeliveryPreparer's own Task.Wait accepts.
        if (PrepareBudget + PrepareWaitGrace > MaximumTimerDuration)
        {
            throw new ArgumentOutOfRangeException(
                nameof(PrepareWaitGrace),
                PrepareWaitGrace,
                "The prepare budget plus its wait grace is the single bound the capture path waits "
                    + "on, so their sum must also stay within what a timeout API can represent.");
        }

        if (PrepareCleanupBudget <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(
                nameof(PrepareCleanupBudget),
                PrepareCleanupBudget,
                "The prepare cleanup budget must be a positive duration.");
        }

        RejectPastTimerLimit(nameof(PrepareCleanupBudget), PrepareCleanupBudget);

        if (string.IsNullOrWhiteSpace(StagingDirectory))
        {
            throw new ArgumentException(
                "The screenshot staging directory must be a non-empty path.",
                nameof(StagingDirectory));
        }

        if (!Path.IsPathFullyQualified(StagingDirectory))
        {
            throw new ArgumentException(
                "The screenshot staging directory must be a fully qualified path.",
                nameof(StagingDirectory));
        }

        if (StagingByteCeiling <= 0)
        {
            throw new ArgumentOutOfRangeException(
                nameof(StagingByteCeiling),
                StagingByteCeiling,
                "The staging byte ceiling must be a positive number of bytes.");
        }

        if (StagingRetention <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(
                nameof(StagingRetention),
                StagingRetention,
                "The staging retention window must be a positive duration.");
        }
    }
}
