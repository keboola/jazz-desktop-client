using System.Text;

namespace JazzCaptureCore.Enrollment;

/// <summary>
/// A deliberately non-normalizing absolute-URL splitter used by every enrollment URL policy.
/// </summary>
/// <remarks>
/// <para>
/// <see cref="Uri"/> is unusable at this boundary: it resolves <c>..</c> segments, collapses
/// duplicate slashes, decodes some percent escapes, supplies a default port, and generally hands
/// back a URL that is not the one the signer signed. Every check here needs to see the exact bytes
/// the server put inside the signature, so this type only splits the string into its RFC 3986
/// components and refuses anything it cannot split unambiguously.
/// </para>
/// <para>
/// The macOS client reaches the same behaviour through <c>URLComponents</c>, which is similarly
/// non-normalizing. Divergences between the two would let a proxy and a client disagree about a
/// route boundary, so this is a port of that behaviour rather than of .NET convention.
/// </para>
/// </remarks>
public sealed class StrictAbsoluteUrl
{
    private StrictAbsoluteUrl(
        string scheme,
        string? userInfo,
        string host,
        bool hostIsIPv6Literal,
        int? port,
        string encodedPath,
        string? query,
        string? fragment)
    {
        Scheme = scheme;
        UserInfo = userInfo;
        Host = host;
        HostIsIPv6Literal = hostIsIPv6Literal;
        Port = port;
        EncodedPath = encodedPath;
        Query = query;
        Fragment = fragment;
    }

    /// <summary>Lowercased scheme, always present.</summary>
    public string Scheme { get; }

    /// <summary>Everything before the <c>@</c> in the authority, or <see langword="null"/>.</summary>
    public string? UserInfo { get; }

    /// <summary>Lowercased host with IPv6 brackets removed (<c>::1</c>, not <c>[::1]</c>).</summary>
    public string Host { get; }

    /// <summary>Whether the authority spelled the host as a bracketed IPv6 literal.</summary>
    public bool HostIsIPv6Literal { get; }

    /// <summary>Explicit port, or <see langword="null"/> when the authority carried none.</summary>
    public int? Port { get; }

    /// <summary>Path exactly as written, still percent-encoded. Empty or starting with <c>/</c>.</summary>
    public string EncodedPath { get; }

    /// <summary>Query without the <c>?</c>, or <see langword="null"/> when absent.</summary>
    public string? Query { get; }

    /// <summary>Fragment without the <c>#</c>, or <see langword="null"/> when absent.</summary>
    public string? Fragment { get; }

    /// <summary>Splits an absolute URL, or returns <see langword="null"/> when it is not one.</summary>
    public static StrictAbsoluteUrl? TryParse(string? value)
    {
        if (string.IsNullOrEmpty(value) || !IsPlausibleUrlText(value))
        {
            return null;
        }

        int schemeEnd = value.IndexOf("://", StringComparison.Ordinal);
        if (schemeEnd <= 0)
        {
            return null;
        }

        string rawScheme = value[..schemeEnd];
        if (!IsScheme(rawScheme))
        {
            return null;
        }

        string rest = value[(schemeEnd + 3)..];

        string? fragment = null;
        int hash = rest.IndexOf('#');
        if (hash >= 0)
        {
            fragment = rest[(hash + 1)..];
            rest = rest[..hash];
        }

        string? query = null;
        int question = rest.IndexOf('?');
        if (question >= 0)
        {
            query = rest[(question + 1)..];
            rest = rest[..question];
        }

        string encodedPath = string.Empty;
        int slash = rest.IndexOf('/');
        if (slash >= 0)
        {
            encodedPath = rest[slash..];
            rest = rest[..slash];
        }

        string authority = rest;
        string? userInfo = null;
        int at = authority.LastIndexOf('@');
        if (at >= 0)
        {
            userInfo = authority[..at];
            authority = authority[(at + 1)..];
        }

        string hostText;
        string portText = string.Empty;
        bool bracketed = false;
        if (authority.StartsWith('['))
        {
            int close = authority.IndexOf(']');
            if (close < 0)
            {
                return null;
            }

            bracketed = true;
            hostText = authority[1..close];
            string tail = authority[(close + 1)..];
            if (tail.Length > 0)
            {
                if (tail[0] != ':')
                {
                    return null;
                }

                portText = tail[1..];
            }
        }
        else
        {
            int colon = authority.IndexOf(':');
            if (colon >= 0)
            {
                hostText = authority[..colon];
                portText = authority[(colon + 1)..];
            }
            else
            {
                hostText = authority;
            }
        }

        if (hostText.Length == 0 || !IsHost(hostText, bracketed))
        {
            return null;
        }

        int? port = null;
        if (portText.Length > 0)
        {
            foreach (char c in portText)
            {
                if (c is < '0' or > '9')
                {
                    return null;
                }
            }

            if (!int.TryParse(portText, out int parsedPort))
            {
                // A port that does not fit in an Int32 is never a usable port; treating it as
                // "absent" would silently promote it to the scheme default.
                return null;
            }

            port = parsedPort;
        }

        if (encodedPath.Length > 0 && encodedPath[0] != '/')
        {
            return null;
        }

        return new StrictAbsoluteUrl(
            rawScheme.ToLowerInvariant(),
            userInfo,
            hostText.ToLowerInvariant(),
            bracketed,
            port,
            encodedPath,
            query,
            fragment);
    }

