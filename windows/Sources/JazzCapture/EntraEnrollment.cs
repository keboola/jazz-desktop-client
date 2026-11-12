using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Security;
using System.Text;
using System.Text.Json;
using JazzCaptureCore;
using JazzCaptureCore.Enrollment;
using Microsoft.Identity.Client;
using Microsoft.Identity.Client.Broker;

namespace JazzCapture;

/// <summary>
/// Non-secret settings that point the client at the Jazz server and at the Jazz app registrations
/// in Microsoft Entra ID: the desktop client (<see cref="ClientId"/>) and the Jazz API it calls
/// (<see cref="ApiId"/>). Nothing here is a credential: the bundle is fetched with a token that
/// Windows issues for the signed-in user.
/// </summary>
public sealed record EntraEnrollmentSettings(string ServerUrl, string ClientId, string ApiId)
{
    public const string ScopeName = "Jazz.Device.Enroll";

    /// <summary>
    /// The scope of the Jazz API in GUID form (<c>{apiId}/scope</c>). The client and the API are two
    /// registrations: WAM accepts the tenant-wide admin consent only when an app does not ask for a
    /// token for itself, and refuses the <c>api://</c> form for such a self request (AADSTS90009).
    /// </summary>
    public string Scope => ApiId + "/" + ScopeName;

    public Uri StartUri => new(ServerUrl + "/device/entra/bundle/start");

    public Uri StatusUri(string jobId) => new(ServerUrl + "/device/entra/bundle/status/" + Uri.EscapeDataString(jobId));
}

public sealed record EntraEnrollmentRead(EntraEnrollmentSettings? Settings, string? Detail);

/// <summary>
/// Reads <c>EnrollmentServerUrl</c>, <c>EntraClientId</c> and <c>EntraApiId</c>: managed policy
/// (HKLM) first, then the HKCU preference, then the values built into the executable. The values
/// are read as one set from one location, so a policy cannot mix with a local preference or with
/// the built-in set.
/// </summary>
public sealed class EntraEnrollmentPolicyStore
{
    public const string ServerUrlValueName = "EnrollmentServerUrl";
    public const string ClientIdValueName = "EntraClientId";
    public const string ApiIdValueName = "EntraApiId";

    private readonly Func<string, string, string, string?> _read;
    private readonly (string Url, string ClientId, string ApiId) _builtIn;

    public EntraEnrollmentPolicyStore(
        Func<string, string, string, string?>? read = null,
        (string Url, string ClientId, string ApiId)? builtIn = null)
    {
        _read = read ?? CommandCenterUrlPolicyStore.DefaultRead;
        _builtIn = builtIn ?? (BuildIdentity.DefaultEnrollmentServerUrl, BuildIdentity.DefaultEntraClientId, BuildIdentity.DefaultEntraApiId);
    }

    public EntraEnrollmentRead Read()
    {
        EntraEnrollmentRead managed = ReadOne(CaptureAtLaunchPolicyStore.ManagedHive, CaptureAtLaunchPolicyStore.ManagedPolicyKey);
        if (managed.Settings is not null || managed.Detail is not null) return managed;
        EntraEnrollmentRead installer = ReadOne(CaptureAtLaunchPolicyStore.InstallerHive, CaptureAtLaunchPolicyStore.InstallerPreferenceKey);
        if (installer.Settings is not null || installer.Detail is not null) return installer;
        return Validate(_builtIn.Url, _builtIn.ClientId, _builtIn.ApiId, "built-in");
    }

    private EntraEnrollmentRead ReadOne(string hive, string key)
    {
        string? url;
        string? clientId;
        string? apiId;
        try
        {
            url = _read(hive, key, ServerUrlValueName);
            clientId = _read(hive, key, ClientIdValueName);
            apiId = _read(hive, key, ApiIdValueName);
        }
        catch (Exception ex) when (ex is SecurityException or UnauthorizedAccessException or IOException or ObjectDisposedException)
        {
            return new(null, FormattableString.Invariant($"{hive}\\{key} Entra enrollment settings could not be read ({ex.GetType().Name})."));
        }

        return Validate(url, clientId, apiId, FormattableString.Invariant($"{hive}\\{key}"));
    }

