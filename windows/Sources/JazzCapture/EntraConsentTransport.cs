using System.IO;
using System.Net;
using System.Net.Http;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using JazzCaptureCore.Consent;
using Microsoft.Identity.Client;

namespace JazzCapture;

/// <summary>
/// <c>GET /device/policy</c> and <c>POST /device/consent</c> for a device that uses Entra ID. The
/// request carries the Entra token of the signed-in person in <c>X-Jazz-Entra-Token</c> and the
/// device id of the bundle. This client has no device-key request signing yet, so the signed route
/// is not available and a device without Entra ID gets no policy.
/// </summary>
internal sealed class EntraConsentTransport : IConsentTransport
{
    internal const string DeviceIdHeader = "X-Jazz-Device-Id";
    internal const string ClientVersionHeader = "X-Jazz-Client-Version";
    internal const string OsUserHeader = "X-Jazz-Os-User";

    private readonly Func<EntraEnrollmentRead> _readSettings;
    private readonly IEntraTokenSource _tokens;
    private readonly HttpClient _http;
    private readonly Func<string?> _readDeviceId;
    private readonly Func<(string QualifiedUser, string? Sid)> _windowsUser;
    private readonly string _clientVersion;

    internal EntraConsentTransport(
        Func<EntraEnrollmentRead> readSettings,
        IEntraTokenSource tokens,
        HttpClient http,
        Func<string?> readDeviceId,
        string clientVersion,
        Func<(string QualifiedUser, string? Sid)>? windowsUser = null)
    {
        _readSettings = readSettings;
        _tokens = tokens;
        _http = http;
        _readDeviceId = readDeviceId;
        _clientVersion = clientVersion;
        _windowsUser = windowsUser ?? CurrentWindowsUser;
    }

    public async Task<ConsentIdentity?> ResolveIdentityAsync(CancellationToken cancellationToken)
    {
        (string user, string? sid) = _windowsUser();
        if (string.IsNullOrWhiteSpace(user)) return null;

        if (_readSettings().Settings is not { } settings)
            return string.IsNullOrEmpty(sid) ? null : ConsentIdentity.ForWindows(user, sid);

        // The device has Entra ID. When Windows cannot give a token now, the person stays unknown
        // for this round. The client never falls back to the Windows key, so a short token failure
        // cannot split one person into two.
        string? token = await TryTokenAsync(settings, cancellationToken).ConfigureAwait(false);
        return token is not null && EntraPerson.TryRead(token, out string tenantId, out string objectId)
            ? ConsentIdentity.ForEntra(tenantId, objectId, user)
            : null;
    }

    public async Task<PolicyFetchResult> FetchPolicyAsync(ConsentIdentity identity, CancellationToken cancellationToken)
    {
        (HttpStatusCode? status, string? body) = await SendAsync(HttpMethod.Get, "/device/policy", identity, null, cancellationToken)
            .ConfigureAwait(false);
        return status switch
        {
            HttpStatusCode.OK when body is not null => new PolicyFetchResult(PolicyFetchOutcome.Fetched, body),
            HttpStatusCode.UpgradeRequired => new PolicyFetchResult(PolicyFetchOutcome.TooOld),
            _ => new PolicyFetchResult(PolicyFetchOutcome.Unavailable),
        };
    }

    public async Task<PostResult> PostDecisionAsync(ConsentIdentity identity, DecisionPost post, CancellationToken cancellationToken)
    {
        (HttpStatusCode? status, _) = await SendAsync(HttpMethod.Post, "/device/consent", identity, Body(identity, post), cancellationToken)
            .ConfigureAwait(false);
        return status switch
        {
            HttpStatusCode.OK => new PostResult(PostOutcome.Accepted),
            HttpStatusCode.Forbidden => new PostResult(PostOutcome.Refused),
            HttpStatusCode.UpgradeRequired => new PostResult(PostOutcome.TooOld),
            _ => new PostResult(PostOutcome.Unavailable),
        };
    }

