using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace JasnostCaptureCore.Json;

/// <summary>
/// RFC 8785 (JSON Canonicalization Scheme) serializer.
/// This is the only permitted source of canonical JSON bytes for archive digests;
/// <see cref="JsonSerializer"/> property order is never authoritative.
/// </summary>
/// <remarks>
/// Rules implemented here, all normative:
/// <list type="bullet">
/// <item>Object keys are sorted by UTF-16 code unit order (<see cref="StringComparer.Ordinal"/>).</item>
/// <item>Only <c>"</c>, <c>\</c>, backspace, tab, line feed, form feed and carriage return get
/// short escapes; remaining C0 controls become <c>\u00xx</c> with lowercase hex. Everything else
/// (including <c>/</c>, <c>&lt;</c>, <c>&gt;</c>, <c>&amp;</c>, <c>+</c>, <c>'</c> and all non-ASCII)
/// is emitted raw.</item>
/// <item>Numbers use ECMAScript <c>Number::toString</c> formatting (shortest round-trip digits,
/// lowercase <c>e</c>, explicit <c>+</c> on positive exponents, plain decimal notation while the
/// decimal point position stays in [-6, 21)).</item>
/// <item>Integers outside the IEEE-754 safe range, non-finite doubles and lone surrogates are rejected.</item>
/// </list>
/// </remarks>
public static class JsonCanonicalizer
{
    /// <summary>Largest integer that survives a round trip through an IEEE-754 double.</summary>
    public const long MaxSafeInteger = 9007199254740991L;

    /// <summary>Smallest integer that survives a round trip through an IEEE-754 double.</summary>
    public const long MinSafeInteger = -9007199254740991L;

    /// <summary>Highest exclusive decimal point position rendered without an exponent.</summary>
    private const int PlainDecimalUpperExclusive = 21;

    /// <summary>Lowest exclusive decimal point position rendered without an exponent.</summary>
    private const int PlainDecimalLowerExclusive = -6;

    /// <summary>Serializes <paramref name="value"/> to its RFC 8785 canonical form.</summary>
    public static string Canonicalize(JsonNode? value)
    {
        var builder = new StringBuilder();
        WriteNode(builder, value);
        return builder.ToString();
    }

    /// <summary>Lowercase hex SHA-256 of the UTF-8 encoded canonical form of <paramref name="value"/>.</summary>
    public static string Sha256Hex(JsonNode? value)
    {
        byte[] utf8 = new UTF8Encoding(false).GetBytes(Canonicalize(value));
        return Convert.ToHexString(SHA256.HashData(utf8)).ToLowerInvariant();
    }

    private static void WriteNode(StringBuilder builder, JsonNode? node)
    {
        switch (node)
        {
            case null:
                builder.Append("null");
                return;
            case JsonObject obj:
                WriteObject(builder, obj);
                return;
            case JsonArray array:
                WriteArray(builder, array);
                return;
            case JsonValue value:
                WriteValue(builder, value);
                return;
            default:
                throw new FormatException($"Unsupported JSON node type '{node.GetType().Name}'.");
        }
    }

    private static void WriteObject(StringBuilder builder, JsonObject obj)
    {
        List<string> keys = obj.Select(entry => entry.Key).ToList();
        keys.Sort(StringComparer.Ordinal);

        builder.Append('{');
        for (int i = 0; i < keys.Count; i++)
        {
            if (i > 0)
            {
                if (string.Equals(keys[i], keys[i - 1], StringComparison.Ordinal))
                {
                    throw new FormatException($"Duplicate object key '{keys[i]}' in canonical JSON.");
                }

                builder.Append(',');
            }

            WriteString(builder, keys[i]);
            builder.Append(':');
            WriteNode(builder, obj[keys[i]]);
        }

        builder.Append('}');
    }

    private static void WriteArray(StringBuilder builder, JsonArray array)
    {
        builder.Append('[');
        for (int i = 0; i < array.Count; i++)
        {
            if (i > 0)
            {
                builder.Append(',');
            }

            WriteNode(builder, array[i]);
        }

        builder.Append(']');
    }

    private static void WriteValue(StringBuilder builder, JsonValue value)
    {
        // Probe for non-finite doubles first: GetValueKind() serializes the value and would
        // surface an ArgumentException from Utf8JsonWriter instead of a FormatException.
        if (IsNonFinite(value))
        {
            throw new FormatException("NaN and Infinity are not representable in canonical JSON.");
        }

        JsonValueKind kind;
        try
        {
            kind = value.GetValueKind();
        }
        catch (Exception ex) when (ex is JsonException or ArgumentException or NotSupportedException)
        {
            throw new FormatException("Value is not representable in canonical JSON.", ex);
        }

        switch (kind)
        {
            case JsonValueKind.Null:
                builder.Append("null");
                return;
            case JsonValueKind.True:
                builder.Append("true");
                return;
            case JsonValueKind.False:
                builder.Append("false");
                return;
            case JsonValueKind.String:
                WriteString(builder, ReadString(value));
                return;
            case JsonValueKind.Number:
                builder.Append(FormatNumber(RawNumber(value)));
                return;
            default:
                throw new FormatException($"Unsupported JSON value kind '{kind}'.");
        }
    }

    private static bool IsNonFinite(JsonValue value)
    {
        if (value.TryGetValue(out double asDouble))
        {
            return double.IsNaN(asDouble) || double.IsInfinity(asDouble);
        }

        if (value.TryGetValue(out float asFloat))
        {
            return float.IsNaN(asFloat) || float.IsInfinity(asFloat);
        }

        return false;
    }

