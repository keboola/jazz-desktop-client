using System.IO;
using System.Runtime.CompilerServices;
using System.Security;
using System.Xml.Linq;
using Microsoft.Win32;
using JazzCapture;
using JazzCaptureCore;

namespace JazzCaptureHostTests;

/// <summary>
/// <see cref="CaptureAtLaunchPolicyStore"/> is the only place this client touches the registry.
/// These tests never write real machine state -- <c>windows/README.md</c> forbids mutating machine
/// state from the local test suite -- so every scenario below injects the reader delegate instead
/// of exercising <see cref="Microsoft.Win32.Registry"/> directly.
/// </summary>
public sealed class CaptureAtLaunchPolicyStoreTests
{
    [Fact]
    public void AbsentBothRanksReadsAsNone()
    {
        var store = new CaptureAtLaunchPolicyStore((hive, key, name) => null);

        CaptureAtLaunchPolicyRead read = store.Read();

        Assert.Equal(CaptureAtLaunchPolicy.None, read.Policy);
        Assert.Null(read.Detail);
    }

    [Fact]
    public void AManagedValueOfOneReadsAsEnabledWithNoDetail()
    {
        var store = new CaptureAtLaunchPolicyStore((hive, key, name) =>
            hive == CaptureAtLaunchPolicyStore.ManagedHive ? "1" : null);

        CaptureAtLaunchPolicyRead read = store.Read();

        Assert.Equal(CaptureAtLaunchPolicyValue.Enabled, read.Policy.ManagedPolicy);
        Assert.Equal(CaptureAtLaunchPolicyValue.Absent, read.Policy.InstallerPreference);
        Assert.Null(read.Detail);
    }

    /// <summary>
    /// <see cref="CaptureAtLaunchPolicyStore.Read"/> is never asked to touch a real registry key in
    /// this test: it asserts that a read failure -- injected here for each of the exception types
    /// the store documents catching -- resolves to <see cref="CaptureAtLaunchPolicyValue.Absent"/>
    /// for that rank plus a non-empty <see cref="CaptureAtLaunchPolicyRead.Detail"/>, and never lets
    /// the exception escape. A registry read failure must never be a capture outage.
    /// </summary>
    public static IEnumerable<object[]> ReadFailureExceptions()
    {
        yield return new object[] { new SecurityException() };
        yield return new object[] { new UnauthorizedAccessException() };
        yield return new object[] { new IOException() };
        yield return new object[] { new ObjectDisposedException(nameof(CaptureAtLaunchPolicyStoreTests)) };
    }

    [Theory]
    [MemberData(nameof(ReadFailureExceptions))]
    public void AReadThatThrowsIsAbsentWithADetailRatherThanAnException(Exception toThrow)
    {
        var store = new CaptureAtLaunchPolicyStore((hive, key, name) => throw toThrow);

        CaptureAtLaunchPolicyRead read = store.Read();

        Assert.Equal(CaptureAtLaunchPolicy.None, read.Policy);
        Assert.False(string.IsNullOrEmpty(read.Detail));
    }

    /// <summary>A read failure's detail must never carry anything that looks like a rejected value
    /// -- it only ever names the key path and the exception type, never a raw registry value.</summary>
    [Fact]
    public void AReadFailureDetailNamesTheKeyNotAnyValue()
    {
        var store = new CaptureAtLaunchPolicyStore((hive, key, name) => throw new IOException());

        CaptureAtLaunchPolicyRead read = store.Read();

        Assert.Contains(CaptureAtLaunchPolicyStore.ValueName, read.Detail);
        Assert.Contains("IOException", read.Detail);
    }

