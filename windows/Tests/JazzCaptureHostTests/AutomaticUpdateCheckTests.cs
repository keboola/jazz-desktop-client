using JazzCapture;
using JazzCaptureCore;

namespace JazzCaptureHostTests;

public sealed class AutomaticUpdateCheckTests
{
    private static readonly AvailableRelease Release = new(
        new Version(9, 9, 9),
        new Uri("https://github.com/keboola/jazz-windows-releases/releases/tag/v9.9.9"),
        new Uri("https://github.com/keboola/jazz-windows-releases/releases/download/v9.9.9/JazzCapture-9.9.9-win-x64-unsigned.msi"),
        new string('a', 64),
        12);

    [Fact]
    public async Task WhenAutomaticUpdatesAreOffNothingIsCheckedDownloadedOrInstalled()
    {
        int checks = 0;
        int applies = 0;
        var gate = new AutomaticUpdateCheck(
            () => false,
            _ => { checks++; return Task.FromResult<AvailableRelease?>(Release); },
            _ => { applies++; return Task.CompletedTask; });

        await gate.RunAsync(CancellationToken.None);

        Assert.Equal(0, checks);
        Assert.Equal(0, applies);
    }

    [Fact]
    public async Task WhenAutomaticUpdatesAreOnANewReleaseIsApplied()
    {
        var applied = new List<AvailableRelease>();
        var gate = new AutomaticUpdateCheck(
            () => true,
            _ => Task.FromResult<AvailableRelease?>(Release),
            release => { applied.Add(release); return Task.CompletedTask; });

        await gate.RunAsync(CancellationToken.None);

        Assert.Equal(new[] { Release }, applied);
    }

    [Fact]
    public async Task WhenThereIsNoNewReleaseNothingIsApplied()
    {
        int applies = 0;
        var gate = new AutomaticUpdateCheck(
            () => true,
            _ => Task.FromResult<AvailableRelease?>(null),
            _ => { applies++; return Task.CompletedTask; });

        await gate.RunAsync(CancellationToken.None);

        Assert.Equal(0, applies);
    }

    [Fact]
    public async Task APolicyThatTurnsUpdatesOffDuringTheCheckStopsTheInstall()
    {
        bool allowed = true;
        int applies = 0;
        var gate = new AutomaticUpdateCheck(
            () => allowed,
            _ => { allowed = false; return Task.FromResult<AvailableRelease?>(Release); },
            _ => { applies++; return Task.CompletedTask; });

        await gate.RunAsync(CancellationToken.None);

        Assert.Equal(0, applies);
    }
}
