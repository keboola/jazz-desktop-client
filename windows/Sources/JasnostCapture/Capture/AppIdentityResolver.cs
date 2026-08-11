using System.IO;
using System.Diagnostics;
using System.Text;
using JasnostCaptureCore;
using JasnostCapture.Interop;

namespace JasnostCapture.Capture;

/// <summary>
/// Turns a window handle or a process id into the stable <see cref="AppIdentity"/> the archive
/// attributes an event to (ANNEX-HOST section 1): a packaged app's AUMID when the Shell exposes one,
/// otherwise the normalized executable path, with the human name and file version filled from the
/// executable's version resource.
/// </summary>
/// <remarks>
/// This is the attribution authority, so it is also the first of the three own-window exclusion
/// layers: any window owned by this process resolves to <see langword="null"/>, which the pipeline
/// turns into a "desktop client UI" gap rather than a recorded event.
/// </remarks>
public sealed class AppIdentityResolver
{
    private static readonly int OwnProcessId = Environment.ProcessId;

    /// <summary>Whether the window belongs to this capture client's own process.</summary>
    public bool IsOwnWindow(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero)
        {
            return false;
        }

        _ = NativeMethods.GetWindowThreadProcessId(hwnd, out uint pid);
        return pid == OwnProcessId;
    }

    /// <summary>Resolves the identity of the application that owns a window.</summary>
    /// <returns>The identity, or <see langword="null"/> when it cannot be attributed or is our own.</returns>
    public AppIdentity? Resolve(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero)
        {
            return null;
        }

        _ = NativeMethods.GetWindowThreadProcessId(hwnd, out uint pid);
        if (pid == 0 || pid == OwnProcessId)
        {
            return null;
        }

        string? aumid = TryReadAumid(hwnd);
        if (!string.IsNullOrWhiteSpace(aumid))
        {
            return new AppIdentity(AppIdentity.AumidNamespace, aumid!, DisplayName(aumid!), null);
        }

        return ResolveByProcess(pid);
    }

    /// <summary>Resolves an identity from a process id alone (no window available).</summary>
    public AppIdentity? ResolveByProcess(uint pid)
    {
        if (pid == 0 || pid == OwnProcessId)
        {
            return null;
        }

        string? path = TryQueryImagePath(pid);
        if (string.IsNullOrWhiteSpace(path))
        {
            return null;
        }

        string normalized = path!.Replace('\\', '/').ToLowerInvariant();
        (string? name, string? version) = TryReadVersion(path!);
        return new AppIdentity(
            AppIdentity.ExecutablePathNamespace,
            normalized,
            name ?? Path.GetFileNameWithoutExtension(path),
            version);
    }

    /// <summary>The top-level window title, for the event's <c>pageTitle</c>.</summary>
    public string? WindowTitle(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero)
        {
            return null;
        }

        int length = NativeMethods.GetWindowTextLengthW(hwnd);
        if (length <= 0)
        {
            return null;
        }

        var buffer = new StringBuilder(length + 1);
        int copied = NativeMethods.GetWindowTextW(hwnd, buffer, buffer.Capacity);
        return copied > 0 ? buffer.ToString() : null;
    }

    private static string DisplayName(string aumid)
    {
        // An AUMID is "PackageFamily!AppId"; the app id is the closest thing to a human name here.
        int bang = aumid.IndexOf('!');
        return bang >= 0 && bang < aumid.Length - 1 ? aumid[(bang + 1)..] : aumid;
    }

    private static string? TryQueryImagePath(uint pid)
    {
        IntPtr handle = NativeMethods.OpenProcess(
            NativeMethods.PROCESS_QUERY_LIMITED_INFORMATION,
            false,
            pid);
        if (handle == IntPtr.Zero)
        {
            return null;
        }

        try
        {
            var buffer = new StringBuilder(1024);
            uint size = (uint)buffer.Capacity;
            return NativeMethods.QueryFullProcessImageNameW(handle, 0, buffer, ref size)
                ? buffer.ToString(0, (int)size)
                : null;
        }
        finally
        {
            NativeMethods.CloseHandle(handle);
        }
    }

    private static (string? Name, string? Version) TryReadVersion(string path)
    {
        try
        {
            FileVersionInfo info = FileVersionInfo.GetVersionInfo(path);
            string? name = string.IsNullOrWhiteSpace(info.ProductName) ? info.FileDescription : info.ProductName;
            return (string.IsNullOrWhiteSpace(name) ? null : name, string.IsNullOrWhiteSpace(info.FileVersion) ? null : info.FileVersion);
        }
        catch
        {
            return (null, null);
        }
    }

    private static string? TryReadAumid(IntPtr hwnd)
    {
        // Best-effort: any COM/marshalling failure yields null and the caller falls back to the path.
        IPropertyStore? store = null;
        try
        {
            Guid iid = ShellInterop.IID_IPropertyStore;
            int hr = ShellInterop.SHGetPropertyStoreForWindow(hwnd, ref iid, out store);
            if (hr < 0 || store is null)
            {
                return null;
            }

            PropertyKey key = ShellInterop.PkeyAppUserModelId;
            hr = store.GetValue(ref key, out PropVariant value);
            if (hr < 0)
            {
                return null;
            }

            try
            {
                if (ShellInterop.PropVariantToStringAlloc(ref value, out IntPtr text) >= 0 && text != IntPtr.Zero)
                {
                    string? result = System.Runtime.InteropServices.Marshal.PtrToStringUni(text);
                    ShellInterop.CoTaskMemFree(text);
                    return string.IsNullOrWhiteSpace(result) ? null : result;
                }

                return null;
            }
            finally
            {
                ShellInterop.PropVariantClear(ref value);
            }
        }
        catch
        {
            return null;
        }
        finally
        {
            if (store is not null)
            {
                System.Runtime.InteropServices.Marshal.ReleaseComObject(store);
            }
        }
    }
}
