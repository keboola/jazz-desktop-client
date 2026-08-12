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
/// <remarks>
/// The microphone preference is held to the same standard, plus one of its own: a file written
/// before the key existed has to keep working, because an upgrade that silently reset somebody's
/// exclusion list would be a far worse failure than the missing preference it was reacting to.
/// </remarks>
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

        HostSettingsStore.Save(
            Path_,
            new HostSettings(withoutBitwarden, HighlightClicks: false, NarrationEnabled: false));

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
        HostSettingsStore.Save(
            Path_,
            new HostSettings(Array.Empty<string>(), HighlightClicks: false, NarrationEnabled: false));

        HostSettingsLoad reopened = HostSettingsStore.Load(Path_, Seeds);
        Assert.Equal(HostSettingsOrigin.Loaded, reopened.Origin);
        Assert.Empty(reopened.Settings.ExcludedApplications);
    }

    [Fact]
    public void SavedSettingsRoundTrip()
    {
        var saved = new HostSettings(
            new[] { "c:/program files/contoso/vault.exe", "Contoso.Bank_8wekyb3d8bbwe!App" },
            HighlightClicks: true,
            NarrationEnabled: true);

        HostSettingsStore.Save(Path_, saved);
        HostSettingsLoad reopened = HostSettingsStore.Load(Path_, Seeds);

        Assert.Equal(HostSettingsOrigin.Loaded, reopened.Origin);
        Assert.Equal(saved.ExcludedApplications, reopened.Settings.ExcludedApplications);
        Assert.True(reopened.Settings.HighlightClicks);
        Assert.True(reopened.Settings.NarrationEnabled);
    }

    [Fact]
    public void NarrationStaysOffUntilTheUserTurnsItOnAndThenStaysOn()
    {
        // The whole point of persisting it: a decision about the microphone is made once, not once
        // per launch. Both directions have to survive, so turning it back off is tested too.
        Assert.False(HostSettingsStore.Load(Path_, Seeds).Settings.NarrationEnabled);

        HostSettingsStore.Save(
            Path_,
            new HostSettings(Seeds, HighlightClicks: false, NarrationEnabled: true));
        Assert.True(HostSettingsStore.Load(Path_, Seeds).Settings.NarrationEnabled);

        HostSettingsStore.Save(
            Path_,
            new HostSettings(Seeds, HighlightClicks: false, NarrationEnabled: false));
        Assert.False(HostSettingsStore.Load(Path_, Seeds).Settings.NarrationEnabled);
    }

    [Fact]
    public void ASettingsFileWrittenBeforeNarrationExistedStillLoads()
    {
        // Exactly what an installation upgraded from a build without the microphone has on disk:
        // schema version 1, no narrationEnabled key. Rejecting it would throw away the user's
        // exclusion list -- the thing this store exists to protect -- to learn something the
        // default already says.
        File.WriteAllText(
            Path_,
            "{\"excludedApplications\":[\"vault.exe\"],\"highlightClicks\":true,\"schemaVersion\":1}",
            Encoding.UTF8);

        HostSettingsLoad load = HostSettingsStore.Load(Path_, Seeds);

        Assert.Equal(HostSettingsOrigin.Loaded, load.Origin);
        Assert.Null(load.Detail);
        Assert.Equal(new[] { "vault.exe" }, load.Settings.ExcludedApplications);
        Assert.True(load.Settings.HighlightClicks);
        Assert.Equal(HostSettingsStore.DefaultNarrationEnabled, load.Settings.NarrationEnabled);
        Assert.False(load.Settings.NarrationEnabled);
    }

    [Fact]
    public void ANarrationKeyThatIsNotABooleanIsStillAParseFailure()
    {
        // Absent is a fact about which version wrote the file; a string where a boolean belongs is a
        // file this build does not understand, and reading it as "off" would be inventing consent
        // state out of a mistyped preference.
        File.WriteAllText(
            Path_,
            "{\"excludedApplications\":[],\"highlightClicks\":false,"
            + "\"narrationEnabled\":\"yes\",\"schemaVersion\":1}",
            Encoding.UTF8);

        HostSettingsLoad load = HostSettingsStore.Load(Path_, Seeds);

        Assert.Equal(HostSettingsOrigin.Unreadable, load.Origin);
        Assert.Contains("narrationEnabled", load.Detail!, StringComparison.Ordinal);
    }

    [Fact]
    public void SavingNormalizesAndCanonicalizes()
    {
        HostSettingsStore.Save(
            Path_,
            new HostSettings(
                new[] { "  Zulu  ", "alpha", "ALPHA", "   ", "mike" },
                HighlightClicks: false,
                NarrationEnabled: false));

        string text = File.ReadAllText(Path_, Encoding.UTF8);

        // Byte-for-byte canonical: sorted keys, no whitespace, and the entries in the one order the
        // normalizer produces, so two profiles holding the same preferences hold the same file.
        Assert.Equal(
            "{\"excludedApplications\":[\"alpha\",\"mike\",\"Zulu\"],"
            + "\"highlightClicks\":false,\"narrationEnabled\":false,\"schemaVersion\":1}",
            text);
        Assert.Equal(text, JsonCanonicalizer.Canonicalize(JsonStrictParser.Parse(text)));
    }

    [Fact]
    public void NoAbsentFieldIsEverWrittenAsNull()
    {
        HostSettingsStore.Save(
            Path_,
            new HostSettings(Array.Empty<string>(), HighlightClicks: false, NarrationEnabled: false));

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

        HostSettingsStore.Save(
            Path_,
            new HostSettings(new[] { "vault.exe" }, HighlightClicks: true, NarrationEnabled: false));

        HostSettingsLoad load = HostSettingsStore.Load(Path_, Seeds);
        Assert.Equal(HostSettingsOrigin.Loaded, load.Origin);
        Assert.Equal(new[] { "vault.exe" }, load.Settings.ExcludedApplications);
    }
}
