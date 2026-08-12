using System.Text.Json.Nodes;
using JazzEnrollmentSecurity;
using JazzEnrollmentSecurityTests.Support;

namespace JazzEnrollmentSecurityTests;

/// <summary>
/// Accounts for the one family of vectors under <c>contract/enrollment/</c> this module does not
/// implement, so "unported" cannot quietly become "accepted".
/// </summary>
/// <remarks>
/// <para>
/// The MVP operator handoff is an unsigned bundle an administrator pastes, whose narrow token the
/// macOS client proves live against Keboola Storage before persisting it. The Windows client has no
/// Storage API client, so the liveness proof that makes the profile safe does not exist here, and
/// the profile is deliberately not ported.
/// </para>
/// <para>
/// What matters is that the gap fails closed. An unsigned object must not slip through the signed
/// importer merely because the signed path never looked at it.
/// </para>
/// </remarks>
public sealed class UnportedEnrollmentProfileTests
{
    public static TheoryData<string> MvpFixtures()
    {
        var data = new TheoryData<string>();
        foreach (string name in EnrollmentContract.MvpFixtureNames())
        {
            data.Add(name);
        }

        return data;
    }

    [Theory]
    [MemberData(nameof(MvpFixtures))]
    public void TheUnsignedMvpHandoffIsRefusedByTheSignedImporter(string name)
    {
        using var harness = new SignedEnrollmentHarness();
        JsonObject bundle = EnrollmentContract.ReadObject("mvp-fixtures", name);
        Assert.Equal("mvp", bundle["enrollmentProfile"]!.GetValue<string>());

        SignedEnrollmentException error = Assert.Throws<SignedEnrollmentException>(
            () => harness.Importer.Authorize(
                EnrollmentContract.CanonicalText(bundle),
                SignedEnrollmentRefusalTests.Instant("2026-07-24T09:35:00Z")));

        Assert.Equal(SignedEnrollmentError.MalformedEnvelope, error.Reason);
    }

    [Fact]
    public void EveryContractEnrollmentFixtureIsEitherVerifiedOrExplicitlyRefused()
    {
        // A guard against a vector being added to the shared contract and silently going unread by
        // this client. Both accepted families and the refused one are enumerated from disk.
        Assert.NotEmpty(EnrollmentContract.SignedFixtureNames());
        Assert.NotEmpty(EnrollmentContract.MvpFixtureNames());
        Assert.NotEmpty(Directory.GetFiles(
            EnrollmentContract.Path_("device-bound", "fixtures"),
            "*.json"));
        Assert.NotEmpty(Directory.GetFiles(
            EnrollmentContract.Path_("device-bound", "http-fixtures"),
            "*.json"));

        string[] families = Directory
            .GetDirectories(EnrollmentContract.Path_())
            .Select(path => Path.GetFileName(path)!)
            .OrderBy(name => name, StringComparer.Ordinal)
            .ToArray();
        Assert.Equal(new[] { "device-bound", "fixtures", "mvp-fixtures", "schema" }, families);
    }
}
