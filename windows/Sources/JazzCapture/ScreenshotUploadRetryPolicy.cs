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
    /// The first 64 bits of <c>sha256(domain || artifactId)</c>, as a stable per-artifact sample.
    /// </summary>
    private static ulong JitterSample(string artifactId)
    {
        byte[] digest = SHA256.HashData(new UTF8Encoding(false).GetBytes(JitterDomain + artifactId));
        string prefix = Convert.ToHexString(digest.AsSpan(0, 8)).ToLowerInvariant();
        return ulong.Parse(prefix, NumberStyles.HexNumber, CultureInfo.InvariantCulture);
    }
}
