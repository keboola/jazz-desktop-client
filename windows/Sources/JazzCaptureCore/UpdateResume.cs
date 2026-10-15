namespace JazzCaptureCore;

/// <summary>
/// After a version change the next process must start recording even if the previous session was
/// paused. Same-version relaunch keeps the pause.
/// </summary>
public static class UpdateResume
{
    public static bool ShouldClearPause(string? lastRunVersion, string currentVersion)
    {
        if (string.IsNullOrWhiteSpace(currentVersion)) return false;
        return !string.Equals(lastRunVersion, currentVersion, StringComparison.Ordinal);
    }
}
