using System.Text.Json;

namespace JazzCaptureCore.Consent;

/// <summary>Where the server resolved <c>capture.enabled</c> from. Display and debugging only.</summary>
public enum CaptureSource
{
    Unknown,
    Company,
    Department,
    Person,
}

/// <summary>
/// The operational settings the Jazz server hands out in the device policy: capture on/off, the
/// screenshot, narration and clipboard switches, the automatic update switch, the enforced
/// exclusions, forced secret masking, the pause reminder, the offline retention and the Jazz web app
/// address.
/// Every field has the value of a client that never received it, so an older server changes nothing.
/// </summary>
public sealed record DeviceOperations
{
    public const int MaximumPauseReminderMinutes = 24 * 60;
    public const int DefaultOfflineRetentionHours = 48;
    public const int MinimumOfflineRetentionHours = 1;
    public const int MaximumOfflineRetentionHours = 168;

    /// <summary>What a policy without any of the new fields means: today's behaviour.</summary>
    public static DeviceOperations Default { get; } = new();

    /// <summary>False means the client does not record and keeps checking the policy.</summary>
    public bool CaptureEnabled { get; init; } = true;

    public CaptureSource CaptureSource { get; init; } = CaptureSource.Unknown;

    /// <summary>False means the client takes no screenshots. True means the user setting decides.</summary>
    public bool CaptureScreenshots { get; init; } = true;

    /// <summary>
    /// False means voice narration is not available and the client does not ask for voice consent.
    /// True means the user setting decides.
    /// </summary>
    public bool CaptureNarration { get; init; } = true;

    /// <summary>False means a paste event carries no clipboard text. The event itself stays.</summary>
    public bool CaptureClipboard { get; init; } = true;

    /// <summary>How long undelivered events are kept, in hours. The size limits stay in the client.</summary>
    public int OfflineRetentionHours { get; init; } = DefaultOfflineRetentionHours;

    /// <summary>
    /// The Jazz web app address for every "open Jazz" link: absolute <c>https</c>, ending with
    /// <c>/</c>. Null when the server does not know it.
    /// </summary>
    public string? CommandCenterUrl { get; init; }

    /// <summary>False means the client neither downloads nor installs updates.</summary>
    public bool AutoUpdate { get; init; } = true;

    /// <summary>Normalized denylist entries the user cannot remove.</summary>
    public IReadOnlyList<string> EnforcedExcludedApps { get; init; } = Array.Empty<string>();

    /// <summary>True when the secret scanner must run and the user cannot turn it off.</summary>
    public bool ForceMaskSecrets { get; init; }

    /// <summary>The pause reminder in minutes. 0 means none. Null means the server did not say.</summary>
    public int? PauseReminderMinutes { get; init; }

    /// <summary>The company voice-consent epoch. A higher value asks again for voice consent. Null means no reset.</summary>
    public int? VoiceConsentEpoch { get; init; }

    public bool Equals(DeviceOperations? other) =>
        other is not null
        && CaptureEnabled == other.CaptureEnabled
        && CaptureSource == other.CaptureSource
        && CaptureScreenshots == other.CaptureScreenshots
        && CaptureNarration == other.CaptureNarration
        && CaptureClipboard == other.CaptureClipboard
        && OfflineRetentionHours == other.OfflineRetentionHours
        && string.Equals(CommandCenterUrl, other.CommandCenterUrl, StringComparison.Ordinal)
        && AutoUpdate == other.AutoUpdate
        && ForceMaskSecrets == other.ForceMaskSecrets
        && PauseReminderMinutes == other.PauseReminderMinutes
        && VoiceConsentEpoch == other.VoiceConsentEpoch
        && EnforcedExcludedApps.SequenceEqual(other.EnforcedExcludedApps, StringComparer.Ordinal);

    public override int GetHashCode() =>
        HashCode.Combine(CaptureEnabled, CaptureSource, AutoUpdate, ForceMaskSecrets, PauseReminderMinutes, EnforcedExcludedApps.Count);

