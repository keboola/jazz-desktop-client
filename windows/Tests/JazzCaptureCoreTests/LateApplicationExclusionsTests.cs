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
}
