using System.IO;
using System.Diagnostics;
using System.Text;
using JazzCaptureCore;
using JazzCapture.Interop;

namespace JazzCapture.Capture;

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

    private readonly Func<IntPtr, uint> _windowProcessId;
    private readonly Func<IntPtr, AumidRead> _readAumid;
    private readonly Func<uint, string?> _queryImagePath;

    /// <summary>Creates the resolver over the real Win32 and Shell calls.</summary>
    public AppIdentityResolver()
        : this(WindowProcessId, TryReadAumid, TryQueryImagePath)
    {
    }

    /// <summary>Creates the resolver over fakes of its Win32 and Shell calls, for tests.</summary>
    /// <param name="windowProcessId">The process owning a window, or 0 when unknown.</param>
    /// <param name="readAumid">Reads a window's AUMID.</param>
    /// <param name="queryImagePath">The executable path of a process, or null when unreadable.</param>
    internal AppIdentityResolver(
        Func<IntPtr, uint> windowProcessId,
        Func<IntPtr, AumidRead> readAumid,
        Func<uint, string?> queryImagePath)
    {
        _windowProcessId = windowProcessId ?? throw new ArgumentNullException(nameof(windowProcessId));
        _readAumid = readAumid ?? throw new ArgumentNullException(nameof(readAumid));
        _queryImagePath = queryImagePath ?? throw new ArgumentNullException(nameof(queryImagePath));
    }

    /// <summary>Whether the window belongs to this capture client's own process.</summary>
    public bool IsOwnWindow(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero)
        {
            return false;
        }

        return _windowProcessId(hwnd) == OwnProcessId;
    }

    /// <summary>Resolves the identity of the application that owns a window.</summary>
    /// <remarks>
    /// A window whose AUMID cannot be read still resolves to its executable path here. Callers that
    /// enforce the denylist must use <see cref="ResolveWindow"/> and honor
    /// <see cref="ResolvedWindow.AumidUnreadable"/> instead.
    /// </remarks>
    /// <returns>The identity, or <see langword="null"/> when it cannot be attributed or is our own.</returns>
    public AppIdentity? Resolve(IntPtr hwnd) => ResolveWindow(hwnd).Identity;

    /// <summary>
    /// Resolves the identity of the application that owns a window and reports whether its AUMID
    /// read failed, as opposed to the window having no AUMID.
    /// </summary>
    public ResolvedWindow ResolveWindow(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero)
        {
            return default;
        }

        uint pid = _windowProcessId(hwnd);
        if (pid == 0 || pid == OwnProcessId)
        {
            return default;
        }

        AumidRead aumid = _readAumid(hwnd);
        if (aumid.Status == AumidStatus.Found && !string.IsNullOrWhiteSpace(aumid.Value))
        {
            return new ResolvedWindow(
                new AppIdentity(AppIdentity.AumidNamespace, aumid.Value!, DisplayName(aumid.Value!), null),
                false);
        }

        return new ResolvedWindow(ResolveByProcess(pid), aumid.Status == AumidStatus.Failed);
    }

    /// <summary>Resolves an identity from a process id alone (no window available).</summary>
    public AppIdentity? ResolveByProcess(uint pid)
    {
        if (pid == 0 || pid == OwnProcessId)
        {
            return null;
        }

        string? path = _queryImagePath(pid);
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

    private static uint WindowProcessId(IntPtr hwnd)
    {
        _ = NativeMethods.GetWindowThreadProcessId(hwnd, out uint pid);
        return pid;
    }

    private static AumidRead TryReadAumid(IntPtr hwnd)
    {
        // An HRESULT failure or an exception is Failed, which callers enforcing the denylist must
        // not treat as "no AUMID". An empty or null property value is a genuine Absent.
        IPropertyStore? store = null;
        try
        {
            Guid iid = ShellInterop.IID_IPropertyStore;
            int hr = ShellInterop.SHGetPropertyStoreForWindow(hwnd, ref iid, out store);
            if (hr < 0 || store is null)
            {
                return AumidRead.Failed;
            }

            PropertyKey key = ShellInterop.PkeyAppUserModelId;
            hr = store.GetValue(ref key, out PropVariant value);
            if (hr < 0)
            {
                return AumidRead.Failed;
            }

            try
            {
                if (value.VarType is VtEmpty or VtNull)
                {
                    return AumidRead.Absent;
                }

                if (ShellInterop.PropVariantToStringAlloc(ref value, out IntPtr text) < 0 || text == IntPtr.Zero)
                {
                    return AumidRead.Failed;
                }

                string? result = System.Runtime.InteropServices.Marshal.PtrToStringUni(text);
                ShellInterop.CoTaskMemFree(text);
                return string.IsNullOrWhiteSpace(result) ? AumidRead.Absent : AumidRead.Found(result!);
            }
            finally
            {
                ShellInterop.PropVariantClear(ref value);
            }
        }
        catch
        {
            return AumidRead.Failed;
        }
        finally
        {
            if (store is not null)
            {
                System.Runtime.InteropServices.Marshal.ReleaseComObject(store);
            }
        }
    }

    private const ushort VtEmpty = 0;
    private const ushort VtNull = 1;
}

/// <summary>How reading a window's AUMID ended.</summary>
internal enum AumidStatus
{
    /// <summary>The window has an AUMID.</summary>
    Found,

    /// <summary>The read succeeded and the window has no AUMID.</summary>
    Absent,

    /// <summary>The read did not complete (HRESULT failure or exception); whether an AUMID exists is unknown.</summary>
    Failed,
}

/// <summary>The outcome of reading a window's AUMID.</summary>
internal readonly record struct AumidRead(AumidStatus Status, string? Value)
{
    /// <summary>The window has no AUMID.</summary>
    public static AumidRead Absent => new(AumidStatus.Absent, null);

    /// <summary>The read failed.</summary>
    public static AumidRead Failed => new(AumidStatus.Failed, null);

    /// <summary>The window has this AUMID.</summary>
    public static AumidRead Found(string value) => new(AumidStatus.Found, value);
}
