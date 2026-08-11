using System.Drawing;
using System.Globalization;
using System.Windows.Forms;
using System.Windows.Threading;
using JazzCaptureCore;
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

    private readonly Settings _settings;
    private readonly NotifyIcon _icon;
    private readonly DispatcherTimer _heartbeat;

    private readonly ContextMenuStrip _menu = new();
    private readonly ToolStripMenuItem _statusItem = Label(IdleStatus);
    private readonly ToolStripMenuItem _reArmItem = Label(string.Empty);
    private readonly ToolStripMenuItem _errorItem = Label(string.Empty);
    private readonly ToolStripMenuItem _captureItem;
    private readonly ToolStripMenuItem _reviewItem;

    private CaptureEngine? _engine;
    private AppIdentityResolver? _identity;
    private UiaResolver? _uia;
    private InputHooks? _hooks;
    private ForegroundTracker? _foreground;
    private CaptureCoordinator? _coordinator;
    private HookWatchdog? _watchdog;
    private ReviewWindow? _review;

    private DateTimeOffset _startedAt;
    private bool _capturing;
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
    /// <param name="settings">The frozen host configuration.</param>
    public TrayHost(Settings settings)
    {
        _settings = settings ?? throw new ArgumentNullException(nameof(settings));
        _icon = new NotifyIcon
        {
            Icon = IdleIcon,
            Visible = true,
            Text = IdleTooltip,
        };
        _heartbeat = new DispatcherTimer { Interval = _settings.HeartbeatInterval };
        _heartbeat.Tick += (_, _) => OnHeartbeat();

        _captureItem = MenuItem("Start capture", (_, _) => ToggleCapture());
        _reviewItem = MenuItem("Open review...", (_, _) => OpenReview(), enabled: false);
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

            _coordinator = new CaptureCoordinator(
                _engine,
                _settings,
                _uia,
                _identity,
                () => DateTimeOffset.UtcNow,
                ReadGestureMetrics());
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
        _coordinator?.DrainAndStop();
        _coordinator?.Dispose();
        _coordinator = null;
        if (_uia is not null)
        {
            _uia.SourceFailed -= OnUiaSourceFailed;
            _uia.Dispose();
            _uia = null;
        }

        _capturing = false;
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
        _menu.Items.Add(_reArmItem);
        _menu.Items.Add(_errorItem);
        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add(_captureItem);
        _menu.Items.Add(_reviewItem);
        _menu.Items.Add(Label("Settings... (not in MVP)"));
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
