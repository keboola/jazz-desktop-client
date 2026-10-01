using System.Collections.ObjectModel;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using JazzCaptureCore;
using JazzCapture.Capture;

namespace JazzCapture;

/// <summary>
/// The settings pane: the list of applications that are never captured, the click-highlight toggle,
/// and the narration toggle (ANNEX-HOST section 6, mirroring the macOS client's "Excluded apps
/// (never captured)" and "Record voice during labeled activities").
/// </summary>
/// <remarks>
/// <para>
/// This window exists because the exclusion list is a privacy control, and a privacy control the
/// user cannot reach is not one. A tool that records the whole desktop has to let the person being
/// recorded say "not that" about their own password manager, their bank, or anything else, without
/// editing a JSON file by hand.
/// </para>
/// <para>
/// Two ways in, and both of them produce an entry that actually matches. The picker lists the
/// applications that currently have a window and writes the identity the capture would attribute an
/// event to, so what is excluded is exactly what the denylist compares against. The text field is
/// for the application that is not running right now, and it takes the same kind of fragment as the
/// built-in seeds; the list beneath shows precisely what will be matched, so nothing is hidden.
/// </para>
/// <para>
/// <b>Nothing here touches a running capture.</b> The policy is frozen before the first hook is
/// installed and the archive declares it in <c>capturePolicy.excludedApplications</c>; letting this
/// window edit that mid-recording would make the archive's own declaration false. So while a capture
/// is recording the window says so in as many words, rather than accepting an edit and quietly doing
/// nothing with it until next time.
/// </para>
/// </remarks>
public partial class SettingsWindow : System.Windows.Window
{
    private const string RecordingNotice =
        "A capture is recording. Its capture policy - the excluded-app list, and whether narration "
        + "is recorded - was frozen when it started, and the archive records that policy. So changes "
        + "saved here apply to the NEXT capture, not this one. Stop the capture to apply them now.";

    private const string UnreadableNoticeFormat =
        "The saved settings could not be read, so the built-in defaults are shown instead ({0}). "
        + "The existing file has been left alone; saving here replaces it.";

    /// <summary>
    /// #60 amendment 2: shown beneath the checkbox whenever a managed policy or installer
    /// preference decided the effective value (<see cref="EffectiveCaptureAtLaunch.Source"/> is
    /// <see cref="CaptureAtLaunchSource.ManagedPolicy"/> or
    /// <see cref="CaptureAtLaunchSource.InstallerPreference"/>) with a value that actually parsed --
    /// i.e. not the <see cref="PolicyUnreadableNotice"/> case below. Exact copy from the decisions
    /// comment on #60, verbatim.
    /// </summary>
    private const string EnforcedNotice =
        "This is set by your organisation's policy and cannot be changed here.";

    /// <summary>
    /// #60 amendment 4: shown instead of <see cref="EnforcedNotice"/> when the deciding rank's
    /// value was <see cref="JazzCaptureCore.CaptureAtLaunchPolicyValue.Malformed"/> -- a
    /// misconfiguration, not an organisational decision, so the copy must not claim one was made.
    /// Exact copy from the decisions comment on #60, verbatim.
    /// </summary>
    private const string PolicyUnreadableNotice =
        "A setting deployed to this machine could not be read, so this cannot be changed here.";

    private readonly Settings _settings;
    private readonly AppIdentityResolver _identity;
    private readonly ObservableCollection<string> _excluded;
    private readonly bool _built;
    private readonly bool _captureAtLaunchEnforced;
    // Not currently rendered anywhere -- see ResolveEnforcedNoticeText's remarks for why the
    // enforced/unreadable choice is derived structurally instead. Kept for a future diagnostic
    // surface and for API symmetry with CaptureAtLaunchPolicyStore's read result.
    private readonly string? _policyDetail;

