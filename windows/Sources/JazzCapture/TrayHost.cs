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
/// The host owns every moving part for one capture — the engine, the input hooks, the foreground
/// tracker, the UI Automation worker, the coordinator, and the watchdog — and wires them together on
/// start and tears them down on stop. The foreground WinEvent hook is installed here, on the WPF UI
/// thread, because that is the thread whose dispatcher pumps messages.
/// </remarks>
public sealed class TrayHost : IDisposable
{
    private readonly Settings _settings;
    private readonly NotifyIcon _icon;
    private readonly DispatcherTimer _heartbeat;

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

    /// <summary>Creates the tray host and shows its icon in the notification area.</summary>
    /// <param name="settings">The frozen host configuration.</param>
    public TrayHost(Settings settings)
    {
        _settings = settings ?? throw new ArgumentNullException(nameof(settings));
        _icon = new NotifyIcon
        {
            Icon = SystemIcons.Application,
            Visible = true,
            Text = "Jazz Capture — idle",
        };
        _heartbeat = new DispatcherTimer { Interval = _settings.HeartbeatInterval };
        _heartbeat.Tick += (_, _) => OnHeartbeat();
        RebuildMenu();
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

        RebuildMenu();
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

        _uia?.Stop();
        _capturing = false;
        RebuildMenu();

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
        _icon.Dispose();
    }

    private void TearDownCapture()
    {
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

    private void RefreshStatus()
    {
        if (_capturing && _engine is not null)
        {
            TimeSpan elapsed = DateTimeOffset.UtcNow - _startedAt;
            string status = string.Format(
                CultureInfo.InvariantCulture,
                "REC {0:hh\\:mm\\:ss} - {1} events",
                elapsed,
                _engine.EventCount);
            _icon.Text = Truncate("Jazz Capture - " + status);
        }
        else
        {
            _icon.Text = "Jazz Capture - idle";
        }

        RebuildMenu();
    }

    private void RebuildMenu()
    {
        var menu = new ContextMenuStrip();

        string statusLine = _capturing && _engine is not null
            ? string.Format(
                CultureInfo.InvariantCulture,
                "REC {0:hh\\:mm\\:ss} - {1} events",
                DateTimeOffset.UtcNow - _startedAt,
                _engine.EventCount)
            : "Idle";
        menu.Items.Add(new ToolStripMenuItem(statusLine) { Enabled = false });

        long reArms = _hooks?.ReArmCount ?? 0;
        if (reArms > 0)
        {
            menu.Items.Add(new ToolStripMenuItem(
                "! Input hook re-armed " + reArms.ToString(CultureInfo.InvariantCulture) + "x this session")
            {
                Enabled = false,
            });
        }

        if (_lastError is not null)
        {
            menu.Items.Add(new ToolStripMenuItem("! " + Truncate(_lastError)) { Enabled = false });
        }

        menu.Items.Add(new ToolStripSeparator());

        if (_capturing)
        {
            menu.Items.Add(MenuItem("Stop capture", (_, _) => StopCapture()));
        }
        else
        {
            menu.Items.Add(MenuItem("Start capture", (_, _) => StartCapture()));
        }

        menu.Items.Add(MenuItem("Open review...", (_, _) => OpenReview(), enabled: _engine is not null && !_capturing));
        menu.Items.Add(new ToolStripMenuItem("Settings... (not in MVP)") { Enabled = false });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(MenuItem("Quit", (_, _) => Quit()));

        _icon.ContextMenuStrip?.Dispose();
        _icon.ContextMenuStrip = menu;
    }

    private static ToolStripMenuItem MenuItem(string text, EventHandler handler, bool enabled = true)
    {
        var item = new ToolStripMenuItem(text) { Enabled = enabled };
        item.Click += handler;
        return item;
    }

    private static string Truncate(string text) => text.Length <= 63 ? text : text[..60] + "...";
}