    /// <summary>
    /// A value present but unparseable is a distinct outcome from a read failure: it is
    /// <see cref="CaptureAtLaunchPolicyValue.Malformed"/>, not <see cref="CaptureAtLaunchPolicyValue.Absent"/>,
    /// and it still carries a detail -- but never the value itself (#62 constraint 2).
    /// </summary>
    [Fact]
    public void AMalformedValueDetailNamesTheKeyButNeverTheValue()
    {
        const string sentinel = "SENTINEL-must-not-appear-in-detail";
        var store = new CaptureAtLaunchPolicyStore((hive, key, name) =>
            hive == CaptureAtLaunchPolicyStore.ManagedHive ? sentinel : null);

        CaptureAtLaunchPolicyRead read = store.Read();

        Assert.Equal(CaptureAtLaunchPolicyValue.Malformed, read.Policy.ManagedPolicy);
        Assert.NotNull(read.Detail);
        Assert.DoesNotContain(sentinel, read.Detail, StringComparison.Ordinal);
        Assert.Contains(CaptureAtLaunchPolicyStore.ManagedPolicyKey, read.Detail, StringComparison.Ordinal);
    }

    /// <summary>
    /// Detail precedence mirrors Resolve's own precedence for the two ranks this store can see: a
    /// managed-policy read failure that leaves it merely Absent must not eclipse a real Malformed
    /// decision at the installer-preference rank one level down.
    /// </summary>
    [Fact]
    public void ADecidingRanksDetailWinsOverAMerelyAbsentHigherRanksDetail()
    {
        var store = new CaptureAtLaunchPolicyStore((hive, key, name) => hive == CaptureAtLaunchPolicyStore.ManagedHive
            ? throw new IOException()
            : "not-a-recognised-value");

        CaptureAtLaunchPolicyRead read = store.Read();

        Assert.Equal(CaptureAtLaunchPolicyValue.Absent, read.Policy.ManagedPolicy);
        Assert.Equal(CaptureAtLaunchPolicyValue.Malformed, read.Policy.InstallerPreference);
        Assert.Contains(CaptureAtLaunchPolicyStore.InstallerPreferenceKey, read.Detail, StringComparison.Ordinal);
    }

    /// <summary>
    /// Regression guard for an Opus review finding on PR #85 (a HIGH-severity bug in the original
    /// implementation): a managed policy that decides <c>Enabled</c> outright must report
    /// <c>Detail == null</c>, even when the installer preference -- a rank
    /// <see cref="EffectiveCaptureAtLaunch.Resolve(HostSettings, bool, CaptureAtLaunchPolicy)"/>
    /// never even consults once the managed policy has decided -- independently holds a malformed
    /// value. The original bug let this combination surface the installer preference's unrelated
    /// detail, which made <c>SettingsWindow</c> render "a setting could not be read" on a machine
    /// that was, in fact, actively enforced on.
    /// </summary>
    [Fact]
    public void AnEnabledManagedPolicyReportsNoDetailEvenWhenTheInstallerPreferenceIsIndependentlyMalformed()
    {
        var store = new CaptureAtLaunchPolicyStore((hive, key, name) =>
            hive == CaptureAtLaunchPolicyStore.ManagedHive ? "1" : "not-a-recognised-value");

        CaptureAtLaunchPolicyRead read = store.Read();

        Assert.Equal(CaptureAtLaunchPolicyValue.Enabled, read.Policy.ManagedPolicy);
        Assert.Equal(CaptureAtLaunchPolicyValue.Malformed, read.Policy.InstallerPreference);
        Assert.Null(read.Detail);
    }

    /// <summary>
    /// The same regression, with the installer preference deciding instead of the managed policy:
    /// a managed-policy read failure (leaving it merely <c>Absent</c>, never a decision) must not
    /// surface its own detail once the installer preference decides <c>Enabled</c> on its own terms.
    /// </summary>
    [Fact]
    public void AnEnabledInstallerPreferenceReportsNoDetailEvenWhenTheManagedPolicyReadFailed()
    {
        var store = new CaptureAtLaunchPolicyStore((hive, key, name) => hive == CaptureAtLaunchPolicyStore.ManagedHive
            ? throw new IOException()
            : "1");

        CaptureAtLaunchPolicyRead read = store.Read();

        Assert.Equal(CaptureAtLaunchPolicyValue.Absent, read.Policy.ManagedPolicy);
        Assert.Equal(CaptureAtLaunchPolicyValue.Enabled, read.Policy.InstallerPreference);
        Assert.Null(read.Detail);
    }