    /// <summary>Creates the settings window.</summary>
    /// <param name="settings">The configuration currently in force.</param>
    /// <param name="isCapturing">Whether a capture is recording, which this window cannot change.</param>
    /// <param name="captureAtLaunch">
    /// The effective capture-at-launch decision -- the same value <c>CaptureStartupGate</c> saw at
    /// startup, not the raw persisted pair -- so a managed policy or installer preference (#60)
    /// renders as enforced rather than as an ordinary toggle the user appears able to change. No
    /// default value, deliberately: the only production call site (<c>TrayHost.OpenSettings</c>)
    /// must pass it explicitly rather than being able to silently drop it, the same reasoning
    /// <c>EffectiveCaptureAtLaunch.Resolve</c>'s own policy parameter documents.
    /// </param>
    /// <param name="loadDetail">
    /// Why the saved settings were unusable, when they were. Absent in the ordinary case.
    /// </param>
    /// <param name="policyDetail">
    /// Non-null only when either policy rank was malformed or a registry read failed outright --
    /// see <c>CaptureAtLaunchPolicyStore</c>'s own remarks for why this is never the rejected value
    /// itself. Accepted for API symmetry with the store's read result and kept for a future
    /// diagnostic surface, but <b>not</b> used to choose between <see cref="EnforcedNotice"/> and
    /// <see cref="PolicyUnreadableNotice"/> -- see <see cref="ResolveEnforcedNoticeText"/>'s remarks
    /// for why that decision must be structural instead.
    /// </param>
    public SettingsWindow(
        Settings settings,
        bool isCapturing,
        EffectiveCaptureAtLaunch captureAtLaunch,
        string? loadDetail = null,
        string? policyDetail = null)
    {
        _settings = settings ?? throw new ArgumentNullException(nameof(settings));
        ArgumentNullException.ThrowIfNull(captureAtLaunch);
        _identity = new AppIdentityResolver();
        _excluded = new ObservableCollection<string>(settings.ExcludedApplications);
        _policyDetail = policyDetail;

        InitializeComponent();
        _built = true;

        ExcludedList.ItemsSource = _excluded;
        HighlightClicksBox.IsChecked = settings.HighlightClicks;
        NarrationBox.IsChecked = settings.NarrationEnabled;
        ContinuousCaptureBox.IsChecked = settings.ContinuousCapture;
        // Mode changes apply only to a later capture, never change an active session's pause rule.
        ContinuousCaptureBox.IsEnabled = !isCapturing;

        _captureAtLaunchEnforced = captureAtLaunch.Source
            is CaptureAtLaunchSource.ManagedPolicy or CaptureAtLaunchSource.InstallerPreference;
        if (_captureAtLaunchEnforced)
        {
            // #60 scope 3: a policy-decided value renders as enforced, not as an ordinary toggle
            // the user appears able to change. IsChecked reflects the effective value (what will
            // actually happen at the next launch), never the persisted user setting underneath it
            // -- see ResolveSavedCaptureAtLaunch's remarks for why that underlying value is left
            // alone by Save regardless of what this checkbox displays.
            CaptureAtLaunchBox.IsChecked = captureAtLaunch.Enabled;
            CaptureAtLaunchBox.IsEnabled = false;
            CaptureAtLaunchEnforcedText.Text = ResolveEnforcedNoticeText(captureAtLaunch);
            CaptureAtLaunchEnforcedText.Visibility = Visibility.Visible;
        }
        else
        {
            CaptureAtLaunchBox.IsChecked = settings.CaptureAtLaunchEnabled;
        }

        ShowNotice(isCapturing, loadDetail);
        LoadRunningApplications();
        RefreshButtons();
    }

    /// <summary>
    /// The preferences the user saved, or <see langword="null"/> when they closed without saving.
    /// </summary>
    public HostSettings? Saved { get; private set; }

    /// <summary>
    /// The recording notice outranks the unreadable-file one: a user editing during a capture needs
    /// to know their change will not affect it more than they need last startup's parse failure.
    /// </summary>
    private void ShowNotice(bool isCapturing, string? loadDetail)
    {
        string? notice = isCapturing
            ? RecordingNotice
            : loadDetail is null
                ? null
                : string.Format(
                    System.Globalization.CultureInfo.CurrentCulture,
                    UnreadableNoticeFormat,
                    loadDetail);

        if (notice is null)
        {
            return;
        }

        NoticeText.Text = notice;
        NoticeText.Visibility = Visibility.Visible;
    }

