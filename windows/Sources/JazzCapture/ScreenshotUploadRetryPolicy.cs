using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace JazzCapture;

/// <summary>
/// Deterministic, bounded, jittered retry timing for the background screenshot upload.
/// </summary>
/// <remarks>
/// <para>
/// The delay doubles per failed attempt from <see cref="ScreenshotDeliverySettings.UploadBackoffInitial"/>
/// and is capped at <see cref="ScreenshotDeliverySettings.UploadBackoffCeiling"/>, so an upload that
/// keeps failing settles at the ceiling instead of growing without limit or hammering GCS.
/// </para>
/// <para>
/// The jitter is derived from the artifact id — the stable identity of one screenshot upload — rather
/// than from process-local randomness, mirroring the structure of
/// <see cref="JazzCaptureCore.Delivery.ArchiveDeliveryRetryPolicy"/>. But the reason differs: this
/// staging area is deliberately not durable (see <see cref="ScreenshotDeliverySettings.StagingDirectory"/>)
/// and does not survive a relaunch, so there is no cross-relaunch schedule to preserve here. Keying on
/// the artifact id instead buys two things within a single process lifetime: two screenshots that
/// failed during the same outage do not wake together and retry in lockstep, and the schedule is
/// testable without depending on wall-clock randomness. It is not, and does not need to be, recoverable
/// across a crash the way the archive delivery schedule is.
/// </para>
/// <para>
/// The multiplier stays inside a closed 75-100% window so the delay is always positive and never
/// exceeds the ceiling.
/// </para>
/// </remarks>
public static class ScreenshotUploadRetryPolicy
{
    /// <summary>
    /// Stable identity fed to <see cref="Delay"/> for <see cref="DeliveryDrainScheduler"/>'s own
    /// backoff between failed screenshot drain passes, when a whole pass fails outright rather than
    /// one particular screenshot's upload failing. Moved here from the now-generalised
    /// <c>ScreenshotDeliveryScheduler</c> (issue #48, §2.6): that type no longer knows this policy
    /// exists, so the identity it used to own now lives beside the policy itself, exactly as
    /// <see cref="EventStreamRetryPolicy.DrainLoopBackoffIdentity"/> does for the event drain loop.
    /// </summary>
    public const string DrainLoopBackoffIdentity = "screenshot-delivery-scheduler/drain-loop";

    /// <summary>Lowest retained fraction of the exponential delay, in basis points.</summary>
    private const long JitterFloorBasisPoints = 7_500;

    /// <summary>Number of distinct jitter values, giving the closed window [7500, 10000] bps.</summary>
    private const long JitterBasisPointCount = 2_501;

    private const long BasisPointDenominator = 10_000;

    /// <summary>
    /// Domain separator of the jitter hash, NUL-terminated so the hashed string cannot run into the
    /// identity appended after it. This domain differs from the archive delivery policy's so the two
    /// policies never produce the same timings for the same identity string.
    /// </summary>
    private const string JitterDomain = "jazz-screenshot-upload-retry-jitter/v1\0";

