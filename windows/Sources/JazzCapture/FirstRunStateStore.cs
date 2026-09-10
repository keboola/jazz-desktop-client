using System.Text.Json;
using System.IO;

namespace JazzCapture;

/// <summary>Small, separate consent-state document; it never changes capture preferences.</summary>
public sealed class FirstRunStateStore
{
    private readonly string _path;
    public FirstRunStateStore(string profileDirectory) => _path = Path.Combine(profileDirectory, "startup-state.json");

    public bool RequiresOnboarding()
    {
        try
        {
            if (!File.Exists(_path)) return true;
            StartupState? state = JsonSerializer.Deserialize<StartupState>(File.ReadAllText(_path));
            return state is not { Schema: 1, OnboardingAcknowledged: true };
        }
        catch (Exception exception) when (IsRecoverable(exception)) { return true; }
    }

    public DateTimeOffset? ReadUpdateAttempt()
    {
        try { return Read()?.UpdateAttemptUtc; }
        catch (Exception exception) when (IsRecoverable(exception)) { return null; }
    }

    /// <summary>Writes the throttle marker before any network operation.</summary>
    public void RecordUpdateAttempt(DateTimeOffset attemptedAt) =>
        Write((ReadRecoverable() ?? new StartupState(1, false)) with { UpdateAttemptUtc = attemptedAt });

    public void Acknowledge()
    {
        Write((ReadRecoverable() ?? new StartupState(1, false)) with { OnboardingAcknowledged = true });
    }

    private StartupState? ReadRecoverable()
    {
        try { return Read(); }
        catch (Exception exception) when (IsRecoverable(exception)) { return null; }
    }

    private StartupState? Read()
    {
        if (!File.Exists(_path)) return null;
        StartupState? state = JsonSerializer.Deserialize<StartupState>(File.ReadAllText(_path));
        return state is { Schema: 1 } ? state : null;
    }
    private void Write(StartupState state)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        string temporary = _path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try { File.WriteAllText(temporary, JsonSerializer.Serialize(state)); File.Move(temporary, _path, true); }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    private static bool IsRecoverable(Exception exception) => exception is IOException
        or UnauthorizedAccessException
        or JsonException
        or ArgumentException;
    private sealed record StartupState(int Schema, bool OnboardingAcknowledged, DateTimeOffset? UpdateAttemptUtc = null);
}
