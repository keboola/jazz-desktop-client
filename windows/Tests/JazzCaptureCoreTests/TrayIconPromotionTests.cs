using JazzCaptureCore;

namespace JazzCaptureCoreTests;

public sealed class TrayIconPromotionTests
{
    private const string Exe = @"C:\Users\anna\AppData\Local\Jazz\App\JazzCapture.exe";

    private sealed class FakeRegistry : INotifyIconSettingsRegistry
    {
        internal readonly List<NotifyIconEntry> Entries = new();
        internal readonly List<string> Promoted = new();

        public IReadOnlyList<NotifyIconEntry> Read() => Entries.ToArray();

        public void SetPromoted(string subKey) => Promoted.Add(subKey);
    }

    [Fact]
    public void ThePathOfTheRunningExecutableSelectsTheSubKey()
    {
        var entries = new[]
        {
            new NotifyIconEntry("1", @"C:\Windows\explorer.exe", null),
            new NotifyIconEntry("2", Exe.ToLowerInvariant(), 0),
            new NotifyIconEntry("3", @"C:\Other\JazzCapture.exe", null),
        };

        Assert.Equal("2", TrayIconPromotion.SelectSubKey(entries, Exe));
    }

    [Fact]
    public void AKnownFolderPrefixMatchesByTheRestOfThePath()
    {
        var entries = new[]
        {
            new NotifyIconEntry("7", @"{F38BF404-1D43-42F2-9305-67DE0B28FC23}\Notepad.exe", null),
            new NotifyIconEntry("8", @"{F1B32785-6FBA-4FCF-9D55-7B8E7F157091}\Jazz\App\JazzCapture.exe", null),
        };

        Assert.Equal("8", TrayIconPromotion.SelectSubKey(entries, Exe));
    }

    [Fact]
    public void AnotherExecutableWithTheSameFileNameIsNotSelected()
    {
        var entries = new[] { new NotifyIconEntry("3", @"C:\Other\JazzCapture.exe", null) };

        Assert.Null(TrayIconPromotion.SelectSubKey(entries, Exe));
    }

    [Fact]
    public void EntriesWithoutAPathAreSkipped()
    {
        var entries = new[] { new NotifyIconEntry("1", null, null), new NotifyIconEntry("2", "  ", null) };

        Assert.Null(TrayIconPromotion.SelectSubKey(entries, Exe));
    }

    [Fact]
    public void PromoteWritesOnlyTheSelectedSubKey()
    {
        var registry = new FakeRegistry();
        registry.Entries.Add(new NotifyIconEntry("1", @"C:\Windows\explorer.exe", 0));
        registry.Entries.Add(new NotifyIconEntry("2", Exe, 0));

        Assert.True(TrayIconPromotion.TryPromote(registry, Exe));

        Assert.Equal(new[] { "2" }, registry.Promoted);
    }

    [Fact]
    public void AnIconThatIsAlreadyPromotedIsNotWrittenAgain()
    {
        var registry = new FakeRegistry();
        registry.Entries.Add(new NotifyIconEntry("2", Exe, 1));

        Assert.True(TrayIconPromotion.TryPromote(registry, Exe));

        Assert.Empty(registry.Promoted);
    }

    [Fact]
    public void WithoutASubKeyNothingIsPromoted()
    {
        var registry = new FakeRegistry();

        Assert.False(TrayIconPromotion.TryPromote(registry, Exe));
        Assert.Empty(registry.Promoted);
    }
}
