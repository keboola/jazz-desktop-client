using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace JazzCaptureCore.Delivery;

/// <summary>
/// Deterministic, bounded, jittered retry timing for archive delivery.
/// </summary>
/// <remarks>
/// <para>
/// The delay doubles per failed attempt from <see cref="InitialDelayMilliseconds"/> and is capped at
/// <see cref="MaximumDelayMilliseconds"/>, so a delivery that keeps failing settles into a five
/// minute poll instead of growing without limit or hammering the server.
/// </para>
/// <para>
/// The jitter is derived from the durable delivery identity, not from process-local randomness. Two
/// consequences follow, and both are the point: different archives spread across the retry window
/// rather than waking together after a shared outage, and one archive computes the same schedule
/// after a relaunch as it did before the crash. The multiplier stays inside a closed 75–100% window
/// so the delay is always positive and never exceeds the cap.
/// </para>
/// <para>
/// A server-supplied <c>nextAttemptAt</c> is authoritative and bypasses this policy entirely; the
/// queue only falls back here when the transport offers nothing.
/// </para>
/// </remarks>
public static class ArchiveDeliveryRetryPolicy
{
    /// <summary>Delay after the first failed attempt, before jitter.</summary>
    public const long InitialDelayMilliseconds = 2_000;

    /// <summary>Hard ceiling on the exponential delay, before jitter.</summary>
    public const long MaximumDelayMilliseconds = 300_000;

    /// <summary>Largest doubling applied to <see cref="InitialDelayMilliseconds"/>.</summary>
    public const int MaximumExponent = 8;

    /// <summary>Lowest retained fraction of the exponential delay, in basis points.</summary>
    private const long JitterFloorBasisPoints = 7_500;

    /// <summary>Number of distinct jitter values, giving the closed window [7500, 10000] bps.</summary>
    private const long JitterBasisPointCount = 2_501;

    private const long BasisPointDenominator = 10_000;

    /// <summary>
    /// Domain separator of the jitter hash, NUL-terminated as on macOS so the hashed string cannot
    /// run into the identity appended after it. The key differs from the macOS client's — this port
    /// keys the schedule on the delivery identity rather than an upload-operation identity — so the
    /// two share the policy, not the individual timings.
    /// </summary>
    private const string JitterDomain = "jazz-archive-upload-retry-jitter/v1\0";

    /// <summary>
    /// Returns the instant at which the delivery may next be attempted.
    /// </summary>
    /// <param name="anchor">Instant the attempt failed.</param>
    /// <param name="failedAttempt">Number of the attempt that just failed; 0 or more.</param>
    /// <param name="deliveryId">Durable delivery identity the jitter is derived from.</param>
    /// <exception cref="ArgumentOutOfRangeException"><paramref name="failedAttempt"/> is negative.</exception>
    /// <exception cref="ArgumentException"><paramref name="deliveryId"/> is not a delivery identity.</exception>
    public static DateTimeOffset NextAttemptAt(DateTimeOffset anchor, int failedAttempt, string deliveryId)
    {
        if (failedAttempt < 0)
        {
            throw new ArgumentOutOfRangeException(
                nameof(failedAttempt),
                failedAttempt,
                "A failed attempt count cannot be negative.");
        }

        if (!DeliveryIds.IsDeliveryId(deliveryId))
        {
            throw new ArgumentException("Retry jitter requires a durable delivery identity.", nameof(deliveryId));
        }

        return anchor.AddMilliseconds(DelayMilliseconds(failedAttempt, deliveryId));
    }

    /// <summary>The bounded jittered delay, in milliseconds, for a given failed attempt.</summary>
    public static long DelayMilliseconds(int failedAttempt, string deliveryId)
    {
        int exponent = Math.Clamp(failedAttempt - 1, 0, MaximumExponent);
        long exponential = Math.Min(InitialDelayMilliseconds << exponent, MaximumDelayMilliseconds);
        long jitterBasisPoints = JitterFloorBasisPoints + (long)(JitterSample(deliveryId) % (ulong)JitterBasisPointCount);
        return exponential * jitterBasisPoints / BasisPointDenominator;
    }

    /// <summary>
    /// The first 64 bits of <c>sha256(domain || deliveryId)</c>, as a stable per-delivery sample.
    /// </summary>
    private static ulong JitterSample(string deliveryId)
    {
        byte[] digest = SHA256.HashData(new UTF8Encoding(false).GetBytes(JitterDomain + deliveryId));
        string prefix = Convert.ToHexString(digest.AsSpan(0, 8)).ToLowerInvariant();
        return ulong.Parse(prefix, NumberStyles.HexNumber, CultureInfo.InvariantCulture);
    }
}