    private void LoadRunningApplications()
    {
        // Applications already on the list are not offered again: excluding one twice is a no-op
        // that only makes the picker longer.
        var denylist = new ApplicationDenylist(_excluded);
        RunningAppsBox.ItemsSource = RunningApplications.Enumerate(_identity)
            .Where(application => !denylist.IsExcluded(application.Identity))
            .ToArray();
        RunningAppsBox.SelectedIndex = -1;
    }

    /// <remarks>
    /// A control's own change event can fire while the XAML tree is still being built, before the
    /// generated fields this reads have all been assigned, so it does nothing until the constructor
    /// says the window exists.
    /// </remarks>
    private void RefreshButtons()
    {
        if (!_built)
        {
            return;
        }

        ExcludeRunningButton.IsEnabled = RunningAppsBox.SelectedItem is RunningApplication;
        AddManualButton.IsEnabled = !string.IsNullOrWhiteSpace(ManualEntryBox.Text);
        RemoveButton.IsEnabled = ExcludedList.SelectedItem is string;
    }

    private void OnSelectionChanged(object sender, RoutedEventArgs e) => RefreshButtons();

    private void OnExcludeRunning(object sender, RoutedEventArgs e)
    {
        if (RunningAppsBox.SelectedItem is RunningApplication application)
        {
            Add(application.Identity.Value);
        }
    }

    private void OnAddManual(object sender, RoutedEventArgs e)
    {
        Add(ManualEntryBox.Text);
        ManualEntryBox.Clear();
    }

    private void OnRemove(object sender, RoutedEventArgs e)
    {
        if (ExcludedList.SelectedItem is string entry)
        {
            _excluded.Remove(entry);
            LoadRunningApplications();
            RefreshButtons();
        }
    }

    private void OnRefreshRunning(object sender, RoutedEventArgs e) => LoadRunningApplications();

    /// <summary>
    /// Adds one entry, re-normalizing the whole list so what the user sees is exactly what will be
    /// matched and persisted — same trimming, same de-duplication, same order.
    /// </summary>
    private void Add(string? entry)
    {
        if (string.IsNullOrWhiteSpace(entry))
        {
            return;
        }

        string[] normalized = ApplicationDenylist.Normalize(_excluded.Append(entry));
        _excluded.Clear();
        foreach (string value in normalized)
        {
            _excluded.Add(value);
        }

        LoadRunningApplications();
        RefreshButtons();
    }

    /// <summary>
    /// Chooses between <see cref="EnforcedNotice"/> and <see cref="PolicyUnreadableNotice"/> for an
    /// enforced capture-at-launch checkbox.
    /// </summary>
    /// <param name="captureAtLaunch">The effective decision this window was opened with. Must have
    /// <c>Source is ManagedPolicy or InstallerPreference</c>; the caller is what decides whether the
    /// checkbox is enforced at all.</param>
    /// <remarks>
    /// <para>
    /// <b>Deliberately structural -- never keyed off <c>CaptureAtLaunchPolicyRead.Detail</c>
    /// (Opus review finding, PR #85).</b> An earlier version of this constructor chose
    /// <see cref="PolicyUnreadableNotice"/> whenever the store's combined <c>Detail</c> was
    /// non-null. But <c>Detail</c> can be non-null because of a rank <em>Resolve never
    /// consulted</em> -- e.g. the managed policy is a clean <c>1</c> (deciding "on" outright) while
    /// the installer preference, never reached, happens to hold a malformed value. That combination
    /// rendered a ticked, enforced-on checkbox with the text "a setting could not be read", telling
    /// the exact opposite of what was actually enforced.
    /// </para>
    /// <para>
    /// <paramref name="captureAtLaunch"/>'s own <see cref="EffectiveCaptureAtLaunch.Enabled"/> alone
    /// is sufficient and cannot be fooled this way: per amendment 3 on #60's decisions comment,
    /// neither policy rank can ever enforce "off" as a decision (a deployed <c>0</c> is "no
    /// opinion", not an override), so the <em>only</em> way an enforced rank
    /// (<c>captureAtLaunch.Source is ManagedPolicy or InstallerPreference</c>) can leave capture off
    /// is a value that failed to parse at that exact rank. Reading <c>Enabled</c> off the already
    /// -resolved effective value therefore always agrees with what <c>Resolve</c> actually decided,
    /// with no dependency on <c>Detail</c> being attributed to the right rank -- the same structural
    /// argument <c>OnboardingWindowContent.Resolve</c> already relies on for its own
    /// <c>PolicyUnreadable</c> disclosure.
    /// </para>
    /// </remarks>
    internal static string ResolveEnforcedNoticeText(EffectiveCaptureAtLaunch captureAtLaunch)
    {
        ArgumentNullException.ThrowIfNull(captureAtLaunch);
        return captureAtLaunch.Enabled ? EnforcedNotice : PolicyUnreadableNotice;
    }

