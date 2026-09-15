using System.IO;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using JazzCaptureCore;

namespace JazzCapture;

/// <summary>
/// Best-effort fetch of <c>client-policy.json</c> from the public release channel. Failures never
/// start, stop, or alter capture.
/// </summary>
internal sealed class ClientPolicyClient : IDisposable
{
    internal static readonly TimeSpan Cadence = TimeSpan.FromHours(1);
    private readonly FirstRunStateStore _state;
    private readonly string _cachePath;
    private readonly HttpClient _http;
    private readonly Func<DateTimeOffset> _clock;
    private readonly TimeSpan _cadence;
    private readonly bool _ownsHttp;

    internal ClientPolicyClient(
        FirstRunStateStore state,
        string profileDirectory,
        HttpClient? http = null,
        Func<DateTimeOffset>? clock = null,
        TimeSpan? cadence = null)
    {
        _state = state;
        _cachePath = Path.Combine(profileDirectory, "client-policy.json");
        _ownsHttp = http is null;
        _http = http ?? new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
        _cadence = cadence ?? Cadence;
    }

    internal ClientPolicy? ReadCache()
    {
        try
        {
            if (!File.Exists(_cachePath)) return null;
            return ClientPolicy.TryParse(File.ReadAllText(_cachePath), out ClientPolicy? policy) ? policy : null;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    internal async Task<ClientPolicy?> CheckAsync(CancellationToken cancellationToken)
    {
        DateTimeOffset now = _clock();
        if (!ReleaseAvailability.IsDue(_state.ReadPolicyAttempt(), now, _cadence)) return ReadCache();
        try { _state.RecordPolicyAttempt(now); }
        catch (IOException) { return ReadCache(); }
        catch (UnauthorizedAccessException) { return ReadCache(); }

        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, ClientPolicy.LatestUrl);
            request.Headers.UserAgent.ParseAdd("JazzCapture/" + BuildIdentity.ProducerVersion);
            using HttpResponseMessage response = await _http.SendAsync(
                request,
                HttpCompletionOption.ResponseHeadersRead,
                cancellationToken).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode || response.Content.Headers.ContentLength is > ClientPolicy.MaximumDocumentBytes)
                return ReadCache();

            await using Stream stream = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
            using var bytes = new MemoryStream();
            byte[] buffer = new byte[4096];
            while (bytes.Length <= ClientPolicy.MaximumDocumentBytes)
            {
                int remaining = ClientPolicy.MaximumDocumentBytes + 1 - checked((int)bytes.Length);
                int read = await stream.ReadAsync(buffer.AsMemory(0, Math.Min(buffer.Length, remaining)), cancellationToken).ConfigureAwait(false);
                if (read == 0) break;
                bytes.Write(buffer, 0, read);
            }
            if (bytes.Length > ClientPolicy.MaximumDocumentBytes) return ReadCache();
            string body = Encoding.UTF8.GetString(bytes.GetBuffer(), 0, (int)bytes.Length);
            if (!ClientPolicy.TryParse(body, out ClientPolicy? policy) || policy is null) return ReadCache();
            TryWriteCache(policy);
            return policy;
        }
        catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException or IOException)
        {
            return ReadCache();
        }
    }

    private void TryWriteCache(ClientPolicy policy)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_cachePath)!);
            string json = JsonSerializer.Serialize(new Dictionary<string, object>
            {
                ["kind"] = ClientPolicy.Kind,
                ["schema"] = ClientPolicy.Schema,
                ["pauseReminderMinutes"] = policy.PauseReminderMinutes,
                ["voiceConsentEpoch"] = policy.VoiceConsentEpoch,
            });
            string temporary = _cachePath + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                File.WriteAllText(temporary, json);
                File.Move(temporary, _cachePath, true);
            }
            finally
            {
                if (File.Exists(temporary)) File.Delete(temporary);
            }
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
        }
    }

    public void Dispose()
    {
        if (_ownsHttp) _http.Dispose();
    }
}
