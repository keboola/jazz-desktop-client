using JazzCaptureCore;

namespace JazzCaptureCoreTests;

public sealed class ReleaseAvailabilityTests
{
    private const string Digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    [Fact]
    public void SelectsOnlyNewerStableGitHubRelease()
    {
        string json = "[" + Release("v0.26.4") + "," + Release("v0.30.0-rc1", prerelease: true) + "]";
        bool found = ReleaseAvailability.TryGetNewer("0.26.3", json, out AvailableRelease? release);
        Assert.True(found);
        Assert.Equal(new Version(0, 26, 4), release!.Version);
        Assert.Equal("https://github.com/keboola/jazz-windows-releases/releases/download/v0.26.4/JazzCapture-0.26.4-win-x64-unsigned.msi", release.MsiUrl.AbsoluteUri);
        Assert.Equal(new string('a', 64), release.Sha256);
        Assert.Equal(12, release.Size);
    }

    [Fact]
    public void RejectsMalformedAndNonAllowlistedUrls()
    {
        string[] rejected =
        {
            "not-json",
            "{}",
            "[{\"tag_name\":\"v9.0.0\",\"html_url\":\"http://evil.invalid\",\"draft\":false,\"prerelease\":false}]",
            "[{\"tag_name\":\"v9.0.0\",\"html_url\":\"https://github.com/other/repo/releases/tag/v9.0.0\",\"draft\":false,\"prerelease\":false}]",
            "[" + Release("v9.0.0", htmlRepo: "jazz-desktop-client") + "]",
            "[{\"tag_name\":\"v9.0.0\",\"html_url\":\"https://github.com/keboola/jazz-windows-releases/releases/tag/v8.0.0\",\"draft\":false,\"prerelease\":false}]",
            "[{\"tag_name\":\"v9.0.0.0\",\"html_url\":\"https://github.com/keboola/jazz-windows-releases/releases/tag/v9.0.0.0\",\"draft\":false,\"prerelease\":false}]",
            "[{\"tag_name\":\"v9.0.0\",\"html_url\":\"https://github.com/keboola/jazz-windows-releases/releases/tag/v9.0.0\",\"draft\":\"yes\"}]",
            "[" + Release("v9.0.0", digest: "sha256:dead") + "]",
            "[" + Release("v9.0.0", size: ReleaseAvailability.MaximumPackageBytes + 1) + "]",
            "[" + Release("v9.0.0", assetName: "JazzCapture-0.26.5-win-x64-unsigned.msi") + "]",
        };

        foreach (string json in rejected)
        {
            Assert.False(ReleaseAvailability.TryGetNewer("0.26.3", json, out _));
        }
    }

    [Fact]
    public void IgnoresEqualOlderDraftAndPrereleaseVersions()
    {
        string json = "[" + Release("v0.26.3") + "," + Release("v0.26.2") + "," + Release("v0.27.0", draft: true) + "," + Release("v0.28.0", prerelease: true) + "]";
        Assert.False(ReleaseAvailability.TryGetNewer("0.26.3", json, out _));
    }

    [Fact]
    public void ThrottleIsDueOnlyAtCadence()
    {
        DateTimeOffset now = DateTimeOffset.UtcNow;
        Assert.False(ReleaseAvailability.IsDue(now - TimeSpan.FromHours(1), now, TimeSpan.FromHours(6)));
        Assert.True(ReleaseAvailability.IsDue(now - TimeSpan.FromHours(6), now, TimeSpan.FromHours(6)));
    }

    private static string Release(
        string tag,
        bool draft = false,
        bool prerelease = false,
        string htmlRepo = "jazz-windows-releases",
        string? digest = Digest,
        long size = 12,
        string? assetName = null)
    {
        string version = tag.StartsWith('v') ? tag[1..] : tag;
        string file = assetName ?? ("JazzCapture-" + version + "-win-x64-unsigned.msi");
        string html = "https://github.com/keboola/" + htmlRepo + "/releases/tag/" + tag;
        string download = "https://github.com/keboola/jazz-windows-releases/releases/download/" + tag + "/" + file;
        string draftJson = draft ? "true" : "false";
        string preJson = prerelease ? "true" : "false";
        return "{\"tag_name\":\"" + tag + "\",\"html_url\":\"" + html + "\",\"draft\":" + draftJson + ",\"prerelease\":" + preJson
            + ",\"assets\":[{\"name\":\"" + file + "\",\"browser_download_url\":\"" + download + "\",\"digest\":\"" + digest + "\",\"size\":" + size + "}]}";
    }
}
