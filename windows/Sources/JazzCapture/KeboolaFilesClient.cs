using System.Net;
using System.Net.Http;
using System.IO;
using System.Text;
using System.Text.Json;
using JazzCaptureCore.Delivery;
using JazzCaptureCore.Enrollment;

namespace JazzCapture;

/// <summary>Strict two-step legacy Files API transport.  It exposes only safe outcome categories;
/// neither a capability URL nor a Storage token can escape through an exception or status string.</summary>
public sealed class KeboolaFilesClient
{
    private const long MaximumPrepareResponseBytes = 64 * 1024;
    private readonly HttpClient client;
    private readonly Uri prepareEndpoint;
    private readonly string token;

    public KeboolaFilesClient(DeviceBundle credential, HttpClient client)
    {
        ArgumentNullException.ThrowIfNull(credential);
        ArgumentNullException.ThrowIfNull(client);
        string stack = credential.NormalizedStackUrl ?? throw new ArgumentException("Invalid Storage routing.", nameof(credential));
        if (!DeviceBundleParser.IsValidStorageToken(credential.Token)) throw new ArgumentException("Invalid Storage credential.", nameof(credential));
        prepareEndpoint = new Uri(stack + "/v2/storage/files", UriKind.Absolute);
        token = credential.Token;
        this.client = client;
    }

    public async Task<FilesDeliveryOutcome> UploadAsync(ArtifactDeliveryRecord record, byte[] bytes, CancellationToken cancellationToken)
    {
        if (bytes.LongLength != record.ByteLength) return FilesDeliveryOutcome.Quarantined;
        try
        {
            Uri? upload = await PrepareAsync(record, cancellationToken).ConfigureAwait(false);
            if (upload is null) return FilesDeliveryOutcome.Retry;
            using var request = new HttpRequestMessage(HttpMethod.Put, upload) { Content = new ByteArrayContent(bytes) };
            request.Content.Headers.ContentType = new(record.MediaType);
            using HttpResponseMessage response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
            return response.IsSuccessStatusCode ? FilesDeliveryOutcome.Acknowledged :
                response.StatusCode is HttpStatusCode.BadRequest or HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden ? FilesDeliveryOutcome.Quarantined : FilesDeliveryOutcome.Retry;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch { return FilesDeliveryOutcome.Retry; }
    }

    private async Task<Uri?> PrepareAsync(ArtifactDeliveryRecord record, CancellationToken cancellationToken)
    {
        byte[] payload = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new { name = record.ArtifactId, contentType = record.MediaType, tags = new[] { "jazz", "screenshot", record.ScreenshotId ?? record.ArtifactId } }));
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Post, prepareEndpoint) { Content = new ByteArrayContent(payload) };
            request.Content.Headers.ContentType = new("application/json");
            if (!request.Headers.TryAddWithoutValidation("X-StorageApi-Token", token)) return null;
            using HttpResponseMessage response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode || response.Content.Headers.ContentLength is > MaximumPrepareResponseBytes) return null;
            await using Stream body = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
            byte[] result = await ReadBoundedAsync(body, cancellationToken).ConfigureAwait(false);
            using JsonDocument document = JsonDocument.Parse(result);
            if (!document.RootElement.TryGetProperty("uploadUrl", out JsonElement value) || value.ValueKind != JsonValueKind.String) return null;
            string? url = value.GetString();
            return Uri.TryCreate(url, UriKind.Absolute, out Uri? parsed) && (parsed.Scheme == Uri.UriSchemeHttps || parsed.IsLoopback) && string.IsNullOrEmpty(parsed.UserInfo) ? parsed : null;
        }
        finally { System.Security.Cryptography.CryptographicOperations.ZeroMemory(payload); }
    }

    private static async Task<byte[]> ReadBoundedAsync(Stream stream, CancellationToken cancellationToken)
    {
        using var output = new MemoryStream(); byte[] buffer = new byte[8192];
        while (true) { int read = await stream.ReadAsync(buffer, cancellationToken).ConfigureAwait(false); if (read == 0) return output.ToArray(); if (output.Length + read > MaximumPrepareResponseBytes) throw new InvalidDataException(); output.Write(buffer, 0, read); }
    }
}

public enum FilesDeliveryOutcome { Acknowledged, Retry, Quarantined }
