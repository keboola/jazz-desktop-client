using System.Drawing;
using System.Globalization;
using System.Windows.Forms;
using System.Windows.Threading;
using JazzCaptureCore;
using JazzCaptureCore.Archive;
using JazzCaptureCore.Input;
using JazzCapture.Capture;
using JazzCapture.Interop;

namespace JazzCapture;

/// <summary>
/// The tray application: a <see cref="NotifyIcon"/> whose menu starts and stops capture, shows the
/// recording state and event count, opens local review, and quits (ANNEX-HOST section 6).
/// </summary>
/// <remarks>
/// <para>
/// The host owns every moving part for one capture — the engine, the input hooks, the foreground
/// tracker, the UI Automation worker, the coordinator, and the watchdog — and wires them together on
/// start and tears them down on stop. The foreground WinEvent hook is installed here, on the WPF UI
/// thread, because that is the thread whose dispatcher pumps messages.
/// </para>
/// <para>
/// Stopping disposes all of them. Only the engine outlives the capture, because local review reads
/// the committed archive from it and the Confirm / Reject decision still has to reach it.
/// </para>
/// <para>
/// The tray menu is built once and updated in place. The heartbeat refreshes the status line every
/// few seconds while recording, and rebuilding the strip there would dispose the menu the user
/// currently has open.
/// </para>
/// </remarks>
public sealed class TrayHost : IDisposable
{
    private const string IdleStatus = "Idle";
    private const string IdleTooltip = "Jazz Capture - idle";
    private const string RecordingFormat = "REC {0:hh\\:mm\\:ss} - {1} events";
    private const string ReArmFormat = "! Input hook re-armed {0}x this session";
    private const string DeclareLabelText = "Label current task...";
    private const string EndLabelFormat = "End label - {0}";
    private const string OpenLabelFormat = "Label: {0}";

    private Settings _settings;
    private readonly NotifyIcon _icon;
    private readonly DispatcherTimer _heartbeat;

    private readonly ContextMenuStrip _menu = new();
    private readonly ToolStripMenuItem _statusItem = Label(IdleStatus);
    private readonly ToolStripMenuItem _labelStatusItem = Label(string.Empty);
    private readonly ToolStripMenuItem _reArmItem = Label(string.Empty);
    private readonly ToolStripMenuItem _errorItem = Label(string.Empty);
    private readonly ToolStripMenuItem _captureItem;
    private readonly ToolStripMenuItem _declareLabelItem;
    private readonly ToolStripMenuItem _endLabelItem;
    private readonly ToolStripMenuItem _reviewItem;
    private readonly ToolStripMenuItem _screenshotsItem;
    private readonly ToolStripMenuItem _settingsItem;

    private CaptureEngine? _engine;
    private AppIdentityResolver? _identity;
    private UiaResolver? _uia;
    private InputHooks? _hooks;
    private ForegroundTracker? _foreground;
    private CaptureCoordinator? _coordinator;
    private HookWatchdog? _watchdog;
    private ReviewWindow? _review;
    private ClickHighlightOverlay? _highlight;

    private DateTimeOffset _startedAt;
    private bool _capturing;
    private bool _labelPromptOpen;
    private bool _settingsPromptOpen;
    private string? _settingsLoadDetail;
    private string? _lastError;
    private long _lastReArmCount;

    private static readonly Icon IdleIcon = LoadIcon("tray-idle.ico");
    private static readonly Icon RecordingIcon = LoadIcon("tray-recording.ico");

    /// <summary>
    /// Loads a tray glyph shipped beside the executable. The notification area is the only place
    /// the user can see this client at all, so a missing asset is a startup failure rather than
    /// something to paper over with a generic system icon nobody can pick out of a flyout.
    /// </summary>
    private static Icon LoadIcon(string fileName)
    {
        // Fully qualified: WPF's Shapes.Path is in scope here.
        string path = System.IO.Path.Combine(AppContext.BaseDirectory, "Assets", fileName);
        return new Icon(path);
    }

