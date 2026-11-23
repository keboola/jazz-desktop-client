using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using JazzCaptureCore;
using JazzCaptureCore.Consent;

namespace JazzCaptureCoreTests;

internal static class ConsentTestSupport
{
    internal const string CurrentVersion = "0.27.0";

    internal static ServedText Text(string version, string body = "# Consent\n\nYou agree.") =>
        new(version, Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(body))).ToLowerInvariant(), body);

    internal static ServedText BrokenHash(string version) =>
        new(version, new string('0', 64), "# Consent\n\nThe body was changed.");

    internal static DevicePolicy Active(
        ConsentPolicyKind policy,
        ServedText? text = null,
        ServedText? notice = null,
        ServedText? modeNotice = null,
        RecordingMode mode = RecordingMode.Continuous,
        string? minClientVersion = null) =>
        new(
            DevicePolicy.StatusActive,
            300,
            minClientVersion,
            mode,
            new ConsentSettings(policy, text ?? Text("0.3"), notice, modeNotice));

    internal static PersonConsentState Answered(ConsentDecision decision, string? version, bool posted = true) =>
        PersonConsentState.Empty with
        {
            Answer = new ConsentAnswer(decision, version, null, "continuous", DateTimeOffset.UnixEpoch, posted),
        };

    internal static string PolicyJson(object consent, string status = "active", string mode = "continuous", string? extra = null)
    {
        string consentJson = JsonSerializer.Serialize(consent);
        return "{\"kind\":\"jazz-windows-client-policy\",\"schema\":1,\"configVersion\":4,\"status\":\"" + status
            + "\",\"consentRefreshSeconds\":120,\"minClientVersion\":\"0.20.0\",\"modeNotice\":null"
            + (mode.Length == 0 ? string.Empty : ",\"recording_mode\":\"" + mode + "\"")
            + ",\"consent\":" + consentJson + (extra ?? string.Empty) + "}";
    }

    internal static object ServedObject(ServedText text) => new { version = text.Version, sha256 = text.Sha256, body = text.Body };
}

internal sealed class FakeStorage : IConsentStorage
{
    internal string? Ledger;
    internal string? Policy;

    public string? ReadLedger() => Ledger;

    public void WriteLedger(string json) => Ledger = json;

    public string? ReadPolicy() => Policy;

    public void WritePolicy(string json) => Policy = json;
}

internal sealed class FakeTransport : IConsentTransport
{
    internal ConsentIdentity? Identity = ConsentIdentity.ForEntra(
        "11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222", @"AzureAD\JNovak");

    internal PolicyFetchResult Fetch = new(PolicyFetchOutcome.Unavailable);
    internal PostOutcome NextPost = PostOutcome.Accepted;
    internal readonly List<DecisionPost> Posts = new();

    public Task<ConsentIdentity?> ResolveIdentityAsync(CancellationToken cancellationToken) => Task.FromResult(Identity);

    internal readonly List<string?> IfNoneMatch = new();

    public Task<PolicyFetchResult> FetchPolicyAsync(ConsentIdentity identity, string? ifNoneMatch, CancellationToken cancellationToken)
    {
        IfNoneMatch.Add(ifNoneMatch);
        return Task.FromResult(Fetch);
    }

    public Task<PostResult> PostDecisionAsync(ConsentIdentity identity, DecisionPost post, CancellationToken cancellationToken)
    {
        Posts.Add(post);
        return Task.FromResult(new PostResult(NextPost));
    }
}
