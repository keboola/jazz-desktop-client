using JazzCaptureCore;

namespace JazzCaptureCoreTests;

/// <summary>
/// Pins the set of applications a user exempted while a capture was already running. The running
/// capture's policy is frozen, so this set is the only thing that can keep such an application's
/// still-queued work out of the old session between the click and the session rotation.
/// </summary>
public sealed class LateApplicationExclusionsTests
{
    private const string TerminalAumid = "Microsoft.WindowsTerminal_8wekyb3d8bbwe!App";
    private const string TerminalExe = "c:/program files/windowsapps/microsoft.windowsterminal/windowsterminal.exe";

    private static readonly AppIdentity TerminalWindow = new(AppIdentity.AumidNamespace, TerminalAumid, "Terminal");
    private static readonly AppIdentity TerminalProcess = new(AppIdentity.ExecutablePathNamespace, TerminalExe, "WindowsTerminal");
    private static readonly AppIdentity Editor = new(AppIdentity.ExecutablePathNamespace, "c:/tools/editor.exe", "Editor");

    [Fact]
    public void NothingIsLateExcludedUntilSomethingIsAdded()
    {
        var exclusions = new LateApplicationExclusions(new ApplicationDenylist(new[] { "1password" }));

        Assert.True(exclusions.IsEmpty);
        Assert.False(exclusions.IsLateExcluded(TerminalWindow));

        // An entry on the frozen policy is the engine's to enforce, not a late exclusion.
        Assert.False(exclusions.IsLateExcluded(
            new AppIdentity(AppIdentity.ExecutablePathNamespace, "c:/1password/1password.exe", "1Password")));
        Assert.Equal(new[] { "1password" }, exclusions.Effective.Entries);
    }

    [Fact]
    public void AnAddedEntryMatchesWithTheDenylistsOwnRule()
    {
        var exclusions = new LateApplicationExclusions(ApplicationDenylist.Empty);

        Assert.True(exclusions.Add(new[] { "WINDOWSTERMINAL" }));

        // Substring, case-insensitive, against the identity value: the same rule ApplicationDenylist uses.
        Assert.False(exclusions.IsEmpty);
        Assert.True(exclusions.IsLateExcluded(TerminalWindow));
        Assert.True(exclusions.IsLateExcluded(TerminalProcess));
        Assert.False(exclusions.IsLateExcluded(Editor));
        Assert.False(exclusions.IsLateExcluded((AppIdentity?)null));
        Assert.True(exclusions.Effective.IsExcluded(TerminalProcess));
    }

    [Fact]
    public void AddingNothingNewReportsNoChange()
    {
        var exclusions = new LateApplicationExclusions(new ApplicationDenylist(new[] { "terminal" }));

        // Already covered by the frozen policy, then by an earlier late entry.
        Assert.False(exclusions.Add(new[] { TerminalAumid }));
        Assert.True(exclusions.IsEmpty);
        Assert.True(exclusions.Add(new[] { "editor.exe" }));
        Assert.False(exclusions.Add(new[] { "c:/tools/editor.exe", " ", "EDITOR.EXE" }));
    }

    /// <summary>
    /// The alias rule has to see the late entry too. The user exempted Terminal by the AUMID the
    /// picker showed; a typed run in it resolves through the executable path. Without the alias the
    /// late check would miss it — exactly the both-identities defect, reopened for late entries.
    /// </summary>
    [Fact]
    public void AttributionOverTheEffectiveDenylistSeesALateAlias()
    {
        var exclusions = new LateApplicationExclusions(ApplicationDenylist.Empty);
        var attribution = new DenylistAttribution(
            () => exclusions.Effective,
            resolveWindow: window => window == 10 ? TerminalWindow : null,
            windowProcessId: window => window == 10 ? 100u : 0u,
            resolveProcess: pid => pid == 100 ? TerminalProcess : null,
            foregroundWindow: () => 10,
            focusedWindow: () => 0,
            rootWindow: window => window);

        // Before the click: the exe identity, nothing excluded.
        Assert.Same(TerminalProcess, attribution.ForFocus(100));

        exclusions.Add(new[] { TerminalAumid });

        AppIdentity? attributed = attribution.ForFocus(100);
        Assert.Same(TerminalWindow, attributed);
        Assert.True(exclusions.IsLateExcluded(attributed));
    }

