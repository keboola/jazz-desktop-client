using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace JazzCapture;

/// <summary>
/// Deterministic, bounded, jittered retry timing for a retryable narration upload failure, and for
/// the drain loop's own backoff between failed passes.
/// </summary>
/// <remarks>
/// <para>
/// Structurally identical to <see cref="EventStreamRetryPolicy"/> and
/// <see cref="ScreenshotUploadRetryPolicy"/>: the delay doubles per failed attempt from
/// <see cref="NarrationDeliverySettings.UploadBackoffInitial"/> and is capped at
/// <see cref="NarrationDeliverySettings.UploadBackoffCeiling"/>, with a 75-100% jitter multiplier
/// derived from a stable identity so the delay is always positive and never exceeds the ceiling.
/// </para>
/// <para>
/// <b>No attempt budget, exactly like an event and unlike a screenshot.</b> A retryable narration
/// upload failure retries indefinitely: <see cref="NarrationSpool.RecordRetry"/> never drops an
/// entry, so this policy only ever needs to compute how long to wait before the next attempt, never
/// whether there should be one. See <see cref="NarrationSpool"/>'s own remarks.
/// </para>
/// <para>
/// The jitter domain below is its own, NUL-terminated string, distinct from every other retry
/// policy's domain in this codebase, so this policy can never produce the same timings as any of the
/// other three for the same identity string.
/// </para>
/// </remarks>
public static class NarrationUploadRetryPolicy
{
    /// <summary>
    /// Stable identity fed to <see cref="Delay"/> for the drain loop's own backoff, when a whole
    /// drain pass fails outright rather than one particular clip's upload failing.
    /// </summary>
    public const string DrainLoopBackoffIdentity = "narration-delivery-scheduler/drain-loop";

    /// <summary>Lowest retained fraction of the exponential delay, in basis points.</summary>
    private const long JitterFloorBasisPoints = 7_500;

    /// <summary>Number of distinct jitter values, giving the closed window [7500, 10000] bps.</summary>
    private const long JitterBasisPointCount = 2_501;

    private const long BasisPointDenominator = 10_000;

    /// <summary>
    /// Domain separator of the jitter hash, NUL-terminated so the hashed string cannot run into the
    /// identity appended after it. Distinct from every other retry policy's domain in this codebase.
    /// </summary>
    private const string JitterDomain = "jazz-narration-upload-retry/v1\0";

    /// <summary>
    /// The bounded jittered delay before retrying a failed narration upload, or before the drain
    /// loop itself retries a failed pass.
    /// </summary>
    /// <param name="failedAttempt">Number of the attempt that just failed; 0 or more.</param>
    /// <param name="identity">
    /// Stable identity the jitter is derived from: the spool key
    /// (<c>"&lt;sessionId&gt;/&lt;fileName&gt;"</c>) for one clip's own retry schedule, or
    /// <see cref="DrainLoopBackoffIdentity"/> for the drain loop's pass-level backoff.
    /// </param>
    /// <param name="settings">The backoff bounds to compute against.</param>
    /// <exception cref="ArgumentOutOfRangeException"><paramref name="failedAttempt"/> is negative.</exception>
    /// <exception cref="ArgumentException"><paramref name="identity"/> is null, empty, or whitespace.</exception>
    /// <exception cref="ArgumentNullException"><paramref name="settings"/> is <see langword="null"/>.</exception>
    public static TimeSpan Delay(int failedAttempt, string identity, NarrationDeliverySettings settings)
    {
        if (failedAttempt < 0)
        {
            throw new ArgumentOutOfRangeException(
                nameof(failedAttempt),
                failedAttempt,
                "A failed attempt count cannot be negative.");
        }

        if (string.IsNullOrWhiteSpace(identity))
        {
            throw new ArgumentException("Retry jitter requires a non-empty identity.", nameof(identity));
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
            JitterFloorBasisPoints + (long)(JitterSample(identity) % (ulong)JitterBasisPointCount);
        long delayMilliseconds = exponential * jitterBasisPoints / BasisPointDenominator;

        return TimeSpan.FromMilliseconds(delayMilliseconds);
    }

    /// <summary>
    /// The smallest delay <see cref="Delay"/> can ever produce for a first failed attempt, using the
    /// lowest possible jitter multiplier rather than any one identity's actual sample. Exists for
    /// <see cref="NarrationDeliverySettings.Validate"/>, exactly as the sibling policies' own
    /// equivalents exist for their settings.
    /// </summary>
    internal static TimeSpan MinimumFirstAttemptDelay(NarrationDeliverySettings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);

        long initialMilliseconds = (long)settings.UploadBackoffInitial.TotalMilliseconds;
        long ceilingMilliseconds = (long)settings.UploadBackoffCeiling.TotalMilliseconds;

        long exponential = Math.Min(initialMilliseconds, ceilingMilliseconds);
        long delayMilliseconds = exponential * JitterFloorBasisPoints / BasisPointDenominator;
        return TimeSpan.FromMilliseconds(delayMilliseconds);
    }

    /// <summary>The first 64 bits of <c>sha256(domain || identity)</c>, as a stable per-identity sample.</summary>
    private static ulong JitterSample(string identity)
    {
        byte[] digest = SHA256.HashData(new UTF8Encoding(false).GetBytes(JitterDomain + identity));
        string prefix = Convert.ToHexString(digest.AsSpan(0, 8)).ToLowerInvariant();
        return ulong.Parse(prefix, NumberStyles.HexNumber, CultureInfo.InvariantCulture);
    }
}
