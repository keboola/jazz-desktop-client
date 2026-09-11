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
    /// Directory that holds screenshot bytes staged for the background uploader, keyed by the Files
    /// id a successful prepare returned.
    /// </summary>
    /// <remarks>
    /// This area is deliberately not durable: it is cleaned at process launch, in explicit contrast
    /// to the narration spool, which macOS states is never cleaned at launch precisely because a
    /// leftover blob there is the whole point (<c>macos/Sources/JazzCaptureCore/NarrationSpool.swift:18-20</c>).
    /// A screenshot is cheap to lose and expensive to keep around indefinitely as a durable
    /// obligation — the event it belongs to has already been emitted, with or without a screenshot
    /// id, by the time anything is staged here — so a crash that loses staged screenshots is an
    /// accepted outcome, not a bug to fix. This path is a separate, non-durable location from the
    /// closed branch's durable spool (which lived under <c>spool\screenshots</c>); reusing that name
    /// here would misleadingly suggest the same durability guarantee.
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
    /// Validates every bound, throwing on the first one that cannot work.
    /// </summary>
    /// <exception cref="ArgumentOutOfRangeException">A bound is out of range for its own meaning.</exception>
    /// <exception cref="ArgumentException"><see cref="StagingDirectory"/> is missing or not rooted.</exception>
    public void Validate()
    {
        if (PrepareBudget <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(
                nameof(PrepareBudget),
                PrepareBudget,
                "The prepare budget must be a positive duration.");
        }

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

        if (UploadCallBudget <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(
                nameof(UploadCallBudget),
                UploadCallBudget,
                "The upload call budget must be a positive duration.");
        }

        if (PrepareWaitGrace <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(
                nameof(PrepareWaitGrace),
                PrepareWaitGrace,
                "The prepare wait grace must be a positive duration.");
        }

        if (PrepareCleanupBudget <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(
                nameof(PrepareCleanupBudget),
                PrepareCleanupBudget,
                "The prepare cleanup budget must be a positive duration.");
        }

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
