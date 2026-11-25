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
/// automatic update switch, the enforced exclusions, forced secret masking and the pause reminder.
/// Every field has the value of a client that never received it, so an older server changes nothing.
/// </summary>
public sealed record DeviceOperations
{
    public const int MaximumPauseReminderMinutes = 24 * 60;

    /// <summary>What a policy without any of the new fields means: today's behaviour.</summary>
    public static DeviceOperations Default { get; } = new();

    /// <summary>False means the client does not record and keeps checking the policy.</summary>
    public bool CaptureEnabled { get; init; } = true;

    public CaptureSource CaptureSource { get; init; } = CaptureSource.Unknown;

    /// <summary>False means the client neither downloads nor installs updates.</summary>
    public bool AutoUpdate { get; init; } = true;

    /// <summary>Normalized denylist entries the user cannot remove.</summary>
    public IReadOnlyList<string> EnforcedExcludedApps { get; init; } = Array.Empty<string>();

    /// <summary>True when the secret scanner must run and the user cannot turn it off.</summary>
    public bool ForceMaskSecrets { get; init; }

    /// <summary>The pause reminder in minutes. 0 means none. Null means the server did not say.</summary>
    public int? PauseReminderMinutes { get; init; }

    public bool Equals(DeviceOperations? other) =>
        other is not null
        && CaptureEnabled == other.CaptureEnabled
        && CaptureSource == other.CaptureSource
        && AutoUpdate == other.AutoUpdate
        && ForceMaskSecrets == other.ForceMaskSecrets
        && PauseReminderMinutes == other.PauseReminderMinutes
        && EnforcedExcludedApps.SequenceEqual(other.EnforcedExcludedApps, StringComparer.Ordinal);

    public override int GetHashCode() =>
        HashCode.Combine(CaptureEnabled, CaptureSource, AutoUpdate, ForceMaskSecrets, PauseReminderMinutes, EnforcedExcludedApps.Count);

    /// <summary>Reads the new top-level fields of the policy. A missing or unreadable field keeps its default.</summary>
    internal static DeviceOperations Parse(JsonElement root)
    {
        bool captureEnabled = true;
        CaptureSource source = CaptureSource.Unknown;
        if (root.TryGetProperty("capture", out JsonElement capture) && capture.ValueKind == JsonValueKind.Object)
        {
            if (capture.TryGetProperty("enabled", out JsonElement enabled)
                && enabled.ValueKind is JsonValueKind.True or JsonValueKind.False)
            {
                captureEnabled = enabled.GetBoolean();
            }

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

        return new DeviceOperations
        {
            CaptureEnabled = captureEnabled,
            CaptureSource = source,
            AutoUpdate = autoUpdate,
            EnforcedExcludedApps = enforced,
            ForceMaskSecrets = maskSecrets,
            PauseReminderMinutes = pauseMinutes,
        };
    }

    private static string? Str(JsonElement parent, string name) =>
        parent.TryGetProperty(name, out JsonElement element) && element.ValueKind == JsonValueKind.String
            ? element.GetString()
            : null;
}

/// <summary>
/// Hook point for the secret scanner. The device policy tells the host whether masking is enforced.
/// The scanner implementation connects here and reports no setting of the user can turn it off.
/// </summary>
public interface ISecretMaskingEnforcer
{
    void SetEnforced(bool enforced);
}