    /// <summary>
    /// DWORD and string registry values must resolve to the same decision:
    /// <see cref="CaptureAtLaunchPolicyStore.NormalizeRegistryValue"/> is the pure projection that
    /// makes both shapes produce the identical string <see cref="CaptureAtLaunchPolicy.Parse"/>
    /// then parses identically -- tested directly, without touching a real registry key, since
    /// writing a real DWORD there would require the mutation the local suite forbids.
    /// </summary>
    [Theory]
    [InlineData(1, "1", CaptureAtLaunchPolicyValue.Enabled)]
    [InlineData(0, "0", CaptureAtLaunchPolicyValue.Disabled)]
    public void BothRegistryValueKindsResolveToTheSameDecision(int dword, string text, CaptureAtLaunchPolicyValue expected)
    {
        string? fromDword = CaptureAtLaunchPolicyStore.NormalizeRegistryValue(dword);
        string? fromString = CaptureAtLaunchPolicyStore.NormalizeRegistryValue(text);

        Assert.Equal(fromString, fromDword);
        Assert.Equal(expected, CaptureAtLaunchPolicy.Parse(fromDword));
        Assert.Equal(expected, CaptureAtLaunchPolicy.Parse(fromString));
    }

    /// <summary>
    /// Inverted from <c>NormalizeRegistryValueAcceptsALongTheSameAsAnInt</c>, which asserted the
    /// defect a review found. <c>REG_QWORD</c> is documented unsupported and <c>DefaultRead</c>'s
    /// <c>RegistryValueKind</c> check rejects it — but that check and the <c>GetValue</c> call are
    /// two separate registry reads, so a value rewritten between them could hand this function a
    /// <see langword="long"/> the kind check had already approved as a DWORD. For the HKCU rank that
    /// rewrite is available to the very user the value is meant to outrank. Rejecting it here too
    /// makes the pure function agree with the kind check rather than depend on it.
    /// </summary>
    [Fact]
    public void NormalizeRegistryValueRejectsALongEvenThoughAnIntIsAccepted()
    {
        Assert.Equal("1", CaptureAtLaunchPolicyStore.NormalizeRegistryValue(1));

        string? fromLong = CaptureAtLaunchPolicyStore.NormalizeRegistryValue(1L);

        Assert.NotEqual("1", fromLong);
        Assert.Equal(CaptureAtLaunchPolicyValue.Malformed, CaptureAtLaunchPolicy.Parse(fromLong));
    }

    [Fact]
    public void NormalizeRegistryValueReturnsNullForAnAbsentValue()
    {
        Assert.Null(CaptureAtLaunchPolicyStore.NormalizeRegistryValue(null));
    }

    /// <summary>
    /// A value kind this store does not expect (REG_BINARY surfaces as <c>byte[]</c>, for instance)
    /// must never be echoed back -- the sentinel is a fixed, generic marker, and it always parses as
    /// Malformed rather than silently being ignored (#60 scope 1: never fall through to the
    /// permissive option).
    /// </summary>
    [Fact]
    public void NormalizeRegistryValueRejectsAnUnsupportedKindAsMalformedWithoutEchoingIt()
    {
        byte[] raw = { 1, 2, 3 };

        string? normalized = CaptureAtLaunchPolicyStore.NormalizeRegistryValue(raw);

        Assert.NotNull(normalized);
        Assert.Equal(CaptureAtLaunchPolicyValue.Malformed, CaptureAtLaunchPolicy.Parse(normalized));
    }