    /// <summary>Creates the tray host and shows its icon in the notification area.</summary>
    /// <param name="settings">The host configuration for this run.</param>
    /// <param name="settingsLoadDetail">
    /// Why the saved preferences were unusable at startup, when they were, so the settings window
    /// can say so instead of silently presenting the defaults as if they were the user's choices.
    /// </param>
    public TrayHost(Settings settings, string? settingsLoadDetail = null)
    {
        _settings = settings ?? throw new ArgumentNullException(nameof(settings));
        _settingsLoadDetail = settingsLoadDetail;
        _icon = new NotifyIcon
        {
            Icon = IdleIcon,
            Visible = true,
            Text = IdleTooltip,
        };
        _heartbeat = new DispatcherTimer { Interval = _settings.HeartbeatInterval };
        _heartbeat.Tick += (_, _) => OnHeartbeat();

        _captureItem = MenuItem("Start capture", (_, _) => ToggleCapture());
        _declareLabelItem = MenuItem(DeclareLabelText, (_, _) => DeclareLabel(), enabled: false);
        _endLabelItem = MenuItem(string.Empty, (_, _) => EndLabel(), enabled: false);
        _reviewItem = MenuItem("Open review...", (_, _) => OpenReview(), enabled: false);
        _screenshotsItem = MenuItem("Screenshots", (_, _) => ToggleScreenshots());
        _screenshotsItem.CheckOnClick = false;
        _screenshotsItem.Checked = _settings.ScreenshotsEnabled;
        _settingsItem = MenuItem("Settings...", (_, _) => OpenSettings());
        BuildMenu();
        RefreshStatus();
    }

    /// <summary>Whether a capture is currently recording.</summary>
    public bool IsCapturing => _capturing;

    /// <summary>Starts a capture: mints an engine, installs the hooks, and begins recording.</summary>
    public void StartCapture()
    {
        if (_capturing)
        {
            return;
        }

        try
        {
            _lastReArmCount = 0;
            _identity = new AppIdentityResolver();
            _uia = new UiaResolver(_identity, _settings.UiaTimeout);
            _uia.SourceFailed += OnUiaSourceFailed;
            _uia.Start();

            var config = new EngineConfig(
                _settings.CaptureRoot,
                _settings.User,
                _settings.InstanceName,
                _settings.ProducerVersion,
                _settings.ExcludedApplications,
                _settings.ScreenshotsEnabled,
                () => DateTimeOffset.UtcNow);

            _engine = CaptureEngine.Start(config);
            _startedAt = DateTimeOffset.UtcNow;

            _highlight = _settings.HighlightClicks ? new ClickHighlightOverlay() : null;

            _coordinator = new CaptureCoordinator(
                _engine,
                _settings,
                _uia,
                _identity,
                () => DateTimeOffset.UtcNow,
                ReadGestureMetrics(),
                _settings.ScreenshotsEnabled
                    ? new ScreenCapture(_identity, () => DateTimeOffset.UtcNow)
                    : null,
                _highlight is null ? null : FlashHighlight);
            _coordinator.LabelChanged += OnLabelChanged;
            _coordinator.Start();

            _hooks = new InputHooks(
                sample => _coordinator!.SubmitMouse(sample),
                sample => _coordinator!.SubmitKey(sample));
            _hooks.Start();

            _foreground = new ForegroundTracker(hwnd => _coordinator!.SubmitForeground(hwnd));
            _foreground.Start();

            _watchdog = new HookWatchdog(_hooks, _settings.HeartbeatInterval, OnHookReArmed);
            _watchdog.Start();

            _capturing = true;
            _lastError = null;
            _heartbeat.Start();
        }
        catch (Exception ex)
        {
            _lastError = ex.Message;
            TearDownCapture();
        }

        RefreshStatus();
    }

    /// <summary>Stops recording, commits, and opens the review window.</summary>
    public void StopCapture()
    {
        if (!_capturing || _engine is null)
        {
            return;
        }

        _heartbeat.Stop();
        _watchdog?.Stop();
        _foreground?.Stop();
        _hooks?.Stop();
        _coordinator?.DrainAndStop();

        StopResult? result = null;
        try
        {
            result = _engine.Stop();
        }
        catch (Exception ex)
        {
            _lastError = ex.Message;
        }

        // Everything the capture owned is released here, not merely stopped: a later Start replaces
        // these fields, so anything left undisposed would leak its timer, thread or COM apartment for
        // the lifetime of the process. The engine survives — review still reads the committed archive
        // from it, and Confirm / Reject has to reach it.
        TearDownCapture();
        RefreshStatus();

        if (result is not null)
        {
            OpenReview();
        }
    }

