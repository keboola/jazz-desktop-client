using JazzCaptureCore;

namespace JazzCaptureCoreTests;

public sealed class CommandCenterUrlTests
{
    [Theory]
    [InlineData("https://cc.example.com/client-policy.json")]
    [InlineData("https://cc.example.com/")]
    [InlineData("https://cc.example.com")]
    public void AcceptsAbsoluteHttpsUrls(string url)
    {
        Assert.Equal(url, CommandCenterUrl.TryNormalize(url));
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("http://cc.example.com/policy.json")]
    [InlineData("ftp://cc.example.com/policy.json")]
    [InlineData("not a url")]
    [InlineData("https://user:pass@cc.example.com/policy.json")]
    public void RejectsNonHttpsOrMalformedUrls(string? url)
    {
        Assert.Null(CommandCenterUrl.TryNormalize(url));
    }
}
