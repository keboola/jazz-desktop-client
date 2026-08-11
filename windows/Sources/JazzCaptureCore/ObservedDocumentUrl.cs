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
/// The rules are the macOS ones, one for one: the scheme is lowercased; user, password, query and
/// fragment are dropped; the host is lowercased; only <c>http</c> and <c>https</c> survive as
/// addresses; a <c>file:</c> URL collapses to a placeholder directory plus the basename, because a
/// local path embeds a login name and machine-specific folders that are neither portable nor needed
/// for review; every other scheme yields nothing at all.
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
/// </remarks>
public static class ObservedDocumentUrl
{
    /// <summary>Stand-in for the local directory hierarchy a file URL is stripped of.</summary>
    public const string LocalPathPlaceholder = "<local>";

    // Foundation's CharacterSet.urlPathAllowed: unreserved, sub-delims, ":", "@" and the separator.
    private const string AdditionalPathAllowed = "-._~!$&'()*+,;=:@/";

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

        // The query is where tokens, session ids and search terms live, and the fragment is where a
        // single-page application hides its real location; neither is evidence worth the exposure.
        int pathEnd = tail.AsSpan().IndexOfAny('?', '#');
        string path = pathEnd < 0 ? tail : tail[..pathEnd];

        var builder = new StringBuilder(scheme).Append("://").Append(normalizedHost);
        if (port is not null)
        {
            builder.Append(':').Append(port);
        }

        AppendEncodedPath(builder, path, preserveExistingEscapes: true);
        return builder.ToString();
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
