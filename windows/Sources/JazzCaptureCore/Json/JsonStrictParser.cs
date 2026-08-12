using System.Buffers;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace JazzCaptureCore.Json;

/// <summary>
/// Strict JSON reader for externally supplied documents (fixtures, goldens, replayed WAL entries).
/// Unlike <see cref="JsonNode.Parse(string, JsonNodeOptions?, JsonDocumentOptions)"/> it rejects
/// duplicate object keys, comments, trailing commas, trailing content, non-finite literals and
/// integers outside the canonical JSON safe range. Every rejection surfaces as
/// <see cref="FormatException"/>.
/// </summary>
public static class JsonStrictParser
{
    private const int MaxDepth = 128;

    /// <summary>Parses <paramref name="text"/> into a <see cref="JsonNode"/> tree.</summary>
    /// <returns>The parsed tree; <see langword="null"/> when the document is the literal <c>null</c>.</returns>
    /// <exception cref="FormatException">The document is not strictly valid JSON.</exception>
    public static JsonNode? Parse(string text)
    {
        ArgumentNullException.ThrowIfNull(text);

        return Parse(new UTF8Encoding(false).GetBytes(text));
    }

    /// <summary>Parses UTF-8 <paramref name="utf8"/> into a <see cref="JsonNode"/> tree.</summary>
    /// <remarks>
    /// Signature and digest boundaries must parse the exact received bytes. Decoding them to a
    /// <see cref="string"/> first would silently replace malformed UTF-8 with U+FFFD, so a document
    /// that is not valid UTF-8 would be accepted as if it were.
    /// </remarks>
    /// <returns>The parsed tree; <see langword="null"/> when the document is the literal <c>null</c>.</returns>
    /// <exception cref="FormatException">The document is not strictly valid JSON.</exception>
    public static JsonNode? Parse(ReadOnlySpan<byte> utf8)
    {
        var options = new JsonReaderOptions
        {
            AllowTrailingCommas = false,
            CommentHandling = JsonCommentHandling.Disallow,
            MaxDepth = MaxDepth,
        };

        var reader = new Utf8JsonReader(utf8, options);
        try
        {
            if (!reader.Read())
            {
                throw new FormatException("Empty JSON document.");
            }

            JsonNode? node = ReadValue(ref reader, 0);

            if (reader.Read())
            {
                throw new FormatException("Trailing content after the top-level JSON value.");
            }

            return node;
        }
        catch (JsonException ex)
        {
            throw new FormatException("Invalid JSON document: " + ex.Message, ex);
        }
    }

    private static JsonNode? ReadValue(ref Utf8JsonReader reader, int depth)
    {
        if (depth > MaxDepth)
        {
            throw new FormatException($"JSON nesting deeper than {MaxDepth} levels.");
        }

        switch (reader.TokenType)
        {
            case JsonTokenType.StartObject:
                return ReadObject(ref reader, depth);
            case JsonTokenType.StartArray:
                return ReadArray(ref reader, depth);
            case JsonTokenType.String:
                return JsonValue.Create(reader.GetString() ?? string.Empty);
            case JsonTokenType.Number:
                return ReadNumber(ref reader);
            case JsonTokenType.True:
                return JsonValue.Create(true);
            case JsonTokenType.False:
                return JsonValue.Create(false);
            case JsonTokenType.Null:
                return null;
            default:
                throw new FormatException($"Unexpected JSON token '{reader.TokenType}'.");
        }
    }

    private static JsonObject ReadObject(ref Utf8JsonReader reader, int depth)
    {
        var obj = new JsonObject();
        while (true)
        {
            if (!reader.Read())
            {
                throw new FormatException("Unterminated JSON object.");
            }

            if (reader.TokenType == JsonTokenType.EndObject)
            {
                return obj;
            }

            if (reader.TokenType != JsonTokenType.PropertyName)
            {
                throw new FormatException($"Expected a property name but found '{reader.TokenType}'.");
            }

            string name = reader.GetString() ?? string.Empty;
            if (obj.ContainsKey(name))
            {
                throw new FormatException($"Duplicate object key '{name}'.");
            }

            if (!reader.Read())
            {
                throw new FormatException($"Missing value for property '{name}'.");
            }

            obj[name] = ReadValue(ref reader, depth + 1);
        }
    }

    private static JsonArray ReadArray(ref Utf8JsonReader reader, int depth)
    {
        var array = new JsonArray();
        while (true)
        {
            if (!reader.Read())
            {
                throw new FormatException("Unterminated JSON array.");
            }

            if (reader.TokenType == JsonTokenType.EndArray)
            {
                return array;
            }

            array.Add(ReadValue(ref reader, depth + 1));
        }
    }

    private static JsonValue ReadNumber(ref Utf8JsonReader reader)
    {
        string raw = RawToken(ref reader);

        if (raw.IndexOfAny(new[] { '.', 'e', 'E' }) < 0)
        {
            if (!long.TryParse(raw, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out long integer))
            {
                throw new FormatException($"Integer '{raw}' is outside the canonical JSON safe range.");
            }

            if (integer is > JsonCanonicalizer.MaxSafeInteger or < JsonCanonicalizer.MinSafeInteger)
            {
                throw new FormatException($"Integer '{raw}' is outside the canonical JSON safe range.");
            }

            return JsonValue.Create(integer);
        }

        if (!double.TryParse(raw, NumberStyles.Float, CultureInfo.InvariantCulture, out double value)
            || double.IsNaN(value)
            || double.IsInfinity(value))
        {
            throw new FormatException($"Number '{raw}' is not representable in canonical JSON.");
        }

        return JsonValue.Create(value);
    }

    private static string RawToken(ref Utf8JsonReader reader)
    {
        ReadOnlySpan<byte> span = reader.HasValueSequence
            ? reader.ValueSequence.ToArray()
            : reader.ValueSpan;
        return Encoding.UTF8.GetString(span);
    }
}
