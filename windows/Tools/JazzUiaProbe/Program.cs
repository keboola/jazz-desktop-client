using System.Runtime.InteropServices;
using JasnostCapture.Capture;

// Exercises the hand-written UI Automation COM interop and the application-identity resolver
// against whatever is currently on screen. The interop declares only the vtable slots the host
// uses, so the slot offsets cannot be checked by the compiler: this probe is how a real machine
// proves they are right before anyone trusts a capture.
//
// Usage: JazzUiaProbe [x y]

var identity = new AppIdentityResolver();
using var resolver = new UiaResolver(identity, TimeSpan.FromMilliseconds(300));

resolver.SourceFailed += reason => Console.WriteLine($"  source failure: {reason}");
resolver.Start();
Console.WriteLine($"resolver ready: {resolver.IsReady}");

if (!resolver.IsReady)
{
    Console.WriteLine("FAIL: the UI Automation object could not be created.");
    return 1;
}

var foreground = Win32.GetForegroundWindow();
Console.WriteLine($"foreground hwnd: 0x{foreground.ToInt64():x}");
Console.WriteLine($"foreground title: {identity.WindowTitle(foreground) ?? "(none)"}");

var app = identity.Resolve(foreground);
Console.WriteLine(app is null
    ? "foreground identity: (unresolved)"
    : $"foreground identity: {app.Namespace} = {app.Value} | name={app.Name} version={app.Version}");

var probes = new List<(string Label, int X, int Y)>();
if (args.Length >= 2 && int.TryParse(args[0], out var ax) && int.TryParse(args[1], out var ay))
{
    probes.Add(("requested point", ax, ay));
}
else
{
    var width = Win32.GetSystemMetrics(Win32.SM_CXSCREEN);
    var height = Win32.GetSystemMetrics(Win32.SM_CYSCREEN);
    Console.WriteLine($"virtual screen: {width}x{height}");
    probes.Add(("screen centre", width / 2, height / 2));
    probes.Add(("taskbar strip", width / 2, height - 10));
    probes.Add(("top-left corner", 8, 8));
}

var resolved = 0;
foreach (var (label, x, y) in probes)
{
    var result = resolver.ResolveAt(x, y);
    Console.WriteLine($"{label} ({x},{y}): status={result.Status}");
    if (result.Target is not { } target)
    {
        continue;
    }

    resolved++;
    Console.WriteLine($"  role={target.Role ?? "(null)"} name={target.Name ?? "(null)"}");
    Console.WriteLine($"  automationId={target.AutomationId ?? "(null)"} isPassword={target.IsPassword}");
    Console.WriteLine($"  bounds={(target.Bounds is null ? "(null)" : $"{target.Bounds.X},{target.Bounds.Y} {target.Bounds.Width}x{target.Bounds.Height}")}");
    Console.WriteLine($"  pid={target.ProcessId} hwnd=0x{target.WindowHandle.ToInt64():x}");
}

var focused = resolver.ResolveFocused();
Console.WriteLine(focused is null
    ? "focused element: (none)"
    : $"focused element: role={focused.Role} name={focused.Name} isPassword={focused.IsPassword}");

resolver.Stop();

// A locked or blank screen legitimately resolves nothing, so an empty result is reported rather
// than treated as a failure. Only a resolver that never came up is a hard failure.
Console.WriteLine($"RESULT: resolver started, {resolved}/{probes.Count} probe points resolved");
return 0;

// The host keeps its own interop internal; the probe declares the two entry points it needs so
// running it never widens the host's public surface.
internal static class Win32
{
    internal const int SM_CXSCREEN = 0;
    internal const int SM_CYSCREEN = 1;

    [DllImport("user32.dll")]
    internal static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    internal static extern int GetSystemMetrics(int nIndex);
}
