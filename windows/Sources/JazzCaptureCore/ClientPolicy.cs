using System.Text.Json;

namespace JazzCaptureCore;

/// <summary>
/// Fleet knobs fetched from the public release channel. Capture never depends on this document.
/// </summary>
public sealed record ClientPolicy(int PauseReminderMinutes, int VoiceConsentEpoch)
{
    public const string Kind = "jazz-windows-client-policy";
    public const int Schema = 1;
    public const int DefaultPauseReminderMinutes = 30;
    public const int MinPauseReminderMinutes = 1;
    public const int MaxPauseReminderMinutes = 24 * 60;
    public const int MaximumDocumentBytes = 16 * 1024;

    public static ClientPolicy Default { get; } = new(DefaultPauseReminderMinutes, 0);

    public static readonly Uri LatestUrl = new(
        "https://github.com/keboola/jazz-windows-releases/releases/latest/download/client-policy.json");

    public static bool TryParse(string json, out ClientPolicy? policy)
    {
        policy = null;
        try
        {
            using JsonDocument document = JsonDocument.Parse(json);
            JsonElement root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return false;
            if (!root.TryGetProperty("kind", out JsonElement kind) || kind.GetString() != Kind) return false;
            if (!root.TryGetProperty("schema", out JsonElement schema) || schema.ValueKind != JsonValueKind.Number
                || !schema.TryGetInt32(out int schemaValue) || schemaValue != Schema) return false;
            if (!root.TryGetProperty("pauseReminderMinutes", out JsonElement minutesElement)
                || minutesElement.ValueKind != JsonValueKind.Number
                || !minutesElement.TryGetInt32(out int minutes)
                || minutes < MinPauseReminderMinutes
                || minutes > MaxPauseReminderMinutes) return false;
            int epoch = 0;
            if (root.TryGetProperty("voiceConsentEpoch", out JsonElement epochElement))
            {
                if (epochElement.ValueKind != JsonValueKind.Number
                    || !epochElement.TryGetInt32(out epoch)
                    || epoch < 0) return false;
            }

            policy = new ClientPolicy(minutes, epoch);
            return true;
        }
        catch (Exception exception) when (exception is JsonException or InvalidOperationException)
        {
            return false;
        }
    }
}
