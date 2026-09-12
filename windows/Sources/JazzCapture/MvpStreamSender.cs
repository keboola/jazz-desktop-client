using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Runtime.InteropServices;
using JazzCaptureCore;
using JazzCaptureCore.Enrollment;

namespace JazzCapture;

/// <summary>
/// Outcome of one classified <c>/v1/logs</c> send attempt, replacing the old two-valued
/// <c>StreamDeliveryStatus</c>. Mirrors the classification <c>KeboolaFilesClient</c> already applies
/// to its own prepare and upload calls (<c>KeboolaFilesClient.cs</c>'s own remarks).
/// </summary>
/// <remarks>
/// | Response | Outcome | Rationale |
/// | --- | --- | --- |
/// | 2xx | <see cref="Acknowledged"/> | |
/// | 400, 422 | <see cref="Dropped"/> | The body is the problem; identical bytes will never be accepted. |
/// | 3xx | <see cref="Retry"/> | <c>RedirectSafeHttpClient</c> never follows a redirect, so a 3xx is a misconfiguration, not a bad body. |
/// | 401, 403 | <see cref="Unauthorized"/> | Not the body's fault -- but not an ordinary retry either. See this member's own remarks for why this is a deliberate correction of the plan's original §2.5 table, which classified these as <see cref="Retry"/>. |
/// | 408, 429, 5xx | <see cref="Retry"/> | |
/// | transport exception, call budget elapsed | <see cref="Retry"/> | |
/// </remarks>
public enum EventSendOutcome
{
    /// <summary>2xx: the caller may delete the spooled entry.</summary>
    Acknowledged,

    /// <summary>Worth another attempt later.</summary>
    Retry,

    /// <summary>Terminal: the caller must delete the spooled entry and count it abandoned.</summary>
    Dropped,

    /// <summary>
    /// 401 or 403: the sink itself has rejected the capability URL. <b>Deliberate correction to the
    /// #48 plan's §2.5</b> (PR review finding, adopted as a ruling): the plan originally classified
    /// 401/403 as <see cref="Retry"/>, reasoning "a revoked capability URL 403s forever and ages out
    /// through the spool's own retention bound" -- but issue #48's own acceptance criterion, listed
    /// as in force by the plan's own §1.6, is "revocation/expiry stops networking without deleting
    /// evidence". Retrying a revoked endpoint every few minutes for up to 48 hours is still
    /// networking, not stopping, so treating it the same as an ordinary transient failure was wrong.
    /// The spooled entry is left exactly as untouched as any other <see cref="Retry"/> (no deletion,
    /// no eviction, the retention bound is still the only backstop) -- what differs is that
    /// <see cref="EventDeliveryWorker"/> treats this as "the credential is no good", not "this one
    /// send failed", and stops attempting any further send through this worker instance entirely
    /// until <c>App.RefreshDeliveryTarget</c> -- the existing seam that already reacts to a real
    /// provisioning change -- discards it for a freshly constructed one. See that type's own remarks
    /// for exactly how sending is halted.
    /// </summary>
    Unauthorized,
}

/// <summary>Small legacy OTLP sender for the unsigned-MVP qualification slice. The endpoint is a
/// capability URL, so failures are intentionally reduced to safe state text.</summary>
public sealed class MvpStreamSender
{
    private readonly RedirectSafeHttpClient client;
    private readonly Uri logsEndpoint;

    public MvpStreamSender(string streamEndpoint, RedirectSafeHttpClient client)
    {
        if (!Uri.TryCreate(streamEndpoint.TrimEnd('/') + "/v1/logs", UriKind.Absolute, out Uri? endpoint)) throw new ArgumentException("Invalid stream endpoint.", nameof(streamEndpoint));
        logsEndpoint = endpoint;
        this.client = client;
    }

