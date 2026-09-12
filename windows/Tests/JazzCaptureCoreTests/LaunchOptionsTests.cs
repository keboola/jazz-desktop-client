using JazzCaptureCore;

namespace JazzCaptureCoreTests;

/// <summary>
/// <see cref="LaunchOptions"/> is the client's only command-line surface (#76). These tests pin
/// its parsing rules -- presence-based, case-insensitive, no value form, unknown arguments ignored
/// rather than fatal -- and, separately, that the type structurally cannot carry or echo a secret:
/// it exposes exactly one <see langword="bool"/> and retains nothing it did not recognise.
/// </summary>
public sealed class LaunchOptionsTests
{
    [Theory]
    [InlineData(null, false)]
    [InlineData(new string[] { }, false)]
    [InlineData(new[] { "--capture-at-launch" }, true)]
    [InlineData(new[] { "--CAPTURE-AT-LAUNCH" }, true)]
    [InlineData(new[] { "--Capture-At-Launch" }, true)]
    [InlineData(new[] { "--capture-at-launch", "--capture-at-launch" }, true)]
    [InlineData(new[] { "-capture-at-launch" }, false)]
    [InlineData(new[] { "/capture-at-launch" }, false)]
    [InlineData(new[] { "--capture-at-launch=1" }, false)]
    [InlineData(new[] { "--capture" }, false)]
    [InlineData(new[] { "" }, false)]
    [InlineData(new[] { "--unknown" }, false)]
    [InlineData(new[] { "--unknown", "--capture-at-launch" }, true)]
    public void ParsesTheSwitchPresenceInsensitivelyWithNoValueForm(string[]? arguments, bool expected)
    {
        Assert.Equal(expected, LaunchOptions.Parse(arguments).CaptureAtLaunch);
    }

    [Fact]
    public void AnUnknownArgumentIsIgnoredRatherThanFatal()
    {
        // Explorer, the Start Menu shortcut, the HKCU Run value, and a person's own hand can all
        // launch this process; a stray or malformed argument must never turn into a startup
        // failure, which is why this is asserted as a fact of its own rather than folded only into
        // the theory above.
        LaunchOptions options = LaunchOptions.Parse(new[] { "--nonsense", "-x", "totally invalid" });

        Assert.False(options.CaptureAtLaunch);
    }

    [Fact]
    public void TheLaunchSurfaceCarriesOneBooleanAndNothingElse()
    {
        // #62 constraint 2, structurally: a reflection assertion is a stronger guarantee than a
        // review comment that nobody added a second member later.
        System.Reflection.PropertyInfo[] properties = typeof(LaunchOptions)
            .GetProperties(System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Instance);

        System.Reflection.PropertyInfo property = Assert.Single(properties);
        Assert.Equal(nameof(LaunchOptions.CaptureAtLaunch), property.Name);
        Assert.Equal(typeof(bool), property.PropertyType);
    }

    [Fact]
    public void AnUnrecognisedArgumentIsNeitherRetainedNorPrintable()
    {
        const string sentinel = "argv-SENTINEL-must-not-appear";

        LaunchOptions options = LaunchOptions.Parse(new[]
        {
            LaunchOptions.CaptureAtLaunchSwitch,
            "--token=" + sentinel,
        });

        Assert.True(options.CaptureAtLaunch);
        Assert.DoesNotContain(sentinel, options.ToString(), StringComparison.Ordinal);
    }
}
