using System.Globalization;
using System.Text;

namespace JazzCaptureCore;

/// <summary>
/// Privacy-preserving normalization for the document context observed through UI Automation, and the
/// portable twin of the macOS <c>ObservedDocumentURL</c> enum. Application identity is carried
/// separately, and no caller may derive a business system or business-object identity from this value
/// alone (ANNEX-HOST section 3).
/// </summary>
/// <remarks>
/// <para>
/// Path, host and file rules match macOS so the two clients still agree on those bytes: the scheme
/// is lowercased; user and password are dropped; the host is lowercased; only <c>http</c> and
/// <c>https</c> survive as addresses; a <c>file:</c> URL collapses to a placeholder directory plus
/// the basename, because a local path embeds a login name and machine-specific folders that are
/// neither portable nor needed for review; every other scheme yields nothing at all.
/// </para>
/// <para>
/// Query and fragment are the Windows exception (accepted, not a defect). macOS still drops both
/// wholesale. Windows keeps query and fragment on every http(s) host so process-mining n-grams can
/// tell which screen was open, and drops only secrets and identifiers: userinfo, token/password/
/// session keys, <c>id</c>/<c>guid</c>/<c>uuid</c>, GUID values, and JWT-like values. A path-like
/// hash with no keys (<c>#/customers/42/ssn</c>) is still dropped. Archives therefore differ from
/// macOS on any page that had a query string; that is the requested Windows-only behaviour.
/// </para>
/// <para>
/// The parse is hand-written rather than delegated to <see cref="Uri"/> because <see cref="Uri"/>
/// normalizes in ways Foundation's <c>URLComponents</c> does not — it compresses <c>..</c> segments
/// and drops default ports — and a document URL that differs between the two clients for the same
/// page would make cross-platform archives disagree about the same evidence. Percent-encoding follows
/// Foundation's <c>urlPathAllowed</c> set so both clients emit byte-identical strings.
/// </para>
/// <para>
/// One shape is worth stating because it looks like a typo and is not: a sanitized file URL is
/// <c>file:/%3Clocal%3E/&lt;basename&gt;</c> with a <em>single</em> slash. The macOS side builds it
/// from <c>URLComponents</c> with a path and no authority, and that is what Foundation emits; this
/// port reproduces it deliberately so the two clients agree.
/// </para>
/// <para>
/// One divergence from Foundation is known and accepted. Foundation strips invisible formatting
/// characters — a leading zero-width space, say — and parses the address underneath; this port trims
/// only whitespace, so such a value has no recognizable scheme and yields nothing. Reproducing it
/// would mean tracking an undocumented internal, and the difference only ever costs a field that was
/// never going to be trustworthy: omitting is the safe direction, and emitting something subtly
/// different from what the user saw is not.
/// </para>
/// </remarks>
public static class ObservedDocumentUrl
{
    /// <summary>Stand-in for the local directory hierarchy a file URL is stripped of.</summary>
    public const string LocalPathPlaceholder = "<local>";

    // Foundation's CharacterSet.urlPathAllowed: unreserved, sub-delims, ":", "@" and the separator.
    private const string AdditionalPathAllowed = "-._~!$&'()*+,;=:@/";

    /// <summary>
    /// Query/fragment keys that are secrets or business-object identifiers. Everything else is kept
    /// for n-gram context, on every host.
    /// </summary>
    private static readonly HashSet<string> DroppedQueryKeys = new(StringComparer.Ordinal)
    {
        "id",
        "ids",
        "guid",
        "uuid",
        "objectid",
        "recordid",
        "entityid",
        "itemid",
        "rowid",
        "password",
        "passwd",
        "pwd",
        "pass",
        "secret",
        "client_secret",
        "token",
        "access_token",
        "refresh_token",
        "id_token",
        "auth_token",
        "oauth_token",
        "api_key",
        "apikey",
        "api-key",
        "authorization",
        "auth",
        "session",
        "sessionid",
        "session_id",
        "sid",
        "phpsessid",
        "jsessionid",
        "code",
        "email",
        "mail",
        "e-mail",
        "phone",
        "tel",
        "mobile",
        "ssn",
        "otp",
        "pin",
        "cvv",
        "cvc",
    };

    private static readonly IdnMapping Idn = new();

