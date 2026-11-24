using JazzCaptureCore.Consent;

namespace JazzCapture;

/// <summary>
/// Picks the route by the settings of the machine. With Entra ID configured the person and the
/// requests are Entra. Without it they are the signed Windows identity. There is no fallback from
/// one to the other: with Entra configured and no token the person stays unknown.
/// </summary>
internal sealed class ConsentTransportRouter : IConsentTransport
{
    private readonly Func<bool> _entraConfigured;
    private readonly IConsentTransport _entra;
    private readonly IConsentTransport _signed;

    internal ConsentTransportRouter(Func<bool> entraConfigured, IConsentTransport entra, IConsentTransport signed)
    {
        _entraConfigured = entraConfigured;
        _entra = entra;
        _signed = signed;
    }

    public Task<ConsentIdentity?> ResolveIdentityAsync(CancellationToken cancellationToken) =>
        (_entraConfigured() ? _entra : _signed).ResolveIdentityAsync(cancellationToken);

    public Task<PolicyFetchResult> FetchPolicyAsync(ConsentIdentity identity, string? ifNoneMatch, CancellationToken cancellationToken) =>
        For(identity).FetchPolicyAsync(identity, ifNoneMatch, cancellationToken);

    public Task<PostResult> PostDecisionAsync(ConsentIdentity identity, DecisionPost post, CancellationToken cancellationToken) =>
        For(identity).PostDecisionAsync(identity, post, cancellationToken);

    private IConsentTransport For(ConsentIdentity identity) => identity.Route == ConsentRoute.Entra ? _entra : _signed;
}