    /// <summary>
    /// Whether saving this window should preserve <paramref name="priorPaused"/> or clear it.
    /// </summary>
    /// <param name="checkedNow">The Save-time state of the "Start local capture automatically
    /// when Jazz opens" checkbox.</param>
    /// <param name="priorEnabled">The persisted <see cref="HostSettings.CaptureAtLaunchEnabled"/>
    /// this window was opened with.</param>
    /// <param name="priorPaused">The persisted <see cref="HostSettings.CaptureAtLaunchPaused"/>
    /// this window was opened with.</param>
    /// <remarks>
    /// <para>
    /// <b>Only an off -&gt; on tick of this checkbox clears a stale pause; nothing else does, in
    /// either direction.</b> Ticking it (<paramref name="checkedNow"/> and not
    /// <paramref name="priorEnabled"/>) is an explicit, fresh choice to start automatically --
    /// exactly like choosing "Start capture" from the tray, which
    /// <see cref="CaptureAtLaunchPreference.AfterSuccessfulManualStart(HostSettings, bool)"/>
    /// treats as an unconditional resume for the same reason (see that method's remarks). Before
    /// #76, <paramref name="priorPaused"/> was always already <see langword="false"/> here, so
    /// this branch was unobservable; #76's switch makes
    /// <c>(CaptureAtLaunchEnabled: false, CaptureAtLaunchPaused: true)</c> reachable, and without
    /// this clause ticking the very checkbox the status window tells such a user to tick would
    /// leave them paused forever, with no UI path back out.
    /// </para>
    /// <para>
    /// <b>Unticking it never clears a pause -- deliberately, even when the launch switch is
    /// absent from this process.</b> An earlier version of this method cleared the pause on an
    /// on -&gt; off untick whenever <em>this process</em> had no launch switch, reasoning that
    /// nothing else could be asking for automatic start. That reasoning does not hold: the switch
    /// is process-scoped by design (#76 R1), so a process with no switch proves nothing about
    /// whether some *other* shortcut, scheduled task, or login script on the same profile carries
    /// one -- which on an MSI-installed machine is the ordinary case, since the installed Run
    /// value and Start Menu shortcut both carry no switch at all (see
    /// <c>windows/README.md</c>'s login-race note). Clearing the pause there would have silently
    /// resumed automatic capture on the next switched launch despite two explicit user actions
    /// (Stop, then untick), exactly the override issue #76 scope 5 forbids. Leaving a pause on
    /// record after an untick is harmless: <c>(CaptureAtLaunchEnabled: false,
    /// CaptureAtLaunchPaused: true)</c> is inert (<see cref="CaptureStartupDecision.ShouldStart"/>
    /// is already false whenever <c>Enabled</c> is false) until either this same checkbox is
    /// ticked again or a manual start clears it -- both already unconditional resumes.
    /// </para>
    /// </remarks>
    internal static bool ResolvePauseOnSave(bool checkedNow, bool priorEnabled, bool priorPaused) =>
        checkedNow && !priorEnabled ? false : priorPaused;

