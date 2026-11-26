using JazzCapture;
using JazzCaptureCore;

namespace JazzCaptureHostTests;

public sealed class TrayIconPromoterTests : IDisposable
{
    private const string Exe = @"C:\Users\anna\AppData\Local\Jazz\App\JazzCapture.exe";
    private readonly string _root = Path.Combine(Path.GetTempPath(), "jazz-tray-" + Guid.NewGuid().ToString("N"));

    private sealed class FakeRegistry : INotifyIconSettingsRegistry
    {
        internal readonly List<NotifyIconEntry> Entries = new();
        internal readonly List<string> Promoted = new();
        internal Exception? ReadFails;

        public IReadOnlyList<NotifyIconEntry> Read()
        {
            if (ReadFails is not null) throw ReadFails;
            return Entries.ToArray();
        }

        public void SetPromoted(string subKey) => Promoted.Add(subKey);
    }

    private static TrayIconPromoter Create(FakeRegistry registry, FirstRunStateStore state, List<TimeSpan> delays, List<string> log, Action? onDelay = null) =>
        new(registry, state, Exe, (delay, _) => { delays.Add(delay); onDelay?.Invoke(); return Task.CompletedTask; }, log.Add);

    [Fact]
    public async Task PromotesOnceAndRemembersIt()
    {
        var registry = new FakeRegistry();
        registry.Entries.Add(new NotifyIconEntry("5", Exe, 0));
        var state = new FirstRunStateStore(_root);
        var delays = new List<TimeSpan>();

        await Create(registry, state, delays, new List<string>()).RunAsync(CancellationToken.None);

        Assert.Equal(new[] { "5" }, registry.Promoted);
        Assert.True(state.ReadTrayIconPromoted());
        Assert.Empty(delays);
    }

    [Fact]
    public async Task AUserWhoHidesTheIconLaterKeepsThatChoice()
    {
        var registry = new FakeRegistry();
        registry.Entries.Add(new NotifyIconEntry("5", Exe, 0));
        var state = new FirstRunStateStore(_root);
        await Create(registry, state, new List<TimeSpan>(), new List<string>()).RunAsync(CancellationToken.None);
        registry.Promoted.Clear();
        registry.Entries[0] = new NotifyIconEntry("5", Exe, 0);

        await Create(registry, state, new List<TimeSpan>(), new List<string>()).RunAsync(CancellationToken.None);

        Assert.Empty(registry.Promoted);
    }

    [Fact]
    public async Task RetriesOnceWhenTheSubKeyAppearsLater()
    {
        var registry = new FakeRegistry();
        var state = new FirstRunStateStore(_root);
        var delays = new List<TimeSpan>();

        await Create(registry, state, delays, new List<string>(),
            onDelay: () => registry.Entries.Add(new NotifyIconEntry("9", Exe, null))).RunAsync(CancellationToken.None);

        Assert.Single(delays);
        Assert.Equal(new[] { "9" }, registry.Promoted);
        Assert.True(state.ReadTrayIconPromoted());
    }

    [Fact]
    public async Task WithoutASubKeyItTriesTwiceLogsAndTriesAgainNextLaunch()
    {
        var registry = new FakeRegistry();
        var state = new FirstRunStateStore(_root);
        var delays = new List<TimeSpan>();
        var log = new List<string>();

        await Create(registry, state, delays, log).RunAsync(CancellationToken.None);

        Assert.Single(delays);
        Assert.Single(log);
        Assert.False(state.ReadTrayIconPromoted());
    }

    [Fact]
    public async Task ARegistryFailureIsLoggedAndNeverThrown()
    {
        var registry = new FakeRegistry { ReadFails = new UnauthorizedAccessException() };
        var state = new FirstRunStateStore(_root);
        var log = new List<string>();

        await Create(registry, state, new List<TimeSpan>(), log).RunAsync(CancellationToken.None);

        Assert.Single(log);
        Assert.False(state.ReadTrayIconPromoted());
    }

    public void Dispose()
    {
        if (Directory.Exists(_root)) Directory.Delete(_root, true);
    }
}