    /// <summary>
    /// Normalizes one observed document URL, or reports that there is nothing safe to record.
    /// </summary>
    /// <param name="raw">The value read from the accessibility tree; may be <see langword="null"/>.</param>
    /// <returns>
    /// The value to emit as <c>documentURL</c>, or <see langword="null"/> when the field must be
    /// omitted entirely — which is every case that is not an HTTP(S) address or a local file.
    /// </returns>
    public static string? Sanitize(string? raw)
    {
        if (raw is null)
        {
            return null;
        }

        string trimmed = raw.Trim();
        if (trimmed.Length == 0)
        {
            return null;
        }

        int separator = SchemeSeparator(trimmed);
        if (separator < 0)
        {
            return null;
        }

        string scheme = trimmed[..separator].ToLowerInvariant();
        string rest = trimmed[(separator + 1)..];

        return scheme switch
        {
            "http" or "https" => SanitizeWeb(scheme, rest),
            "file" => SanitizeFile(rest),
            _ => null,
        };
    }

    /// <summary>
    /// Finds the colon that ends a well-formed scheme, or -1 when the value has none — which is what
    /// makes a bare path or a bare host name yield nothing rather than a half-parsed address.
    /// </summary>
    private static int SchemeSeparator(string value)
    {
        if (!char.IsAsciiLetter(value[0]))
        {
            return -1;
        }

        for (int index = 1; index < value.Length; index++)
        {
            char current = value[index];
            if (current == ':')
            {
                return index;
            }

            if (!char.IsAsciiLetterOrDigit(current) && current is not ('+' or '-' or '.'))
            {
                return -1;
            }
        }

        return -1;
    }

    private static string? SanitizeWeb(string scheme, string rest)
    {
        // No authority means no host, and a host is the whole point of an HTTP document context.
        if (!rest.StartsWith("//", StringComparison.Ordinal))
        {
            return null;
        }

        string afterSlashes = rest[2..];
        int authorityEnd = afterSlashes.AsSpan().IndexOfAny('/', '?', '#');
        if (authorityEnd < 0)
        {
            authorityEnd = afterSlashes.Length;
        }

        string authority = afterSlashes[..authorityEnd];
        string tail = afterSlashes[authorityEnd..];

        // Everything ahead of the last "@" is userinfo: a login name and very often a password.
        int userInfoEnd = authority.LastIndexOf('@');
        string hostPort = userInfoEnd >= 0 ? authority[(userInfoEnd + 1)..] : authority;
        if (!TrySplitHostPort(hostPort, out string host, out string? port))
        {
            return null;
        }

        string? normalizedHost = NormalizeHost(host);
        if (normalizedHost is null)
        {
            return null;
        }

        // Userinfo is already gone. Keep query/fragment keys that name a screen; drop secrets and
        // record ids so n-grams work on every site without storing a business object or a token.
        SplitPathQueryFragment(tail, out string path, out string query, out string fragment);

        var builder = new StringBuilder(scheme).Append("://").Append(normalizedHost);
        if (port is not null)
        {
            builder.Append(':').Append(port);
        }

        AppendEncodedPath(builder, path, preserveExistingEscapes: true);

        string? keptQuery = FilterQueryPairs(query);
        if (keptQuery is not null)
        {
            builder.Append('?').Append(keptQuery);
        }

        string? keptFragment = FilterFragment(fragment);
        if (keptFragment is not null)
        {
            builder.Append('#').Append(keptFragment);
        }

        return builder.ToString();
    }

    private static void SplitPathQueryFragment(
        string tail, out string path, out string query, out string fragment)
    {
        query = string.Empty;
        fragment = string.Empty;

        int hash = tail.IndexOf('#');
        int question = tail.IndexOf('?');
        if (question >= 0 && (hash < 0 || question < hash))
        {
            path = tail[..question];
            if (hash >= 0)
            {
                query = tail[(question + 1)..hash];
                fragment = tail[(hash + 1)..];
            }
            else
            {
                query = tail[(question + 1)..];
            }

            return;
        }

        if (hash >= 0)
        {
            path = tail[..hash];
            fragment = tail[(hash + 1)..];
            return;
        }

        path = tail;
    }

    /// <summary>
    /// Rebuilds a fragment after dropping secret and id keys. A leading <c>/?</c> or <c>?</c> is
    /// kept so an F&amp;O hash-route still looks like a hash-route; a path-like hash with no keys is
    /// dropped.
    /// </summary>
    private static string? FilterFragment(string fragment)
    {
        if (fragment.Length == 0)
        {
            return null;
        }

        string prefix;
        string payload;
        if (fragment.StartsWith("/?", StringComparison.Ordinal))
        {
            prefix = "/?";
            payload = fragment[2..];
        }
        else if (fragment.StartsWith('?'))
        {
            prefix = "?";
            payload = fragment[1..];
        }
        else
        {
            int question = fragment.IndexOf('?');
            if (question >= 0)
            {
                prefix = "?";
                payload = fragment[(question + 1)..];
            }
            else
            {
                prefix = string.Empty;
                payload = fragment;
            }
        }

        string? kept = FilterQueryPairs(payload);
        return kept is null ? null : prefix + kept;
    }

