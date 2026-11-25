using System.Reflection;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace JazzCaptureCore;

/// <summary>The field a scanned value came from; the password-like check applies to typed text only.</summary>
public enum SecretField
{
    /// <summary>A committed typing run.</summary>
    TypedText,

    /// <summary>A window or page title.</summary>
    Title,

    /// <summary>A document URL.</summary>
    Url,
}

/// <summary>The scanned text and how many replacements were made.</summary>
/// <param name="Text">The text with every detected secret replaced.</param>
/// <param name="Count">Number of replacements. Never the text or the rule that matched.</param>
public readonly record struct SecretScanResult(string Text, int Count);

/// <summary>
/// Rule-based secret scanner (<c>contract/secret-rules.json</c>), run on typed text, window titles
/// and URLs after the masking in <see cref="Redaction"/>.
/// </summary>
/// <remarks>
/// <para>
/// The rules file is shared with the Jazz server, which runs the same scan again before every LLM
/// call. Both sides run the same vectors from <c>contract/secret-rules.vectors.json</c>, so the
/// order and the exact steps here must match the contract: the named rules in file order, then the
/// entropy check, then (typed text only) the password-like check.
/// </para>
/// <para>
/// The scanner never throws and fails closed. If a pattern times out or anything unexpected happens,
/// the whole value is replaced and counted as one replacement.
/// </para>
/// </remarks>
public sealed class SecretScanner
{
    private const string ResourceName = "JazzCaptureCore.secret-rules.json";

    private static readonly TimeSpan MatchTimeout = TimeSpan.FromMilliseconds(250);

    // Whitespace and the quote and bracket characters the contract splits tokens on.
    private static readonly Regex TokenPattern = new(
        "[^\\s\"'<>()\\[\\]{},;]+",
        RegexOptions.CultureInvariant | RegexOptions.Compiled,
        MatchTimeout);

    // Pieces of a URL token: path segments, query parts, fragment, host and userinfo.
    private static readonly Regex UrlPiecePattern = new(
        "[^/?&#:@]+",
        RegexOptions.CultureInvariant | RegexOptions.Compiled,
        MatchTimeout);

    private static readonly Lazy<SecretScanner> DefaultScanner = new(
        () => FromJson(ReadEmbeddedRules()),
        LazyThreadSafetyMode.ExecutionAndPublication);

    private readonly NamedRule[] _rules;
    private readonly int _entropyMinLength;
    private readonly double _base64MinBits;
    private readonly double _hexMinBits;
    private readonly bool _ignoreGuid;
    private readonly int _passwordMinLength;
    private readonly int _passwordMaxLength;
    private readonly string[] _passwordClasses;

    private SecretScanner(
        int version,
        string replacement,
        NamedRule[] rules,
        int entropyMinLength,
        double base64MinBits,
        double hexMinBits,
        bool ignoreGuid,
        int passwordMinLength,
        int passwordMaxLength,
        string[] passwordClasses)
    {
        Version = version;
        Replacement = replacement;
        _rules = rules;
        _entropyMinLength = entropyMinLength;
        _base64MinBits = base64MinBits;
        _hexMinBits = hexMinBits;
        _ignoreGuid = ignoreGuid;
        _passwordMinLength = passwordMinLength;
        _passwordMaxLength = passwordMaxLength;
        _passwordClasses = passwordClasses;
    }

    /// <summary>The scanner built from the rules file embedded in this assembly.</summary>
    public static SecretScanner Default => DefaultScanner.Value;

    /// <summary>The <c>version</c> of the rules file.</summary>
    public int Version { get; }

    /// <summary>The text written in place of a secret.</summary>
    public string Replacement { get; }

    /// <summary>Builds a scanner from the text of a rules file.</summary>
    /// <exception cref="FormatException">The document is not a usable rules file.</exception>
    public static SecretScanner FromJson(string json)
    {
        ArgumentNullException.ThrowIfNull(json);

        try
        {
            using JsonDocument document = JsonDocument.Parse(json);
            JsonElement root = document.RootElement;
            string replacement = root.GetProperty("replacement").GetString()
                ?? throw new FormatException("The rules file has no replacement.");

            var rules = new List<NamedRule>();
            foreach (JsonElement rule in root.GetProperty("rules").EnumerateArray())
            {
                string id = rule.GetProperty("id").GetString()!;
                var pattern = new Regex(
                    rule.GetProperty("pattern").GetString()!,
                    RegexOptions.CultureInvariant | RegexOptions.Compiled,
                    MatchTimeout);
                rules.Add(new NamedRule(id, pattern));
            }

            JsonElement entropy = root.GetProperty("entropy");
            JsonElement passwordLike = root.GetProperty("passwordLike");
            var classes = new List<string>();
            foreach (JsonElement name in passwordLike.GetProperty("requireClasses").EnumerateArray())
            {
                classes.Add(name.GetString()!);
            }

            return new SecretScanner(
                root.GetProperty("version").GetInt32(),
                replacement,
                rules.ToArray(),
                entropy.GetProperty("minLength").GetInt32(),
                entropy.GetProperty("base64MinBitsPerChar").GetDouble(),
                entropy.GetProperty("hexMinBitsPerChar").GetDouble(),
                entropy.GetProperty("ignoreGuid").GetBoolean(),
                passwordLike.GetProperty("minLength").GetInt32(),
                passwordLike.GetProperty("maxLength").GetInt32(),
                classes.ToArray());
        }
        catch (Exception ex) when (ex is JsonException or KeyNotFoundException or InvalidOperationException
            or ArgumentException or FormatException)
        {
            throw new FormatException("The secret rules file is not usable: " + ex.Message, ex);
        }
    }

