using System.Text.Json;
using System.Net.Http;
using System.IO;
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

    public async Task<VerifiedDeviceToken> VerifyAsync(DeviceBundle bundle, CancellationToken cancellationToken)
    {
        string stack = bundle.NormalizedStackUrl ?? throw new DeviceBundleException(DeviceBundleError.InvalidRouting);
        using var request = new HttpRequestMessage(HttpMethod.Get, stack + "/v2/storage/tokens/verify");
        request.Headers.Add("X-StorageApi-Token", bundle.Token);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(30));
        try
        {
            using HttpResponseMessage response = await client.SendAsync(request, timeout.Token).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode) throw new DeviceBundleException(DeviceBundleError.InvalidCredential);
            if (response.Content.Headers.ContentLength is > MaximumResponseBytes) throw new DeviceBundleException(DeviceBundleError.InvalidCredential);
            await using Stream stream = await response.Content.ReadAsStreamAsync(timeout.Token).ConfigureAwait(false);
            VerifyWire? value = await JsonSerializer.DeserializeAsync<VerifyWire>(stream,
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true }, timeout.Token).ConfigureAwait(false);
            return value?.ToVerified(stack) ?? throw new DeviceBundleException(DeviceBundleError.InvalidCredential);
        }
        catch (DeviceBundleException) { throw; }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or JsonException)
        { throw new DeviceBundleException(DeviceBundleError.VerificationUnavailable); }
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
        public VerifiedDeviceToken ToVerified(string stack) => new(Id ?? "", Owner?.Id.ToString() ?? "", stack, Expires ?? "", IsMasterToken, IsDisabled, IsExpired, CanManageBuckets, CanManageTokens, CanReadAllFileUploads, BucketPermissions, Admin is not null && Admin.Value.ValueKind != JsonValueKind.Null);
    }
    private sealed class OwnerWire { public long? Id { get; init; } }
}

public static class DeviceCredentialAuthorizer
{
    public static async Task<DeviceBundle> AuthorizeAsync(string text, IDeviceTokenVerifier verifier, DateTimeOffset now, CancellationToken cancellationToken)
    {
        DeviceBundle bundle = DeviceBundleParser.Parse(text, now);
        VerifiedDeviceToken verified = await verifier.VerifyAsync(bundle, cancellationToken).ConfigureAwait(false);
        if (verified.TokenId != bundle.TokenId || verified.ProjectId != bundle.ProjectId || verified.StackUrl != bundle.NormalizedStackUrl
            || Timestamps.TryParseRfc3339(verified.ExpiresAt) != Timestamps.TryParseRfc3339(bundle.ExpiresAt)
            || Timestamps.TryParseRfc3339(bundle.ExpiresAt) <= now
            || verified.IsMasterToken != false || verified.HasAdmin || verified.IsDisabled != false || verified.IsExpired != false
            || verified.CanManageBuckets != false || verified.CanManageTokens != false || verified.CanReadAllFileUploads != false
            || !HasExactBucketScope(bundle, verified.BucketPermissions))
            throw new DeviceBundleException(DeviceBundleError.InvalidCredential);
        return bundle;
    }

    private static bool HasExactBucketScope(DeviceBundle bundle, IReadOnlyDictionary<string, string>? actual) => actual is not null &&
        (bundle.TokenBucketScope == JazzArchiveTokenBucketScope.None
            ? actual.Count == 0
            : bundle.SinkBucketId is { } sink && actual.Count == 1 && actual.TryGetValue(sink, out string? permission) && permission == "write");
}