    private static string? FilterQueryPairs(string raw)
    {
        if (raw.Length == 0)
        {
            return null;
        }

        List<string>? kept = null;
        HashSet<string>? seen = null;
        int start = 0;
        while (start <= raw.Length)
        {
            int amp = start < raw.Length ? raw.IndexOf('&', start) : -1;
            int end = amp < 0 ? raw.Length : amp;
            if (end > start)
            {
                string pair = raw[start..end];
                int eq = pair.IndexOf('=');
                if (eq > 0)
                {
                    string key = NormalizeQueryKey(pair[..eq]);
                    string value = pair[(eq + 1)..];
                    if (key.Length > 0
                        && value.Length > 0
                        && !IsDroppedQueryKey(key)
                        && !LooksLikeSecretOrIdValue(value))
                    {
                        seen ??= new HashSet<string>(StringComparer.Ordinal);
                        if (seen.Add(key))
                        {
                            kept ??= [];
                            kept.Add(key + "=" + value);
                        }
                    }
                }
            }

            if (amp < 0)
            {
                break;
            }

            start = amp + 1;
        }

        return kept is { Count: > 0 } ? string.Join('&', kept) : null;
    }

    private static string NormalizeQueryKey(string raw)
    {
        string trimmed = raw.Trim();
        if (trimmed.Length == 0)
        {
            return string.Empty;
        }

        string decoded;
        try
        {
            decoded = Uri.UnescapeDataString(trimmed);
        }
        catch (UriFormatException)
        {
            decoded = trimmed;
        }

        return decoded.ToLowerInvariant();
    }

    private static bool IsDroppedQueryKey(string key) =>
        DroppedQueryKeys.Contains(key)
        || key.Contains("token", StringComparison.Ordinal)
        || key.Contains("secret", StringComparison.Ordinal)
        || key.Contains("password", StringComparison.Ordinal)
        || key.Contains("passwd", StringComparison.Ordinal)
        || key.Contains("session", StringComparison.Ordinal);

    /// <summary>
    /// A GUID or JWT is a secret or a business-object id (ANNEX-HOST) even on an otherwise kept key.
    /// </summary>
    private static bool LooksLikeSecretOrIdValue(string raw)
    {
        string candidate;
        try
        {
            candidate = Uri.UnescapeDataString(raw);
        }
        catch (UriFormatException)
        {
            candidate = raw;
        }

        candidate = candidate.Trim().Trim('{', '}');
        if (candidate.StartsWith("eyJ", StringComparison.Ordinal))
        {
            return true;
        }

        return Guid.TryParse(candidate, out _);
    }

    private static string? SanitizeFile(string rest)
    {
        int queryStart = rest.AsSpan().IndexOfAny('?', '#');
        string withoutQuery = queryStart < 0 ? rest : rest[..queryStart];

        string path;
        if (withoutQuery.StartsWith("//", StringComparison.Ordinal))
        {
            // "file://host/share/doc" — the host is a machine name, so only the path survives.
            int pathStart = withoutQuery.IndexOf('/', 2);
            path = pathStart < 0 ? string.Empty : withoutQuery[pathStart..];
        }
        else
        {
            path = withoutQuery;
        }

        string? name = LastPathComponent(path);
        if (name is null)
        {
            return null;
        }

        // Foundation reads the basename through URL.lastPathComponent, which decodes, and writes it
        // back through URLComponents.path, which re-encodes. Round-tripping here keeps a name such as
        // "c%20d.pdf" stable and turns a literal percent into %25 exactly as the macOS client does.
        string decoded = DecodePercentEscapes(name);
        if (decoded.Length == 0)
        {
            return null;
        }

        var builder = new StringBuilder("file:");
        AppendEncodedPath(
            builder,
            $"/{LocalPathPlaceholder}/{decoded}",
            preserveExistingEscapes: false);
        return builder.ToString();
    }

    /// <summary>Foundation's <c>URL.lastPathComponent</c>: trailing separators are not a component.</summary>
    private static string? LastPathComponent(string path)
    {
        if (path.Length == 0)
        {
            return null;
        }

        int end = path.Length;
        while (end > 0 && path[end - 1] == '/')
        {
            end--;
        }

        // A path of nothing but separators is the root, and Foundation names the root "/".
        if (end == 0)
        {
            return "/";
        }

        int start = path.LastIndexOf('/', end - 1) + 1;
        string name = path[start..end];
        return name.Length == 0 ? null : name;
    }

