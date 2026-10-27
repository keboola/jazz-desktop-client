namespace JazzCapture;

public enum ClientPolicyPresentationState
{
    LocalDefaults,
    Configured,
    Invalid,
}

/// <summary>
/// Tray- and status-window-facing copy for fleet <c>client-policy.json</c> configuration. Never
/// carries a URL or other secret.
/// </summary>
public readonly record struct ClientPolicyPresentation(ClientPolicyPresentationState State, string? Detail)
{
    public static ClientPolicyPresentation LocalDefaults() =>
        new(ClientPolicyPresentationState.LocalDefaults, null);

    public static ClientPolicyPresentation FromRead(CommandCenterUrlRead read) =>
        read.Url is not null
            ? new ClientPolicyPresentation(ClientPolicyPresentationState.Configured, null)
            : read.Detail is not null
                ? new ClientPolicyPresentation(ClientPolicyPresentationState.Invalid, read.Detail)
                : new ClientPolicyPresentation(ClientPolicyPresentationState.LocalDefaults, null);

    public string Describe() => State switch
    {
        ClientPolicyPresentationState.Configured =>
            "fleet policy from your organisation's command center",
        ClientPolicyPresentationState.Invalid =>
            "command center URL is not usable; using cached or local defaults",
        _ => "no command center URL; using local defaults",
    };

    public string StatusWindowLine => State switch
    {
        ClientPolicyPresentationState.Configured =>
            "Fleet policy: fetched from your organisation's command center when configured.",
        ClientPolicyPresentationState.Invalid =>
            "Fleet policy: the command center URL deployed to this machine could not be used, so Jazz "
            + "is not fetching new policy from it. Cached or local defaults still apply. Ask whoever "
            + "manages this machine to check the URL is a secure web address with no credentials in it.",
        _ => "Fleet policy: no command center URL is configured; Jazz uses local defaults and any "
            + "cached policy on this machine.",
    };

    public bool ShowFaultPrefix => State == ClientPolicyPresentationState.Invalid;
}
