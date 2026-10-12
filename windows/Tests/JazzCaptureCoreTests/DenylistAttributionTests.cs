using JazzCaptureCore;

namespace JazzCaptureCoreTests;

/// <summary>
/// Windows gives one application two identities — a packaged or Chromium window's AUMID and its
/// process's executable path — and different gestures are attributed through different ones. These
/// tests pin that an exclusion entered against either identity holds for every gesture of that
/// application, and that an application nobody excluded keeps exactly the attribution it had.
/// </summary>
public sealed class DenylistAttributionTests
{
    private const string VaultAumid = "Contoso.Vault_8wekyb3d8bbwe!App";
    private const string VaultExe = "c:/program files/windowsapps/contoso.vault/vault.exe";
    private const string BrowserExe = "c:/program files/contoso/browser.exe";

    private static readonly AppIdentity VaultWindow = new(AppIdentity.AumidNamespace, VaultAumid, "App");
    private static readonly AppIdentity VaultProcess = new(AppIdentity.ExecutablePathNamespace, VaultExe, "Vault");
    private static readonly AppIdentity Browser = new(AppIdentity.ExecutablePathNamespace, BrowserExe, "Browser");

    private static ApplicationDenylist Deny(params string[] entries) => new(entries);

    // --- The rule ----------------------------------------------------------------------------

    [Fact]
    public void AnAumidEntryDropsAnExeAttributedEvent()
    {
        AppIdentity? attributed = DenylistAttribution.Attribute(VaultProcess, new[] { VaultWindow }, Deny(VaultAumid));

        Assert.Same(VaultWindow, attributed);
    }

    [Fact]
    public void AnExeEntryDropsAnAumidAttributedEvent()
    {
        AppIdentity? attributed = DenylistAttribution.Attribute(VaultWindow, new[] { VaultProcess }, Deny("vault.exe"));

        Assert.Same(VaultProcess, attributed);
    }

    [Fact]
    public void NothingExcludedKeepsThePrimary()
    {
        AppIdentity? attributed = DenylistAttribution.Attribute(VaultWindow, new[] { VaultProcess }, Deny("1password"));

        Assert.Same(VaultWindow, attributed);
    }

    [Fact]
    public void AnUnresolvedPrimaryWithAnExcludedAliasIsExcluded()
    {
        var blank = new AppIdentity(AppIdentity.ExecutablePathNamespace, "  ");

        Assert.Same(VaultWindow, DenylistAttribution.Attribute(null, new[] { VaultWindow }, Deny(VaultAumid)));
        Assert.Same(VaultWindow, DenylistAttribution.Attribute(blank, new AppIdentity?[] { null, VaultWindow }, Deny(VaultAumid)));
    }

    [Fact]
    public void BothExcludedReturnsThePrimary()
    {
        AppIdentity? attributed = DenylistAttribution.Attribute(
            VaultProcess, new[] { VaultWindow }, Deny(VaultAumid, "vault.exe"));

        Assert.Same(VaultProcess, attributed);
    }

    [Fact]
    public void AnEmptyDenylistKeepsThePrimary()
    {
        Assert.Same(VaultProcess, DenylistAttribution.Attribute(VaultProcess, new[] { VaultWindow }, ApplicationDenylist.Empty));
        Assert.Null(DenylistAttribution.Attribute(null, new[] { VaultWindow }, ApplicationDenylist.Empty));
    }

    // --- Which identities belong to the same owner -------------------------------------------

    /// <summary>A desktop of fake windows and processes, counting every lookup it answers.</summary>
    private sealed class Desktop
    {
        public Dictionary<nint, uint> WindowProcess { get; } = new();

        public Dictionary<nint, AppIdentity> WindowIdentity { get; } = new();

        public Dictionary<uint, AppIdentity> ProcessIdentity { get; } = new();

        public nint Foreground { get; set; }

        public int Lookups { get; private set; }

        public DenylistAttribution Attribution(ApplicationDenylist denylist) => new(
            denylist,
            resolveWindow: window => Count(WindowIdentity.GetValueOrDefault(window)),
            windowProcessId: window => WindowProcess.GetValueOrDefault(window),
            resolveProcess: pid => Count(ProcessIdentity.GetValueOrDefault(pid)),
            foregroundWindow: () => Foreground);

        private AppIdentity? Count(AppIdentity? identity)
        {
            Lookups++;
            return identity;
        }
    }

