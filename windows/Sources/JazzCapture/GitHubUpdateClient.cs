using System.Net.Http;
using System.IO;
using JazzCaptureCore;

namespace JazzCapture;

/// <summary>Best-effort public release polling. It has no authority over local capture.</summary>
internal sealed class GitHubUpdateClient : IDisposable
{
    private static readonly Uri Releases = new("https://api.github.com/repos/keboola/jazz-desktop-client/releases");
    private static readonly TimeSpan Cadence = TimeSpan.FromHours(12);
    private readonly FirstRunStateStore _state;
    private readonly HttpClient _http;
    private readonly Func<DateTimeOffset> _clock;
    private readonly TimeSpan _cadence;
    private readonly bool _ownsHttp;

    public GitHubUpdateClient(
        FirstRunStateStore state,
        HttpClient? http = null,
        Func<DateTimeOffset>? clock = null,
        TimeSpan? cadence = null)
    {
        _state = state;
        _ownsHttp = http is null;
        _http = http ?? new HttpClient { Timeout = TimeSpan.FromSeconds(5) };
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
        _cadence = cadence ?? Cadence;
        _http.DefaultRequestHeaders.UserAgent.ParseAdd("JazzCapture/" + BuildIdentity.ProducerVersion);
    }
    public async Task<AvailableRelease?> CheckAsync(CancellationToken cancellationToken)
    {
        DateTimeOffset now = _clock();
        if (!ReleaseAvailability.IsDue(_state.ReadUpdateAttempt(), now, _cadence)) return null;
        // Durably throttle before opening a socket; an interrupted request must not become a loop.
        try { _state.RecordUpdateAttempt(now); }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }
        try
        {
            using HttpResponseMessage response = await _http.GetAsync(Releases, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
            if (!response.IsSuccessStatusCode || response.Content.Headers.ContentLength is > 1_048_576) return null;
            await using Stream stream = await response.Content.ReadAsStreamAsync(cancellationToken);
            using var bytes = new MemoryStream();
            byte[] buffer = new byte[8192];
            while (bytes.Length <= 1_048_576)
            {
                int read = await stream.ReadAsync(buffer.AsMemory(), cancellationToken);
                if (read == 0) break;
                bytes.Write(buffer, 0, read);
            }
            if (bytes.Length > 1_048_576) return null;
            string body = System.Text.Encoding.UTF8.GetString(bytes.GetBuffer(), 0, (int)bytes.Length);
            return ReleaseAvailability.TryGetNewer(BuildIdentity.ProducerVersion, body, out AvailableRelease? release) ? release : null;
        }
        catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException or IOException) { return null; }
    }

    public void Dispose()
    {
        if (_ownsHttp) _http.Dispose();
    }
}
