using JazzCaptureCore;
using JazzCaptureCore.Screen;

namespace JazzCaptureCoreTests;

/// <summary>
/// Pins the owner check that stands between a click and a screenshot: the right application's
/// window is photographed whichever way it was identified, and another application's never is.
/// </summary>
public sealed class ScreenshotOwnershipTests
{
    private static readonly AppIdentity EdgeByProcess = new(
        AppIdentity.ExecutablePathNamespace,
        "c:/program files (x86)/microsoft/edge/application/msedge.exe",
        "Microsoft Edge");

    private static readonly AppIdentity EdgeByWindow = new(AppIdentity.AumidNamespace, "MSEdge", "MSEdge");

    private static readonly AppIdentity ExcelByProcess = new(
        AppIdentity.ExecutablePathNamespace,
        "c:/program files/microsoft office/root/office16/excel.exe",
        "Microsoft Excel");

    /// <summary>
    /// The browser regression: a click resolved by process, landing in a window that carries an
    /// AUMID. Before the fix this was refused as an owner mismatch on every Edge and Chrome click.
    /// </summary>
    [Fact]
    public void AWindowWithAnAumidIsOwnedByTheClickOwnerResolvedByProcess()
    {
        Assert.True(ScreenshotOwnership.IsOwnedBy(EdgeByProcess, EdgeByWindow, EdgeByProcess, ApplicationDenylist.Empty));
    }

    [Fact]
    public void AnOwnerResolvedByWindowStillMatchesItsWindow()
    {
        Assert.True(ScreenshotOwnership.IsOwnedBy(EdgeByWindow, EdgeByWindow, EdgeByProcess, ApplicationDenylist.Empty));
    }

    [Fact]
    public void AWindowWithoutAnAumidMatchesByProcess()
    {
        Assert.True(ScreenshotOwnership.IsOwnedBy(ExcelByProcess, ExcelByProcess, ExcelByProcess, ApplicationDenylist.Empty));
    }

    [Fact]
    public void ExecutablePathsCompareCaseInsensitively()
    {
        AppIdentity shouted = EdgeByProcess with { Value = EdgeByProcess.Value.ToUpperInvariant() };

        Assert.True(ScreenshotOwnership.IsOwnedBy(EdgeByProcess, EdgeByWindow, shouted, ApplicationDenylist.Empty));
    }

    [Fact]
    public void AnotherApplicationsWindowIsRefused()
    {
        Assert.False(ScreenshotOwnership.IsOwnedBy(ExcelByProcess, EdgeByWindow, EdgeByProcess, ApplicationDenylist.Empty));
        Assert.False(ScreenshotOwnership.IsOwnedBy(EdgeByProcess, ExcelByProcess, ExcelByProcess, ApplicationDenylist.Empty));
    }

    /// <summary>The same string in different namespaces names different things.</summary>
    [Fact]
    public void AValueInTheOtherNamespaceIsNotAMatch()
    {
        var aumidLookalike = new AppIdentity(AppIdentity.AumidNamespace, EdgeByProcess.Value);

        Assert.False(ScreenshotOwnership.IsOwnedBy(EdgeByProcess, aumidLookalike, null, ApplicationDenylist.Empty));
    }

    [Fact]
    public void AnUnresolvableWindowIsRefused()
    {
        Assert.False(ScreenshotOwnership.IsOwnedBy(EdgeByProcess, null, null, ApplicationDenylist.Empty));
        Assert.False(ScreenshotOwnership.IsOwnedBy(
            EdgeByProcess,
            new AppIdentity(AppIdentity.AumidNamespace, " "),
            new AppIdentity(AppIdentity.ExecutablePathNamespace, ""), ApplicationDenylist.Empty));
    }

    [Fact]
    public void ABlankOwnerMatchesNothing()
    {
        var blank = new AppIdentity(AppIdentity.ExecutablePathNamespace, "");

        Assert.False(ScreenshotOwnership.IsOwnedBy(blank, blank, blank, ApplicationDenylist.Empty));
    }

    /// <summary>
    /// A denylisted window stays out of the archive whichever identity the exclusion names, even
    /// when the click owner matched on the other one.
    /// </summary>
    [Fact]
    public void AWindowExcludedByEitherIdentityIsRefused()
    {
        var byAumid = new ApplicationDenylist(new[] { EdgeByWindow.Value });
        var byPath = new ApplicationDenylist(new[] { EdgeByProcess.Value });

        Assert.False(ScreenshotOwnership.IsOwnedBy(EdgeByProcess, EdgeByWindow, EdgeByProcess, byAumid));
        Assert.False(ScreenshotOwnership.IsOwnedBy(EdgeByWindow, EdgeByWindow, EdgeByProcess, byPath));
    }

    [Fact]
    public void ADenylistNamingAnotherApplicationDoesNotRefuse()
    {
        var excelOnly = new ApplicationDenylist(new[] { ExcelByProcess.Value });

        Assert.True(ScreenshotOwnership.IsOwnedBy(EdgeByProcess, EdgeByWindow, EdgeByProcess, excelOnly));
    }
}
