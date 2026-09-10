using JazzCaptureCore;

namespace JazzCaptureCoreTests;

public sealed class ReleaseAvailabilityTests
{
    [Fact]
    public void SelectsOnlyNewerStableGitHubRelease()
    {
        const string json = "[{\"tag_name\":\"v0.26.4\",\"html_url\":\"https://github.com/keboola/jazz-desktop-client/releases/tag/v0.26.4\",\"draft\":false,\"prerelease\":false},{\"tag_name\":\"v0.30.0-rc1\",\"html_url\":\"https://github.com/keboola/jazz-desktop-client/releases/tag/v0.30.0-rc1\",\"draft\":false,\"prerelease\":true}]";
        bool found = ReleaseAvailability.TryGetNewer("0.26.3", json, out AvailableRelease? release);
        Assert.True(found); Assert.Equal(new Version(0, 26, 4), release!.Version);
    }

    [Fact]
    public void RejectsMalformedAndNonAllowlistedUrls()
    {
        const string json = "[{\"tag_name\":\"v9.0.0\",\"html_url\":\"http://evil.invalid\",\"draft\":false,\"prerelease\":false}]";
        Assert.False(ReleaseAvailability.TryGetNewer("0.26.3", json, out _));
    }

    [Fact]
    public void ThrottleIsDueOnlyAtCadence()
    {
        DateTimeOffset now = DateTimeOffset.UtcNow;
        Assert.False(ReleaseAvailability.IsDue(now - TimeSpan.FromHours(1), now, TimeSpan.FromHours(6)));
        Assert.True(ReleaseAvailability.IsDue(now - TimeSpan.FromHours(6), now, TimeSpan.FromHours(6)));
    }
}
