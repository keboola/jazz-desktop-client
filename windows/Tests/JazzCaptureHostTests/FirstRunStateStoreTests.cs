using JazzCapture;
using System.IO;
using System.Linq;
using System.Reflection;

namespace JazzCaptureHostTests;

public sealed class FirstRunStateStoreTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "jazz-first-run-" + Guid.NewGuid().ToString("N"));

    /// <summary>
    /// #75 acceptance: "A fresh profile launches to the tray with no window shown." The strongest
    /// automated expression of that is that nothing on this type can even be asked whether to show
    /// one any more -- <c>FirstRunStateStore.RequiresOnboarding</c>, the API the deleted
    /// <c>App.xaml.cs:183</c> startup gate used to call, no longer exists on the type at all. This
    /// stops that gate from silently reappearing in a later change.
    /// </summary>
    [Fact]
    public void TheStoreExposesNoStartupOnboardingGate()
    {
        Assert.Empty(typeof(FirstRunStateStore).GetMembers()
            .Where(member => member.Name.Contains("Onboarding", StringComparison.Ordinal)));
    }

    /// <summary>
    /// #75 acceptance: "A profile with no startup-state.json launches with no window shown, on every
    /// launch," and the update-check throttle must still work on such a profile. No file on disk
    /// reads as no prior attempt, and recording one round-trips normally.
    /// </summary>
    [Fact]
    public void UpdateThrottleWorksOnAProfileThatNeverAcknowledgesAnything()
    {
        var store = new FirstRunStateStore(_root);
        Assert.Null(store.ReadUpdateAttempt());

        DateTimeOffset attempt = DateTimeOffset.UtcNow;
        store.RecordUpdateAttempt(attempt);

        Assert.Equal(attempt.ToUnixTimeSeconds(), store.ReadUpdateAttempt()!.Value.ToUnixTimeSeconds());
        Assert.False(File.Exists(Path.Combine(_root, "settings.json")));
    }

    /// <summary>
    /// #75 acceptance: an unreadable or schema-mismatched startup-state.json must not block startup
    /// and, now that nothing at startup asks the store anything, cannot produce a window either way.
    /// The throttle must still recover regardless of what shape the file is in.
    /// </summary>
    [Fact]
    public void MissingCorruptAndMismatchedStateNeitherThrowNorBlockTheUpdateThrottle()
    {
        var store = new FirstRunStateStore(_root);
        Assert.Null(store.ReadUpdateAttempt());

        Directory.CreateDirectory(_root);
        File.WriteAllText(Path.Combine(_root, "startup-state.json"), "{");
        Assert.Null(store.ReadUpdateAttempt());

        File.WriteAllText(Path.Combine(_root, "startup-state.json"), "{\"Schema\":1}");
        Assert.Null(store.ReadUpdateAttempt());

        DateTimeOffset attempt = DateTimeOffset.UtcNow;
        store.RecordUpdateAttempt(attempt);
        Assert.Equal(attempt.ToUnixTimeSeconds(), store.ReadUpdateAttempt()!.Value.ToUnixTimeSeconds());
    }

    [Fact]
    public void AcknowledgementAndUpdateAttemptShareAtomicStateWithoutPreferences()
    {
        var store = new FirstRunStateStore(_root);
        DateTimeOffset attempt = DateTimeOffset.UtcNow;
        store.RecordUpdateAttempt(attempt);
        store.Acknowledge();
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
        Assert.Null(store.ReadUpdateAttempt());

        DateTimeOffset laterAttempt = attempt.AddMinutes(1);
        store.RecordUpdateAttempt(laterAttempt);
        Assert.Equal(laterAttempt.ToUnixTimeSeconds(), store.ReadUpdateAttempt()!.Value.ToUnixTimeSeconds());
    }

    [Fact]
    public void ConcurrentAcknowledgementAndThrottleWritesPreserveBothFields()
    {
        var store = new FirstRunStateStore(_root);
        DateTimeOffset attempt = DateTimeOffset.UtcNow;

        Parallel.For(0, 100, index =>
        {
            if (index % 2 == 0) store.Acknowledge();
            else store.RecordUpdateAttempt(attempt);
        });

        Assert.Equal(attempt.ToUnixTimeSeconds(), store.ReadUpdateAttempt()!.Value.ToUnixTimeSeconds());
    }

    public void Dispose() { if (Directory.Exists(_root)) Directory.Delete(_root, true); }
}
