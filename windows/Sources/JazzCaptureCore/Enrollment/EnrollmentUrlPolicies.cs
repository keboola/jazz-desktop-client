using System.Globalization;

namespace JazzCaptureCore.Enrollment;

/// <summary>
/// Pure validation and routing helpers for Keboola Storage API stack URLs.
/// </summary>
/// <remarks>
/// A newly-issued enrollment bundle carries its exact stack so a dedicated or single-tenant project
/// (for example <c>connection.&lt;tenant&gt;.keboola.cloud</c>) never depends on the desktop's finite
/// list of public stacks. The URL is non-secret, but it receives the device token in
/// <c>tokens/verify</c>, so only canonical HTTPS Keboola connection hosts are accepted.
/// </remarks>
public static class KeboolaStack
{
    /// <summary>
    /// Returns a canonical Storage API base URL, or <see langword="null"/> when <paramref name="raw"/>
    /// is not a supported Keboola connection host. Paths, credentials, ports, queries and fragments
    /// are rejected.
    /// </summary>
    public static string? Normalize(string? raw)
    {
        if (raw is null)
        {
            return null;
        }

        string value = raw.Trim();
        StrictAbsoluteUrl? url = StrictAbsoluteUrl.TryParse(value);
        if (url is null || url.Scheme != "https")
        {
            return null;
        }

        bool isKeboolaHost = url.Host.StartsWith("connection.", StringComparison.Ordinal)
            && (url.Host.EndsWith(".keboola.com", StringComparison.Ordinal)
                || url.Host.EndsWith(".keboola.cloud", StringComparison.Ordinal));
        if (!isKeboolaHost
            || url.UserInfo is not null
            || url.Port is not null
            || url.Query is not null
            || url.Fragment is not null
            || (url.EncodedPath.Length != 0 && url.EncodedPath != "/"))
        {
            return null;
        }

        return "https://" + url.Host;
    }

    /// <summary>
    /// Preferred stack first, then the built-in public stacks, normalized and de-duplicated.
    /// Invalid candidates are discarded rather than receiving a token-bearing verify request.
    /// </summary>
    public static IReadOnlyList<string> VerificationCandidates(string? preferred, IEnumerable<string> known)
    {
        var result = new List<string>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        IEnumerable<string> candidates = preferred is null ? known : new[] { preferred }.Concat(known);
        foreach (string raw in candidates)
        {
            string? normalized = Normalize(raw);
            if (normalized is not null && seen.Add(normalized))
            {
                result.Add(normalized);
            }
        }

        return result;
    }
}

/// <summary>
/// Canonical, non-secret Jazz Archive control-plane routing.
/// </summary>
/// <remarks>
/// This mirrors the server-side enrollment validator: public hosts require HTTPS, while plain HTTP
/// is accepted only for the three literal loopback hosts used by local development. Ambiguous paths
/// are rejected before any URL library gets a chance to normalize them.
/// </remarks>
public static class JazzArchiveControlPlaneUrl
{
    private const string RequiredSuffix = "/api/archive-ingests";

    /// <summary>Canonical form of <paramref name="value"/>, or <see langword="null"/> when it is not routable.</summary>
    public static string? Normalize(string? value)
    {
        if (value is null)
        {
            return null;
        }

        string candidate = value.Trim();
        if (candidate.Length == 0
            || candidate.Contains('\\', StringComparison.Ordinal)
            || candidate.Contains('?', StringComparison.Ordinal)
            || candidate.Contains('#', StringComparison.Ordinal))
        {
            return null;
        }

        StrictAbsoluteUrl? url = StrictAbsoluteUrl.TryParse(candidate);
        if (url is null
            || url.Host.Length == 0
            || url.UserInfo is not null
            || url.Query is not null
            || url.Fragment is not null)
        {
            return null;
        }

        bool isLoopbackHttp = url.Scheme == "http" && EnrollmentHosts.IsLiteralLoopback(url.Host);
        if (url.Scheme != "https" && !isLoopbackHttp)
        {
            return null;
        }

        string encodedPath = url.EncodedPath;
        string lowercasedPath = encodedPath.ToLowerInvariant();

        // Encoded separators are deliberately refused even when they would decode to an otherwise
        // valid suffix. A proxy and the application must never disagree on route boundaries.
        if (lowercasedPath.Contains("%2f", StringComparison.Ordinal)
            || lowercasedPath.Contains("%5c", StringComparison.Ordinal))
        {
            return null;
        }

        string? decodedPath = StrictAbsoluteUrl.TryRemovePercentEncoding(encodedPath);
        if (decodedPath is null
            || decodedPath.Contains("//", StringComparison.Ordinal)
            || decodedPath.Contains('\\', StringComparison.Ordinal))
        {
            return null;
        }

        foreach (string segment in decodedPath.Split('/'))
        {
            if (segment is "." or "..")
            {
                return null;
            }
        }

        string canonicalEncodedPath = encodedPath.EndsWith('/') ? encodedPath[..^1] : encodedPath;
        string canonicalDecodedPath = decodedPath.EndsWith('/') ? decodedPath[..^1] : decodedPath;
        if (!canonicalDecodedPath.EndsWith(RequiredSuffix, StringComparison.Ordinal))
        {
            return null;
        }

        int defaultPort = url.Scheme == "https" ? 443 : 80;
        string port = url.Port is int explicitPort && explicitPort != defaultPort
            ? ":" + explicitPort.ToString(CultureInfo.InvariantCulture)
            : string.Empty;
        return url.Scheme + "://" + url.CanonicalHost + port + canonicalEncodedPath;
    }
}

/// <summary>Hygiene for the pasted OTLP ingest URL, whose path embeds the stream secret.</summary>
public static class StreamEndpoint
{
    /// <summary>
    /// Signed enrollment endpoint policy shared by the JWS verifier and the persisted credential
    /// envelope. Public hosts require HTTPS; literal loopback hosts may use HTTP for local
    /// development. Credentials, whitespace or control characters, query and fragment are refused so
    /// a restored envelope cannot change URL interpretation.
    /// </summary>
    public static bool IsSecureSignedEndpoint(string? value)
    {
        if (value is null
            || value != value.Trim()
            || value.Contains('\\', StringComparison.Ordinal)
            || value.Contains('?', StringComparison.Ordinal)
            || value.Contains('#', StringComparison.Ordinal))
        {
            return false;
        }

        StrictAbsoluteUrl? url = StrictAbsoluteUrl.TryParse(value);
        if (url is null
            || url.Host.Length == 0
            || url.UserInfo is not null
            || url.Query is not null
            || url.Fragment is not null
            || url.Port is < 1 or > 65_535)
        {
            return false;
        }

        return url.Scheme == "https"
            || (url.Scheme == "http" && EnrollmentHosts.IsLiteralLoopback(url.Host));
    }
}

/// <summary>The three literal loopback hosts that may drop TLS for local development.</summary>
public static class EnrollmentHosts
{
    private static readonly HashSet<string> Loopback = new(StringComparer.Ordinal)
    {
        "localhost",
        "127.0.0.1",
        "::1",
    };

    /// <summary>Whether <paramref name="host"/> is one of the three literal loopback hosts.</summary>
    public static bool IsLiteralLoopback(string host) => Loopback.Contains(host);
}
