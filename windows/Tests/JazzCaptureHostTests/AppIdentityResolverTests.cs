using JazzCapture.Capture;
using JazzCaptureCore;

namespace JazzCaptureHostTests;

/// <summary>
/// Pins that a failed AUMID read is reported as such and is never confused with a window that has
/// no AUMID. The Win32 and Shell calls are faked, so no desktop is needed.
/// </summary>
public sealed class AppIdentityResolverTests
{
    private const uint Pid = 4242;
    private static readonly IntPtr Window = (IntPtr)0x1234;
    private const string ExePath = @"C:\Program Files\Contoso\Vault\vault.exe";
    private const string Aumid = "Contoso.Vault_8wekyb3d8bbwe!App";

    private static AppIdentityResolver ResolverWith(AumidRead read) => new(
        windowProcessId: _ => Pid,
        readAumid: _ => read,
        queryImagePath: _ => ExePath);

    [Fact]
    public void AFoundAumidIsTheIdentity()
    {
        ResolvedWindow resolved = ResolverWith(AumidRead.Found(Aumid)).ResolveWindow(Window);

        Assert.False(resolved.AumidUnreadable);
        Assert.Equal(AppIdentity.AumidNamespace, resolved.Identity!.Namespace);
        Assert.Equal(Aumid, resolved.Identity.Value);
    }

    [Fact]
    public void AnAbsentAumidFallsBackToThePathAndIsNotUnreadable()
    {
        ResolvedWindow resolved = ResolverWith(AumidRead.Absent).ResolveWindow(Window);

        Assert.False(resolved.AumidUnreadable);
        Assert.Equal(AppIdentity.ExecutablePathNamespace, resolved.Identity!.Namespace);
        Assert.Equal("c:/program files/contoso/vault/vault.exe", resolved.Identity.Value);
    }

    [Fact]
    public void AFailedAumidReadFallsBackToThePathAndIsMarkedUnreadable()
    {
        ResolvedWindow resolved = ResolverWith(AumidRead.Failed).ResolveWindow(Window);

        Assert.True(resolved.AumidUnreadable);
        Assert.Equal(AppIdentity.ExecutablePathNamespace, resolved.Identity!.Namespace);
    }

    [Fact]
    public void AFoundButBlankAumidIsTreatedAsAbsent()
    {
        ResolvedWindow resolved = ResolverWith(AumidRead.Found("  ")).ResolveWindow(Window);

        Assert.False(resolved.AumidUnreadable);
        Assert.Equal(AppIdentity.ExecutablePathNamespace, resolved.Identity!.Namespace);
    }

    [Fact]
    public void ResolveStillReturnsThePathIdentityWhenTheReadFails()
    {
        AppIdentity? identity = ResolverWith(AumidRead.Failed).Resolve(Window);

        Assert.Equal(AppIdentity.ExecutablePathNamespace, identity!.Namespace);
    }

    [Fact]
    public void AWindowWithNoProcessIsNotAttributedAndNotUnreadable()
    {
        var resolver = new AppIdentityResolver(_ => 0, _ => AumidRead.Failed, _ => ExePath);

        ResolvedWindow resolved = resolver.ResolveWindow(Window);

        Assert.Null(resolved.Identity);
        Assert.False(resolved.AumidUnreadable);
    }
}