    /// <summary>
    /// Decides what <see cref="OnSave"/> writes into <see cref="HostSettings.CaptureAtLaunchEnabled"/>
    /// -- the sharpest trap in #60's slice 1 (the plan's own words).
    /// </summary>
    /// <param name="checkedNow">The Save-time state of the "Start local capture automatically when
    /// Jazz opens" checkbox.</param>
    /// <param name="enforced">Whether a managed policy or installer preference decided the
    /// effective value this window was opened with (<c>captureAtLaunch.Source is ManagedPolicy or
    /// InstallerPreference</c>) -- in which case the checkbox is disabled and <paramref name="checkedNow"/>
    /// merely mirrors what the policy displayed, not a user choice.</param>
    /// <param name="priorEnabled">The persisted <see cref="HostSettings.CaptureAtLaunchEnabled"/>
    /// this window was opened with -- the user's own preference underneath the policy, untouched by
    /// it, since this client never writes a policy value into <see cref="HostSettings"/>.</param>
    /// <remarks>
    /// <para>
    /// <b>While enforced, the checkbox's displayed state is never written back.</b> A disabled
    /// checkbox showing <c>captureAtLaunch.Enabled</c> is not a user decision -- it is this window
    /// reflecting what a policy will do at the next launch, and the checkbox cannot be unticked or
    /// ticked to disagree. If <c>OnSave</c> fed that displayed state straight into
    /// <see cref="HostSettings"/> (as it did before this method existed), saving any unrelated
    /// preference -- an exclusion, narration, even just clicking Save with nothing changed -- would
    /// silently overwrite the user's own <c>captureAtLaunchEnabled</c> with whatever the policy
    /// currently says. The user's real preference would then be gone, and the moment the policy is
    /// later removed, the profile would resume with a value nobody actually chose rather than the
    /// preference the user had before the policy ever arrived. This is #76 R1 -- "an in-memory fold
    /// silently persists" -- arriving through the Settings window instead of the launch switch.
    /// </para>
    /// <para>
    /// So while enforced, this returns <paramref name="priorEnabled"/> unchanged: whatever the user's
    /// own setting already was stays exactly as it was, regardless of what the disabled checkbox
    /// shows. Only when the checkbox is not enforced -- an ordinary, editable toggle -- does the
    /// Save-time checked state reach <see cref="HostSettings"/> at all, exactly as before #60.
    /// </para>
    /// </remarks>
    internal static bool ResolveSavedCaptureAtLaunch(bool checkedNow, bool enforced, bool priorEnabled) =>
        enforced ? priorEnabled : checkedNow;

    private void OnSave(object sender, RoutedEventArgs e)
    {
        bool checkedNow = CaptureAtLaunchBox.IsChecked == true;

        // #60: never let a disabled, policy-mirroring checkbox write the policy's value into the
        // user's own persisted preference -- see ResolveSavedCaptureAtLaunch's remarks. The result
        // feeds ResolvePauseOnSave as both the persisted value AND the checked-now input: while
        // enforced, savedCaptureAtLaunch always equals _settings.CaptureAtLaunchEnabled (priorEnabled),
        // so ResolvePauseOnSave's own "off -> on tick clears a pause" branch cannot fire from a
        // checkbox the user never actually changed -- a pause is cleared only by a real user action
        // (an actual tick, or Start capture), never by this window's rendering of a policy.
        bool savedCaptureAtLaunch = ResolveSavedCaptureAtLaunch(
            checkedNow, _captureAtLaunchEnforced, _settings.CaptureAtLaunchEnabled);
        var settings = new HostSettings(
            ApplicationDenylist.Normalize(_excluded),
            HighlightClicksBox.IsChecked == true,
            NarrationBox.IsChecked == true,
            _settings.ScreenshotsEnabled,
            savedCaptureAtLaunch,
            ResolvePauseOnSave(savedCaptureAtLaunch, _settings.CaptureAtLaunchEnabled, _settings.CaptureAtLaunchPaused),
            ContinuousCaptureBox.IsChecked == true);

        try
        {
            HostSettingsStore.Save(_settings.SettingsFilePath, settings);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // Reporting the failure matters more than usual here: a user who believes they have
            // excluded their password manager, and has not, is worse off than one who knows.
            System.Windows.MessageBox.Show(
                this,
                ex.Message,
                "Could not save settings",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            return;
        }

        Saved = settings;
        DialogResult = true;
        Close();
    }

    private void OnClose(object sender, RoutedEventArgs e) => Close();
}
