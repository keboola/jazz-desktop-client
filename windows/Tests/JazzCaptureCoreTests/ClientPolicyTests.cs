using JazzCaptureCore;

namespace JazzCaptureCoreTests;

public sealed class ClientPolicyTests
{
    [Fact]
    public void ParsesFleetDocument()
    {
        const string json = "{\"kind\":\"jazz-windows-client-policy\",\"schema\":1,\"pauseReminderMinutes\":15,\"future\":true}";
        Assert.True(ClientPolicy.TryParse(json, out ClientPolicy? policy));
        Assert.Equal(15, policy!.PauseReminderMinutes);
        Assert.Equal(0, policy.VoiceConsentEpoch);
    }

    [Fact]
    public void RejectsUnknownKindWrongSchemaAndOutOfRangeMinutes()
    {
        string[] rejected =
        {
            "not-json",
            "{}",
            "{\"kind\":\"other\",\"schema\":1,\"pauseReminderMinutes\":15}",
            "{\"kind\":\"jazz-windows-client-policy\",\"schema\":2,\"pauseReminderMinutes\":15}",
            "{\"kind\":\"jazz-windows-client-policy\",\"schema\":1,\"pauseReminderMinutes\":0}",
            "{\"kind\":\"jazz-windows-client-policy\",\"schema\":1,\"pauseReminderMinutes\":1441}",
            "{\"kind\":\"jazz-windows-client-policy\",\"schema\":1,\"pauseReminderMinutes\":\"60\"}",
        };

        foreach (string json in rejected)
            Assert.False(ClientPolicy.TryParse(json, out _));
    }
}
