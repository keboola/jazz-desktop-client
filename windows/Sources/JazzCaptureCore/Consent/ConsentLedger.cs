using System.Text.Json;
using System.Text.Json.Serialization;

namespace JazzCaptureCore.Consent;

public enum ConsentDecision
{
    Agreed,
    Declined,
    Withdrawn,
}

/// <summary>
/// One decision of the person. <see cref="Posted"/> is false until the server accepted it. A
/// declined or withdrawn answer applies at once and is posted again until it is accepted.
/// </summary>
public sealed record ConsentAnswer(
    ConsentDecision Decision,
    string? TextVersion,
    string? TextHash,
    string? CaptureMode,
    DateTimeOffset At,
    bool Posted);

/// <summary>What this computer knows about one person: the last answer and the notices already shown.</summary>
public sealed record PersonConsentState(
    ConsentAnswer? Answer,
    string? CompanyNoticeVersion,
    string? ModeNoticeMarker)
{
    public static PersonConsentState Empty { get; } = new(null, null, null);
}

/// <summary>The file the client keeps in the profile of the Windows user. A broken file reads as empty and never grants consent.</summary>
public sealed record ConsentLedger(
    int Schema,
    ConsentIdentity? LastIdentity,
    Dictionary<string, PersonConsentState> People)
{
    public const int CurrentSchema = 1;

    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Converters = { new JsonStringEnumConverter() },
    };

    public static ConsentLedger Empty() => new(CurrentSchema, null, new Dictionary<string, PersonConsentState>());

    public PersonConsentState Person(string storeKey) =>
        People.TryGetValue(storeKey, out PersonConsentState? state) ? state : PersonConsentState.Empty;

    public string ToJson() => JsonSerializer.Serialize(this, Options);

    public static ConsentLedger Parse(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return Empty();
        try
        {
            ConsentLedger? ledger = JsonSerializer.Deserialize<ConsentLedger>(json, Options);
            return ledger is { Schema: CurrentSchema, People: not null } ? ledger : Empty();
        }
        catch (Exception exception) when (exception is JsonException or NotSupportedException)
        {
            return Empty();
        }
    }
}
