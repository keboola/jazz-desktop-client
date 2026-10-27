using JazzCapture;

namespace JazzCaptureHostTests;

public sealed class CommandCenterUrlPolicyStoreTests
{
    private const string ValidUrl = "https://cc.example.com/client-policy.json";

    [Fact]
    public void AbsentBothRanksReadsAsUnconfigured()
    {
        var store = new CommandCenterUrlPolicyStore((_, _, _) => null);
        CommandCenterUrlRead read = store.Read();
        Assert.Null(read.Url);
        Assert.Null(read.Detail);
    }

    [Fact]
    public void ManagedPolicyWinsOverInstallerPreference()
    {
        var store = new CommandCenterUrlPolicyStore((hive, _, _) =>
            hive == CommandCenterUrlPolicyStore.ManagedHive
                ? "https://managed.example/policy.json"
                : "https://installer.example/policy.json");

        CommandCenterUrlRead read = store.Read();
        Assert.Equal("https://managed.example/policy.json", read.Url);
    }

    [Fact]
    public void InstallerPreferenceIsUsedWhenManagedIsAbsent()
    {
        var store = new CommandCenterUrlPolicyStore((hive, _, _) =>
            hive == CommandCenterUrlPolicyStore.InstallerHive ? ValidUrl : null);

        CommandCenterUrlRead read = store.Read();
        Assert.Equal(ValidUrl, read.Url);
    }

    [Fact]
    public void InvalidManagedUrlIsRefusedWithoutEchoingTheValue()
    {
        const string rejected = "http://insecure.example/policy.json";
        var store = new CommandCenterUrlPolicyStore((hive, _, _) =>
            hive == CommandCenterUrlPolicyStore.ManagedHive ? rejected : null);

        CommandCenterUrlRead read = store.Read();
        Assert.Null(read.Url);
        Assert.Contains(CommandCenterUrlPolicyStore.ValueName, read.Detail);
        Assert.DoesNotContain(rejected, read.Detail, StringComparison.Ordinal);
    }
}