    private static EntraEnrollmentRead Validate(string? url, string? clientId, string? apiId, string source)
    {
        if (string.IsNullOrWhiteSpace(url) && string.IsNullOrWhiteSpace(clientId) && string.IsNullOrWhiteSpace(apiId)) return new(null, null);

        string? server = NormalizeServerUrl(url);
        if (server is null
            || !Guid.TryParseExact(clientId?.Trim(), "D", out Guid parsedClientId)
            || !Guid.TryParseExact(apiId?.Trim(), "D", out Guid parsedApiId))
        {
            return new(null, FormattableString.Invariant(
                $"{source} needs {ServerUrlValueName} (an https URL), {ClientIdValueName} and {ApiIdValueName} (GUIDs)."));
        }

        return new(new EntraEnrollmentSettings(
            server,
            parsedClientId.ToString("D", CultureInfo.InvariantCulture),
            parsedApiId.ToString("D", CultureInfo.InvariantCulture)), null);
    }

    internal static string? NormalizeServerUrl(string? raw)
    {
        string? value = CommandCenterUrl.TryNormalize(raw);
        if (value is null || value.Contains('?', StringComparison.Ordinal) || value.Contains('#', StringComparison.Ordinal)) return null;
        return value.TrimEnd('/');
    }
}

/// <summary>Gets an access token for the Jazz API without showing any window.</summary>
public interface IEntraTokenSource
{
    /// <returns>The token, or <see langword="null"/> when Windows cannot issue one silently.</returns>
    Task<string?> AcquireSilentAsync(EntraEnrollmentSettings settings, CancellationToken cancellationToken);

    /// <summary>Shows the Windows account dialog once, for example to collect a missing consent.</summary>
    /// <returns>The token, or <see langword="null"/> when the person closed the dialog.</returns>
    Task<string?> AcquireInteractiveAsync(EntraEnrollmentSettings settings, IntPtr parentWindow, CancellationToken cancellationToken);
}

/// <summary>
/// The Windows account broker (WAM). On an Entra-joined or hybrid-joined machine the primary
/// refresh token from the Windows sign-in gives the token without a prompt.
/// </summary>
public sealed class WamEntraTokenSource : IEntraTokenSource
{
    private readonly object _gate = new();
    private IPublicClientApplication? _app;
    private string? _appClientId;

    public async Task<string?> AcquireSilentAsync(EntraEnrollmentSettings settings, CancellationToken cancellationToken)
    {
        IPublicClientApplication app = Application(settings.ClientId);
        try
        {
            AuthenticationResult result = await app
                .AcquireTokenSilent([settings.Scope], PublicClientApplication.OperatingSystemAccount)
                .ExecuteAsync(cancellationToken)
                .ConfigureAwait(false);
            return result.AccessToken;
        }
        catch (MsalUiRequiredException)
        {
            return null;
        }
    }

    public async Task<string?> AcquireInteractiveAsync(EntraEnrollmentSettings settings, IntPtr parentWindow, CancellationToken cancellationToken)
    {
        try
        {
            AuthenticationResult result = await Application(settings.ClientId)
                .AcquireTokenInteractive([settings.Scope])
                .WithAccount(PublicClientApplication.OperatingSystemAccount)
                .WithParentActivityOrWindow(parentWindow)
                .ExecuteAsync(cancellationToken)
                .ConfigureAwait(false);
            return result.AccessToken;
        }
        catch (MsalClientException ex) when (ex.ErrorCode == MsalError.AuthenticationCanceledError)
        {
            return null;
        }
    }

    private IPublicClientApplication Application(string clientId)
    {
        lock (_gate)
        {
            if (_app is null || _appClientId != clientId)
            {
                _app = PublicClientApplicationBuilder.Create(clientId)
                    .WithAuthority(AadAuthorityAudience.AzureAdMultipleOrgs)
                    .WithBroker(new BrokerOptions(BrokerOptions.OperatingSystems.Windows))
                    .Build();
                _appClientId = clientId;
            }

            return _app;
        }
    }
}

public enum EntraBundleOutcome
{
    SignInRequired,
    Refused,
    Unavailable,
    Received,
}

/// <summary>A fetch result. <see cref="ToString"/> never prints the bundle, which holds secrets.</summary>
public sealed record EntraBundleResult(EntraBundleOutcome Outcome, string Reason, string? BundleJson = null)
{
    public override string ToString() => "EntraBundleResult(" + Outcome + ", " + Reason + ")";
}

/// <summary>
/// Starts the server's bundle job with the user's Entra token and polls it until the one-time
/// bundle arrives. The caller still verifies the bundle and its Storage token before storing it.
/// </summary>
public sealed class EntraBundleClient
{
    public const string EntraTokenHeader = "X-Jazz-Entra-Token";
    private const int MaximumResponseBytes = 64 * 1024;
    private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(2);
    private const int MaximumPolls = 90;
    private static readonly TimeSpan DefaultPollDeadline = TimeSpan.FromMinutes(3);
    private static readonly System.Text.RegularExpressions.Regex SafeCode = new("^[A-Z0-9_]{1,40}$");

