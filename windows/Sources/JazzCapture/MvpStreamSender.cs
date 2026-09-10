using System.Net.Http;
using System.Text;
using System.Threading.Channels;
using JazzCaptureCore;
using JazzCaptureCore.Enrollment;

namespace JazzCapture;

/// <summary>Small legacy OTLP sender for the unsigned-MVP qualification slice. The endpoint is a
/// capability URL, so failures are intentionally reduced to safe state text.</summary>
public sealed class MvpStreamSender : IScreenshotStreamTransport
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

    /// <summary>Sends a previously durable OTLP body unchanged; used after Files correlation.</summary>
    public async Task<StreamDeliveryStatus> SendExactAsync(byte[] body, CancellationToken cancellationToken)
    {
        try { using var request = new HttpRequestMessage(HttpMethod.Post, logsEndpoint) { Content = new ByteArrayContent(body) }; request.Content.Headers.ContentType = new("application/json"); using var response = await client.SendAsync(request, cancellationToken).ConfigureAwait(false); return response.IsSuccessStatusCode ? StreamDeliveryStatus.Streaming : StreamDeliveryStatus.Unreachable; }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; } catch { return StreamDeliveryStatus.Unreachable; }
    }
}

public enum StreamDeliveryStatus { Waiting, Backpressure, NotProvisioned, Streaming, Unreachable }

/// <summary>Credential gate kept separate from the UI so an expired protected value can never
/// reach an HTTP sender.</summary>
internal static class MvpDeliveryPolicy
{
    internal static Task<StreamDeliveryStatus> DeliverIfActiveAsync(DeviceBundle? credential, DateTimeOffset now, Func<DeviceBundle, Task<StreamDeliveryStatus>> send)
    {
        if (credential?.StreamEndpoint is null || Timestamps.TryParseRfc3339(credential.ExpiresAt) is not { } expiry || expiry <= now)
            return Task.FromResult(StreamDeliveryStatus.NotProvisioned);
        return send(credential);
    }
}
internal sealed record MvpDeliveryTarget(MvpStreamSender Sender, DateTimeOffset ExpiresAt, DeviceBundle Bundle);

/// <summary>Bounded, ordered, non-durable delivery attachment for #65. It deliberately drops
/// under pressure rather than blocking capture; #48 replaces this with the durable spool.</summary>
public sealed class MvpStreamDispatcher : IAsyncDisposable
{
    // Wait is chosen solely because TryWrite then returns false at capacity. We never call
    // WriteAsync, so producer admission remains non-blocking and drops explicitly.
    private readonly Channel<(ActivityEvent Event, SessionContext Context)> queue = Channel.CreateBounded<(ActivityEvent, SessionContext)>(new BoundedChannelOptions(64) { FullMode = BoundedChannelFullMode.Wait, SingleReader = true });
    private readonly CancellationTokenSource shutdown = new();
    private readonly Func<ActivityEvent, SessionContext, CancellationToken, Task<StreamDeliveryStatus>> deliver;
    private readonly Action<StreamDeliveryStatus> status;
    private readonly Task worker;
    private int lastStatus = -1;
    public MvpStreamDispatcher(Func<ActivityEvent, SessionContext, CancellationToken, Task<StreamDeliveryStatus>> deliver, Action<StreamDeliveryStatus> status)
    { this.deliver = deliver; this.status = status; worker = Task.Run(DrainAsync); }
    public void Enqueue(ActivityEvent activityEvent, SessionContext context)
    { if (!queue.Writer.TryWrite((activityEvent, context))) SafeStatus(StreamDeliveryStatus.Backpressure); }
    private async Task DrainAsync()
    {
        try { await foreach (var item in queue.Reader.ReadAllAsync(shutdown.Token).ConfigureAwait(false))
            { StreamDeliveryStatus result; try { result = await deliver(item.Event, item.Context, shutdown.Token).ConfigureAwait(false); } catch (OperationCanceledException) when (shutdown.IsCancellationRequested) { break; } catch { result = StreamDeliveryStatus.Unreachable; } SafeStatus(result); } }
        catch (OperationCanceledException) when (shutdown.IsCancellationRequested) { }
    }
    public async ValueTask DisposeAsync()
    { queue.Writer.TryComplete(); shutdown.Cancel(); try { await worker.ConfigureAwait(false); } catch (OperationCanceledException) { } shutdown.Dispose(); }
    private void SafeStatus(StreamDeliveryStatus value)
    {
        if (Interlocked.Exchange(ref lastStatus, (int)value) == (int)value) return;
        try { status(value); } catch { }
    }
}
