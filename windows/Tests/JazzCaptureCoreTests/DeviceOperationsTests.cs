using JazzCaptureCore;
using JazzCaptureCore.Consent;
using static JazzCaptureCoreTests.ConsentTestSupport;

namespace JazzCaptureCoreTests;

public sealed class DeviceOperationsTests
{
    private static DevicePolicy Parse(string json)
    {
        Assert.True(DevicePolicy.TryParse(json, out DevicePolicy? policy));
        return policy!;
    }

    private static string Json(string? extra) =>
        PolicyJson(new { policy = "company_wide", key = "entra_tid_oid", text = ServedObject(Text("0.3")) }, extra: extra);

    [Fact]
    public void ASeverWithoutTheNewFieldsMeansTodaysBehaviour()
    {
        DeviceOperations operations = Parse(Json(null)).Operations!;

        Assert.True(operations.CaptureEnabled);
        Assert.True(operations.AutoUpdate);
        Assert.Empty(operations.EnforcedExcludedApps);
        Assert.False(operations.ForceMaskSecrets);
        Assert.Null(operations.PauseReminderMinutes);
        Assert.Equal(DeviceOperations.Default, operations);
    }

    [Fact]
    public void AllNewFieldsAreRead()
    {
        DeviceOperations operations = Parse(Json(
            ",\"capture\":{\"enabled\":false,\"source\":\"department\"}"
            + ",\"update\":{\"auto\":false}"
            + ",\"protection\":{\"enforcedExcludedApps\":[\"1password\",\" Bitwarden \",\"1PASSWORD\",7],\"maskSecrets\":true,\"secretRulesVersion\":1}"
            + ",\"pauseReminderMinutes\":45")).Operations!;

        Assert.False(operations.CaptureEnabled);
        Assert.Equal(CaptureSource.Department, operations.CaptureSource);
        Assert.False(operations.AutoUpdate);
        Assert.Equal(new[] { "1password", "Bitwarden" }, operations.EnforcedExcludedApps);
        Assert.True(operations.ForceMaskSecrets);
        Assert.Equal(45, operations.PauseReminderMinutes);
    }

    [Fact]
    public void ZeroMeansNoPauseReminderAndIsNotTheSameAsMissing()
    {
        Assert.Equal(0, Parse(Json(",\"pauseReminderMinutes\":0")).Operations!.PauseReminderMinutes);
    }

    [Theory]
    [InlineData(",\"pauseReminderMinutes\":-5")]
    [InlineData(",\"pauseReminderMinutes\":\"30\"")]
    [InlineData(",\"capture\":{\"enabled\":\"no\"}")]
    [InlineData(",\"capture\":\"off\"")]
    [InlineData(",\"update\":{\"auto\":0}")]
    [InlineData(",\"protection\":[]")]
    public void AnUnreadableFieldKeepsItsDefault(string extra)
    {
        DeviceOperations operations = Parse(Json(extra)).Operations!;

        Assert.True(operations.CaptureEnabled);
        Assert.True(operations.AutoUpdate);
        Assert.False(operations.ForceMaskSecrets);
        Assert.Null(operations.PauseReminderMinutes);
    }

    [Fact]
    public void AProtectionBlockWithoutMaskSecretsMasksByDefault()
    {
        Assert.True(Parse(Json(",\"protection\":{\"enforcedExcludedApps\":[]}")).Operations!.ForceMaskSecrets);
        Assert.False(Parse(Json(",\"protection\":{\"maskSecrets\":false}")).Operations!.ForceMaskSecrets);
    }

    [Fact]
    public void CaptureOffStopsRecordingWhateverThePersonAnswered()
    {
        DevicePolicy policy = Parse(Json(",\"capture\":{\"enabled\":false,\"source\":\"company\"}"));

        ConsentVerdict verdict = ConsentEvaluator.Evaluate(
            policy, false, CurrentVersion, Answered(ConsentDecision.Agreed, "0.3"));

        Assert.False(verdict.MayRecord);
        Assert.Equal(ConsentStatus.CaptureOffByAdmin, verdict.Status);
        Assert.Equal("Recording turned off by your administrator", verdict.StatusText);
        Assert.Equal(ConsentPrompt.None, verdict.Prompt);
        Assert.Equal(ConsentNotice.None, verdict.Notice);
        Assert.False(verdict.Settings.CaptureEnabled);
    }

    [Fact]
    public void CaptureOffDoesNotAskForConsent()
    {
        DevicePolicy policy = ConsentTestSupport.Active(ConsentPolicyKind.PerPerson) with
        {
            Operations = new DeviceOperations { CaptureEnabled = false },
        };

        ConsentVerdict verdict = ConsentEvaluator.Evaluate(policy, false, CurrentVersion, PersonConsentState.Empty);

        Assert.Equal(ConsentStatus.CaptureOffByAdmin, verdict.Status);
        Assert.Equal(ConsentPrompt.None, verdict.Prompt);
    }

    [Fact]
    public void CaptureOnAgainRecordsWithoutATimer()
    {
        DevicePolicy off = Parse(Json(",\"capture\":{\"enabled\":false}"));
        DevicePolicy on = Parse(Json(",\"capture\":{\"enabled\":true}"));

        Assert.False(ConsentEvaluator.Evaluate(off, false, CurrentVersion, PersonConsentState.Empty).MayRecord);
        Assert.True(ConsentEvaluator.Evaluate(on, false, CurrentVersion, PersonConsentState.Empty).MayRecord);
    }

    [Fact]
    public void EveryVerdictCarriesTheOperationsOfItsPolicy()
    {
        DevicePolicy policy = Parse(Json(",\"update\":{\"auto\":false}"));

        Assert.False(ConsentEvaluator.Evaluate(policy, false, CurrentVersion, PersonConsentState.Empty).Settings.AutoUpdate);
        Assert.True(ConsentEvaluator.Evaluate(null, false, CurrentVersion, PersonConsentState.Empty).Settings.AutoUpdate);
    }

    [Fact]
    public async Task TheControllerStopsAndResumesWithThePolicyAndNothingElse()
    {
        var storage = new FakeStorage();
        var transport = new FakeTransport();
        var verdicts = new List<ConsentVerdict>();
        var controller = new ConsentController(
            transport, storage, CurrentVersion, () => new DateTimeOffset(2026, 11, 23, 10, 0, 0, TimeSpan.Zero), verdicts.Add);
        controller.Load();

        transport.Fetch = new PolicyFetchResult(PolicyFetchOutcome.Fetched, Json(",\"capture\":{\"enabled\":false}"));
        await controller.RefreshAsync(CancellationToken.None);
        Assert.Equal(ConsentStatus.CaptureOffByAdmin, controller.Current.Status);
        Assert.False(controller.Current.MayRecord);

        await controller.RefreshAsync(CancellationToken.None);
        Assert.False(controller.Current.MayRecord);

        transport.Fetch = new PolicyFetchResult(PolicyFetchOutcome.Fetched, Json(",\"capture\":{\"enabled\":true}"));
        await controller.RefreshAsync(CancellationToken.None);
        Assert.True(controller.Current.MayRecord);
    }
}