    /// <summary>Replaces every detected secret in <paramref name="text"/>.</summary>
    /// <param name="text">The value, already masked by <see cref="Redaction"/>.</param>
    /// <param name="field">Where the value came from.</param>
    /// <returns>The scanned text and the number of replacements. Never throws.</returns>
    public SecretScanResult Scan(string? text, SecretField field)
    {
        if (string.IsNullOrEmpty(text))
        {
            return new SecretScanResult(text ?? string.Empty, 0);
        }

        try
        {
            int count = 0;
            string current = text;

            foreach (NamedRule rule in _rules)
            {
                current = rule.Pattern.Replace(current, match => ReplaceRuleMatch(rule.Id, match, ref count));
            }

            current = ReplaceHighEntropyTokens(current, field, ref count);

            if (field == SecretField.TypedText && IsPasswordLike(current))
            {
                current = Replacement;
                count++;
            }

            return new SecretScanResult(current, count);
        }
        catch (Exception)
        {
            return new SecretScanResult(Replacement, 1);
        }
    }

    private string ReplaceRuleMatch(string ruleId, Match match, ref int count)
    {
        string value = match.Value;

        if (ruleId == "secret-assignment")
        {
            // Keep the key name, the delimiter and the whitespace after it; replace only the value.
            int delimiter = value.AsSpan().IndexOfAny(':', '=');
            int valueStart = delimiter + 1;
            while (valueStart < value.Length && char.IsWhiteSpace(value[valueStart]))
            {
                valueStart++;
            }

            if (string.Equals(value[valueStart..], Replacement, StringComparison.Ordinal))
            {
                return value;
            }

            count++;
            return value[..valueStart] + Replacement;
        }

        count++;

        if (ruleId == "url-credentials")
        {
            // Keep the scheme; the host stays because the match ends at the '@'.
            return value[..(value.IndexOf("://", StringComparison.Ordinal) + 3)] + Replacement + "@";
        }

        return Replacement;
    }

    private string ReplaceHighEntropyTokens(string text, SecretField field, ref int count)
    {
        int replaced = 0;

        string result = TokenPattern.Replace(text, match =>
        {
            string token = match.Value;
            if (field != SecretField.Url && !token.Contains("://", StringComparison.Ordinal))
            {
                return CheckToken(token, ref replaced);
            }

            // A URL is checked per path segment and query value, never as one token.
            return UrlPiecePattern.Replace(token, piece =>
            {
                string value = piece.Value;
                int equals = value.IndexOf('=');
                return equals < 0
                    ? CheckToken(value, ref replaced)
                    : value[..(equals + 1)] + CheckToken(value[(equals + 1)..], ref replaced);
            });
        });

        count += replaced;
        return result;
    }

    private string CheckToken(string token, ref int replaced)
    {
        if (!IsHighEntropy(token))
        {
            return token;
        }

        replaced++;
        return Replacement;
    }

    private bool IsHighEntropy(string token)
    {
        if (token.Length < _entropyMinLength)
        {
            return false;
        }

        if (_ignoreGuid && IsGuid(token))
        {
            return false;
        }

        if (AllChars(token, IsHexChar))
        {
            return ShannonEntropy(token) >= _hexMinBits;
        }

        return AllChars(token, IsBase64Char) && ShannonEntropy(token) >= _base64MinBits;
    }

    private bool IsPasswordLike(string text)
    {
        if (text.Length < _passwordMinLength || text.Length > _passwordMaxLength)
        {
            return false;
        }

        // Text that already holds a replacement was scanned; do not count it a second time.
        if (text.Contains(Replacement, StringComparison.Ordinal))
        {
            return false;
        }

        bool lower = false, upper = false, digit = false, symbol = false;
        foreach (char c in text)
        {
            if (char.IsWhiteSpace(c))
            {
                return false;
            }

            lower |= char.IsAsciiLetterLower(c);
            upper |= char.IsAsciiLetterUpper(c);
            digit |= char.IsAsciiDigit(c);
            symbol |= c is > ' ' and <= '~' && !char.IsAsciiLetterOrDigit(c);
        }

        foreach (string required in _passwordClasses)
        {
            bool present = required switch
            {
                "lower" => lower,
                "upper" => upper,
                "digit" => digit,
                "symbol" => symbol,
                _ => false,
            };

            if (!present)
            {
                return false;
            }
        }

        return true;
    }

    private static bool IsGuid(string token) =>
        token.Length == 36
        && token[8] == '-' && token[13] == '-' && token[18] == '-' && token[23] == '-'
        && Guid.TryParseExact(token, "D", out _);

    private static bool IsHexChar(char c) => char.IsAsciiHexDigit(c);

    private static bool IsBase64Char(char c) => char.IsAsciiLetterOrDigit(c) || c is '+' or '/' or '=' or '_' or '-';

    private static bool AllChars(string token, Func<char, bool> predicate)
    {
        foreach (char c in token)
        {
            if (!predicate(c))
            {
                return false;
            }
        }

        return true;
    }

    private static double ShannonEntropy(string token)
    {
        var counts = new Dictionary<char, int>();
        foreach (char c in token)
        {
            counts[c] = counts.GetValueOrDefault(c) + 1;
        }

        double bits = 0;
        foreach (int count in counts.Values)
        {
            double p = (double)count / token.Length;
            bits -= p * Math.Log2(p);
        }

        return bits;
    }

    private static string ReadEmbeddedRules()
    {
        using Stream stream = typeof(SecretScanner).Assembly.GetManifestResourceStream(ResourceName)
            ?? throw new InvalidOperationException("The embedded resource " + ResourceName + " is missing.");
        using var reader = new StreamReader(stream, Encoding.UTF8);
        return reader.ReadToEnd();
    }

    private sealed record NamedRule(string Id, Regex Pattern);
}
