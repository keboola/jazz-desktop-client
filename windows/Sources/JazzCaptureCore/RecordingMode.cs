namespace JazzCaptureCore;

/// <summary>Fleet recording behaviour: always-on capture or explicit start/stop sessions.</summary>
public enum RecordingMode
{
    Session,
    Continuous,
}

/// <summary>Parses <see cref="RecordingMode"/> from remote policy and managed-registry strings.</summary>
public static class RecordingModeParser
{
    public const string SessionValue = "session";
    public const string ContinuousValue = "continuous";

    public static bool TryParse(string? value, out RecordingMode mode)
    {
        if (value is null)
        {
            mode = default;
            return false;
        }

        if (string.Equals(value, SessionValue, StringComparison.OrdinalIgnoreCase))
        {
            mode = RecordingMode.Session;
            return true;
        }

        if (string.Equals(value, ContinuousValue, StringComparison.OrdinalIgnoreCase))
        {
            mode = RecordingMode.Continuous;
            return true;
        }

        mode = default;
        return false;
    }
}