    /// <summary>Reads the new top-level fields of the policy. A missing or unreadable field keeps its default.</summary>
    internal static DeviceOperations Parse(JsonElement root)
    {
        bool captureEnabled = true;
        bool screenshots = true;
        bool narration = true;
        bool clipboard = true;
        CaptureSource source = CaptureSource.Unknown;
        if (root.TryGetProperty("capture", out JsonElement capture) && capture.ValueKind == JsonValueKind.Object)
        {
            captureEnabled = Flag(capture, "enabled", true);
            screenshots = Flag(capture, "screenshots", true);
            narration = Flag(capture, "narration", true);
            clipboard = Flag(capture, "clipboard", true);

            source = Str(capture, "source") switch
            {
                "company" => CaptureSource.Company,
                "department" => CaptureSource.Department,
                "person" => CaptureSource.Person,
                _ => CaptureSource.Unknown,
            };
        }

        bool autoUpdate = true;
        if (root.TryGetProperty("update", out JsonElement update) && update.ValueKind == JsonValueKind.Object
            && update.TryGetProperty("auto", out JsonElement auto)
            && auto.ValueKind is JsonValueKind.True or JsonValueKind.False)
        {
            autoUpdate = auto.GetBoolean();
        }

        string[] enforced = Array.Empty<string>();
        bool maskSecrets = false;
        if (root.TryGetProperty("protection", out JsonElement protection) && protection.ValueKind == JsonValueKind.Object)
        {
            if (protection.TryGetProperty("enforcedExcludedApps", out JsonElement apps) && apps.ValueKind == JsonValueKind.Array)
            {
                enforced = ApplicationDenylist.Normalize(
                    apps.EnumerateArray().Where(item => item.ValueKind == JsonValueKind.String).Select(item => item.GetString()!));
            }

            // The contract default for a policy that has a protection block is true.
            maskSecrets = !(protection.TryGetProperty("maskSecrets", out JsonElement mask)
                && mask.ValueKind == JsonValueKind.False);
        }

        int? pauseMinutes = null;
        if (root.TryGetProperty("pauseReminderMinutes", out JsonElement minutes)
            && minutes.ValueKind == JsonValueKind.Number
            && minutes.TryGetInt32(out int value)
            && value >= 0)
        {
            pauseMinutes = Math.Min(value, MaximumPauseReminderMinutes);
        }

        int? epoch = null;
        if (root.TryGetProperty("voiceConsentEpoch", out JsonElement epochElement)
            && epochElement.ValueKind == JsonValueKind.Number
            && epochElement.TryGetInt32(out int epochValue)
            && epochValue >= 0)
        {
            epoch = epochValue;
        }

        int retentionHours = DefaultOfflineRetentionHours;
        if (root.TryGetProperty("offline", out JsonElement offline) && offline.ValueKind == JsonValueKind.Object
            && offline.TryGetProperty("retentionHours", out JsonElement hours)
            && hours.ValueKind == JsonValueKind.Number
            && hours.TryGetInt32(out int hoursValue)
            && hoursValue is >= MinimumOfflineRetentionHours and <= MaximumOfflineRetentionHours)
        {
            retentionHours = hoursValue;
        }

        string? commandCenterUrl = global::JazzCaptureCore.CommandCenterUrl.TryNormalize(Str(root, "commandCenterUrl"));
        if (commandCenterUrl is not null && !commandCenterUrl.EndsWith('/'))
        {
            commandCenterUrl = null;
        }

        return new DeviceOperations
        {
            VoiceConsentEpoch = epoch,
            CaptureEnabled = captureEnabled,
            CaptureSource = source,
            CaptureScreenshots = screenshots,
            CaptureNarration = narration,
            CaptureClipboard = clipboard,
            OfflineRetentionHours = retentionHours,
            CommandCenterUrl = commandCenterUrl,
            AutoUpdate = autoUpdate,
            EnforcedExcludedApps = enforced,
            ForceMaskSecrets = maskSecrets,
            PauseReminderMinutes = pauseMinutes,
        };
    }

    private static bool Flag(JsonElement parent, string name, bool fallback) =>
        parent.TryGetProperty(name, out JsonElement element) && element.ValueKind is JsonValueKind.True or JsonValueKind.False
            ? element.GetBoolean()
            : fallback;

    private static string? Str(JsonElement parent, string name) =>
        parent.TryGetProperty(name, out JsonElement element) && element.ValueKind == JsonValueKind.String
            ? element.GetString()
            : null;
}
