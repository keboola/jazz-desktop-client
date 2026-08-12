using JazzCaptureCore;

namespace JazzCaptureCoreTests;

/// <summary>
/// The denylist rule decides whether a password manager reaches the archive, so it is tested for
/// what it must match, what it must not, and the normalization the settings window relies on to show
/// the user exactly what will be compared.
/// </summary>
public sealed class ApplicationDenylistTests
{
    private static AppIdentity Exe(string path) => new(AppIdentity.ExecutablePathNamespace, path, "Contoso");

    [Fact]
    public void AShortEntryMatchesAnywhereInsideAnInstalledPath()
    {
        // This is the case the seeded entries exist for. Under an equality rule every seed in this
        // client matched nothing at all, which is the failure a user could not possibly detect.
        var denylist = new ApplicationDenylist(new[] { "1password" });

        Assert.True(denylist.IsExcluded(Exe("c:/program files/1password/1password.exe")));
        Assert.True(denylist.IsExcluded(Exe("d:/apps/1Password/app/8/1Password.exe")));
    }

    [Fact]
    public void MatchingIgnoresCase()
    {
        var denylist = new ApplicationDenylist(new[] { "Contoso.Vault" });

        Assert.True(denylist.IsExcluded(new AppIdentity(AppIdentity.AumidNamespace, "contoso.VAULT")));
    }

    [Fact]
    public void AWholeIdentityValueMatchesItself()
    {
        // What the "Exclude a running app" picker writes: the identity the capture would attribute.
        const string value = "c:/program files/contoso/bank.exe";
        var denylist = new ApplicationDenylist(new[] { value });

        Assert.True(denylist.IsExcluded(Exe(value)));
    }

    [Fact]
    public void UnrelatedApplicationsAreNotExcluded()
    {
        var denylist = new ApplicationDenylist(new[] { "1password", "logonui.exe" });

        Assert.False(denylist.IsExcluded(Exe("c:/program files/contoso/browser.exe")));
        Assert.False(denylist.IsExcluded(new AppIdentity(AppIdentity.AumidNamespace, "Contoso.Browser")));
    }

    [Fact]
    public void AnUnresolvedOrAbsentOwnerIsNotAMatch()
    {
        var denylist = new ApplicationDenylist(new[] { "vault" });

        Assert.False(denylist.IsExcluded((AppIdentity?)null));
        Assert.False(denylist.IsExcluded(new AppIdentity(AppIdentity.ExecutablePathNamespace, "   ")));
        Assert.False(denylist.IsExcluded((string?)null));
        Assert.False(denylist.IsExcluded(string.Empty));
    }

    [Fact]
    public void AnEmptyDenylistExcludesNothing()
    {
        Assert.True(ApplicationDenylist.Empty.IsEmpty);
        Assert.False(ApplicationDenylist.Empty.IsExcluded(Exe("c:/windows/system32/logonui.exe")));
    }

    [Fact]
    public void BlankEntriesAreDroppedRatherThanMatchingEverything()
    {
        // A surviving empty entry would be a substring of every identity, silently excluding the
        // whole desktop.
        var denylist = new ApplicationDenylist(new[] { "  ", string.Empty, "\t" });

        Assert.True(denylist.IsEmpty);
        Assert.False(denylist.IsExcluded(Exe("c:/program files/contoso/browser.exe")));
    }

    [Fact]
    public void NormalizationTrimsDeduplicatesAndOrders()
    {
        string[] normalized = ApplicationDenylist.Normalize(
            new[] { " zulu ", "alpha", "ALPHA", "   ", "Mike" });

        // Case is preserved on the first occurrence so an AUMID stays recognizable, duplicates that
        // differ only by case collapse, and the order is stable so the file does not churn.
        Assert.Equal(new[] { "alpha", "Mike", "zulu" }, normalized);
    }

    [Fact]
    public void NormalizationIsIdempotent()
    {
        string[] once = ApplicationDenylist.Normalize(new[] { " zulu ", "ALPHA", "alpha" });
        Assert.Equal(once, ApplicationDenylist.Normalize(once));
    }

    [Fact]
    public void EntriesAreExposedNormalized()
    {
        var denylist = new ApplicationDenylist(new[] { " zulu ", "alpha" });

        Assert.Equal(new[] { "alpha", "zulu" }, denylist.Entries);
    }
}
