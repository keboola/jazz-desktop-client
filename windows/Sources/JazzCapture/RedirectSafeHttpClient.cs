using System.Net.Http;

namespace JazzCapture;

/// <summary>
/// Wraps an <see cref="HttpClient"/> that is proven, at construction time, never to follow a
/// redirect automatically.
/// </summary>
/// <remarks>
/// <para>
/// .NET's redirect handling strips only the <c>Authorization</c> header when a request is
/// redirected cross-origin; a custom header such as <c>X-StorageApi-Token</c> survives a
/// <c>302</c> response and would be replayed against whatever host the redirect names. A Files
/// client that carries the Keboola Storage token must therefore never be built over a
/// redirect-following <see cref="HttpClient"/>. <see cref="HttpClient"/> does not expose its
/// handler, so a constructor taking an <see cref="HttpClient"/> directly cannot check this -- the
/// only way to make the guarantee load-bearing is to make the *type* itself the proof, so a
/// <see cref="KeboolaFilesClient"/> constructor can require this wrapper instead of a bare
/// <see cref="HttpClient"/>.
/// </para>
/// <para>
/// <see cref="KeboolaDeviceTokenVerifier"/>'s <c>CreateProductionHandler()</c> already sets
/// <c>AllowAutoRedirect = false</c> for exactly this reason; <see cref="CreateProduction"/> reuses
/// that handler and asserts the property instead of assuming it, so a future change to that
/// handler cannot silently reopen this hole.
/// </para>
/// </remarks>
public sealed class RedirectSafeHttpClient : IDisposable
{
    private readonly HttpClient _client;

    private RedirectSafeHttpClient(HttpClient client) => _client = client;

    /// <summary>
    /// The only public factory. Builds the wrapped client from
    /// <see cref="KeboolaDeviceTokenVerifier.CreateProductionHandler"/> and asserts -- rather than
    /// assumes -- that the handler will not follow a redirect.
    /// </summary>
    public static RedirectSafeHttpClient CreateProduction()
    {
        HttpClientHandler handler = KeboolaDeviceTokenVerifier.CreateProductionHandler();
        if (handler.AllowAutoRedirect)
        {
            // Should be unreachable: CreateProductionHandler() is defined a few lines away from
            // this check today, but a future edit there must not silently reopen the header-leak
            // hole this type exists to close.
            throw new InvalidOperationException(
                "The production HTTP handler must not follow redirects.");
        }

        return new RedirectSafeHttpClient(new HttpClient(handler));
    }

    /// <summary>
    /// Test-only seam. Accepts an arbitrary <see cref="HttpMessageHandler"/> -- a fake in-memory
    /// handler has no redirect-following behaviour to check and is accepted as-is -- but still
    /// rejects an <see cref="HttpClientHandler"/> or <see cref="SocketsHttpHandler"/> whose
    /// <c>AllowAutoRedirect</c> is <see langword="true"/>, exactly as <see cref="CreateProduction"/>
    /// does. This is safe to expose internally: it only widens *which handler types* may be
    /// supplied, never *which handlers pass* -- a redirect-following concrete handler is refused
    /// here exactly as it would be in production.
    /// </summary>
    internal static RedirectSafeHttpClient CreateForTests(HttpMessageHandler handler)
    {
        ArgumentNullException.ThrowIfNull(handler);
        switch (handler)
        {
            case HttpClientHandler concrete when concrete.AllowAutoRedirect:
                throw new ArgumentException(
                    "A redirect-following HttpClientHandler is not allowed.", nameof(handler));
            case SocketsHttpHandler concrete when concrete.AllowAutoRedirect:
                throw new ArgumentException(
                    "A redirect-following SocketsHttpHandler is not allowed.", nameof(handler));
        }

        return new RedirectSafeHttpClient(new HttpClient(handler));
    }

    internal Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        HttpCompletionOption completionOption,
        CancellationToken cancellationToken) =>
        _client.SendAsync(request, completionOption, cancellationToken);

    public void Dispose() => _client.Dispose();
}
