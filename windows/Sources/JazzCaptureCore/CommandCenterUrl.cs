using JazzCaptureCore.Enrollment;

namespace JazzCaptureCore;

/// <summary>
/// Validates the HTTPS command-center URL from managed config or the MSI installer preference.
/// </summary>
public static class CommandCenterUrl
{
    /// <summary>
    /// Returns the trimmed URL when <paramref name="raw"/> is an absolute <c>https</c> URL with a
    /// host and no userinfo; otherwise <see langword="null"/>.
    /// </summary>
    public static string? TryNormalize(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw))
        {
            return null;
        }

        string value = raw.Trim();
        StrictAbsoluteUrl? url = StrictAbsoluteUrl.TryParse(value);
        if (url is null
            || url.Scheme != "https"
            || url.UserInfo is not null
            || string.IsNullOrEmpty(url.Host))
        {
            return null;
        }

        return value;
    }
}