    /// <summary>The fields of <c>POST /device/consent</c>. <c>windowsSid</c> goes only on the signed route.</summary>
    internal static string Body(ConsentIdentity identity, DecisionPost post)
    {
        var fields = new Dictionary<string, string>
        {
            ["consentKey"] = identity.ConsentKey,
            ["decision"] = post.Decision switch
            {
                ConsentDecision.Agreed => "agreed",
                ConsentDecision.Declined => "declined",
                _ => "withdrawn",
            },
        };
        if (post.TextVersion is not null) fields["textVersion"] = post.TextVersion;
        if (post.TextHash is not null) fields["textHash"] = post.TextHash;
        if (post.CaptureMode is not null) fields["captureMode"] = post.CaptureMode;
        if (identity.Route == ConsentRoute.Signed && identity.WindowsSid is not null) fields["windowsSid"] = identity.WindowsSid;
        return JsonSerializer.Serialize(fields);
    }

    private async Task<(HttpStatusCode? Status, string? Body)> SendAsync(
        HttpMethod method, string path, ConsentIdentity identity, string? json, CancellationToken cancellationToken)
    {
        if (identity.Route != ConsentRoute.Entra
            || _readSettings().Settings is not { } settings
            || _readDeviceId() is not { Length: > 0 } deviceId)
        {
            return (null, null);
        }

        string? token = await TryTokenAsync(settings, cancellationToken).ConfigureAwait(false);
        if (token is null) return (null, null);

        try
        {
            using var request = new HttpRequestMessage(method, settings.ServerUrl + path);
            request.Headers.TryAddWithoutValidation(EntraBundleClient.EntraTokenHeader, token);
            request.Headers.TryAddWithoutValidation(DeviceIdHeader, deviceId);
            request.Headers.TryAddWithoutValidation(ClientVersionHeader, _clientVersion);
            if (IsPlainAscii(identity.QualifiedUser))
                request.Headers.TryAddWithoutValidation(OsUserHeader, identity.QualifiedUser);
            request.Headers.UserAgent.ParseAdd("JazzCapture/" + _clientVersion);
            if (json is not null) request.Content = new StringContent(json, Encoding.UTF8, "application/json");

            using HttpResponseMessage response = await _http
                .SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken)
                .ConfigureAwait(false);
            if (method != HttpMethod.Get || response.StatusCode != HttpStatusCode.OK)
                return (response.StatusCode, null);
            if (response.Content.Headers.ContentLength is > DevicePolicy.MaximumDocumentBytes)
                return (null, null);

            await using Stream stream = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
            using var bytes = new MemoryStream();
            byte[] buffer = new byte[8192];
            while (true)
            {
                int read = await stream.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
                if (read == 0) break;
                if (bytes.Length + read > DevicePolicy.MaximumDocumentBytes) return (null, null);
                bytes.Write(buffer, 0, read);
            }

            return (response.StatusCode, Encoding.UTF8.GetString(bytes.GetBuffer(), 0, (int)bytes.Length));
        }
        catch (Exception exception) when (exception is HttpRequestException or IOException
            || (exception is TaskCanceledException && !cancellationToken.IsCancellationRequested))
        {
            return (null, null);
        }
    }

    private async Task<string?> TryTokenAsync(EntraEnrollmentSettings settings, CancellationToken cancellationToken)
    {
        try
        {
            return await _tokens.AcquireSilentAsync(settings, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception exception) when (exception is MsalException or HttpRequestException)
        {
            return null;
        }
    }

    private static bool IsPlainAscii(string value) => value.All(character => character is >= ' ' and <= '~');

    private static (string QualifiedUser, string? Sid) CurrentWindowsUser()
    {
        using WindowsIdentity identity = WindowsIdentity.GetCurrent();
        return (identity.Name, identity.User?.Value);
    }
}
