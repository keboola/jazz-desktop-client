using System.Net.Http;
using System.Text;
using JazzCaptureCore;

namespace JazzCapture;

/// <summary>Small legacy OTLP sender for the unsigned-MVP qualification slice. The endpoint is a
/// capability URL, so failures are intentionally reduced to safe state text.</summary>
public sealed class MvpStreamSender
{
    private readonly HttpClient client;
    private readonly Uri logsEndpoint;
    public MvpStreamSender(string streamEndpoint, HttpClient client)
    {
        if (!Uri.TryCreate(streamEndpoint.TrimEnd('/') + "/v1/logs", UriKind.Absolute, out Uri? endpoint)) throw new ArgumentException("Invalid stream endpoint.", nameof(streamEndpoint));
        logsEndpoint = endpoint;
        this.client = client;
    }

    public async Task<StreamDeliveryStatus> SendAsync(ActivityEvent activityEvent, SessionContext context, CancellationToken cancellationToken)
    {
        try
        {
            byte[] body = Encoding.UTF8.GetBytes(OtlpMapper.LogsRequest(new[] { activityEvent }, context).ToJsonString());
            try
            {
                using var request = new HttpRequestMessage(HttpMethod.Post, logsEndpoint) { Content = new ByteArrayContent(body) };
                request.Content.Headers.ContentType = new("application/json");
                // Deliberately no Authorization header: the capability is the stream URL path.
                using var response = await client.SendAsync(request, cancellationToken).ConfigureAwait(false);
                return response.IsSuccessStatusCode ? StreamDeliveryStatus.Streaming : StreamDeliveryStatus.Unreachable;
            }
            finally { System.Security.Cryptography.CryptographicOperations.ZeroMemory(body); }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch { return StreamDeliveryStatus.Unreachable; }
    }
}

public enum StreamDeliveryStatus { NotProvisioned, Streaming, Unreachable }
