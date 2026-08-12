using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using JazzCaptureCore;
using JazzCaptureCore.Json;

namespace JazzCaptureCoreTests.Support;

/// <summary>
/// A validator for the JSON Schema subset the archive contract actually uses.
/// </summary>
/// <remarks>
/// <para>
/// There is no JSON Schema implementation in this solution and no network to fetch one from, so the
/// alternative to this class is a test that restates the schema by hand — which would pass happily
/// after someone edited the schema and forgot the producer. This reads the real file from
/// <c>contract/archive/schema/</c>, resolves <c>$ref</c> into the shared common schema, and applies
/// the keywords those documents use: <c>type</c>, <c>const</c>, <c>enum</c>, <c>required</c>,
/// <c>properties</c>, <c>additionalProperties: false</c>, <c>items</c>, <c>minItems</c>,
/// <c>minLength</c>, <c>minimum</c>, <c>pattern</c>, <c>not</c>/<c>anyOf</c> and
/// <c>format: date-time</c>.
/// </para>
/// <para>
/// An unrecognised keyword is a hard failure rather than something to skip: silently ignoring a
/// constraint would turn "validates against the schema" into a claim the test cannot support.
/// </para>
/// </remarks>
public sealed class ContractJsonSchema
{
    private const string CommonSchemaId = "https://jazz.dev/archive/schema/archive-common.schema.json";

    private static readonly IReadOnlySet<string> KnownKeywords = new HashSet<string>(StringComparer.Ordinal)
    {
        "$schema", "$id", "title", "description", "$defs", "$ref",
        "type", "const", "enum", "required", "properties", "additionalProperties",
        "items", "minItems", "minLength", "minimum", "pattern", "format", "not", "anyOf",
    };

    private readonly JsonObject _root;
    private readonly JsonObject _common;

    private ContractJsonSchema(JsonObject root, JsonObject common)
    {
        _root = root;
        _common = common;
    }

    /// <summary>Loads a schema by file name from <c>contract/archive/schema/</c>.</summary>
    public static ContractJsonSchema Load(string fileName)
    {
        string directory = Path.Combine(ContractPaths.Root(), "contract", "archive", "schema");
        return new ContractJsonSchema(ReadObject(Path.Combine(directory, fileName)),
            ReadObject(Path.Combine(directory, "archive-common.schema.json")));
    }

    /// <summary>Every constraint <paramref name="value"/> violates; empty when it validates.</summary>
    public IReadOnlyList<string> Validate(JsonNode? value)
    {
        var errors = new List<string>();
        Check(value, _root, "$", errors);
        return errors;
    }

    private static JsonObject ReadObject(string path) =>
        JsonStrictParser.Parse(File.ReadAllBytes(path)) as JsonObject
            ?? throw new InvalidOperationException("Schema is not a JSON object: " + path);

    private void Check(JsonNode? value, JsonObject schema, string path, List<string> errors)
    {
        foreach (KeyValuePair<string, JsonNode?> entry in schema)
        {
            if (!KnownKeywords.Contains(entry.Key))
            {
                errors.Add(path + ": the test validator does not implement schema keyword '" + entry.Key + "'");
            }
        }

        if ((string?)schema["$ref"] is { } reference)
        {
            Check(value, Resolve(reference), path, errors);
            return;
        }

        if ((string?)schema["type"] is { } type && !MatchesType(value, type))
        {
            errors.Add(path + ": expected type '" + type + "'");
            return;
        }

        if (schema.ContainsKey("const") && !SameJson(value, schema["const"]))
        {
            errors.Add(path + ": expected the constant " + Render(schema["const"]));
        }

        if (schema["enum"] is JsonArray allowed
            && !allowed.Any(candidate => SameJson(value, candidate)))
        {
            errors.Add(path + ": " + Render(value) + " is not one of " + Render(allowed));
        }

        if ((string?)schema["pattern"] is { } pattern
            && value is JsonValue && value.GetValueKind() == System.Text.Json.JsonValueKind.String
            && !Regex.IsMatch((string)value!, pattern, RegexOptions.CultureInvariant))
        {
            errors.Add(path + ": '" + (string)value! + "' does not match " + pattern);
        }

        if ((string?)schema["format"] == "date-time"
            && value is JsonValue && value.GetValueKind() == System.Text.Json.JsonValueKind.String
            && Timestamps.TryParseRfc3339((string)value!) is null)
        {
            errors.Add(path + ": '" + (string)value! + "' is not an RFC 3339 instant");
        }

        if ((long?)schema["minLength"] is { } minLength
            && value is JsonValue && value.GetValueKind() == System.Text.Json.JsonValueKind.String
            && ((string)value!).Length < minLength)
        {
            errors.Add(path + ": shorter than the minimum length " + minLength);
        }

        if ((long?)schema["minimum"] is { } minimum
            && TryWholeNumber(value, out long number)
            && number < minimum)
        {
            errors.Add(path + ": below the minimum " + minimum);
        }

        if (schema["not"] is JsonObject negated && Nested(value, negated).Count == 0)
        {
            errors.Add(path + ": matches a forbidden shape");
        }

        if (schema["anyOf"] is JsonArray anyOf
            && !anyOf.Any(branch => branch is JsonObject option && Nested(value, option).Count == 0))
        {
            errors.Add(path + ": matches none of the permitted shapes");
        }

        if (value is JsonObject instance)
        {
            CheckObject(instance, schema, path, errors);
        }

        if (value is JsonArray array)
        {
            CheckArray(array, schema, path, errors);
        }
    }

