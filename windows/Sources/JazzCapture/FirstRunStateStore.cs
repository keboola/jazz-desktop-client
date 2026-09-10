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
        catch (Exception) when (ExceptionAllowsRecovery()) { return true; }
    }

    public void Acknowledge()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        string temporary = _path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllText(temporary, JsonSerializer.Serialize(new StartupState(1, true)));
            File.Move(temporary, _path, true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    private static bool ExceptionAllowsRecovery() => true;
    private sealed record StartupState(int Schema, bool OnboardingAcknowledged);
}