    /// <summary>
    /// POSTs one already-serialized <c>/v1/logs</c> request body under <paramref name="settings"/>'s
    /// <see cref="EventDeliverySettings.SendCallBudget"/>, classifying the outcome per this type's
    /// own remarks. The caller owns <paramref name="body"/> and is responsible for zeroing it once
    /// this call returns -- the previous <c>SendAsync(ActivityEvent, ...)</c> overload zeroed its own
    /// locally-constructed buffer, but body construction has moved to the capture path
    /// (<c>App.SendCapturedEventAsync</c>, which spools it) and the drain worker (which reads it back
    /// from the spool), each of which owns its own buffer's whole lifetime.
    /// </summary>
    public async Task<EventSendOutcome> SendBodyAsync(
        ReadOnlyMemory<byte> body,
        EventDeliverySettings settings,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(settings);

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(settings.SendCallBudget);
        try
        {
            byte[] bytes = MemoryMarshal.TryGetArray(body, out ArraySegment<byte> segment)
                && segment.Offset == 0
                && segment.Array is { } array
                && segment.Count == array.Length
                    ? array
                    : body.ToArray();

            using var request = new HttpRequestMessage(HttpMethod.Post, logsEndpoint)
            {
                Content = new ByteArrayContent(bytes),
            };
            request.Content.Headers.ContentType = new("application/json");
            // Deliberately no Authorization header: the capability is the stream URL path.
            // HttpCompletionOption.ResponseHeadersRead is deliberately not used here, unlike
            // KeboolaFilesClient's calls: this classification only ever inspects the status code and
            // never reads the response body, and one POST per observation means this runs at click
            // and keystroke cadence -- leaving the (small, OTLP-acknowledgement-shaped) body
            // undrained on every call would generally prevent the underlying connection from
            // returning to the pool, forcing a fresh TCP/TLS handshake per event. The default
            // completion option reads the whole response, including its body, before returning.
            using HttpResponseMessage response = await client
                .SendAsync(request, HttpCompletionOption.ResponseContentRead, timeout.Token)
                .ConfigureAwait(false);

            if (response.IsSuccessStatusCode)
            {
                return EventSendOutcome.Acknowledged;
            }

            if (response.StatusCode is HttpStatusCode.BadRequest or HttpStatusCode.UnprocessableEntity)
            {
                return EventSendOutcome.Dropped;
            }

            // See EventSendOutcome.Unauthorized's own remarks: this is a deliberate correction of the
            // #48 plan's original §2.5 table, which classified 401/403 as an ordinary Retry.
            return response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden
                ? EventSendOutcome.Unauthorized
                : EventSendOutcome.Retry;
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            // The send call budget elapsed, not the caller: retryable, not an exception.
            return EventSendOutcome.Retry;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (HttpRequestException)
        {
            return EventSendOutcome.Retry;
        }
        catch (IOException)
        {
            return EventSendOutcome.Retry;
        }
    }
}

/// <summary>Credential gate kept separate from the UI so an expired protected value can never
/// reach an HTTP sender.</summary>
internal static class MvpDeliveryPolicy
{
    /// <summary>
    /// Returns <see cref="EventSendOutcome.Retry"/> without ever invoking <paramref name="send"/>
    /// when there is no usable credential -- matching <c>DeliverEventAsync</c>'s own choice to
    /// return <c>Retry</c> rather than a distinct "not provisioned" value, so the caller leaves the
    /// entry spooled either way.
    /// </summary>
    internal static Task<EventSendOutcome> DeliverIfActiveAsync(
        DeviceBundle? credential,
        DateTimeOffset now,
        Func<DeviceBundle, Task<EventSendOutcome>> send)
    {
        if (credential?.StreamEndpoint is null || Timestamps.TryParseRfc3339(credential.ExpiresAt) is not { } expiry || expiry <= now)
            return Task.FromResult(EventSendOutcome.Retry);
        return send(credential);
    }
}
/// <summary>Live sender plus the expiry that decides whether it may still be used, and the device
/// bundle screenshot delivery needs for its Storage token and stack routing.</summary>
/// <remarks>
/// A positional record's compiler-generated <c>ToString()</c> prints every member by calling
/// <c>ToString()</c> on each; <see cref="Sender"/> holds the stream endpoint URI -- the OTLP
/// capability secret -- in a private field, and <see cref="Bundle"/> holds the plaintext Keboola
/// Storage token. <see cref="MvpStreamSender"/> is a plain class with no <c>ToString()</c> override
/// today, so the default object identity string is all that would print right now, but that is an
/// accident of the current implementation, not a guarantee: nothing stops a future debugging aid
/// from adding one that surfaces the endpoint. <see cref="DeviceBundle"/> already overrides
/// <c>ToString()</c> to a fixed, non-secret shape, but this record must not depend on that -- it
/// still must not call <see cref="Bundle"/>'s <c>ToString()</c> (or anything else's) from its own.
/// Overriding <c>ToString()</c> here removes the accident and keeps this record's text safe
/// regardless of what either member does later.
/// </remarks>
internal sealed record MvpDeliveryTarget(MvpStreamSender Sender, DateTimeOffset ExpiresAt, DeviceBundle Bundle)
{
    public override string ToString() =>
        string.Format(CultureInfo.InvariantCulture, "MvpDeliveryTarget({0:O})", ExpiresAt);
}