    private void CheckObject(JsonObject instance, JsonObject schema, string path, List<string> errors)
    {
        var properties = schema["properties"] as JsonObject;

        foreach (JsonNode? required in schema["required"] as JsonArray ?? new JsonArray())
        {
            var name = (string?)required;
            if (name is not null && !instance.ContainsKey(name))
            {
                errors.Add(path + ": required property '" + name + "' is missing");
            }
        }

        foreach (KeyValuePair<string, JsonNode?> member in instance)
        {
            // A null in an instance is never right here: the archive contract sets
            // additionalProperties false everywhere and declares no nullable property, so an absent
            // optional must be absent rather than present-and-null.
            if (member.Value is null)
            {
                errors.Add(path + "." + member.Key + ": is JSON null; an absent field must be omitted");
                continue;
            }

            if (properties?[member.Key] is JsonObject memberSchema)
            {
                Check(member.Value, memberSchema, path + "." + member.Key, errors);
                continue;
            }

            if (schema["additionalProperties"] is JsonValue flag && (bool?)flag == false)
            {
                errors.Add(path + ": property '" + member.Key + "' is not permitted");
            }
        }
    }

    private void CheckArray(JsonArray array, JsonObject schema, string path, List<string> errors)
    {
        if ((long?)schema["minItems"] is { } minItems && array.Count < minItems)
        {
            errors.Add(path + ": fewer than the minimum " + minItems + " items");
        }

        if (schema["items"] is not JsonObject itemSchema)
        {
            return;
        }

        for (var index = 0; index < array.Count; index++)
        {
            Check(array[index], itemSchema, path + "[" + index + "]", errors);
        }
    }

    private IReadOnlyList<string> Nested(JsonNode? value, JsonObject schema)
    {
        var errors = new List<string>();
        Check(value, schema, "$", errors);
        return errors;
    }

    private JsonObject Resolve(string reference)
    {
        string pointer = reference;
        JsonObject document = _root;

        int hash = reference.IndexOf('#', StringComparison.Ordinal);
        if (hash > 0)
        {
            string documentId = reference[..hash];
            document = documentId == CommonSchemaId
                ? _common
                : throw new InvalidOperationException("Unresolvable schema reference: " + reference);
            pointer = reference[hash..];
        }

        if (!pointer.StartsWith("#/$defs/", StringComparison.Ordinal))
        {
            throw new InvalidOperationException("Unsupported schema pointer: " + reference);
        }

        string name = pointer["#/$defs/".Length..];
        return document["$defs"]?[name] as JsonObject
            ?? throw new InvalidOperationException("Schema definition not found: " + reference);
    }

    private static bool MatchesType(JsonNode? value, string type) => type switch
    {
        "object" => value is JsonObject,
        "array" => value is JsonArray,
        "string" => value is JsonValue && value.GetValueKind() == System.Text.Json.JsonValueKind.String,
        "integer" => TryWholeNumber(value, out _),
        "boolean" => value is JsonValue
            && value.GetValueKind() is System.Text.Json.JsonValueKind.True or System.Text.Json.JsonValueKind.False,
        _ => throw new InvalidOperationException("The test validator does not implement type '" + type + "'."),
    };

    /// <summary>
    /// Reads a whole number regardless of the CLR type behind the node. A document built in memory
    /// may hold an <see cref="int"/> where a parsed one holds a <see cref="long"/>, and a validator
    /// that only understood one of them would pass or fail on where the value came from.
    /// </summary>
    private static bool TryWholeNumber(JsonNode? value, out long number)
    {
        number = 0;
        if (value is not JsonValue whole || value.GetValueKind() != System.Text.Json.JsonValueKind.Number)
        {
            return false;
        }

        if (whole.TryGetValue(out long asLong))
        {
            number = asLong;
            return true;
        }

        if (whole.TryGetValue(out int asInt))
        {
            number = asInt;
            return true;
        }

        return false;
    }

    private static bool SameJson(JsonNode? left, JsonNode? right) =>
        string.Equals(Render(left), Render(right), StringComparison.Ordinal);

    private static string Render(JsonNode? value) =>
        value is null ? "null" : JsonCanonicalizer.Canonicalize(value);
}
