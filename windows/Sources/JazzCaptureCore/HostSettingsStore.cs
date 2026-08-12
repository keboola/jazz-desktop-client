using System.Text;
using System.Text.Json.Nodes;
using JazzCaptureCore.Journal;
using JazzCaptureCore.Json;

namespace JazzCaptureCore;

/// <summary>The host preferences that survive a restart.</summary>
/// <param name="ExcludedApplications">
/// Applications the user has asked never to be recorded. Already normalized by
/// <see cref="ApplicationDenylist.Normalize"/> whenever it comes from
/// <see cref="HostSettingsStore"/>.
/// </param>
/// <param name="HighlightClicks">
/// Whether a brief flash is drawn over the element each click resolved to. Off by default: it is a
/// visible change to the user's screen, so it is something they turn on, not something they discover
/// happening.
/// </param>
/// <param name="NarrationEnabled">
/// Whether the microphone records think-aloud narration for the length of each declared label. No
/// default: every construction states what it means, so a later call site cannot acquire a
/// microphone setting by omission.
/// </param>
public sealed record HostSettings(
    IReadOnlyList<string> ExcludedApplications,
    bool HighlightClicks,
    bool NarrationEnabled);

/// <summary>How <see cref="HostSettingsStore.Load"/> arrived at the settings it returned.</summary>
public enum HostSettingsOrigin
{
    /// <summary>No settings file existed, so the built-in seeds were used.</summary>
    Seeded,

    /// <summary>A settings file was read; its contents are authoritative.</summary>
    Loaded,

    /// <summary>A settings file existed but could not be used; the seeds stood in for it.</summary>
    Unreadable,
}

/// <summary>The outcome of a load, including why it turned out that way.</summary>
/// <param name="Settings">The settings to run with.</param>
/// <param name="Origin">Where those settings came from.</param>
/// <param name="Detail">
/// Why a file was rejected, for the settings window to show. Absent unless
/// <see cref="Origin"/> is <see cref="HostSettingsOrigin.Unreadable"/>.
/// </param>
public sealed record HostSettingsLoad(
    HostSettings Settings,
    HostSettingsOrigin Origin,
    string? Detail = null);

/// <summary>
/// Reads and writes the host preferences as one canonical JSON document, so the exclusion list the
/// user edits is still there on the next run.
/// </summary>
/// <remarks>
/// <para>
/// <b>Seeds apply only while no file exists.</b> The built-in list of credential surfaces is a
/// starting point for a fresh installation, not a floor. Once anything has been saved, the file is
/// the whole truth and the seeds are never consulted again — so an entry the user deliberately
/// removed stays removed, which is the only behaviour that makes the list feel like a control rather
/// than a suggestion. The cost of that choice is that a seed added by a later version of this client
/// never reaches an existing installation, and that is the right way round: silently re-adding
/// exclusions is merely surprising, while silently resurrecting one the user rejected is a broken
/// promise.
/// </para>
/// <para>
/// <b>A bad file never stops the client.</b> Corrupt JSON, the wrong shape, or a file that cannot be
/// read at all all resolve to the seeds plus a reported reason. The alternative — throwing during
/// startup — leaves the user with no capture client and no way to fix the file from inside it. The
/// unreadable file is deliberately left on disk rather than replaced, so nothing the user wrote is
/// destroyed by a parser disagreement; the next successful save supersedes it.
/// </para>
/// <para>
/// Loading never writes. That keeps the "first run" state observable — no file means no decision has
/// been recorded yet — and keeps this type safe to call from anywhere, including a settings window
/// that is only previewing what a fresh profile would look like.
/// </para>
/// <para>
/// <b>A preference added by a later version is absent, not invalid.</b> A file written before a key
/// existed is a perfectly good file, and rejecting it would throw away the user's exclusion list —
/// the thing this store exists to protect — to learn something the default already says. So a
/// missing key falls back to its documented default while a key that is present with the wrong type
/// is still a parse failure, which is the same distinction the macOS client draws with
/// <c>defaults.object(forKey:) as? Bool ?? default</c>. The schema version is bumped when the
/// meaning of an existing key changes, not when a new one appears.
/// </para>
/// </remarks>
public static class HostSettingsStore
{
    /// <summary>Name of the settings document inside the client's local application data directory.</summary>
    public const string FileName = "settings.json";

    /// <summary>Version of the document shape written by this build.</summary>
    public const int SchemaVersion = 1;

    /// <summary>Default for <see cref="HostSettings.HighlightClicks"/> on a profile that has never set it.</summary>
    public const bool DefaultHighlightClicks = false;

    /// <summary>
    /// Default for <see cref="HostSettings.NarrationEnabled"/> on a profile that has never set it.
    /// </summary>
    /// <remarks>
    /// <b>Off, where the macOS client defaults it on — deliberately.</b> On macOS the first recording
    /// makes the system put up its own microphone consent dialog for the application, so a default of
    /// on still meets the user at a prompt they have to answer. Windows has no per-application
    /// microphone prompt: access is granted once, globally, in the privacy pane, and an app that
    /// finds it already granted can open the microphone with nothing shown to anybody. On this
    /// platform the application itself is therefore the only consent step there is, which it cannot
    /// be if it arrives switched on. Once the user has answered, the answer is remembered — the
    /// default governs the first run, not every run.
    /// </remarks>
    public const bool DefaultNarrationEnabled = false;

