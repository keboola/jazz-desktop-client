using System.Net.Http;
using System.IO;
using JazzCaptureCore;

namespace JazzCapture;

/// <summary>Best-effort public release polling. It has no authority over local capture.</summary>
internal sealed class GitHubUpdateClient
{
    private static readonly Uri Releases = new("https://api.github.com/repos/keboola/jazz-desktop-client/releases");
    private static readonly TimeSpan Cadence = TimeSpan.FromHours(12);
    private readonly FirstRunStateStore _state;
    private readonly HttpClient _http;
    public GitHubUpdateClient(FirstRunStateStore state, HttpClient? http = null)
    {
        _state = state; _http = http ?? new HttpClient { Timeout = TimeSpan.FromSeconds(5) };
        _http.DefaultRequestHeaders.UserAgent.ParseAdd("JazzCapture/" + BuildIdentity.ProducerVersion);
    }
    public async Task<AvailableRelease?> CheckAsync(CancellationToken cancellationToken)
    {
        DateTimeOffset now = DateTimeOffset.UtcNow;
        if (!ReleaseAvailability.IsDue(_state.ReadUpdateAttempt(), now, Cadence)) return null;
        // Durably throttle before opening a socket; an interrupted request must not become a loop.
        _state.RecordUpdateAttempt(now);
        try
        {
            using HttpResponseMessage response = await _http.GetAsync(Releases, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
            if (!response.IsSuccessStatusCode || response.Content.Headers.ContentLength is > 1_048_576) return null;
            string body = await response.Content.ReadAsStringAsync(cancellationToken);
            return body.Length <= 1_048_576 && ReleaseAvailability.TryGetNewer(BuildIdentity.ProducerVersion, body, out AvailableRelease? release) ? release : null;
        }
        catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException or IOException) { return null; }
    }
}
