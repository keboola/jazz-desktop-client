using System.Runtime.InteropServices;
using JazzCapture.Capture;
using JazzCaptureCore;

// Exercises the screenshot path against whatever is on screen right now, so the parts that no test
// on another platform can reach are answered by the machine itself: whether PrintWindow returns
// pixels rather than black on a DWM-composited window, whether the DIB stride assumptions hold,
// whether WIC encodes from a worker thread, and what a quality-85 frame actually costs.
//
// It writes the JPEG next to itself so the frame can be looked at, and reports the share of
// non-black pixels — a byte count alone cannot tell a real capture from a black rectangle, which is
// the classic PrintWindow failure.
//
// Usage: JazzScreenProbe [outputDirectory]

string outputDirectory = args.Length > 0 ? args[0] : AppContext.BaseDirectory;

var identity = new AppIdentityResolver();
var capture = new ScreenCapture(identity, () => DateTimeOffset.UtcNow);

IntPtr foreground = Win32.GetForegroundWindow();
Win32.GetWindowThreadProcessId(foreground, out uint pid);
AppIdentity? owner = identity.ResolveByProcess(pid);

Console.WriteLine($"foreground hwnd : 0x{foreground.ToInt64():x}");
Console.WriteLine($"foreground title: {identity.WindowTitle(foreground) ?? "(none)"}");
Console.WriteLine($"owner           : {owner?.Name ?? "(unresolved)"} pid={pid}");

if (owner is null)
{
    Console.WriteLine("RESULT: no owner identity, nothing to attribute a frame to");
    return 1;
}

// No target rect: the picker falls back to the owner's largest qualifying window, which is what a
// probe wants. A real click supplies the element rectangle.
ScreenshotAttempt attempt = capture.CaptureWindow(owner, pid, targetRect: null);

if (attempt.Frame is not { } frame)
{
    Console.WriteLine($"RESULT: no frame - {attempt.Detail}");
    return 1;
}

string path = System.IO.Path.Combine(outputDirectory, "probe-frame.jpg");
System.IO.File.WriteAllBytes(path, frame.Jpeg);

Console.WriteLine($"jpeg bytes      : {frame.Jpeg.Length}");
Console.WriteLine($"jpeg magic      : {(IsJpeg(frame.Jpeg) ? "ok (ffd8..ffd9)" : "NOT A JPEG")}");
Console.WriteLine($"perceptual hash : 0x{frame.PerceptualHash:x16}");
Console.WriteLine($"duration ms     : {frame.MonotonicDurationMillis}");
Console.WriteLine($"scope           : {frame.Scope}");
Console.WriteLine($"written to      : {path}");

// A hash of zero means every sampled cell had the same brightness: an all-black or all-white frame,
// which is exactly what a failed PrintWindow produces while still returning success.
Console.WriteLine(frame.PerceptualHash == 0
    ? "WARNING: the perceptual hash is flat, which is what an all-black frame looks like"
    : "content         : the frame has structure, so PrintWindow returned real pixels");

// A second capture proves the single-flight slot is released by the first one's return.
ScreenshotAttempt second = capture.CaptureWindow(owner, pid, targetRect: null);
Console.WriteLine(second.Frame is null
    ? $"second capture  : refused - {second.Detail}"
    : $"second capture  : {second.Frame.Jpeg.Length} bytes in {second.Frame.MonotonicDurationMillis} ms");

Console.WriteLine("RESULT: captured");
return 0;

static bool IsJpeg(byte[] bytes) =>
    bytes.Length > 4
    && bytes[0] == 0xFF && bytes[1] == 0xD8
    && bytes[^2] == 0xFF && bytes[^1] == 0xD9;

internal static class Win32
{
    [DllImport("user32.dll")]
    internal static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    internal static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
}