    private readonly HttpClient _http;
    private readonly IEntraTokenSource _tokens;
    private readonly Func<TimeSpan, CancellationToken, Task> _delay;
    private readonly TimeSpan _pollDeadline;

    public EntraBundleClient(
        HttpClient http, IEntraTokenSource tokens, Func<TimeSpan, CancellationToken, Task>? delay = null, TimeSpan? pollDeadline = null)
    {
        _http = http;
        _tokens = tokens;
        _delay = delay ?? Task.Delay;
        _pollDeadline = pollDeadline ?? DefaultPollDeadline;
    }

    public static HttpClient CreateProductionClient() => new(new HttpClientHandler { AllowAutoRedirect = false }) { Timeout = TimeSpan.FromSeconds(30) };

    /// <param name="interactiveParent">A window handle to show the Windows account dialog instead
    /// of the silent call; <see langword="null"/> for the unattended path.</param>
    public async Task<EntraBundleResult> FetchAsync(
        EntraEnrollmentSettings settings, string hostName, CancellationToken cancellationToken, IntPtr? interactiveParent = null)
    {
        string? token;
        try
        {
            token = interactiveParent is { } parent
                ? await _tokens.AcquireInteractiveAsync(settings, parent, cancellationToken).ConfigureAwait(false)
                : await _tokens.AcquireSilentAsync(settings, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch (MsalException ex)
        {
            // The MSAL error code is not secret and is the one fact that makes this failure findable.
            return new(EntraBundleOutcome.Unavailable, "Windows could not get a work account token right now (" + ex.ErrorCode + ").");
        }
        catch (Exception ex) when (ex is HttpRequestException or OperationCanceledException)
        {
            return new(EntraBundleOutcome.Unavailable, "Windows could not get a work account token right now.");
        }

        if (token is null)
            return new(EntraBundleOutcome.SignInRequired, "Windows needs your confirmation: use \"Sign in with work account...\" in this menu.");

        // One overall deadline, so a slow server cannot hold the provisioning loop for the full
        // per-request timeout times the poll count.
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(_pollDeadline);
        try
        {
            string startBody = JsonSerializer.Serialize(new Dictionary<string, string> { ["hostName"] = hostName });
            (HttpStatusCode startStatus, JsonDocument? start) = await SendAsync(HttpMethod.Post, settings.StartUri, token, startBody, deadline.Token).ConfigureAwait(false);
            using (start)
            {
                if (startStatus != HttpStatusCode.OK)
                    return Failure(startStatus, start);
                if (start is null || !start.RootElement.TryGetProperty("jobId", out JsonElement job) || job.ValueKind != JsonValueKind.String || string.IsNullOrEmpty(job.GetString()))
                    return new(EntraBundleOutcome.Unavailable, "The Jazz server sent an unexpected answer.");
                return await PollAsync(settings, token, job.GetString()!, deadline.Token).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch (OperationCanceledException) when (deadline.IsCancellationRequested)
        {
            return new(EntraBundleOutcome.Unavailable, "The Jazz server did not finish the device bundle in time.");
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or JsonException or IOException or InvalidDataException)
        {
            return new(EntraBundleOutcome.Unavailable, "The Jazz server could not be reached.");
        }
    }

    private async Task<EntraBundleResult> PollAsync(EntraEnrollmentSettings settings, string token, string jobId, CancellationToken cancellationToken)
    {
        for (int poll = 0; poll < MaximumPolls; poll++)
        {
            await _delay(PollInterval, cancellationToken).ConfigureAwait(false);
            (HttpStatusCode status, JsonDocument? document) = await SendAsync(HttpMethod.Get, settings.StatusUri(jobId), token, null, cancellationToken).ConfigureAwait(false);
            using (document)
            {
                if (status != HttpStatusCode.OK) return Failure(status, document);
                JsonElement root = document?.RootElement ?? default;
                string? state = root.ValueKind == JsonValueKind.Object && root.TryGetProperty("status", out JsonElement s) && s.ValueKind == JsonValueKind.String ? s.GetString() : null;
                switch (state)
                {
                    case "running":
                        continue;
                    case "done" when root.TryGetProperty("bundle", out JsonElement bundle) && bundle.ValueKind == JsonValueKind.Object:
                        return new(EntraBundleOutcome.Received, "The Jazz server issued a device bundle.", bundle.GetRawText());
                    case "error":
                        return new(EntraBundleOutcome.Unavailable, "The Jazz server could not issue a device bundle.");
                    default:
                        return new(EntraBundleOutcome.Unavailable, "The Jazz server sent an unexpected answer.");
                }
            }
        }

        return new(EntraBundleOutcome.Unavailable, "The Jazz server did not finish the device bundle in time.");
    }

    private async Task<(HttpStatusCode Status, JsonDocument? Body)> SendAsync(
        HttpMethod method, Uri uri, string token, string? jsonBody, CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(method, uri);
        // The Data App proxy in front of the Jazz server does not pass Authorization to the app.
        request.Headers.TryAddWithoutValidation(EntraTokenHeader, token);
        request.Headers.UserAgent.ParseAdd("JazzCapture/" + BuildIdentity.ProducerVersion);
        if (jsonBody is not null) request.Content = new StringContent(jsonBody, Encoding.UTF8, "application/json");
        using HttpResponseMessage response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
        if (response.Content.Headers.ContentLength is > MaximumResponseBytes) throw new InvalidDataException("The response is too large.");
        await using Stream stream = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        byte[] bytes = await ReadBoundedAsync(stream, cancellationToken).ConfigureAwait(false);
        if (bytes.Length == 0) return (response.StatusCode, null);
        try
        {
            return (response.StatusCode, JsonDocument.Parse(bytes));
        }
        catch (JsonException) when (response.StatusCode != HttpStatusCode.OK)
        {
            // A proxy error page is not JSON. The status code still decides the result.
            return (response.StatusCode, null);
        }
    }

    private static EntraBundleResult Failure(HttpStatusCode status, JsonDocument? body)
    {
        string? code = body is not null
            && body.RootElement.ValueKind == JsonValueKind.Object
            && body.RootElement.TryGetProperty("detail", out JsonElement detail)
            && detail.ValueKind == JsonValueKind.Object
            && detail.TryGetProperty("code", out JsonElement c)
            && c.ValueKind == JsonValueKind.String ? c.GetString() : null;
        // The code comes from the server and goes into the tray text: accept only a plain error code.
        if (code is not null && !SafeCode.IsMatch(code)) code = null;
        return status switch
        {
            HttpStatusCode.Forbidden when code == "ENTRA_TENANT_NOT_ALLOWED" =>
                new(EntraBundleOutcome.Refused, "Your organization is not enabled for Jazz."),
            HttpStatusCode.Conflict when code == "DEVICE_REVOKED" =>
                new(EntraBundleOutcome.Refused, "An administrator revoked this device."),
            HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden or HttpStatusCode.Conflict or HttpStatusCode.NotFound or HttpStatusCode.UnprocessableEntity or HttpStatusCode.NotImplemented =>
                new(EntraBundleOutcome.Refused, "The Jazz server refused the device bundle request (" + (code ?? ((int)status).ToString(CultureInfo.InvariantCulture)) + ")."),
            _ => new(EntraBundleOutcome.Unavailable, "The Jazz server is not available right now."),
        };
    }

    private static async Task<byte[]> ReadBoundedAsync(Stream stream, CancellationToken cancellationToken)
    {
        using var output = new MemoryStream();
        byte[] buffer = new byte[8192];
        while (true)
        {
            int read = await stream.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
            if (read == 0) return output.ToArray();
            if (output.Length + read > MaximumResponseBytes) throw new InvalidDataException("The response is too large.");
            output.Write(buffer, 0, read);
        }
    }
}

/// <summary>When to ask the server for a new bundle.</summary>
public static class EntraBundleSchedule
{
    /// <summary>A bundle whose credential ends within this window is replaced before it ends.</summary>
    public static readonly TimeSpan RefreshBefore = TimeSpan.FromMinutes(15);

    public static bool NeedsBundle(DeviceBundle? current, DateTimeOffset now)
        => current is null
            || Timestamps.TryParseRfc3339(current.ExpiresAt) is not { } expiry
            || expiry - now <= RefreshBefore;

    /// <summary>Wait after a failed attempt. A missing sign-in or a refusal does not change by itself soon.</summary>
    public static TimeSpan RetryAfter(EntraBundleOutcome outcome, int failures) => outcome switch
    {
        EntraBundleOutcome.SignInRequired or EntraBundleOutcome.Refused => TimeSpan.FromMinutes(15),
        _ => TimeSpan.FromSeconds(Math.Min(300, 15 << Math.Min(5, Math.Max(0, failures)))),
    };
}
