using System.Diagnostics;
using Microsoft.Win32;
using JazzCaptureCore;

namespace JazzCapture;

/// <summary>
/// <c>HKCU\Control Panel\NotifyIconSettings</c>: one subkey per notification-area icon. Windows 11
/// creates the subkey after the icon registers. The key is not documented by Microsoft.
/// </summary>
internal sealed class NotifyIconSettingsRegistry : INotifyIconSettingsRegistry
{
    internal const string KeyPath = @"Control Panel\NotifyIconSettings";

    public IReadOnlyList<NotifyIconEntry> Read()
    {
        var entries = new List<NotifyIconEntry>();
        using RegistryKey? root = Registry.CurrentUser.OpenSubKey(KeyPath, writable: false);
        if (root is null) return entries;
        foreach (string name in root.GetSubKeyNames())
        {
            using RegistryKey? subKey = root.OpenSubKey(name, writable: false);
            if (subKey is null) continue;
            string? path = subKey.GetValue("ExecutablePath") as string;
            int? promoted = subKey.GetValue("IsPromoted") is int value ? value : null;
            entries.Add(new NotifyIconEntry(name, path, promoted));
        }

        return entries;
    }

    public void SetPromoted(string subKey)
    {
        using RegistryKey? key = Registry.CurrentUser.OpenSubKey(KeyPath + "\\" + subKey, writable: true);
        key?.SetValue("IsPromoted", 1, RegistryValueKind.DWord);
    }
}

/// <summary>
/// Shows the tray icon on the taskbar on Windows 11, once per install. A user who hides it later
/// keeps that choice, because the marker is stored and the setting is not written again.
/// Never throws: a failure is logged and the next launch tries again.
/// </summary>
internal sealed class TrayIconPromoter
{
    internal static readonly TimeSpan RetryDelay = TimeSpan.FromSeconds(10);

    private readonly INotifyIconSettingsRegistry _registry;
    private readonly FirstRunStateStore _state;
    private readonly string _executablePath;
    private readonly Func<TimeSpan, CancellationToken, Task> _delay;
    private readonly Action<string> _log;

    internal TrayIconPromoter(
        INotifyIconSettingsRegistry registry,
        FirstRunStateStore state,
        string executablePath,
        Func<TimeSpan, CancellationToken, Task>? delay = null,
        Action<string>? log = null)
    {
        _registry = registry;
        _state = state;
        _executablePath = executablePath;
        _delay = delay ?? Task.Delay;
        _log = log ?? (message => Trace.WriteLine("Jazz tray icon: " + message));
    }

    internal async Task RunAsync(CancellationToken cancellationToken)
    {
        try
        {
            if (_state.ReadTrayIconPromoted()) return;
            if (TryPromoteOnce()) return;

            // The subkey appears only after the icon registers.
            await _delay(RetryDelay, cancellationToken).ConfigureAwait(false);
            if (!TryPromoteOnce()) _log("no NotifyIconSettings entry found for this executable");
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception exception)
        {
            _log("could not promote the icon: " + exception.GetType().Name);
        }
    }

    private bool TryPromoteOnce()
    {
        if (!TrayIconPromotion.TryPromote(_registry, _executablePath)) return false;
        _state.RecordTrayIconPromoted();
        return true;
    }
}