    /// <summary>
    /// Regression guard for a Copilot review finding on PR #85: <see cref="RegistryKey.GetValue(string?)"/>
    /// alone cannot tell a <c>REG_SZ</c> apart from a <c>REG_EXPAND_SZ</c> (both surface as
    /// <see cref="string"/>), or a <c>REG_QWORD</c> apart from the accepted <c>REG_DWORD</c> case
    /// (the former surfaces as <see cref="long"/>, which <see cref="CaptureAtLaunchPolicyStore.NormalizeRegistryValue"/>
    /// also accepts). <see cref="CaptureAtLaunchPolicyStore.IsSupportedValueKind"/> is the gate
    /// <c>DefaultRead</c> applies before ever reading the value itself -- pinned here directly,
    /// since <c>DefaultRead</c> touches a real registry key and cannot be exercised by this
    /// mutation-free suite.
    /// </summary>
    [Theory]
    [InlineData(RegistryValueKind.DWord, true)]
    [InlineData(RegistryValueKind.String, true)]
    [InlineData(RegistryValueKind.QWord, false)]
    [InlineData(RegistryValueKind.ExpandString, false)]
    [InlineData(RegistryValueKind.MultiString, false)]
    [InlineData(RegistryValueKind.Binary, false)]
    [InlineData(RegistryValueKind.None, false)]
    [InlineData(RegistryValueKind.Unknown, false)]
    public void OnlyDwordAndStringAreSupportedValueKinds(RegistryValueKind kind, bool expectedSupported)
    {
        Assert.Equal(expectedSupported, CaptureAtLaunchPolicyStore.IsSupportedValueKind(kind));
    }

    /// <summary>
    /// The drift guard <c>windows/README.md</c> asks for: the installer-preference key this store
    /// reads must agree with what the per-user MSI's authoring will write in slice 2, composed from
    /// the same <c>Jazz.Version.props</c> properties <c>Package.wxs</c> already uses for its own
    /// <c>Software\$(var.Manufacturer)\$(var.DataFolderName)</c> key. Reads the props file as plain
    /// XML rather than invoking MSBuild, matching how <see cref="OnboardingWindowContentTests"/>
    /// locates the repository root.
    /// </summary>
    [Fact]
    public void TheInstallerPreferenceKeyAgreesWithThePackageAuthoring()
    {
        (string manufacturer, string dataFolderName, string? _) = ReadVersionProps();

        Assert.Equal(
            CaptureAtLaunchPolicyStore.InstallerPreferenceKey,
            $@"Software\{manufacturer}\{dataFolderName}\Policy");
    }

    /// <summary>
    /// The same drift guard, extended to the value name (a review finding on PR #85: the key-path
    /// guard alone would not catch slice 2 authoring a <c>JazzPolicyValueName</c> that disagreed
    /// with <see cref="CaptureAtLaunchPolicyStore.ValueName"/> -- the MSI would then write a value
    /// this client silently never reads). Slice 1 has not added that property yet, so this is
    /// deliberately lenient rather than a hard requirement today: if <c>Jazz.Version.props</c>
    /// already defines it (once slice 2 lands), the two must agree; until then this test passes
    /// vacuously rather than failing on a property slice 1 has no business asserting exists.
    /// </summary>
    [Fact]
    public void TheValueNameAgreesWithThePackageAuthoringOnceSliceTwoDefinesIt()
    {
        (string _, string _, string? policyValueName) = ReadVersionProps();

        if (policyValueName is not null)
        {
            Assert.Equal(CaptureAtLaunchPolicyStore.ValueName, policyValueName);
        }
    }

    private static (string Manufacturer, string DataFolderName, string? PolicyValueName) ReadVersionProps(
        [CallerFilePath] string testFilePath = "")
    {
        string windowsRoot = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(testFilePath)!, "..", ".."));
        string propsPath = Path.Combine(windowsRoot, "installer", "Jazz.Version.props");
        XDocument document = XDocument.Load(propsPath);

        string manufacturer = document.Descendants("JazzManufacturer").Single().Value;
        string dataFolderName = document.Descendants("JazzDataFolderName").Single().Value;
        string? policyValueName = document.Descendants("JazzPolicyValueName").SingleOrDefault()?.Value;
        return (manufacturer, dataFolderName, policyValueName);
    }
}
