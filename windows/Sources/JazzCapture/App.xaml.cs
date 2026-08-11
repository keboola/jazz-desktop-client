using System.Windows;

namespace JazzCapture;

/// <summary>
/// The application entry point. It has no main window: the whole UI is the tray icon, so the
/// application starts the <see cref="TrayHost"/> and only exits when the host asks it to.
/// </summary>
public partial class App
{
    private TrayHost? _host;

    /// <inheritdoc />
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        _host = new TrayHost(new Settings());
    }

    /// <inheritdoc />
    protected override void OnExit(ExitEventArgs e)
    {
        _host?.Dispose();
        _host = null;
        base.OnExit(e);
    }
}
