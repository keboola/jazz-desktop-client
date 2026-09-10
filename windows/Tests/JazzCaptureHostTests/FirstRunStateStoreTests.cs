using JazzCapture;
using System.IO;

namespace JazzCaptureHostTests;

public sealed class FirstRunStateStoreTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "jazz-first-run-" + Guid.NewGuid().ToString("N"));

    [Fact]
    public void MissingCorruptAndPartialStateRequireConsentSafeOnboarding()
    {
        var store = new FirstRunStateStore(_root);
        Assert.True(store.RequiresOnboarding());
        Directory.CreateDirectory(_root);
        File.WriteAllText(Path.Combine(_root, "startup-state.json"), "{");
        Assert.True(store.RequiresOnboarding());
        File.WriteAllText(Path.Combine(_root, "startup-state.json"), "{\"Schema\":1}");
        Assert.True(store.RequiresOnboarding());
    }

    [Fact]
    public void AcknowledgementAndUpdateAttemptShareAtomicStateWithoutPreferences()
    {
        var store = new FirstRunStateStore(_root);
        DateTimeOffset attempt = DateTimeOffset.UtcNow;
        store.RecordUpdateAttempt(attempt);
        store.Acknowledge();
        Assert.False(store.RequiresOnboarding());
        Assert.Equal(attempt.ToUnixTimeSeconds(), store.ReadUpdateAttempt()!.Value.ToUnixTimeSeconds());
        Assert.False(File.Exists(Path.Combine(_root, "settings.json")));
    }

    [Fact]
    public void CorruptStateCanBeRecoveredByEitherWrite()
    {
        Directory.CreateDirectory(_root);
        string path = Path.Combine(_root, "startup-state.json");
        File.WriteAllText(path, "{");
        var store = new FirstRunStateStore(_root);
        DateTimeOffset attempt = DateTimeOffset.UtcNow;

        store.RecordUpdateAttempt(attempt);
        Assert.Equal(attempt.ToUnixTimeSeconds(), store.ReadUpdateAttempt()!.Value.ToUnixTimeSeconds());

        File.WriteAllText(path, "{");
        store.Acknowledge();
        Assert.False(store.RequiresOnboarding());
    }

    public void Dispose() { if (Directory.Exists(_root)) Directory.Delete(_root, true); }
}