    /// <summary>Host as it must be written back into a canonical origin string.</summary>
    public string CanonicalHost => Host.Contains(':', StringComparison.Ordinal) ? "[" + Host + "]" : Host;

    /// <summary>
    /// Decodes <c>%XX</c> escapes in <paramref name="encoded"/>, or returns <see langword="null"/>
    /// when an escape is malformed or the result is not valid UTF-8.
    /// </summary>
    public static string? TryRemovePercentEncoding(string encoded)
    {
        if (encoded.IndexOf('%') < 0)
        {
            return encoded;
        }

        var bytes = new List<byte>(encoded.Length);
        for (int i = 0; i < encoded.Length; i++)
        {
            char c = encoded[i];
            if (c != '%')
            {
                if (c > 0x7f)
                {
                    bytes.AddRange(Encoding.UTF8.GetBytes(c.ToString()));
                    continue;
                }

                bytes.Add((byte)c);
                continue;
            }

            if (i + 2 >= encoded.Length
                || !TryHexDigit(encoded[i + 1], out int high)
                || !TryHexDigit(encoded[i + 2], out int low))
            {
                return null;
            }

            bytes.Add((byte)((high << 4) | low));
            i += 2;
        }

        try
        {
            return new UTF8Encoding(false, true).GetString(bytes.ToArray());
        }
        catch (DecoderFallbackException)
        {
            return null;
        }
    }

    private static bool TryHexDigit(char c, out int value)
    {
        value = c switch
        {
            >= '0' and <= '9' => c - '0',
            >= 'a' and <= 'f' => c - 'a' + 10,
            >= 'A' and <= 'F' => c - 'A' + 10,
            _ => -1,
        };
        return value >= 0;
    }

    private static bool IsScheme(string value)
    {
        if (value.Length == 0 || !char.IsAsciiLetter(value[0]))
        {
            return false;
        }

        foreach (char c in value)
        {
            if (!char.IsAsciiLetterOrDigit(c) && c is not ('+' or '-' or '.'))
            {
                return false;
            }
        }

        return true;
    }

    private static bool IsHost(string value, bool bracketed)
    {
        foreach (char c in value)
        {
            bool allowed = char.IsAsciiLetterOrDigit(c)
                || c is '-' or '.' or '_' or '~' or '%'
                || (bracketed && c is ':');
            if (!allowed)
            {
                return false;
            }
        }

        return true;
    }

    /// <summary>
    /// Rejects the characters that make a URL string ambiguous before it is even split: ASCII
    /// whitespace and controls, DEL, and any C1 control. A backslash is left to the individual
    /// policies, which all refuse it explicitly.
    /// </summary>
    private static bool IsPlausibleUrlText(string value)
    {
        foreach (char c in value)
        {
            if (c <= 0x20 || c == 0x7f || (c >= 0x80 && c <= 0x9f))
            {
                return false;
            }
        }

        return true;
    }
}
