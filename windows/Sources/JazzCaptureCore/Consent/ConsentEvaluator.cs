namespace JazzCaptureCore.Consent;

public enum ConsentStatus
{
    /// <summary>No valid policy and none cached.</summary>
    NotSetUp,

    /// <summary>The admin has not finished the first run.</summary>
    SetupNotFinished,

    /// <summary>The client is older than <c>minClientVersion</c>.</summary>
    UpdateRequired,

    /// <summary>A served text is missing or fails its hash check.</summary>
    TextError,

    AwaitingAnswer,

    /// <summary>The person agreed to an older text version.</summary>
    AwaitingNewAnswer,

    Agreed,

    CompanyWide,

    Declined,

    Withdrawn,
}

public enum ConsentPrompt
{
    None,

    /// <summary>First ask. The person never answered.</summary>
    Ask,

    /// <summary>A new text version asks a person who agreed before.</summary>
    Reask,
}

public enum ConsentNotice
{
    None,
    CompanyWide,
    ModeChange,
}

/// <summary>What the client does now. Pure data: the UI only shows it.</summary>
/// <param name="OfferedText">The verified text for the prompt and for "Give consent again". Null when none is offered.</param>
/// <param name="NoticeText">The verified text of <see cref="Notice"/>.</param>
public sealed record ConsentVerdict(
    ConsentStatus Status,
    bool MayRecord,
    RecordingMode? Mode,
    ConsentPrompt Prompt,
    ConsentNotice Notice,
    bool CanWithdraw,
    bool CanGiveConsent,
    ServedText? OfferedText,
    ServedText? NoticeText)
{
    public static ConsentVerdict NoRecording(ConsentStatus status, RecordingMode? mode = null) =>
        new(status, false, mode, ConsentPrompt.None, ConsentNotice.None, false, false, null, null);

    public string StatusText => Status switch
    {
        ConsentStatus.NotSetUp => "Not set up",
        ConsentStatus.SetupNotFinished => "Setup not finished",
        ConsentStatus.UpdateRequired => "Update required",
        ConsentStatus.TextError => "Not recording - the consent text could not be verified",
        ConsentStatus.AwaitingAnswer or ConsentStatus.AwaitingNewAnswer => "Not recording - waiting for your answer",
        ConsentStatus.Declined => "Not recording - you did not agree",
        ConsentStatus.Withdrawn => "Not recording - consent withdrawn",
        ConsentStatus.CompanyWide => "Recording allowed - company-wide consent",
        _ => "Recording allowed - you agreed",
    };
}

/// <summary>
/// The decision state machine. It has no I/O and no clock: the same inputs give the same verdict.
/// </summary>
public static class ConsentEvaluator
{
    /// <param name="policy">The latest valid policy, fetched or cached. Null when there is none.</param>
    /// <param name="refusedAsTooOld">The server answered 426 to this client.</param>
    public static ConsentVerdict Evaluate(
        DevicePolicy? policy,
        bool refusedAsTooOld,
        string clientVersion,
        PersonConsentState person)
    {
        if (refusedAsTooOld || (policy is not null && ClientVersion.IsBelow(clientVersion, policy.MinClientVersion)))
            return ConsentVerdict.NoRecording(ConsentStatus.UpdateRequired);
        if (policy is null)
            return ConsentVerdict.NoRecording(ConsentStatus.NotSetUp);
        if (policy.Status == DevicePolicy.StatusAwaitingAdminFirstRun)
            return ConsentVerdict.NoRecording(ConsentStatus.SetupNotFinished);
        if (policy.Status != DevicePolicy.StatusActive || policy.Mode is not RecordingMode mode || policy.Consent is not { } consent)
            return ConsentVerdict.NoRecording(ConsentStatus.NotSetUp);

        ConsentAnswer? answer = person.Answer;
        if (answer is { Decision: ConsentDecision.Declined or ConsentDecision.Withdrawn })
        {
            // A personal decline or withdrawal beats company-wide consent and every new text version.
            ServedText? again = consent.Text is { } text && text.HashMatches() ? text : null;
            return new ConsentVerdict(
                answer.Decision == ConsentDecision.Declined ? ConsentStatus.Declined : ConsentStatus.Withdrawn,
                false, mode, ConsentPrompt.None, ConsentNotice.None, false, again is not null, again, null);
        }

        return consent.Policy == ConsentPolicyKind.PerPerson
            ? EvaluatePerPerson(consent, mode, answer, person)
            : EvaluateCompanyWide(consent, mode, person);
    }

    /// <summary>
    /// A person is told once per notice version and per capture mode. The marker changes with the
    /// mode and never changes the stored answer.
    /// </summary>
    public static string ModeNoticeMarker(ServedText modeNotice, RecordingMode mode) =>
        modeNotice.Version + "/" + (mode == RecordingMode.Continuous ? RecordingModeParser.ContinuousValue : RecordingModeParser.SessionValue);

    private static ConsentVerdict EvaluatePerPerson(
        ConsentSettings consent, RecordingMode mode, ConsentAnswer? answer, PersonConsentState person)
    {
        if (consent.Text is not { } text || !text.HashMatches())
            return ConsentVerdict.NoRecording(ConsentStatus.TextError, mode);

        if (answer is null)
        {
            return new ConsentVerdict(
                ConsentStatus.AwaitingAnswer, false, mode, ConsentPrompt.Ask, ConsentNotice.None, false, false, text, null);
        }

        if (answer.TextVersion != text.Version)
        {
            return new ConsentVerdict(
                ConsentStatus.AwaitingNewAnswer, false, mode, ConsentPrompt.Reask, ConsentNotice.None, false, false, text, null);
        }

        return Recording(ConsentStatus.Agreed, consent, mode, person, companyNoticePending: false);
    }

    private static ConsentVerdict EvaluateCompanyWide(ConsentSettings consent, RecordingMode mode, PersonConsentState person) =>
        Recording(
            ConsentStatus.CompanyWide,
            consent,
            mode,
            person,
            companyNoticePending: consent.Notice is { } notice && person.CompanyNoticeVersion != notice.Version);

    private static ConsentVerdict Recording(
        ConsentStatus status, ConsentSettings consent, RecordingMode mode, PersonConsentState person, bool companyNoticePending)
    {
        ConsentNotice kind = ConsentNotice.None;
        ServedText? noticeText = null;
        if (companyNoticePending)
        {
            kind = ConsentNotice.CompanyWide;
            noticeText = consent.Notice;
        }
        else if (consent.ModeNotice is { } modeNotice && person.ModeNoticeMarker != ModeNoticeMarker(modeNotice, mode))
        {
            kind = ConsentNotice.ModeChange;
            noticeText = modeNotice;
        }

        // A notice that cannot be shown as served stops recording, like a consent text that fails its hash.
        if (noticeText is not null && !noticeText.HashMatches())
            return ConsentVerdict.NoRecording(ConsentStatus.TextError, mode);

        return new ConsentVerdict(status, true, mode, ConsentPrompt.None, kind, true, false, null, noticeText);
    }
}
