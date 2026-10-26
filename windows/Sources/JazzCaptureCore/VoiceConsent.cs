namespace JazzCaptureCore;

/// <summary>Whether to record the microphone for one declared label, and whether to stop asking.</summary>
public readonly record struct VoiceConsentDecision(bool Record, bool Persist);

/// <summary>
/// Local voice-consent rules. Capture never depends on the prompt; a declined or skipped answer
/// still opens the label without audio.
/// </summary>
public static class VoiceConsent
{
    public static bool ShouldPrompt(HostSettings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
        return !settings.SuppressVoicePrompt;
    }

    public static bool RecordWithoutPrompt(HostSettings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
        return settings.SuppressVoicePrompt && settings.NarrationEnabled;
    }

    public static HostSettings AfterPrompt(HostSettings settings, bool record, bool dontAskAgain)
    {
        ArgumentNullException.ThrowIfNull(settings);
        if (!dontAskAgain) return settings;
        return settings with { NarrationEnabled = record, SuppressVoicePrompt = true };
    }

    public static HostSettings AfterSettingsToggle(HostSettings settings, bool enabled)
    {
        ArgumentNullException.ThrowIfNull(settings);
        // On: voice is allowed and the next label asks again (unless they later tick Don't ask again).
        // Off: do not record and do not prompt.
        return enabled
            ? settings with { NarrationEnabled = true, SuppressVoicePrompt = false }
            : settings with { NarrationEnabled = false, SuppressVoicePrompt = true };
    }

    public static HostSettings AfterPolicyEpoch(HostSettings settings, int epoch)
    {
        ArgumentNullException.ThrowIfNull(settings);
        if (epoch <= settings.VoiceConsentEpoch) return settings;
        return settings with
        {
            NarrationEnabled = false,
            SuppressVoicePrompt = false,
            VoiceConsentEpoch = epoch,
        };
    }
}