    private const string SchemaVersionKey = "schemaVersion";
    private const string ExcludedApplicationsKey = "excludedApplications";
    private const string HighlightClicksKey = "highlightClicks";
    private const string NarrationEnabledKey = "narrationEnabled";

    /// <summary>Reads the settings, falling back to <paramref name="seeds"/> rather than failing.</summary>
    /// <param name="path">Full path of the settings document; it need not exist.</param>
    /// <param name="seeds">The built-in exclusions used when no usable file is present.</param>
    public static HostSettingsLoad Load(string path, IEnumerable<string> seeds)
    {
        ArgumentException.ThrowIfNullOrEmpty(path);
        ArgumentNullException.ThrowIfNull(seeds);

        HostSettings seeded = new(
            ApplicationDenylist.Normalize(seeds),
            DefaultHighlightClicks,
            DefaultNarrationEnabled);

        string text;
        try
        {
            if (!File.Exists(path))
            {
                return new HostSettingsLoad(seeded, HostSettingsOrigin.Seeded);
            }

            text = File.ReadAllText(path, Encoding.UTF8);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or NotSupportedException)
        {
            return new HostSettingsLoad(seeded, HostSettingsOrigin.Unreadable, ex.Message);
        }

        try
        {
            return new HostSettingsLoad(Parse(text), HostSettingsOrigin.Loaded);
        }
        catch (FormatException ex)
        {
            return new HostSettingsLoad(seeded, HostSettingsOrigin.Unreadable, ex.Message);
        }
    }

    /// <summary>Writes the settings, replacing any previous document atomically.</summary>
    /// <param name="path">Full path of the settings document.</param>
    /// <param name="settings">The settings to persist; the exclusion list is normalized first.</param>
    public static void Save(string path, HostSettings settings)
    {
        ArgumentException.ThrowIfNullOrEmpty(path);
        ArgumentNullException.ThrowIfNull(settings);

        Durability.ReplaceAtomic(path, new UTF8Encoding(false).GetBytes(Serialize(settings)));
    }

    /// <summary>The canonical JSON text a given set of settings is persisted as.</summary>
    /// <remarks>
    /// Canonical because two profiles holding the same preferences should hold the same bytes: it
    /// makes the file diffable, makes a round-trip test meaningful, and keeps this document to the
    /// same serialization discipline as everything else the client writes.
    /// </remarks>
    public static string Serialize(HostSettings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);

        var excluded = new JsonArray();
        foreach (string entry in ApplicationDenylist.Normalize(settings.ExcludedApplications))
        {
            excluded.Add(JsonValue.Create(entry));
        }

        // Every key is written with a value. An absent preference is not expressible here — each
        // field always has one — so there is never a reason to write a null. A reader may still
        // encounter a file with a key missing, because a file written by an earlier version of this
        // client predates the key; that is a reading concern, and Parse handles it.
        return JsonCanonicalizer.Canonicalize(new JsonObject
        {
            [SchemaVersionKey] = JsonValue.Create(SchemaVersion),
            [ExcludedApplicationsKey] = excluded,
            [HighlightClicksKey] = JsonValue.Create(settings.HighlightClicks),
            [NarrationEnabledKey] = JsonValue.Create(settings.NarrationEnabled),
        });
    }

    /// <summary>Parses a settings document.</summary>
    /// <exception cref="FormatException">The document is not a usable settings file.</exception>
    private static HostSettings Parse(string text)
    {
        if (JsonStrictParser.Parse(text) is not JsonObject root)
        {
            throw new FormatException("The settings document is not a JSON object.");
        }

        if (root[SchemaVersionKey] is not JsonValue versionValue
            || !versionValue.TryGetValue(out long version)
            || version != SchemaVersion)
        {
            throw new FormatException(
                "The settings document declares an unsupported " + SchemaVersionKey + ".");
        }

        if (root[ExcludedApplicationsKey] is not JsonArray excluded)
        {
            throw new FormatException("The settings document has no " + ExcludedApplicationsKey + " array.");
        }

        var entries = new List<string>(excluded.Count);
        foreach (JsonNode? node in excluded)
        {
            if (node is not JsonValue value || !value.TryGetValue(out string? entry) || entry is null)
            {
                throw new FormatException(ExcludedApplicationsKey + " must contain only strings.");
            }

            entries.Add(entry);
        }

        if (root[HighlightClicksKey] is not JsonValue highlightValue
            || !highlightValue.TryGetValue(out bool highlightClicks))
        {
            throw new FormatException("The settings document has no boolean " + HighlightClicksKey + ".");
        }

        return new HostSettings(
            ApplicationDenylist.Normalize(entries),
            highlightClicks,
            OptionalFlag(root, NarrationEnabledKey, DefaultNarrationEnabled));
    }

    /// <summary>
    /// Reads a boolean preference that a file written by an earlier version may not carry at all.
    /// </summary>
    /// <remarks>
    /// Absent is not the same as malformed. A key this build added is simply not in a document that
    /// predates it, and the default is the honest answer; a key that is there holding something other
    /// than a boolean is a file this build does not understand, and saying so is what stops a
    /// mistyped preference from being read as its safest value and quietly obeyed.
    /// </remarks>
    /// <exception cref="FormatException">The key is present but is not a boolean.</exception>
    private static bool OptionalFlag(JsonObject root, string key, bool fallback)
    {
        if (root[key] is not { } node)
        {
            return fallback;
        }

        if (node is not JsonValue value || !value.TryGetValue(out bool flag))
        {
            throw new FormatException("The settings document's " + key + " is not a boolean.");
        }

        return flag;
    }
}
