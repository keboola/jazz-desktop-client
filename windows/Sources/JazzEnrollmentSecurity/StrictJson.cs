using System.Text.Json.Nodes;
using JazzCaptureCore.Json;

namespace JazzEnrollmentSecurity;

/// <summary>
/// The strict JSON gate every enrollment document passes before anything reads a field from it.
/// </summary>
/// <remarks>
/// <para>
/// The macOS client runs a hand-written structural pre-pass (<c>StrictJSON</c>) purely because
/// <c>JSONSerialization</c> silently keeps one value for a duplicated object member, which is
/// unsafe at a signature and credential-routing boundary. .NET needs no separate pre-pass: the
/// shared <see cref="JsonStrictParser"/> already rejects duplicate keys, comments, trailing commas,
/// trailing content, non-finite numbers and integers outside the canonical safe range in one pass
/// over the exact bytes. This type is the thin adapter that keeps the call sites reading like the
/// Swift ones.
/// </para>
/// <para>
/// Everything here works on <c>ReadOnlySpan&lt;byte&gt;</c>. Converting to <see cref="string"/>
/// first would map malformed UTF-8 to U+FFFD and quietly accept bytes the signer never signed.
/// </para>
/// </remarks>
public static class StrictJson
{
    /// <summary>Whether <paramref name="utf8"/> is strictly valid JSON with unique object keys.</summary>
    public static bool IsStrictDocument(ReadOnlySpan<byte> utf8)
    {
        try
        {
            JsonStrictParser.Parse(utf8);
            return true;
        }
        catch (FormatException)
        {
            return false;
        }
    }

    /// <summary>
    /// Parses <paramref name="utf8"/> and returns its top-level object, or <see langword="null"/>
    /// when the document is malformed, has a duplicate key, or is not an object.
    /// </summary>
    public static JsonObject? TryParseObject(ReadOnlySpan<byte> utf8)
    {
        try
        {
            return JsonStrictParser.Parse(utf8) as JsonObject;
        }
        catch (FormatException)
        {
            return null;
        }
    }

    /// <summary>
    /// Parses <paramref name="utf8"/> into an object and additionally requires that re-serializing
    /// it in canonical form reproduces <paramref name="utf8"/> byte for byte.
    /// </summary>
    /// <returns>
    /// The object when the document is strict and canonical; otherwise <see langword="null"/>. The
    /// caller distinguishes "not strict" from "not canonical" by calling
    /// <see cref="TryParseObject(ReadOnlySpan{byte})"/> first when it needs different errors.
    /// </returns>
    public static JsonObject? TryParseCanonicalObject(ReadOnlySpan<byte> utf8)
    {
        JsonObject? parsed = TryParseObject(utf8);
        if (parsed is null)
        {
            return null;
        }

        byte[]? canonical = EnrollmentEncoding.TryCanonicalJson(parsed);
        return canonical is not null && utf8.SequenceEqual(canonical) ? parsed : null;
    }

    /// <summary>Whether the object's member names are exactly <paramref name="expected"/>.</summary>
    public static bool HasExactlyKeys(JsonObject value, IReadOnlyCollection<string> expected)
    {
        if (value.Count != expected.Count)
        {
            return false;
        }

        foreach (string key in expected)
        {
            if (!value.ContainsKey(key))
            {
                return false;
            }
        }

        return true;
    }

    /// <summary>Whether every member name of the object appears in <paramref name="allowed"/>.</summary>
    public static bool HasOnlyKeys(JsonObject value, IReadOnlyCollection<string> allowed)
    {
        foreach (KeyValuePair<string, JsonNode?> entry in value)
        {
            if (!allowed.Contains(entry.Key))
            {
                return false;
            }
        }

        return true;
    }

    /// <summary>The member as a JSON string, or <see langword="null"/> when absent, null, or another type.</summary>
    public static string? StringOrNull(JsonObject value, string key)
    {
        if (!value.TryGetPropertyValue(key, out JsonNode? node) || node is null)
        {
            return null;
        }

        return node is JsonValue candidate && candidate.TryGetValue(out string? text) ? text : null;
    }

    /// <summary>The member as a JSON integer, or <see langword="null"/> when absent, null, or another type.</summary>
    public static long? IntegerOrNull(JsonObject value, string key)
    {
        if (!value.TryGetPropertyValue(key, out JsonNode? node) || node is null)
        {
            return null;
        }

        return node is JsonValue candidate && candidate.TryGetValue(out long number) ? number : null;
    }

    /// <summary>Whether the member is present and explicitly the JSON literal <c>null</c>.</summary>
    public static bool IsExplicitNull(JsonObject value, string key) =>
        value.TryGetPropertyValue(key, out JsonNode? node) && node is null;

    /// <summary>The member as an array of JSON strings, or <see langword="null"/> when it is anything else.</summary>
    public static IReadOnlyList<string>? StringArrayOrNull(JsonObject value, string key)
    {
        if (!value.TryGetPropertyValue(key, out JsonNode? node) || node is not JsonArray array)
        {
            return null;
        }

        var result = new List<string>(array.Count);
        foreach (JsonNode? element in array)
        {
            if (element is not JsonValue candidate || !candidate.TryGetValue(out string? text))
            {
                return null;
            }

            result.Add(text);
        }

        return result;
    }

    /// <summary>The member as a nested object, or <see langword="null"/> when it is anything else.</summary>
    public static JsonObject? ObjectOrNull(JsonObject value, string key) =>
        value.TryGetPropertyValue(key, out JsonNode? node) ? node as JsonObject : null;
}
