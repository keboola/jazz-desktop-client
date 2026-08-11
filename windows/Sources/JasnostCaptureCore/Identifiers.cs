using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace JasnostCaptureCore;

/// <summary>
/// Identifier minting for archive documents and capture records.
/// Every archive identifier is <c>"&lt;prefix&gt;-" + lowercase RFC 9562 UUIDv7</c>.
/// </summary>
public static class Identifiers
{
    /// <summary>Number of random bytes consumed from the entropy source (UUID bytes 6..15).</summary>
    public const int RandomByteCount = 10;

    /// <summary>Bytes 0..5 carry a 48-bit big-endian Unix millisecond timestamp.</summary>
    private const int TimestampByteCount = 6;

    private const int UuidByteCount = 16;

    /// <summary>
    /// Builds an RFC 9562 UUIDv7 from an explicit clock and entropy source.
    /// Injecting both keeps the layout unit-testable.
    /// </summary>
    /// <param name="now">Timestamp whose Unix millisecond value fills bytes 0..5.</param>
    /// <param name="rng">Entropy source; must return at least <see cref="RandomByteCount"/> bytes.</param>
    public static string UuidV7(DateTimeOffset now, Func<byte[]> rng)
    {
        ArgumentNullException.ThrowIfNull(rng);

        long milliseconds = now.ToUnixTimeMilliseconds();
        if (milliseconds < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(now), now, "UUIDv7 cannot encode pre-1970 timestamps.");
        }

        if (milliseconds > 0xFFFFFFFFFFFFL)
        {
            throw new ArgumentOutOfRangeException(nameof(now), now, "UUIDv7 timestamps must fit in 48 bits.");
        }

        byte[] random = rng() ?? throw new ArgumentException("Entropy source returned null.", nameof(rng));
        if (random.Length < RandomByteCount)
        {
            throw new ArgumentException(
                $"Entropy source must return at least {RandomByteCount} bytes.",
                nameof(rng));
        }

        Span<byte> bytes = stackalloc byte[UuidByteCount];
        for (int i = 0; i < TimestampByteCount; i++)
        {
            bytes[i] = (byte)(milliseconds >> (8 * (TimestampByteCount - 1 - i)));
        }

        random.AsSpan(0, RandomByteCount).CopyTo(bytes[TimestampByteCount..]);

        bytes[6] = (byte)((bytes[6] & 0x0F) | 0x70);
        bytes[8] = (byte)((bytes[8] & 0x3F) | 0x80);

        return Format(bytes);
    }

    /// <summary>Builds a UUIDv7 from the system clock and a cryptographic entropy source.</summary>
    public static string UuidV7() =>
        UuidV7(DateTimeOffset.UtcNow, () => RandomNumberGenerator.GetBytes(RandomByteCount));

    /// <summary>Builds a prefixed archive identifier, for example <c>Prefixed("ar")</c>.</summary>
    public static string Prefixed(string prefix)
    {
        if (string.IsNullOrWhiteSpace(prefix))
        {
            throw new ArgumentException("Identifier prefix must not be empty.", nameof(prefix));
        }

        return prefix + "-" + UuidV7();
    }

    /// <summary>Builds a prefixed archive identifier from an injected clock and entropy source.</summary>
    public static string Prefixed(string prefix, DateTimeOffset now, Func<byte[]> rng)
    {
        if (string.IsNullOrWhiteSpace(prefix))
        {
            throw new ArgumentException("Identifier prefix must not be empty.", nameof(prefix));
        }

        return prefix + "-" + UuidV7(now, rng);
    }

    /// <summary>Deterministic per-session event identifier: <c>&lt;sessionId&gt;-&lt;sequence&gt;</c>.</summary>
    public static string EventId(string sessionId, long sequence)
    {
        if (string.IsNullOrEmpty(sessionId))
        {
            throw new ArgumentException("Session id must not be empty.", nameof(sessionId));
        }

        return sessionId + "-" + sequence.ToString(CultureInfo.InvariantCulture);
    }

    /// <summary>Renders the 16 UUID bytes as canonical lowercase 8-4-4-4-12 hex.</summary>
    private static string Format(ReadOnlySpan<byte> bytes)
    {
        var builder = new StringBuilder(36);
        for (int i = 0; i < UuidByteCount; i++)
        {
            if (i is 4 or 6 or 8 or 10)
            {
                builder.Append('-');
            }

            builder.Append(bytes[i].ToString("x2", CultureInfo.InvariantCulture));
        }

        return builder.ToString();
    }
}

/// <summary>
/// OpenTelemetry trace and span identifiers. Both are random (never derived from the session id)
/// and are minted once per capture session, then reused by every log record and the session span.
/// </summary>
public static class OtlpIds
{
    private const int TraceIdByteCount = 16;
    private const int SpanIdByteCount = 8;

    /// <summary>32 lowercase hex characters.</summary>
    public static string TraceId() => Hex(TraceIdByteCount);

    /// <summary>16 lowercase hex characters.</summary>
    public static string SpanId() => Hex(SpanIdByteCount);

    private static string Hex(int byteCount) =>
        Convert.ToHexString(RandomNumberGenerator.GetBytes(byteCount)).ToLowerInvariant();
}