    /// <summary>
    /// Asks the user what they are working on and opens a bracketed label around it. Declaring a
    /// second one while another is open closes the first, which is what the engine does anyway.
    /// </summary>
    /// <remarks>
    /// <para>
    /// The prompt is modal, and a modal WPF dialog runs a nested dispatcher loop: the tray menu keeps
    /// pumping for as long as it is open, so <see cref="StopCapture"/> can run to completion
    /// underneath it and tear the pipeline down. Every piece of state read before the prompt is
    /// therefore stale by the time it returns, and has to be read again.
    /// </para>
    /// <para>
    /// A capture that ended while the prompt was open is not an error to report. The user chose to
    /// stop, the review window for the recording they just finished is already coming up, and a
    /// message box about a label they can no longer open would only stand between them and it.
    /// </para>
    /// </remarks>
    public void DeclareLabel()
    {
        // A second prompt stacked on the first is the same nested-pump hazard one step further on:
        // the menu item stays enabled while the dialog owns the screen.
        if (!_capturing || _coordinator is null || _labelPromptOpen)
        {
            return;
        }

        string? text;
        _labelPromptOpen = true;
        try
        {
            text = LabelPromptWindow.Ask();
        }
        finally
        {
            _labelPromptOpen = false;
        }

        if (text is null)
        {
            return;
        }

        // Re-read rather than reuse: the field checked above may since have been nulled by a stop,
        // and dereferencing it would take the process down with the archive awaiting review.
        CaptureCoordinator? coordinator = _coordinator;
        if (!_capturing || coordinator is null)
        {
            return;
        }

        coordinator.SubmitLabelStart(text);
    }

    /// <summary>Closes the open bracketed label. Does nothing when none is open.</summary>
    public void EndLabel()
    {
        if (_capturing && _coordinator is not null)
        {
            _coordinator.SubmitLabelEnd();
        }
    }

    /// <summary>
    /// Opens the settings pane and adopts whatever the user saved.
    /// </summary>
    /// <remarks>
    /// <para>
    /// The new exclusion list reaches the pipeline the next time a capture starts, because that is
    /// when the policy is frozen and written into the archive. The window says so plainly while a
    /// capture is running, so nobody is left believing an edit took effect that did not.
    /// </para>
    /// <para>
    /// Modal, and guarded against a second instance, for the same reason the label prompt is: a
    /// modal WPF dialog runs a nested dispatcher loop, so the tray menu keeps pumping underneath it
    /// and can be clicked again.
    /// </para>
    /// </remarks>
    public void OpenSettings()
    {
        if (_settingsPromptOpen)
        {
            return;
        }

        _settingsPromptOpen = true;
        try
        {
            var window = new SettingsWindow(_settings, _capturing, _settingsLoadDetail);
            window.ShowDialog();
            if (window.Saved is { } saved)
            {
                _settings = _settings.With(saved);

                // A successful save supersedes whatever could not be read at startup.
                _settingsLoadDetail = null;
            }
        }
        finally
        {
            _settingsPromptOpen = false;
        }

        RefreshStatus();
    }

    /// <summary>Opens (or focuses) the review window for the committed archive.</summary>
    public void OpenReview()
    {
        if (_engine is null || _engine.State == EngineState.Recording)
        {
            return;
        }

        if (_review is null || !_review.IsLoaded)
        {
            _review = new ReviewWindow(_engine, _settings);
            _review.Closed += (_, _) => _review = null;
        }

        _review.Show();
        _review.Activate();
    }

    /// <summary>Shuts the tray host down and releases every resource.</summary>
    public void Quit()
    {
        Dispose();
        System.Windows.Application.Current?.Shutdown();
    }

    /// <inheritdoc />
    public void Dispose()
    {
        _heartbeat.Stop();
        TearDownCapture();
        _icon.Visible = false;
        _icon.ContextMenuStrip = null;
        _menu.Dispose();
        _icon.Dispose();
    }

    private void ToggleCapture()
    {
        if (_capturing)
        {
            StopCapture();
        }
        else
        {
            StartCapture();
        }
    }

    /// <summary>
    /// Turns the screenshot modality on or off for the next capture.
    /// </summary>
    /// <remarks>
    /// Deliberately not effective mid-recording. The capture policy is frozen before the first hook
    /// exists and the archive declares it once; letting a menu item change what the session claims
    /// to have consented to, halfway through, would make the declaration meaningless.
    /// </remarks>
    private void ToggleScreenshots()
    {
        if (_capturing)
        {
            _lastError = "Screenshots change takes effect on the next capture";
            RefreshStatus();
            return;
        }

        _settings = _settings with { ScreenshotsEnabled = !_settings.ScreenshotsEnabled };
        RefreshStatus();
    }

