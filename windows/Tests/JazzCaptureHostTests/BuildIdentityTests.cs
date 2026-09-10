using System.Reflection;
using JazzCapture;

namespace JazzCaptureHostTests;

public sealed class BuildIdentityTests
{
    [Fact]
    public void ExecutableSettingsUiAndArchiveProducerUseOneVersion()
    {
        string canonical = BuildIdentity.ProducerVersion;
        Version assembly = typeof(App).Assembly.GetName().Version
            ?? throw new InvalidOperationException("JazzCapture assembly version is missing.");

        Assert.Equal($"{assembly.Major}.{assembly.Minor}.{assembly.Build}", canonical);
        Assert.Equal(canonical, new Settings().ProducerVersion);
        Assert.Equal(
            canonical,
            typeof(App).Assembly.GetCustomAttributes<AssemblyMetadataAttribute>()
                .Single(attribute => attribute.Key == "JazzProducerVersion").Value);
    }
}