    /// <summary>
    /// Review finding on PR #120: a typed run is attributed to Terminal's executable path when it
    /// begins. The user exempts Terminal by its AUMID while the flush's UI Automation read-back is
    /// blocked, so the pre-read check has already passed. The final admission check after the read
    /// must still see the exemption through the owner's other identity; comparing only the saved
    /// identity misses it and the text is journaled after the exemption took effect.
    /// </summary>
    [Fact]
    public async Task AnExemptionPublishedDuringABlockedReadIsSeenByTheFinalOwnerCheck()
    {
        var exclusions = new LateApplicationExclusions(ApplicationDenylist.Empty);
        DenylistAttribution attribution = TerminalAttribution(exclusions);
        var owner = new EventOwner(TerminalProcess, 100, 10);
        using var readBlocked = new ManualResetEventSlim();
        using var releaseRead = new ManualResetEventSlim();

        Task<(bool Before, bool After)> flush = Task.Run(() =>
        {
            bool before = exclusions.IsLateExcluded(owner, attribution);
            readBlocked.Set();
            releaseRead.Wait();
            return (before, exclusions.IsLateExcluded(owner, attribution));
        });

        Assert.True(readBlocked.Wait(TimeSpan.FromSeconds(10)));
        exclusions.Add(new[] { TerminalAumid });
        releaseRead.Set();
        (bool before, bool after) = await flush;

        Assert.False(before);
        Assert.True(after);

        // The saved identity alone is exactly the check that missed it.
        Assert.False(exclusions.IsLateExcluded(owner.Attributed));
    }

    [Fact]
    public void AnOwnerWithoutAProcessIsCheckedThroughItsWindowOnly()
    {
        var exclusions = new LateApplicationExclusions(ApplicationDenylist.Empty);
        DenylistAttribution attribution = TerminalAttribution(exclusions);
        exclusions.Add(new[] { "windowsterminal.exe" });

        Assert.True(exclusions.IsLateExcluded(new EventOwner(TerminalWindow, null, 10), attribution));
        Assert.False(exclusions.IsLateExcluded(new EventOwner(Editor, null, 0), attribution));
        Assert.False(exclusions.IsLateExcluded(new EventOwner(Editor, 200, 20), attribution));
    }

    [Fact]
    public void NoLateEntryMeansNoOwnerLookup()
    {
        var exclusions = new LateApplicationExclusions(new ApplicationDenylist(new[] { "terminal" }));
        int lookups = 0;
        var attribution = new DenylistAttribution(
            () => exclusions.Effective,
            resolveWindow: _ => { lookups++; return TerminalWindow; },
            windowProcessId: _ => { lookups++; return 100u; },
            resolveProcess: _ => { lookups++; return TerminalProcess; },
            foregroundWindow: () => 10,
            focusedWindow: () => 0,
            rootWindow: window => window);

        Assert.False(exclusions.IsLateExcluded(new EventOwner(TerminalProcess, 100, 10), attribution));
        Assert.Equal(0, lookups);
    }

    /// <summary>Terminal: window 10 (AUMID) owned by process 100 (exe); an editor: window 20, process 200.</summary>
    private static DenylistAttribution TerminalAttribution(LateApplicationExclusions exclusions) => new(
        () => exclusions.Effective,
        resolveWindow: window => window switch { 10 => TerminalWindow, 20 => Editor, _ => null },
        windowProcessId: window => window switch { 10 => 100u, 20 => 200u, _ => 0u },
        resolveProcess: pid => pid switch { 100 => TerminalProcess, 200 => Editor, _ => null },
        foregroundWindow: () => 20,
        focusedWindow: () => 0,
        rootWindow: window => window);
}