    private void TearDownCapture()
    {
        // The re-arm count is a per-session diagnostic the menu keeps showing after the hooks are gone.
        _lastReArmCount = _hooks?.ReArmCount ?? _lastReArmCount;

        _watchdog?.Dispose();
        _watchdog = null;
        _foreground?.Dispose();
        _foreground = null;
        _hooks?.Dispose();
        _hooks = null;
        if (_coordinator is not null)
        {
            _coordinator.LabelChanged -= OnLabelChanged;
            _coordinator.DrainAndStop();
            _coordinator.Dispose();
            _coordinator = null;
        }

        if (_uia is not null)
        {
            _uia.SourceFailed -= OnUiaSourceFailed;
            _uia.Dispose();
            _uia = null;
        }

        // The overlay outlives nothing: it is a visible mark on the user's screen that says a
        // capture is watching, so it goes away at the same moment the capture does.
        if (_highlight is not null)
        {
            ClickHighlightOverlay overlay = _highlight;
            _highlight = null;
            Marshal(overlay.Dispose);
        }

        _capturing = false;
    }

    /// <summary>
    /// Draws one click highlight. Called from the coordinator's worker thread, so the work is
    /// handed to the dispatcher that owns the overlay window rather than done in place.
    /// </summary>
    private void FlashHighlight(BoundingBox bounds) => Marshal(() => _highlight?.Flash(bounds));

    /// <summary>Runs an action on the UI thread, in place when already there.</summary>
    private void Marshal(Action action)
    {
        if (_heartbeat.Dispatcher.CheckAccess())
        {
            action();
            return;
        }

        _heartbeat.Dispatcher.BeginInvoke(action);
    }

    private void OnHeartbeat()
    {
        PollCapabilities();
        RefreshStatus();
    }

    private void PollCapabilities()
    {
        if (_coordinator is null)
        {
            return;
        }

        bool hooksLive = _hooks?.IsInstalled ?? false;
        _coordinator.EmitCapability(Sample(Capability.PointerCapture, hooksLive));
        _coordinator.EmitCapability(Sample(Capability.KeyboardCapture, hooksLive));
        _coordinator.EmitCapability(Sample(Capability.AccessibilityContext, _uia?.IsReady ?? false));
    }

    private static CapabilitySample Sample(Capability capability, bool available) => available
        ? new CapabilitySample(
            capability,
            CapabilityAuthorization.Granted,
            CapabilityAvailability.Available,
            CapabilityReason.PermissionGranted)
        : new CapabilitySample(
            capability,
            CapabilityAuthorization.Granted,
            CapabilityAvailability.Unavailable,
            CapabilityReason.SourceFailure,
            "modality not supplying evidence");

    private void OnHookReArmed()
    {
        if (_coordinator is null || _hooks is null)
        {
            return;
        }

        string detail = "event tap re-armed " + _hooks.ReArmCount.ToString(CultureInfo.InvariantCulture);
        foreach (Capability capability in new[] { Capability.PointerCapture, Capability.KeyboardCapture })
        {
            _coordinator.EmitCapability(new CapabilitySample(
                capability,
                CapabilityAuthorization.Granted,
                CapabilityAvailability.Unavailable,
                CapabilityReason.EventTapTimeout,
                detail));
            _coordinator.EmitCapability(new CapabilitySample(
                capability,
                CapabilityAuthorization.Granted,
                CapabilityAvailability.Available,
                CapabilityReason.SourceRecovered,
                detail));
        }

        _lastError = "Input hook re-armed " + _hooks.ReArmCount.ToString(CultureInfo.InvariantCulture) + "x this session";
        RefreshStatus();
    }

    /// <summary>
    /// A label boundary reached the engine. The coordinator raises this on its worker thread, and
    /// the menu belongs to the UI thread, so the refresh is marshalled rather than done in place.
    /// </summary>
    private void OnLabelChanged() => Marshal(RefreshStatus);

