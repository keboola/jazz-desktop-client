using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace JasnostCaptureCoreTests.Support;

/// <summary>
/// Structural JSON comparison used by the conformance runner.
/// Objects are order-insensitive, arrays are order-sensitive, numbers compare by
/// numeric value (decimal first, double as a fallback) and never across value kinds.
/// </summary>
public static class JsonDeepComparer
{
    public static bool DeepEquals(JsonNode? a, JsonNode? b)
    {
        if (a is null || b is null)
        {
            return IsNull(a) && IsNull(b);
        }

        JsonValueKind kindA = a.GetValueKind();
        JsonValueKind kindB = b.GetValueKind();
        if (kindA != kindB)
        {
            return false;
        }

        switch (kindA)
        {
            case JsonValueKind.Null:
                return true;
            case JsonValueKind.True:
            case JsonValueKind.False:
                return true;
            case JsonValueKind.String:
                return string.Equals(AsString(a), AsString(b), StringComparison.Ordinal);
            case JsonValueKind.Number:
                return NumbersEqual(a, b);
            case JsonValueKind.Array:
                return ArraysEqual((JsonArray)a, (JsonArray)b);
            case JsonValueKind.Object:
                return ObjectsEqual((JsonObject)a, (JsonObject)b);
            default:
                return false;
        }
    }

    private static bool IsNull(JsonNode? node) => node is null || node.GetValueKind() == JsonValueKind.Null;

    private static bool ArraysEqual(JsonArray a, JsonArray b)
    {
        if (a.Count != b.Count)
        {
            return false;
        }

        for (int i = 0; i < a.Count; i++)
        {
            if (!DeepEquals(a[i], b[i]))
            {
                return false;
            }
        }

        return true;
    }

    private static bool ObjectsEqual(JsonObject a, JsonObject b)
    {
        if (a.Count != b.Count)
        {
            return false;
        }

        foreach (KeyValuePair<string, JsonNode?> entry in a)
        {
            if (!b.TryGetPropertyValue(entry.Key, out JsonNode? other))
            {
                return false;
            }

            if (!DeepEquals(entry.Value, other))
            {
                return false;
            }
        }

        return true;
    }

    private static bool NumbersEqual(JsonNode a, JsonNode b)
    {
        string rawA = RawNumber(a);
        string rawB = RawNumber(b);
        if (string.Equals(rawA, rawB, StringComparison.Ordinal))
        {
            return true;
        }

        if (decimal.TryParse(rawA, NumberStyles.Float, CultureInfo.InvariantCulture, out decimal decA)
            && decimal.TryParse(rawB, NumberStyles.Float, CultureInfo.InvariantCulture, out decimal decB))
        {
            return decA == decB;
        }

        return double.TryParse(rawA, NumberStyles.Float, CultureInfo.InvariantCulture, out double dblA)
               && double.TryParse(rawB, NumberStyles.Float, CultureInfo.InvariantCulture, out double dblB)
               && dblA.Equals(dblB);
    }

    private static string RawNumber(JsonNode node)
    {
        if (node is JsonValue value && value.TryGetValue(out JsonElement element) && element.ValueKind == JsonValueKind.Number)
        {
            return element.GetRawText();
        }

        return node.ToJsonString();
    }

    private static string AsString(JsonNode node)
    {
        if (node is JsonValue value)
        {
            if (value.TryGetValue(out string? text))
            {
                return text ?? string.Empty;
            }

            if (value.TryGetValue(out JsonElement element) && element.ValueKind == JsonValueKind.String)
            {
                return element.GetString() ?? string.Empty;
            }
        }

        return JsonSerializer.Deserialize<string>(node.ToJsonString()) ?? string.Empty;
    }
}
