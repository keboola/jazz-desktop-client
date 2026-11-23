using System.IO;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using JazzCaptureCore.Consent;

namespace JazzCapture;

/// <summary>
/// The signed route for a device without Entra ID. The device enrolls once with the per-tenant
/// enrollment code and its own P-256 key, then signs <c>GET /device/policy</c>,
/// <c>POST /device/consent</c> and <c>POST /device/token/renew</c>. The person is the qualified
/// Windows user name plus the SID, and the SID goes with every decision.
/// </summary>
internal sealed class SignedConsentTransport : IConsentTransport
{
    private static readonly TimeSpan EnrollRetry = TimeSpan.FromMinutes(5);
    private static readonly TimeSpan RenewBefore = TimeSpan.FromMinutes(10);

    private readonly Func<SignedEnrollmentSettings?> _readSettings;
    private readonly DeviceKeyStore _keys;
    private readonly HttpClient _http;
    private readonly string _clientVersion;
    private readonly Func<DateTimeOffset> _clock;
    private readonly Func<(string QualifiedUser, string? Sid)> _windowsUser;
    private readonly Func<string> _hostName;
    private DateTimeOffset _nextEnroll = DateTimeOffset.MinValue;

    internal SignedConsentTransport(
        Func<SignedEnrollmentSettings?> readSettings,
        DeviceKeyStore keys,
        HttpClient http,
        string clientVersion,
        Func<DateTimeOffset>? clock = null,
        Func<(string QualifiedUser, string? Sid)>? windowsUser = null,
        Func<string>? hostName = null)
    {
        _readSettings = readSettings;
        _keys = keys;
        _http = http;
        _clientVersion = clientVersion;
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
        _windowsUser = windowsUser ?? CurrentWindowsUser;
        _hostName = hostName ?? (() => Environment.MachineName);
    }

    /// <summary>A client for the signed route. Header values go out as UTF-8, and the signature covers what the server reads.</summary>
    internal static HttpClient CreateProductionClient() => new(new SocketsHttpHandler
    {
        AllowAutoRedirect = false,
        RequestHeaderEncodingSelector = (_, _) => Encoding.UTF8,
    })
    {
        Timeout = TimeSpan.FromSeconds(30),
    };

    public Task<ConsentIdentity?> ResolveIdentityAsync(CancellationToken cancellationToken)
    {
        (string user, string? sid) = _windowsUser();
        return Task.FromResult<ConsentIdentity?>(
            string.IsNullOrWhiteSpace(user) || string.IsNullOrEmpty(sid) ? null : ConsentIdentity.ForWindows(user, sid));
    }

    public async Task<PolicyFetchResult> FetchPolicyAsync(ConsentIdentity identity, string? ifNoneMatch, CancellationToken cancellationToken)
    {
        try
        {
            if (identity.Route != ConsentRoute.Signed || _readSettings() is not { } settings)
                return new PolicyFetchResult(PolicyFetchOutcome.Unavailable);
            DeviceKeyRecord? device = await EnsureEnrolledAsync(settings, identity, cancellationToken).ConfigureAwait(false);
            if (device is null) return new PolicyFetchResult(PolicyFetchOutcome.Unavailable);

            device = await RenewIfDueAsync(settings, identity, device, cancellationToken).ConfigureAwait(false);
            (HttpStatusCode? status, string? body, string? etag) = await SendAsync(
                settings, device, identity, HttpMethod.Get, DeviceRequestSigning.PolicyPath, ifNoneMatch, null, cancellationToken)
                .ConfigureAwait(false);
            switch (status)
            {
                case HttpStatusCode.OK when body is not null:
                    RememberFilesToken(device, body);
                    return new PolicyFetchResult(PolicyFetchOutcome.Fetched, body, etag);
                case HttpStatusCode.NotModified:
                    return new PolicyFetchResult(PolicyFetchOutcome.NotModified);
                case HttpStatusCode.UpgradeRequired:
                    return new PolicyFetchResult(PolicyFetchOutcome.TooOld);
                default:
                    return new PolicyFetchResult(PolicyFetchOutcome.Unavailable);
            }
        }
        catch (Exception exception) when (exception is InvalidDataException or CryptographicException)
        {
            return new PolicyFetchResult(PolicyFetchOutcome.Unavailable);
        }
    }