    /// <summary>
    /// The bounded jittered delay before retrying a failed screenshot upload.
    /// </summary>
    /// <param name="failedAttempt">Number of the attempt that just failed; 0 or more.</param>
    /// <param name="artifactId">Stable identity of the screenshot upload the jitter is derived from.</param>
    /// <param name="settings">The backoff bounds to compute against.</param>
    /// <exception cref="ArgumentOutOfRangeException"><paramref name="failedAttempt"/> is negative.</exception>
    /// <exception cref="ArgumentException"><paramref name="artifactId"/> is null, empty, or whitespace.</exception>
    /// <exception cref="ArgumentNullException"><paramref name="settings"/> is <see langword="null"/>.</exception>
    public static TimeSpan Delay(int failedAttempt, string artifactId, ScreenshotDeliverySettings settings)
    {
        if (failedAttempt < 0)
        {
            throw new ArgumentOutOfRangeException(
                nameof(failedAttempt),
                failedAttempt,
                "A failed attempt count cannot be negative.");
        }

        if (string.IsNullOrWhiteSpace(artifactId))
        {
            throw new ArgumentException("Retry jitter requires a non-empty artifact id.", nameof(artifactId));
        }

        ArgumentNullException.ThrowIfNull(settings);

        long initialMilliseconds = (long)settings.UploadBackoffInitial.TotalMilliseconds;
        long ceilingMilliseconds = (long)settings.UploadBackoffCeiling.TotalMilliseconds;

        // Finding 3 (#74 review, second pass) also flagged that this loop runs its full 62
        // iterations when initialMilliseconds is 0, since 0 << n never exceeds the ceiling. No
        // extra guard is added here: the "&& maximumExponent < 62" clause already bounds every
        // call to at most 62 cheap shift-and-compare iterations regardless of input, so this was
        // never an unbounded loop, only a wasted (and harmless) worst case. ScreenshotDeliverySettings.Validate
        // now rejects any UploadBackoffInitial that cannot produce a positive delay -- see
        // MinimumFirstAttemptDelay below -- so initialMilliseconds is at least 2 for any settings
        // that passed validation, and this loop exits after its very first comparison in the
        // overwhelming majority of real configurations anyway.
        int maximumExponent = 0;
        while (initialMilliseconds << (maximumExponent + 1) <= ceilingMilliseconds
            && maximumExponent < 62)
        {
            maximumExponent++;
        }

        int exponent = Math.Clamp(failedAttempt - 1, 0, maximumExponent);
        long exponential = Math.Min(initialMilliseconds << exponent, ceilingMilliseconds);
        long jitterBasisPoints =
            JitterFloorBasisPoints + (long)(JitterSample(artifactId) % (ulong)JitterBasisPointCount);
        long delayMilliseconds = exponential * jitterBasisPoints / BasisPointDenominator;

        return TimeSpan.FromMilliseconds(delayMilliseconds);
    }

    /// <summary>
    /// The smallest delay <see cref="Delay"/> can ever produce for a first failed attempt (exponent
    /// zero), using the lowest possible jitter multiplier (<see cref="JitterFloorBasisPoints"/> over
    /// <see cref="BasisPointDenominator"/>) rather than any one artifact id's actual sample.
    /// </summary>
    /// <remarks>
    /// <para>
    /// This exists for <see cref="ScreenshotDeliverySettings.Validate"/> (Finding 3, #74 review,
    /// second pass): a sub-millisecond <see cref="ScreenshotDeliverySettings.UploadBackoffInitial"/>
    /// truncates to zero milliseconds in <see cref="Delay"/>'s integer arithmetic, and the jitter
    /// applied on top of zero is still zero, so a retryable failure in
    /// <see cref="DeliveryDrainScheduler"/>'s exception path would retry with no backoff at all
    /// -- a hot loop. Deriving the validator's floor from this method, instead of hardcoding the
    /// integer millisecond threshold (2) directly in the settings validator, means the check tracks
    /// <see cref="JitterFloorBasisPoints"/> and <see cref="BasisPointDenominator"/> automatically if
    /// either ever changes, rather than silently drifting out of sync with them.
    /// </para>
    /// <para>
    /// Deliberately does not depend on <paramref name="settings"/>'s own <see cref="Delay"/> having
    /// been called with any particular artifact id: a specific id's jitter sample can land anywhere
    /// in the closed window and might happen to round up even when the true worst case (the lowest
    /// multiplier, drawn by some other id) would still truncate to zero. Validation has to reject
    /// the worst case, not get lucky on whichever id happens to be handy.
    /// </para>
    /// </remarks>
    internal static TimeSpan MinimumFirstAttemptDelay(ScreenshotDeliverySettings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);

        long initialMilliseconds = (long)settings.UploadBackoffInitial.TotalMilliseconds;
        long ceilingMilliseconds = (long)settings.UploadBackoffCeiling.TotalMilliseconds;

        // Exponent zero: the first failed attempt's exponential delay before jitter, exactly as
        // Delay computes it for failedAttempt <= 1.
        long exponential = Math.Min(initialMilliseconds, ceilingMilliseconds);
        long delayMilliseconds = exponential * JitterFloorBasisPoints / BasisPointDenominator;
        return TimeSpan.FromMilliseconds(delayMilliseconds);
    }

    /// <summary>
    /// The first 64 bits of <c>sha256(domain || artifactId)</c>, as a stable per-artifact sample.
    /// </summary>
    private static ulong JitterSample(string artifactId)
    {
        byte[] digest = SHA256.HashData(new UTF8Encoding(false).GetBytes(JitterDomain + artifactId));
        string prefix = Convert.ToHexString(digest.AsSpan(0, 8)).ToLowerInvariant();
        return ulong.Parse(prefix, NumberStyles.HexNumber, CultureInfo.InvariantCulture);
    }
}
