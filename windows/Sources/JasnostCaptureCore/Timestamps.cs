using System.Globalization;

namespace JasnostCaptureCore;

/// <summary>
/// Timestamp conversions for the OTLP projection.
/// </summary>
/// <remarks>
/// <see cref="UnixNanos"/> is integer-exact on purpose: the fractional digits are extracted as a
/// string and added to <c>epochSeconds * 1_000_000_000</c>. Routing the fraction through
/// <see cref="DateTimeOffset"/> would quantise it to 100 ns ticks and silently drop the last two
/// digits of a nanosecond-precision input.
/// </remarks>
public static class Timestamps
{
    /// <summary>Nanoseconds in one second.</summary>
    public const long NanosPerSecond = 1_000_000_000L;

    /// <summary>Number of fractional digits an OTLP nanosecond timestamp carries.</summary>
    private const int FractionDigits = 9;

    /// <summary>Wire format for archive timestamps: exactly three fractional digits, UTC, trailing Z.</summary>
    private const string IsoMillisFormat = "yyyy-MM-dd'T'HH:mm:ss.fff'Z'";

    /// <summary>RFC 3339 shapes accepted by <see cref="UnixNanos"/> after the fraction is removed.</summary>
    private static readonly string[] Rfc3339Formats =
    {
        "yyyy-MM-dd'T'HH:mm:ss'Z'",
        "yyyy-MM-dd'T'HH:mm:sszzz",
    };

    /// <summary>
    /// Converts an ISO 8601 / RFC 3339 instant into Unix nanoseconds.
    /// </summary>
    /// <returns>
    /// The nanosecond value, or <see langword="null"/> when the input is unparseable, lacks a
    /// UTC designator or offset, or predates 1970-01-01T00:00:00Z. Callers substitute
    /// <c>UnixNanos(now)</c> on <see langword="null"/>.
    /// </returns>
    public static long? UnixNanos(string iso8601)
    {
        if (string.IsNullOrWhiteSpace(iso8601))
        {
            return null;
        }

        string whole = iso8601;
        long fractionNanos = 0;

        int dot = iso8601.IndexOf('.');
        if (dot >= 0)
        {
            int end = dot + 1;
            while (end < iso8601.Length && iso8601[end] is >= '0' and <= '9')
            {
                end++;
            }

            if (end == dot + 1)
            {
                // A '.' not followed by any digit is not a valid fraction.
                return null;
            }

            string fraction = iso8601[(dot + 1)..end];
            whole = iso8601[..dot] + iso8601[end..];
            fractionNanos = FractionToNanos(fraction);
        }

        if (!DateTimeOffset.TryParseExact(
                whole,
                Rfc3339Formats,
                CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
                out DateTimeOffset parsed))
        {
            return null;
        }

        long seconds = parsed.ToUnixTimeSeconds();
        if (seconds < 0)
        {
            return null;
        }

        return (seconds * NanosPerSecond) + fractionNanos;
    }

    /// <summary>Renders an instant as <c>YYYY-MM-DDTHH:mm:ss.SSSZ</c> in UTC.</summary>
    public static string IsoMillisUtc(DateTimeOffset t) =>
        t.ToUniversalTime().ToString(IsoMillisFormat, CultureInfo.InvariantCulture);

    /// <summary>Truncates or right-pads the fractional digit run to exactly nine digits.</summary>
    private static long FractionToNanos(string fraction)
    {
        Span<char> digits = stackalloc char[FractionDigits];
        for (int i = 0; i < FractionDigits; i++)
        {
            digits[i] = i < fraction.Length ? fraction[i] : '0';
        }

        return long.Parse(digits, NumberStyles.None, CultureInfo.InvariantCulture);
    }
}
