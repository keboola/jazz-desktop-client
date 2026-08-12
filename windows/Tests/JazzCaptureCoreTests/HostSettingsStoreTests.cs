using System.Text;
using System.Text.Json.Nodes;
using JazzCaptureCore;
using JazzCaptureCore.Json;

namespace JazzCaptureCoreTests;

/// <summary>
/// The exclusion list is the one privacy control the user drives directly, so its persistence is
/// tested for the four things that decide whether it can be trusted: a fresh profile gets the seeds,
/// a removal survives a restart, what was saved is what comes back, and a damaged file degrades to
/// the seeds instead of taking the client down on startup.
/// </summary>
public sealed class HostSettingsStoreTests : IDisposable
{
    private static readonly string[] Seeds = { "1password", "bitwarden", "logonui.exe" };

    private readonly string _root = Path.Combine(
        Path.GetTempPath(),
        "jazz-settings-" + Guid.NewGuid().ToString("n"));

    public HostSettingsStoreTests() => Directory.CreateDirectory(_root);

    public void Dispose()
    {
        try
        {
            Directory.Delete(_root, recursive: true);
        }
        catch (IOException)
        {
            // A scanner still holding the directory must not fail the test run.
        }
    }

    private string Path_ => Path.Combine(_root, HostSettingsStore.FileName);

    [Fact]
    public void AFreshProfileStartsFromTheSeeds()
    {
        HostSettingsLoad load = HostSettingsStore.Load(Path_, Seeds);

        Assert.Equal(HostSettingsOrigin.Seeded, load.Origin);
        Assert.Null(load.Detail);
        Assert.Equal(new[] { "1password", "bitwarden", "logonui.exe" }, load.Settings.ExcludedApplications);
        Assert.Equal(HostSettingsStore.DefaultHighlightClicks, load.Settings.HighlightClicks);
    }

    [Fact]
    public void LoadingAFreshProfileWritesNothing()
    {
        HostSettingsStore.Load(Path_, Seeds);

        // No file means no decision has been recorded yet, and that has to stay observable: it is
        // the only thing separating "never configured" from "configured to look like the defaults".
        Assert.False(File.Exists(Path_));
    }

    [Fact]
    public void ARemovedSeedStaysRemoved()
    {
        HostSettingsLoad first = HostSettingsStore.Load(Path_, Seeds);
        string[] withoutBitwarden = first.Settings.ExcludedApplications
            .Where(entry => entry != "bitwarden")
            .ToArray();

        HostSettingsStore.Save(Path_, new HostSettings(withoutBitwarden, HighlightClicks: false));

        HostSettingsLoad reopened = HostSettingsStore.Load(Path_, Seeds);
        Assert.Equal(HostSettingsOrigin.Loaded, reopened.Origin);
        Assert.DoesNotContain("bitwarden", reopened.Settings.ExcludedApplications);
        Assert.Equal(new[] { "1password", "logonui.exe" }, reopened.Settings.ExcludedApplications);
    }

    [Fact]
    public void AnEmptiedListStaysEmpty()
    {
        // The strongest form of the same rule: a user who removes every seed is making a choice,
        // not resetting to the defaults.
        HostSettingsStore.Save(Path_, new HostSettings(Array.Empty<string>(), HighlightClicks: false));

        HostSettingsLoad reopened = HostSettingsStore.Load(Path_, Seeds);
        Assert.Equal(HostSettingsOrigin.Loaded, reopened.Origin);
        Assert.Empty(reopened.Settings.ExcludedApplications);
    }

    [Fact]
    public void SavedSettingsRoundTrip()
    {
        var saved = new HostSettings(
            new[] { "c:/program files/contoso/vault.exe", "Contoso.Bank_8wekyb3d8bbwe!App" },
            HighlightClicks: true);

        HostSettingsStore.Save(Path_, saved);
        HostSettingsLoad reopened = HostSettingsStore.Load(Path_, Seeds);

        Assert.Equal(HostSettingsOrigin.Loaded, reopened.Origin);
        Assert.Equal(saved.ExcludedApplications, reopened.Settings.ExcludedApplications);
        Assert.True(reopened.Settings.HighlightClicks);
    }

    [Fact]
    public void SavingNormalizesAndCanonicalizes()
    {
        HostSettingsStore.Save(
            Path_,
            new HostSettings(new[] { "  Zulu  ", "alpha", "ALPHA", "   ", "mike" }, HighlightClicks: false));

        string text = File.ReadAllText(Path_, Encoding.UTF8);

        // Byte-for-byte canonical: sorted keys, no whitespace, and the entries in the one order the
        // normalizer produces, so two profiles holding the same preferences hold the same file.
        Assert.Equal(
            "{\"excludedApplications\":[\"alpha\",\"mike\",\"Zulu\"],"
            + "\"highlightClicks\":false,\"schemaVersion\":1}",
            text);
        Assert.Equal(text, JsonCanonicalizer.Canonicalize(JsonStrictParser.Parse(text)));
    }

    [Fact]
    public void NoAbsentFieldIsEverWrittenAsNull()
    {
        HostSettingsStore.Save(Path_, new HostSettings(Array.Empty<string>(), HighlightClicks: false));

        var root = Assert.IsType<JsonObject>(JsonStrictParser.Parse(File.ReadAllText(Path_, Encoding.UTF8)));
        Assert.All(root, pair => Assert.NotNull(pair.Value));
    }

    [Theory]
    [InlineData("{ this is not json")]
    [InlineData("[]")]
    [InlineData("\"a string\"")]
    [InlineData("{\"schemaVersion\":1}")]
    [InlineData("{\"schemaVersion\":99,\"excludedApplications\":[],\"highlightClicks\":false}")]
    [InlineData("{\"schemaVersion\":1,\"excludedApplications\":[7],\"highlightClicks\":false}")]
    [InlineData("{\"schemaVersion\":1,\"excludedApplications\":[],\"highlightClicks\":\"yes\"}")]
    [InlineData("{\"schemaVersion\":1,\"excludedApplications\":{},\"highlightClicks\":false}")]
    public void ACorruptFileFallsBackToTheSeedsInsteadOfThrowing(string contents)
    {
        File.WriteAllText(Path_, contents, Encoding.UTF8);

        HostSettingsLoad load = HostSettingsStore.Load(Path_, Seeds);

        Assert.Equal(HostSettingsOrigin.Unreadable, load.Origin);
        Assert.False(string.IsNullOrWhiteSpace(load.Detail));
        Assert.Equal(new[] { "1password", "bitwarden", "logonui.exe" }, load.Settings.ExcludedApplications);

        // Falling back must not destroy what the user had: the next save supersedes the file, but a
        // parser disagreement on its own is no reason to throw their list away.
        Assert.Equal(contents, File.ReadAllText(Path_, Encoding.UTF8));
    }

    [Fact]
    public void SavingReplacesAnUnreadableFile()
    {
        File.WriteAllText(Path_, "{ broken", Encoding.UTF8);

        HostSettingsStore.Save(Path_, new HostSettings(new[] { "vault.exe" }, HighlightClicks: true));

        HostSettingsLoad load = HostSettingsStore.Load(Path_, Seeds);
        Assert.Equal(HostSettingsOrigin.Loaded, load.Origin);
        Assert.Equal(new[] { "vault.exe" }, load.Settings.ExcludedApplications);
    }
}
