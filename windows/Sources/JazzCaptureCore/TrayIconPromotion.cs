namespace JazzCaptureCore;

/// <summary>One subkey of <c>HKCU\Control Panel\NotifyIconSettings</c>.</summary>
public sealed record NotifyIconEntry(string SubKey, string? ExecutablePath, int? IsPromoted);

/// <summary>The registry behind <see cref="TrayIconPromotion"/>, so the selection can be tested without one.</summary>
public interface INotifyIconSettingsRegistry
{
    IReadOnlyList<NotifyIconEntry> Read();

    void SetPromoted(string subKey);
}

/// <summary>
/// Windows 11 hides a new notification-area icon in the overflow flyout. It shows the icon when
/// <c>IsPromoted</c> is 1 in the subkey of that executable. The setting is not documented by
/// Microsoft.
/// </summary>
public static class TrayIconPromotion
{
    /// <summary>
    /// The subkey that belongs to <paramref name="executablePath"/>, or null. Windows may store the
    /// path with a leading known-folder id such as <c>{GUID}\Jazz\JazzCapture.exe</c>, so such a
    /// path matches when the running path ends with the part after the id.
    /// </summary>
    public static string? SelectSubKey(IEnumerable<NotifyIconEntry> entries, string executablePath)
    {
        string running = Normalize(executablePath);
        foreach (NotifyIconEntry entry in entries)
        {
            if (string.IsNullOrWhiteSpace(entry.ExecutablePath)) continue;
            string stored = Normalize(entry.ExecutablePath);
            if (stored.StartsWith('{'))
            {
                int end = stored.IndexOf('}');
                if (end < 0) continue;
                string tail = stored[(end + 1)..];
                if (tail.Length > 1 && running.EndsWith(tail, StringComparison.OrdinalIgnoreCase)) return entry.SubKey;
            }
            else if (string.Equals(stored, running, StringComparison.OrdinalIgnoreCase))
            {
                return entry.SubKey;
            }
        }

        return null;
    }

    /// <summary>
    /// Sets <c>IsPromoted=1</c> for the icon of this executable.
    /// </summary>
    /// <returns>True when the icon is promoted now, or was before. False when no subkey exists yet.</returns>
    public static bool TryPromote(INotifyIconSettingsRegistry registry, string executablePath)
    {
        IReadOnlyList<NotifyIconEntry> entries = registry.Read();
        string? subKey = SelectSubKey(entries, executablePath);
        if (subKey is null) return false;
        NotifyIconEntry entry = entries.First(candidate => candidate.SubKey == subKey);
        if (entry.IsPromoted != 1) registry.SetPromoted(subKey);
        return true;
    }

    private static string Normalize(string path) => path.Trim().Replace('/', '\\');
}
