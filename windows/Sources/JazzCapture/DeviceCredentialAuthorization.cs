using System.Text.Json;
using System.Net.Http;
using System.Net;
using System.IO;
using System.Globalization;
using JazzCaptureCore;
using JazzCaptureCore.Enrollment;

namespace JazzCapture;

/// <summary>Strict, non-secret projection of Storage's token verification response.</summary>
public sealed record VerifiedDeviceToken(
    string TokenId, string ProjectId, string StackUrl, string ExpiresAt,
    bool? IsMasterToken, bool? IsDisabled, bool? IsExpired,
    bool? CanManageBuckets, bool? CanManageTokens, bool? CanReadAllFileUploads,
    IReadOnlyDictionary<string, string>? BucketPermissions, bool HasAdmin);

public interface IDeviceTokenVerifier
{
    Task<VerifiedDeviceToken> VerifyAsync(DeviceBundle bundle, CancellationToken cancellationToken);
}

/// <summary>Storage API verifier; exceptions intentionally contain no request URL or credential.</summary>
public sealed class KeboolaDeviceTokenVerifier : IDeviceTokenVerifier
{
    private const long MaximumResponseBytes = 64 * 1024;
    private readonly HttpClient client;
    public KeboolaDeviceTokenVerifier(HttpClient client) => this.client = client;
    internal static HttpClientHandler CreateProductionHandler() => new() { AllowAutoRedirect = false };
    public static HttpClient CreateProductionClient() => new(CreateProductionHandler());

    public async Task<VerifiedDeviceToken> VerifyAsync(DeviceBundle bundle, CancellationToken cancellationToken)
    {
        string stack = bundle.NormalizedStackUrl ?? throw new DeviceBundleException(DeviceBundleError.InvalidRouting);
        try
        {
            if (!DeviceBundleParser.IsValidStorageToken(bundle.Token)) throw new DeviceBundleException(DeviceBundleError.InvalidCredential);
            using var request = new HttpRequestMessage(HttpMethod.Get, stack + "/v2/storage/tokens/verify");
            if (!request.Headers.TryAddWithoutValidation("X-StorageApi-Token", bundle.Token))
                throw new DeviceBundleException(DeviceBundleError.InvalidCredential);
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromSeconds(30));
            using HttpResponseMessage response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
                throw new DeviceBundleException(response.StatusCode is HttpStatusCode.BadRequest or HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden
                    ? DeviceBundleError.InvalidCredential : DeviceBundleError.VerificationUnavailable);
            if (response.Content.Headers.ContentLength is > MaximumResponseBytes) throw new DeviceBundleException(DeviceBundleError.InvalidCredential);
            await using Stream stream = await response.Content.ReadAsStreamAsync(timeout.Token).ConfigureAwait(false);
            byte[] bytes = await ReadBoundedAsync(stream, timeout.Token).ConfigureAwait(false);
            VerifyWire? value = JsonSerializer.Deserialize<VerifyWire>(bytes,
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
            return value?.ToVerified(stack) ?? throw new DeviceBundleException(DeviceBundleError.InvalidCredential);
        }
        catch (DeviceBundleException) { throw; }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or JsonException or IOException or ArgumentException or FormatException)
        { throw new DeviceBundleException(DeviceBundleError.VerificationUnavailable); }
    }

    private static async Task<byte[]> ReadBoundedAsync(Stream stream, CancellationToken cancellationToken)
    {
        using var output = new MemoryStream();
        byte[] buffer = new byte[8192];
        while (true)
        {
            int read = await stream.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
            if (read == 0) return output.ToArray();
            if (output.Length + read > MaximumResponseBytes) throw new DeviceBundleException(DeviceBundleError.InvalidCredential);
            output.Write(buffer, 0, read);
        }
    }

    private sealed class VerifyWire
    {
        public string? Id { get; init; }
        public OwnerWire? Owner { get; init; }
        public string? Expires { get; init; }
        public bool? IsMasterToken { get; init; }
        public bool? IsDisabled { get; init; }
        public bool? IsExpired { get; init; }
        public bool? CanManageBuckets { get; init; }
        public bool? CanManageTokens { get; init; }
        public bool? CanReadAllFileUploads { get; init; }
        public Dictionary<string, string>? BucketPermissions { get; init; }
        public JsonElement? Admin { get; init; }
        public VerifiedDeviceToken ToVerified(string stack) => new(Id ?? "", Owner?.Id?.ToString(CultureInfo.InvariantCulture) ?? "", stack, Expires ?? "", IsMasterToken, IsDisabled, IsExpired, CanManageBuckets, CanManageTokens, CanReadAllFileUploads, BucketPermissions, Admin is not null && Admin.Value.ValueKind != JsonValueKind.Null);
    }
    private sealed class OwnerWire { public long? Id { get; init; } }
}

