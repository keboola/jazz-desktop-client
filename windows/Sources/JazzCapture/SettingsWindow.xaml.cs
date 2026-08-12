using System.Collections.ObjectModel;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using JazzCaptureCore;
using JazzCapture.Capture;

namespace JazzCapture;

/// <summary>
/// The settings pane: the list of applications that are never captured, and the click-highlight
/// toggle (ANNEX-HOST section 6, mirroring the macOS client's "Excluded apps (never captured)").
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
        "A capture is recording. Its excluded-app list was frozen when it started, and the archive "
        + "records that list - so changes saved here apply to the NEXT capture, not this one. Stop "
        + "the capture to apply them now.";

    private const string UnreadableNoticeFormat =
        "The saved settings could not be read, so the built-in defaults are shown instead ({0}). "
        + "The existing file has been left alone; saving here replaces it.";

    private readonly Settings _settings;
    private readonly AppIdentityResolver _identity;
    private readonly ObservableCollection<string> _excluded;

    /// <summary>Creates the settings window.</summary>
    /// <param name="settings">The configuration currently in force.</param>
    /// <param name="isCapturing">Whether a capture is recording, which this window cannot change.</param>
    /// <param name="loadDetail">
    /// Why the saved settings were unusable, when they were. Absent in the ordinary case.
    /// </param>
    public SettingsWindow(Settings settings, bool isCapturing, string? loadDetail = null)
    {
        _settings = settings ?? throw new ArgumentNullException(nameof(settings));
        _identity = new AppIdentityResolver();
        _excluded = new ObservableCollection<string>(settings.ExcludedApplications);

        InitializeComponent();

        ExcludedList.ItemsSource = _excluded;
        HighlightClicksBox.IsChecked = settings.HighlightClicks;
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

    private void RefreshButtons()
    {
        ExcludeRunningButton.IsEnabled = RunningAppsBox.SelectedItem is RunningApplication;
        AddManualButton.IsEnabled = !string.IsNullOrWhiteSpace(ManualEntryBox.Text);
        RemoveButton.IsEnabled = ExcludedList.SelectedItem is string;
    }

    private void OnSelectionChanged(object sender, RoutedEventArgs e) => RefreshButtons();

    private void OnDirty(object sender, RoutedEventArgs e)
    {
        // The checkbox carries its own state; nothing else has to happen until Save.
    }

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

    private void OnSave(object sender, RoutedEventArgs e)
    {
        var settings = new HostSettings(
            ApplicationDenylist.Normalize(_excluded),
            HighlightClicksBox.IsChecked == true);

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
