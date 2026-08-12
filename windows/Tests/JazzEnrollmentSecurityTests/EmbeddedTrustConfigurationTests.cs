using System.Reflection;
using JazzEnrollmentSecurity;

namespace JazzEnrollmentSecurityTests;

/// <summary>
/// The production trust-loading path: configuration read out of the signed assembly, not off disk.
/// </summary>
/// <remarks>
/// A file beside the executable is deliberately not supported. Anyone who can write next to the
/// binary could otherwise install their own enrollment trust root; an embedded resource is covered
/// by the same signature as the code that reads it.
/// </remarks>
public sealed class EmbeddedTrustConfigurationTests
{
    [Fact]
    public void TheEmbeddedConfigurationYieldsBothTheTrustPolicyAndTheRouteAllowlist()
    {
        EnrollmentTrustConfiguration? configuration =
            EnrollmentTrustBootstrap.LoadEmbeddedConfiguration(Assembly.GetExecutingAssembly());

        Assert.NotNull(configuration);

        EnrollmentTrustPolicy? policy = EnrollmentTrustBootstrap.Load(configuration);
        Assert.NotNull(policy);
        Assert.Equal("https://jazz.example.test", policy.Issuer);
        Assert.Equal("jazz-desktop-client", policy.Audience);
        Assert.True(policy.HasPublicKey("test-2026-07-rfc8032-1"));

        EnrollmentRedemptionRoutePolicy? route =
            EnrollmentTrustBootstrap.LoadRedemptionRoutePolicy(configuration);
        Assert.NotNull(route);
        Assert.True(route.Allows("https://native.example.test/jazz/api/device-enrollment/redemptions/x"));
    }

    [Fact]
    public void AnAssemblyWithNoEmbeddedConfigurationYieldsNoTrust()
    {
        // The library itself carries none: trust belongs to the signed host, not to a shared
        // component that several hosts might link.
        Assembly library = typeof(EnrollmentTrustBootstrap).Assembly;

        Assert.Null(EnrollmentTrustBootstrap.LoadEmbeddedConfiguration(library));
        Assert.Null(EnrollmentTrustBootstrap.Load(null));
        Assert.Null(EnrollmentTrustBootstrap.LoadRedemptionRoutePolicy(null));
    }

    [Fact]
    public void TheEmbeddedResourceNameIsTheOneTheLoaderLooksFor()
    {
        string[] names = Assembly.GetExecutingAssembly().GetManifestResourceNames();

        Assert.Contains(
            names,
            name => name.EndsWith(EnrollmentTrustBootstrap.EmbeddedResourceName, StringComparison.Ordinal));
    }
}
