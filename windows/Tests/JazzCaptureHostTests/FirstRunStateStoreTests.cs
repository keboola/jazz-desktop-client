using JazzCapture;
using System.IO;
using System.Reflection;
using System.Text.Json;

namespace JazzCaptureHostTests;

public sealed class FirstRunStateStoreTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "jazz-first-run-" + Guid.NewGuid().ToString("N"));

    /// <summary>
    /// #75 acceptance: "A fresh profile launches to the tray with no window shown." The strongest
    /// automated expression of that is that nothing on this type can even be asked whether to show
    /// one any more -- <c>FirstRunStateStore.RequiresOnboarding</c>, the API the deleted
    /// <c>App.xaml.cs:183</c> startup gate used to call, no longer exists on the type at all. All
    /// visibilities are checked, not just public: an <c>internal</c> re-acquisition would be just as
    /// callable from <c>App</c> (same assembly) and must fail this just as loudly. This stops that
    /// gate from silently reappearing in a later change, at any accessibility level.
    /// </summary>
    [Fact]
    public void TheStoreExposesNoStartupOnboardingGate()
    {
        // NonPublic is what actually does the widening work here (round-1 review: a plain
        // GetMembers() call defaults to Public | Instance | Static, so an internal-only gate
        // would have slipped past it); DeclaredOnly just excludes members inherited from object,
        // which this sealed type would never rely on to gate a startup window anyway.
        const BindingFlags AnyDeclaredMember = BindingFlags.Public | BindingFlags.NonPublic
            | BindingFlags.Instance | BindingFlags.Static | BindingFlags.DeclaredOnly;
        Assert.Empty(typeof(FirstRunStateStore).GetMembers(AnyDeclaredMember)
            .Where(member => member.Name.Contains("Onboarding", StringComparison.Ordinal)));
    }

    /// <summary>
    /// Reads the on-disk field directly rather than through the store: <see cref="FirstRunStateStore"/>
    /// exposes no public reader for it any more (<c>RequiresOnboarding()</c> was its only one, and
    /// #75 deletes it), yet the amendment to the plan requires the field itself to keep being
    /// written for downgrade compatibility with a published build that still reads it. Without a
    /// direct assertion somewhere, nothing would fail if <see cref="FirstRunStateStore.Acknowledge"/>
    /// silently became a no-op.
    /// </summary>
    private bool ReadOnboardingAcknowledgedFromDisk()
    {
        using JsonDocument document = JsonDocument.Parse(File.ReadAllText(Path.Combine(_root, "startup-state.json")));
        return document.RootElement.GetProperty("OnboardingAcknowledged").GetBoolean();
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
    /// <remarks>
    /// Round-5 Copilot review: <c>{"Schema":1}</c> is the *supported* schema with fields merely
    /// missing (<c>Read</c>'s own <c>state is { Schema: 1 }</c> check accepts it) -- a genuine
    /// mismatch is <c>Schema != 1</c>, which this test did not actually exercise despite its name
    /// and its "schema-mismatched" doc comment. Both arrangements are kept: the partial-state case
    /// (inherited verbatim from the plan's own specified rewrite) and a real <c>{"Schema":2}</c>
    /// mismatch added alongside it, so the acceptance case can no longer regress unnoticed.
    /// </remarks>
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

        File.WriteAllText(Path.Combine(_root, "startup-state.json"), "{\"Schema\":2}");
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
        Assert.True(ReadOnboardingAcknowledgedFromDisk());
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
        // Assert.Null(ReadUpdateAttempt()) alone would be vacuous here: it reads null whether
        // Acknowledge() actually recovered the corrupt file or the file is still unparsable JSON
        // (ReadUpdateAttempt's own JsonException handling returns null either way). Reading the
        // flag directly off disk is what actually proves the corrupt-state write recovered.
        Assert.True(ReadOnboardingAcknowledgedFromDisk());
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
        Assert.True(ReadOnboardingAcknowledgedFromDisk());
    }

    public void Dispose() { if (Directory.Exists(_root)) Directory.Delete(_root, true); }
}