    /// <summary>The vault: one window (10) owned by process 100, with both identities resolvable.</summary>
    private static Desktop VaultDesktop()
    {
        var desktop = new Desktop { Foreground = 10 };
        desktop.WindowProcess[10] = 100;
        desktop.WindowIdentity[10] = VaultWindow;
        desktop.ProcessIdentity[100] = VaultProcess;
        desktop.WindowProcess[20] = 200;
        desktop.WindowIdentity[20] = Browser;
        desktop.ProcessIdentity[200] = Browser;
        return desktop;
    }

    [Fact]
    public void AFocusInTheForegroundProcessIsCheckedAgainstTheForegroundWindow()
    {
        // Typing into the vault: focus is attributed by exe, the user excluded it by AUMID.
        Desktop desktop = VaultDesktop();

        Assert.Same(VaultWindow, desktop.Attribution(Deny(VaultAumid)).ForFocus(100));
    }

    [Fact]
    public void AFocusInAnotherProcessThanTheForegroundGetsNoAliases()
    {
        // The vault is in front but focus reports the browser: no established association, so the
        // browser keeps its own attribution instead of borrowing the vault's exclusion.
        Desktop desktop = VaultDesktop();

        Assert.Same(Browser, desktop.Attribution(Deny(VaultAumid)).ForFocus(200));
    }

    [Fact]
    public void AMissingFocusUsesBothIdentitiesOfTheSameWindow()
    {
        Desktop desktop = VaultDesktop();

        Assert.Same(VaultProcess, desktop.Attribution(Deny("vault.exe")).ForFocus(null));
        Assert.Same(VaultWindow, desktop.Attribution(Deny("1password")).ForFocus(null));
    }

    [Fact]
    public void AWindowEventIsCheckedAgainstItsProcessToo()
    {
        // Keydown and navigate attribute by the window's AUMID; an exe entry must still drop them.
        Desktop desktop = VaultDesktop();

        Assert.Same(VaultProcess, desktop.Attribution(Deny("vault.exe")).ForWindow(10));
        Assert.Same(VaultWindow, desktop.Attribution(Deny("1password")).ForWindow(10));
    }

    [Fact]
    public void APointerTargetIsCheckedAgainstItsRootWindowsProcess()
    {
        // A control of a helper process (300) hosted inside the vault's window: excluding the vault
        // by exe path excludes what is shown inside it.
        Desktop desktop = VaultDesktop();
        var helper = new AppIdentity(AppIdentity.ExecutablePathNamespace, "c:/windows/system32/helper.exe");
        desktop.ProcessIdentity[300] = helper;

        Assert.Same(VaultProcess, desktop.Attribution(Deny("vault.exe")).ForTarget(300, 10));
        Assert.Same(VaultWindow, desktop.Attribution(Deny(VaultAumid)).ForTarget(300, 10));
        Assert.Same(helper, desktop.Attribution(Deny("1password")).ForTarget(300, 10));
    }

    [Fact]
    public void AFailedProcessLookupFallsBackToTheForegroundWindowsIdentities()
    {
        // Process 999 cannot be opened: the event is attributed to the foreground window as before,
        // and that window's exclusion — by either identity — still applies.
        Desktop desktop = VaultDesktop();

        Assert.Same(VaultWindow, desktop.Attribution(Deny("1password")).ForTarget(999, 20));
        Assert.Same(VaultProcess, desktop.Attribution(Deny("vault.exe")).ForTarget(999, 20));
        Assert.Same(VaultProcess, desktop.Attribution(Deny("vault.exe")).ForFocus(999));
    }

    [Fact]
    public void UnresolvableWindowsStayUnattributed()
    {
        // Our own window or a vanished one resolves to nothing; aliases must not invent an owner.
        Desktop desktop = VaultDesktop();

        Assert.Null(desktop.Attribution(Deny("vault")).ForWindow(0));
        Assert.Null(desktop.Attribution(Deny("vault")).ForWindow(42));
    }

    [Fact]
    public void AnEmptyDenylistResolvesNoAliases()
    {
        Desktop desktop = VaultDesktop();

        Assert.Same(VaultProcess, desktop.Attribution(ApplicationDenylist.Empty).ForTarget(100, 10));

        Assert.Equal(1, desktop.Lookups);
    }

    [Fact]
    public void AnExcludedPrimaryResolvesNoAliases()
    {
        Desktop desktop = VaultDesktop();

        Assert.Same(VaultProcess, desktop.Attribution(Deny("vault.exe")).ForFocus(100));

        Assert.Equal(1, desktop.Lookups);
    }
}