public static class DeviceCredentialAuthorizer
{
    public static async Task<DeviceBundle> AuthorizeAsync(string text, IDeviceTokenVerifier verifier, DateTimeOffset now, CancellationToken cancellationToken)
    {
        DeviceBundle bundle = DeviceBundleParser.ParseMvp(text, now);
        VerifiedDeviceToken verified = await verifier.VerifyAsync(bundle, cancellationToken).ConfigureAwait(false);
        // tokens/verify includes an `admin` object for the creating user on almost every token.
        // That is not "this is a master/admin token". Only isMasterToken is authority.
        if (verified.IsMasterToken == true)
            throw new DeviceBundleException(DeviceBundleError.MasterToken);
        if (verified.IsExpired == true)
            throw new DeviceBundleException(DeviceBundleError.Expired);
        DateTimeOffset? verifiedLifetime = Timestamps.TryParseRfc3339(verified.ExpiresAt);
        if (verifiedLifetime is { } verifiedExpiry && verifiedExpiry <= now)
            throw new DeviceBundleException(DeviceBundleError.Expired);
        if (verified.TokenId != bundle.TokenId) throw new DeviceBundleException(DeviceBundleError.TokenIdMismatch);
        // Storage UI "Expires never" is a missing/empty expires field. That is not a mismatch
        // against the bundle's required expiresAt; only a *present* Storage expiry must match.
        if (verifiedLifetime is not null
            && verifiedLifetime != Timestamps.TryParseRfc3339(bundle.ExpiresAt))
            throw new DeviceBundleException(DeviceBundleError.ExpiryMismatch);
        if (verified.ProjectId != bundle.ProjectId || verified.StackUrl != bundle.NormalizedStackUrl)
            throw new DeviceBundleException(DeviceBundleError.ProjectMismatch);
        // Master / admin / manage-tokens stay refused. A Jazz Storage Token used for fleet MVP
        // typically has Components & Buckets and Files (canManageBuckets / canReadAllFileUploads);
        // those are accepted here so the same company token can be dropped on every PC.
        if (verified.IsDisabled == true || verified.CanManageTokens == true)
            throw new DeviceBundleException(DeviceBundleError.PrivilegedToken);
        if (!HasUsableBucketScope(bundle, verified))
            throw new DeviceBundleException(DeviceBundleError.BucketScopeMismatch);
        // Claims are retained only after the live authority agrees; callers route from this
        // verified stack/project tuple rather than trusting a free-form bundle claim.
        return bundle with { StackUrl = verified.StackUrl, ProjectId = verified.ProjectId };
    }

    private static bool HasUsableBucketScope(DeviceBundle bundle, VerifiedDeviceToken verified)
    {
        if (verified.CanManageBuckets == true || verified.CanReadAllFileUploads == true)
        {
            return true;
        }

        IReadOnlyDictionary<string, string>? actual = verified.BucketPermissions;
        if (actual is null)
        {
            return false;
        }

        return bundle.TokenBucketScope == JazzArchiveTokenBucketScope.None
            ? actual.Count == 0
            : bundle.SinkBucketId is { } sink
                && actual.TryGetValue(sink, out string? permission)
                && permission == "write";
    }
}
