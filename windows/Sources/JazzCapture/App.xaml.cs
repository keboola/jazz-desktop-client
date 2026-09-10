using System.Windows;
using System.IO;
using JazzCaptureCore;

namespace JazzCapture;

/// <summary>
/// The application entry point. It has no main window: the whole UI is the tray icon, so the
/// application starts the <see cref="TrayHost"/> and only exits when the host asks it to.
/// </summary>
public partial class App
{
    private TrayHost? _host;
    private MaintenanceShutdownWindow? _maintenanceWindow;
    private Mutex? _instanceMutex;
    private bool _ownsInstanceMutex;
    private UserActivation? _activation;
    private FirstRunStateStore? _startupState;
    private Settings? _settings;
    private OnboardingWindow? _statusWindow;
    private readonly CancellationTokenSource _shutdown = new();

    /// <inheritdoc />
    /// <remarks>
    /// The user's saved preferences are read here, before anything else exists, because the
    /// exclusion list has to be in force from the first capture of the run. A settings file that
    /// cannot be read never stops startup: the built-in seeds stand in, and the reason travels to
    /// the settings window so it can be shown rather than swallowed.
    /// </remarks>
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        string sid = System.Security.Principal.WindowsIdentity.GetCurrent().User?.Value
            ?? throw new InvalidOperationException("Current user SID is unavailable.");
        bool owned;
        try
        {
            _instanceMutex = new Mutex(true, "Local\\JazzCapture." + sid, out owned);
        }
        catch (AbandonedMutexException exception) when (exception.Mutex is Mutex recovered)
        {
            // Ownership is recovered; a stale process must not permanently prevent local UI access.
            _instanceMutex = recovered;
            owned = true;
        }
        _ownsInstanceMutex = owned;
        if (!owned)
        {
            UserActivation.TryActivateExisting();
            Shutdown();
            return;
        }

        _startupState = new FirstRunStateStore(Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Jazz"));
        (Settings settings, HostSettingsLoad load) = Settings.Load();
        _settings = settings;
        _host = new TrayHost(
            settings,
            load.Origin == HostSettingsOrigin.Unreadable ? load.Detail : null);
        _activation = new UserActivation(() => Dispatcher.BeginInvoke(ShowStatus));
        _activation.Start();
        _maintenanceWindow = new MaintenanceShutdownWindow(
            () => _host?.TryPrepareForMaintenance() ?? true,
            () => Dispatcher.BeginInvoke(() => Shutdown()));
        if (_startupState.RequiresOnboarding()) ShowStatus();
        _ = CheckForUpdateAsync(_startupState, _shutdown.Token);
    }

    internal void ShowStatus()
    {
        if (_startupState is null) return;
        if (_statusWindow is null || !_statusWindow.IsLoaded)
        {
            _statusWindow = new OnboardingWindow(_startupState.Acknowledge, _settings ?? new Settings());
            _statusWindow.Closed += (_, _) => _statusWindow = null;
            _statusWindow.Show();
        }
        _statusWindow.Activate();
    }

    private async Task CheckForUpdateAsync(FirstRunStateStore state, CancellationToken cancellationToken)
    {
        using var client = new GitHubUpdateClient(state);
        AvailableRelease? release = await client.CheckAsync(cancellationToken);
        if (release is not null && _host is not null)
        {
            await Dispatcher.InvokeAsync(() => _host?.SetAvailableRelease(release));
        }
    }

    /// <inheritdoc />
    protected override void OnExit(ExitEventArgs e)
    {
        _shutdown.Cancel();
        _host?.Dispose();
        _host = null;
        _maintenanceWindow?.Dispose();
        _maintenanceWindow = null;
        _statusWindow?.Close();
        _statusWindow = null;
        _activation?.Dispose();
        _activation = null;
        if (_ownsInstanceMutex) _instanceMutex?.ReleaseMutex();
        _instanceMutex?.Dispose();
        _instanceMutex = null;
        _shutdown.Dispose();
        base.OnExit(e);
    }
}