    private static string ReadString(JsonValue value)
    {
        if (value.TryGetValue(out string? text))
        {
            return text ?? string.Empty;
        }

        if (value.TryGetValue(out JsonElement element) && element.ValueKind == JsonValueKind.String)
        {
            return element.GetString() ?? string.Empty;
        }

        return JsonSerializer.Deserialize<string>(value.ToJsonString()) ?? string.Empty;
    }

    private static string RawNumber(JsonValue value)
    {
        if (value.TryGetValue(out JsonElement element) && element.ValueKind == JsonValueKind.Number)
        {
            return element.GetRawText();
        }

        try
        {
            return value.ToJsonString();
        }
        catch (Exception ex) when (ex is JsonException or ArgumentException or NotSupportedException)
        {
            throw new FormatException("Number is not representable in canonical JSON.", ex);
        }
    }

    /// <summary>
    /// Formats a JSON number token. Tokens without a fraction or exponent stay exact integers;
    /// everything else goes through ECMAScript double formatting.
    /// </summary>
    internal static string FormatNumber(string raw)
    {
        if (raw.IndexOfAny(new[] { '.', 'e', 'E' }) < 0)
        {
            if (!long.TryParse(raw, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out long integer))
            {
                throw new FormatException($"Integer '{raw}' is outside the canonical JSON safe range.");
            }

            return FormatInteger(integer);
        }

        if (!double.TryParse(raw, NumberStyles.Float, CultureInfo.InvariantCulture, out double value))
        {
            throw new FormatException($"Number '{raw}' is not a valid JSON number.");
        }

        return FormatDouble(value);
    }

    internal static string FormatInteger(long value)
    {
        if (value is > MaxSafeInteger or < MinSafeInteger)
        {
            throw new FormatException($"Integer {value} is outside the canonical JSON safe range.");
        }

        return value.ToString(CultureInfo.InvariantCulture);
    }

    /// <summary>ECMAScript <c>Number::toString</c> (radix 10) over the shortest round-trip digits.</summary>
    internal static string FormatDouble(double value)
    {
        if (double.IsNaN(value) || double.IsInfinity(value))
        {
            throw new FormatException("NaN and Infinity are not representable in canonical JSON.");
        }

        if (value == 0d)
        {
            // ECMAScript renders both +0 and -0 as "0".
            return "0";
        }

        bool negative = value < 0d;
        string roundTrip = Math.Abs(value).ToString("R", CultureInfo.InvariantCulture);

        int exponentIndex = roundTrip.IndexOfAny(new[] { 'e', 'E' });
        string mantissa = exponentIndex < 0 ? roundTrip : roundTrip.Substring(0, exponentIndex);
        int exponent = exponentIndex < 0
            ? 0
            : int.Parse(roundTrip.Substring(exponentIndex + 1), NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture);

        int dotIndex = mantissa.IndexOf('.');
        string digits = dotIndex < 0 ? mantissa : mantissa.Remove(dotIndex, 1);
        int integerLength = dotIndex < 0 ? mantissa.Length : dotIndex;

        // pointPosition is ECMAScript's "n": the number of digits before the decimal point.
        int pointPosition = integerLength + exponent;

        int leading = 0;
        while (leading < digits.Length - 1 && digits[leading] == '0')
        {
            leading++;
            pointPosition--;
        }

        digits = digits.Substring(leading).TrimEnd('0');
        if (digits.Length == 0)
        {
            return "0";
        }

        int digitCount = digits.Length;
        string body;
        if (digitCount <= pointPosition && pointPosition <= PlainDecimalUpperExclusive)
        {
            body = digits + new string('0', pointPosition - digitCount);
        }
        else if (pointPosition > 0 && pointPosition <= PlainDecimalUpperExclusive)
        {
            body = digits.Substring(0, pointPosition) + "." + digits.Substring(pointPosition);
        }
        else if (pointPosition > PlainDecimalLowerExclusive && pointPosition <= 0)
        {
            body = "0." + new string('0', -pointPosition) + digits;
        }
        else
        {
            int scientificExponent = pointPosition - 1;
            string sign = scientificExponent >= 0 ? "+" : "-";
            string magnitude = Math.Abs(scientificExponent).ToString(CultureInfo.InvariantCulture);
            string significand = digitCount == 1 ? digits : digits.Substring(0, 1) + "." + digits.Substring(1);
            body = significand + "e" + sign + magnitude;
        }

        return negative ? "-" + body : body;
    }

    private static void WriteString(StringBuilder builder, string value)
    {
        builder.Append('"');
        for (int i = 0; i < value.Length; i++)
        {
            char c = value[i];
            switch (c)
            {
                case '"':
                    builder.Append("\\\"");
                    continue;
                case '\\':
                    builder.Append("\\\\");
                    continue;
                case '\b':
                    builder.Append("\\b");
                    continue;
                case '\t':
                    builder.Append("\\t");
                    continue;
                case '\n':
                    builder.Append("\\n");
                    continue;
                case '\f':
                    builder.Append("\\f");
                    continue;
                case '\r':
                    builder.Append("\\r");
                    continue;
            }

            if (c < 0x20)
            {
                builder.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                continue;
            }

            if (char.IsHighSurrogate(c))
            {
                if (i + 1 >= value.Length || !char.IsLowSurrogate(value[i + 1]))
                {
                    throw new FormatException("Lone high surrogate cannot be encoded as UTF-8.");
                }

                builder.Append(c).Append(value[i + 1]);
                i++;
                continue;
            }

            if (char.IsLowSurrogate(c))
            {
                throw new FormatException("Lone low surrogate cannot be encoded as UTF-8.");
            }

            builder.Append(c);
        }

        builder.Append('"');
    }
}
