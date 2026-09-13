using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace JazzCapture;

/// <summary>
/// Deterministic, bounded, jittered retry timing for a retryable event send, and for the drain
/// loop's own backoff between failed passes.
/// </summary>
/// <remarks>
/// <para>
/// Structurally identical to <see cref="ScreenshotUploadRetryPolicy"/>: the delay doubles per failed
/// attempt from <see cref="EventDeliverySettings.SendBackoffInitial"/> and is capped at
/// <see cref="EventDeliverySettings.SendBackoffCeiling"/>, with a 75-100% jitter multiplier derived
/// from a stable identity so the delay is always positive and never exceeds the ceiling.
/// </para>
/// <para>
/// <b>Why a third policy rather than generalising one shared implementation (see §2.5 of the #48
/// plan).</b> Extracting a shared <c>JitteredBackoff</c> is the tidier end state and should be a
/// follow-up, not here: <see cref="JazzCaptureCore.Delivery.ArchiveDeliveryRetryPolicy"/>'s output is
/// pinned millisecond-for-millisecond by its own tests and is load-bearing for the archive queue's
/// cross-relaunch guarantee. A refactor that must not change a single millisecond there is review
/// cost with no behaviour gain for this change.
/// </para>
/// <para>
/// <b>Why this policy's numbers differ from <see cref="ScreenshotUploadRetryPolicy"/>'s.</b> An event
/// has no attempt budget -- a retryable failure retries indefinitely until it succeeds, is
/// classified terminal, or ages out of the spool (see <see cref="EventSpool"/>'s own remarks) -- so
/// its schedule must settle into a poll that can survive a multi-hour network outage, not a
/// screenshot's much shorter 1/2/4/8 second progression. <see cref="EventDeliverySettings.SendBackoffInitial"/>
/// and <see cref="EventDeliverySettings.SendBackoffCeiling"/> default to 2 seconds and 5 minutes --
/// <see cref="JazzCaptureCore.Delivery.ArchiveDeliveryRetryPolicy"/>'s numbers, chosen for exactly
/// that reason.
/// </para>
/// <para>
/// The jitter domain below is its own, NUL-terminated string, distinct from both
/// <see cref="ScreenshotUploadRetryPolicy"/>'s and <see cref="JazzCaptureCore.Delivery.ArchiveDeliveryRetryPolicy"/>'s,
/// so this policy can never produce the same timings as either existing policy for the same
/// identity string.
/// </para>
/// </remarks>
public static class EventStreamRetryPolicy
{
    /// <summary>
    /// Stable identity fed to <see cref="Delay"/> for the drain loop's own backoff, when a whole
    /// drain pass fails outright (e.g. the transport itself threw) rather than one particular
    /// event's send failing. Mirrors <c>ScreenshotUploadRetryPolicy.DrainLoopBackoffIdentity</c>'s
    /// own reasoning: there is no per-event identity to key on for a pass-level failure, and a
    /// single fixed constant is all "do not busy-retry a loop that just failed" needs.
    /// </summary>
    public const string DrainLoopBackoffIdentity = "event-delivery-scheduler/drain-loop";

    /// <summary>Lowest retained fraction of the exponential delay, in basis points.</summary>
    private const long JitterFloorBasisPoints = 7_500;

    /// <summary>Number of distinct jitter values, giving the closed window [7500, 10000] bps.</summary>
    private const long JitterBasisPointCount = 2_501;

    private const long BasisPointDenominator = 10_000;

    /// <summary>
    /// Domain separator of the jitter hash, NUL-terminated so the hashed string cannot run into the
    /// identity appended after it. Distinct from every other retry policy's domain in this codebase
    /// so none of them can ever produce the same timings for the same identity string.
    /// </summary>
    private const string JitterDomain = "jazz-event-stream-retry/v1\0";

    /// <summary>
    /// The bounded jittered delay before retrying a failed event send, or before the drain loop
    /// itself retries a failed pass.
    /// </summary>
    /// <param name="failedAttempt">Number of the attempt that just failed; 0 or more.</param>
    /// <param name="identity">
    /// Stable identity the jitter is derived from: the spool key (<c>"&lt;sessionId&gt;/&lt;fileName&gt;"</c>)
    /// for one event's own retry schedule, or <see cref="DrainLoopBackoffIdentity"/> for the drain
    /// loop's pass-level backoff.
    /// </param>
    /// <param name="settings">The backoff bounds to compute against.</param>
    /// <exception cref="ArgumentOutOfRangeException"><paramref name="failedAttempt"/> is negative.</exception>
    /// <exception cref="ArgumentException"><paramref name="identity"/> is null, empty, or whitespace.</exception>
    /// <exception cref="ArgumentNullException"><paramref name="settings"/> is <see langword="null"/>.</exception>
    public static TimeSpan Delay(int failedAttempt, string identity, EventDeliverySettings settings)
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

        long initialMilliseconds = (long)settings.SendBackoffInitial.TotalMilliseconds;
        long ceilingMilliseconds = (long)settings.SendBackoffCeiling.TotalMilliseconds;

        // See ScreenshotUploadRetryPolicy.Delay's identical comment: this loop is bounded at 62
        // cheap shift-and-compare iterations regardless of input, and Validate already rejects any
        // SendBackoffInitial that cannot produce a positive first delay.
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
    /// <see cref="EventDeliverySettings.Validate"/> exactly as <see cref="ScreenshotUploadRetryPolicy.MinimumFirstAttemptDelay"/>
    /// exists for <see cref="ScreenshotDeliverySettings.Validate"/>.
    /// </summary>
    internal static TimeSpan MinimumFirstAttemptDelay(EventDeliverySettings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);

        long initialMilliseconds = (long)settings.SendBackoffInitial.TotalMilliseconds;
        long ceilingMilliseconds = (long)settings.SendBackoffCeiling.TotalMilliseconds;

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