    private void OnUiaSourceFailed(string message)
    {
        _coordinator?.EmitCapability(new CapabilitySample(
            Capability.AccessibilityContext,
            CapabilityAuthorization.Granted,
            CapabilityAvailability.Unavailable,
            CapabilityReason.SourceFailure,
            message.Length > CapabilityObservation.MaxDetailLength
                ? message[..CapabilityObservation.MaxDetailLength]
                : message));
    }

    private static GestureMetrics ReadGestureMetrics() => new(
        NativeMethods.GetDoubleClickTime(),
        NativeMethods.GetSystemMetrics(NativeMethods.SM_CXDOUBLECLK),
        NativeMethods.GetSystemMetrics(NativeMethods.SM_CYDOUBLECLK),
        NativeMethods.GetSystemMetrics(NativeMethods.SM_CXDRAG),
        NativeMethods.GetSystemMetrics(NativeMethods.SM_CYDRAG));

    /// <summary>
    /// Assembles the tray menu once. Every later change is a property update on these items: the
    /// heartbeat fires while recording, and disposing the strip there would pull the menu out from
    /// under a user who has it open.
    /// </summary>
    private void BuildMenu()
    {
        _menu.Items.Add(_statusItem);
        _menu.Items.Add(_labelStatusItem);
        _menu.Items.Add(_reArmItem);
        _menu.Items.Add(_errorItem);
        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add(_captureItem);
        _menu.Items.Add(_declareLabelItem);
        _menu.Items.Add(_endLabelItem);
        _menu.Items.Add(_reviewItem);
        _menu.Items.Add(_screenshotsItem);
        _menu.Items.Add(_settingsItem);
        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add(MenuItem("Quit", (_, _) => Quit()));

        _icon.ContextMenuStrip = _menu;
    }

    /// <summary>Updates the tooltip and every menu line in place, open menu or not.</summary>
    private void RefreshStatus()
    {
        bool recording = _capturing && _engine is not null;
        string status = recording
            ? string.Format(
                CultureInfo.InvariantCulture,
                RecordingFormat,
                DateTimeOffset.UtcNow - _startedAt,
                _engine!.EventCount)
            : IdleStatus;

        // The glyph carries the state on its own: a hollow ring while idle, a filled disc while
        // recording, the same distinction the macOS menu bar makes. A tooltip only shows on hover,
        // and whether capture is running is exactly what must be legible without one.
        _icon.Icon = recording ? RecordingIcon : IdleIcon;
        _icon.Text = recording ? Truncate("Jazz Capture - " + status) : IdleTooltip;
        _statusItem.Text = status;

        // What the user declared they are doing outranks every diagnostic below it: it is the one
        // line that says whether this stretch of the recording will mean anything downstream.
        LabelSegment? open = recording ? _engine!.OpenLabel : null;
        _labelStatusItem.Available = open is not null;
        _declareLabelItem.Enabled = recording;
        _endLabelItem.Available = open is not null;
        if (open is not null)
        {
            _labelStatusItem.Text = Truncate(
                string.Format(CultureInfo.InvariantCulture, OpenLabelFormat, open.Text));
            _endLabelItem.Text = Truncate(
                string.Format(CultureInfo.InvariantCulture, EndLabelFormat, open.Text));
            _endLabelItem.Enabled = true;
        }

        long reArms = _hooks?.ReArmCount ?? _lastReArmCount;
        _reArmItem.Available = reArms > 0;
        if (reArms > 0)
        {
            _reArmItem.Text = string.Format(CultureInfo.InvariantCulture, ReArmFormat, reArms);
        }

        _errorItem.Available = _lastError is not null;
        if (_lastError is not null)
        {
            _errorItem.Text = "! " + Truncate(_lastError);
        }

        _captureItem.Text = _capturing ? "Stop capture" : "Start capture";
        _reviewItem.Enabled = _engine is not null && !_capturing;
        _screenshotsItem.Checked = _settings.ScreenshotsEnabled;
        _screenshotsItem.Enabled = !_capturing;
    }

    private static ToolStripMenuItem MenuItem(string text, EventHandler handler, bool enabled = true)
    {
        var item = new ToolStripMenuItem(text) { Enabled = enabled };
        item.Click += handler;
        return item;
    }

    /// <summary>A non-interactive line: status, a warning, or a placeholder.</summary>
    private static ToolStripMenuItem Label(string text) => new(text) { Enabled = false };

    private static string Truncate(string text) => text.Length <= 63 ? text : text[..60] + "...";
}