    public async Task<PostResult> PostDecisionAsync(ConsentIdentity identity, DecisionPost post, CancellationToken cancellationToken)
    {
        try
        {
            if (identity.Route != ConsentRoute.Signed || _readSettings() is not { } settings)
                return new PostResult(PostOutcome.Unavailable);
            DeviceKeyRecord? device = await EnsureEnrolledAsync(settings, identity, cancellationToken).ConfigureAwait(false);
            if (device is null) return new PostResult(PostOutcome.Unavailable);

            (HttpStatusCode? status, _, _) = await SendAsync(
                settings, device, identity, HttpMethod.Post, DeviceRequestSigning.ConsentPath, null, ConsentFields(identity, post), cancellationToken)
                .ConfigureAwait(false);
            return status switch
            {
                HttpStatusCode.OK => new PostResult(PostOutcome.Accepted),
                HttpStatusCode.Forbidden => new PostResult(PostOutcome.Refused),
                HttpStatusCode.UpgradeRequired => new PostResult(PostOutcome.TooOld),
                _ => new PostResult(PostOutcome.Unavailable),
            };
        }
        catch (Exception exception) when (exception is InvalidDataException or CryptographicException)
        {
            return new PostResult(PostOutcome.Unavailable);
        }
    }

    /// <summary>The consent fields. They are signed, and they are the JSON body.</summary>
    internal static Dictionary<string, string> ConsentFields(ConsentIdentity identity, DecisionPost post)
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
        if (identity.WindowsSid is not null) fields["windowsSid"] = identity.WindowsSid;
        if (post.TextVersion is not null) fields["textVersion"] = post.TextVersion;
        if (post.TextHash is not null) fields["textHash"] = post.TextHash;
        if (post.CaptureMode is not null) fields["captureMode"] = post.CaptureMode;
        return fields;
    }

    /// <summary>Enrolls the device once. Without the enrollment code a device that never enrolled gets nothing.</summary>
    private async Task<DeviceKeyRecord?> EnsureEnrolledAsync(
        SignedEnrollmentSettings settings, ConsentIdentity identity, CancellationToken cancellationToken)
    {
        DeviceKeyRecord device = _keys.LoadOrCreate();
        if (device.Enrolled) return device;
        if (settings.Code is null || _clock() < _nextEnroll) return null;
        _nextEnroll = _clock() + EnrollRetry;

        IDeviceSigner signer = _keys.OpenProofKey(device);
        try
        {
            string body = DeviceRequestSigning.EnrollBody(
                signer,
                _keys.WrappingPublicKey(device),
                device.DeviceId,
                settings.Code,
                DeviceRequestSigning.HeaderSafe(_hostName()),
                identity.QualifiedUser,
                device.KeyProtection);
            using var request = new HttpRequestMessage(HttpMethod.Post, settings.ServerUrl + DeviceRequestSigning.EnrollPath);
            request.Headers.TryAddWithoutValidation("X-Jazz-Enrollment-Code", settings.Code);
            request.Headers.TryAddWithoutValidation(EntraConsentTransport.ClientVersionHeader, _clientVersion);
            request.Headers.UserAgent.ParseAdd("JazzCapture/" + _clientVersion);
            request.Content = new StringContent(body, Encoding.UTF8, "application/json");
            using HttpResponseMessage response = await _http
                .SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken)
                .ConfigureAwait(false);
            if (response.StatusCode != HttpStatusCode.OK) return null;

            // The answer holds the first row key sealed to the wrapping key. Nothing uses a row key
            // yet, so it is not kept. The device is enrolled once the server answered 200.
            DeviceKeyRecord enrolled = device with { Enrolled = true };
            _keys.Save(enrolled);
            return enrolled;
        }
        catch (Exception exception) when (exception is HttpRequestException or IOException
            || (exception is TaskCanceledException && !cancellationToken.IsCancellationRequested))
        {
            return null;
        }
        finally
        {
            (signer as IDisposable)?.Dispose();
        }
    }

    /// <summary>Renews the Files token shortly before it ends. The upload path does not use this token yet.</summary>
    private async Task<DeviceKeyRecord> RenewIfDueAsync(
        SignedEnrollmentSettings settings, ConsentIdentity identity, DeviceKeyRecord device, CancellationToken cancellationToken)
    {
        if (device.FilesTokenId is null || device.FilesTokenExpiresAt is not { } ends || ends - _clock() > RenewBefore) return device;
        (HttpStatusCode? status, string? body, _) = await SendAsync(
            settings, device, identity, HttpMethod.Post, DeviceRequestSigning.RenewPath, null, null, cancellationToken, readBody: true)
            .ConfigureAwait(false);
        if (status != HttpStatusCode.OK || body is null) return device;
        try
        {
            using JsonDocument document = JsonDocument.Parse(body);
            if (!DevicePolicyDocument.TryReadToken(document.RootElement, out string id, out DateTimeOffset expires)) return device;
            DeviceKeyRecord renewed = device with { FilesTokenId = id, FilesTokenExpiresAt = expires };
            _keys.Save(renewed);
            return renewed;
        }
        catch (JsonException)
        {
            return device;
        }
    }

    private void RememberFilesToken(DeviceKeyRecord device, string policyJson)
    {
        // Only the id and the end are kept. The token goes with the policy and is not stored.
        if (!DevicePolicyDocument.TryReadFilesToken(policyJson, out string id, out DateTimeOffset expires)) return;
        _keys.Save(device with { FilesTokenId = id, FilesTokenExpiresAt = expires });
    }

    private async Task<(HttpStatusCode? Status, string? Body, string? ETag)> SendAsync(
        SignedEnrollmentSettings settings,
        DeviceKeyRecord device,
        ConsentIdentity identity,
        HttpMethod method,
        string path,
        string? ifNoneMatch,
        IReadOnlyDictionary<string, string>? fields,
        CancellationToken cancellationToken,
        bool readBody = false)
    {
        IDeviceSigner signer = _keys.OpenProofKey(device);
        try
        {
            SignedRequest signed = DeviceRequestSigning.Sign(
                signer,
                method.Method,
                path,
                device.DeviceId,
                DeviceRequestSigning.Timestamp(_clock()),
                DeviceRequestSigning.NewNonce(),
                identity.QualifiedUser,
                _hostName(),
                _clientVersion,
                device.FilesTokenId ?? string.Empty,
                ifNoneMatch,
                fields);
            using var request = new HttpRequestMessage(method, settings.ServerUrl + path);
            foreach ((string name, string value) in signed.Headers) request.Headers.TryAddWithoutValidation(name, value);
            request.Headers.UserAgent.ParseAdd("JazzCapture/" + _clientVersion);
            if (signed.Body is not null) request.Content = new StringContent(signed.Body, Encoding.UTF8, "application/json");

            using HttpResponseMessage response = await _http
                .SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken)
                .ConfigureAwait(false);
            if ((method != HttpMethod.Get && !readBody) || response.StatusCode != HttpStatusCode.OK)
                return (response.StatusCode, null, null);
            if (response.Content.Headers.ContentLength is > DevicePolicy.MaximumDocumentBytes) return (null, null, null);

            await using Stream stream = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
            using var bytes = new MemoryStream();
            byte[] buffer = new byte[8192];
            while (true)
            {
                int read = await stream.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
                if (read == 0) break;
                if (bytes.Length + read > DevicePolicy.MaximumDocumentBytes) return (null, null, null);
                bytes.Write(buffer, 0, read);
            }

            return (
                response.StatusCode,
                Encoding.UTF8.GetString(bytes.GetBuffer(), 0, (int)bytes.Length),
                response.Headers.ETag?.ToString());
        }
        catch (Exception exception) when (exception is HttpRequestException or IOException
            || (exception is TaskCanceledException && !cancellationToken.IsCancellationRequested))
        {
            return (null, null, null);
        }
        finally
        {
            (signer as IDisposable)?.Dispose();
        }
    }

    private static (string QualifiedUser, string? Sid) CurrentWindowsUser()
    {
        using WindowsIdentity identity = WindowsIdentity.GetCurrent();
        return (identity.Name, identity.User?.Value);
    }
}