    private static bool TrySplitHostPort(string value, out string host, out string? port)
    {
        host = value;
        port = null;

        if (value.StartsWith('['))
        {
            // A bracketed IPv6 literal is full of colons, so the port can only follow the bracket.
            int close = value.IndexOf(']');
            if (close < 0)
            {
                return false;
            }

            host = value[..(close + 1)];
            string remainder = value[(close + 1)..];
            return remainder.Length == 0
                ? true
                : remainder[0] == ':' && TryReadPort(remainder[1..], out port);
        }

        int colon = value.IndexOf(':');
        if (colon < 0)
        {
            return true;
        }

        host = value[..colon];
        return TryReadPort(value[(colon + 1)..], out port);
    }

    private static bool TryReadPort(string digits, out string? port)
    {
        port = null;
        if (digits.Length == 0)
        {
            return true;
        }

        foreach (char digit in digits)
        {
            if (!char.IsAsciiDigit(digit))
            {
                return false;
            }
        }

        port = digits;
        return true;
    }

    private static string? NormalizeHost(string host)
    {
        if (host.Length == 0)
        {
            return null;
        }

        bool ascii = true;
        foreach (char current in host)
        {
            if (char.IsWhiteSpace(current) || current is '/' or '?' or '#' or '@' or '\\')
            {
                return null;
            }

            if (!char.IsAscii(current))
            {
                ascii = false;
            }
        }

        if (ascii)
        {
            return host.ToLowerInvariant();
        }

        try
        {
            // Foundation punycodes an international host; matching it keeps both clients' archives
            // comparable for the same page.
            return Idn.GetAscii(host);
        }
        catch (ArgumentException)
        {
            return host.ToLowerInvariant();
        }
    }

    private static string DecodePercentEscapes(string value)
    {
        if (!value.Contains('%', StringComparison.Ordinal))
        {
            return value;
        }

        var bytes = new List<byte>(value.Length);
        int index = 0;
        while (index < value.Length)
        {
            if (TryReadEscape(value, index, out byte decoded))
            {
                if (decoded == (byte)'/')
                {
                    // An encoded separator is not a separator: Foundation leaves %2F encoded inside a
                    // path component, and the re-encode below then writes it as %252F.
                    bytes.Add((byte)'%');
                    bytes.Add((byte)value[index + 1]);
                    bytes.Add((byte)value[index + 2]);
                }
                else
                {
                    bytes.Add(decoded);
                }

                index += 3;
                continue;
            }

            int start = index;
            do
            {
                index++;
            }
            while (index < value.Length && !TryReadEscape(value, index, out _));

            bytes.AddRange(Encoding.UTF8.GetBytes(value[start..index]));
        }

        return Encoding.UTF8.GetString(bytes.ToArray());
    }

    private static bool TryReadEscape(string value, int index, out byte decoded)
    {
        decoded = 0;
        if (value[index] != '%'
            || index + 2 >= value.Length
            || !char.IsAsciiHexDigit(value[index + 1])
            || !char.IsAsciiHexDigit(value[index + 2]))
        {
            return false;
        }

        decoded = (byte)((HexValue(value[index + 1]) << 4) | HexValue(value[index + 2]));
        return true;
    }

    private static int HexValue(char digit) => digit switch
    {
        >= '0' and <= '9' => digit - '0',
        >= 'a' and <= 'f' => digit - 'a' + 10,
        _ => digit - 'A' + 10,
    };

    /// <param name="preserveExistingEscapes">
    /// True for a path that arrived already encoded, so <c>%41</c> stays <c>%41</c> while a stray
    /// percent that begins no escape still becomes <c>%25</c>. False for a decoded basename, where
    /// every percent is literal.
    /// </param>
    private static void AppendEncodedPath(StringBuilder builder, string path, bool preserveExistingEscapes)
    {
        for (int index = 0; index < path.Length; index++)
        {
            char current = path[index];
            if (preserveExistingEscapes
                && current == '%'
                && index + 2 < path.Length
                && char.IsAsciiHexDigit(path[index + 1])
                && char.IsAsciiHexDigit(path[index + 2]))
            {
                builder.Append(path, index, 3);
                index += 2;
                continue;
            }

            if (char.IsAsciiLetterOrDigit(current) || AdditionalPathAllowed.Contains(current))
            {
                builder.Append(current);
                continue;
            }

            AppendPercentEncoded(builder, path, ref index);
        }
    }

    private static void AppendPercentEncoded(StringBuilder builder, string value, ref int index)
    {
        int length = char.IsHighSurrogate(value[index])
            && index + 1 < value.Length
            && char.IsLowSurrogate(value[index + 1])
                ? 2
                : 1;

        Span<byte> buffer = stackalloc byte[4];
        int written = Encoding.UTF8.GetBytes(value.AsSpan(index, length), buffer);
        for (int offset = 0; offset < written; offset++)
        {
            builder.Append('%').Append(buffer[offset].ToString("X2", CultureInfo.InvariantCulture));
        }

        index += length - 1;
    }
}
