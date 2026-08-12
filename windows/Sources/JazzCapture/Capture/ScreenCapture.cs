using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using JazzCaptureCore;
using JazzCaptureCore.Archive;
using JazzCaptureCore.Screen;
using JazzCapture.Interop;

namespace JazzCapture.Capture;

/// <summary>Why one screenshot attempt produced no bytes.</summary>
public enum ScreenshotFailure
{
    /// <summary>An earlier physical capture still holds the process-wide slot.</summary>
    PriorRequestStillInFlight,

    /// <summary>The capture did not return within its budget.</summary>
    DeadlineExceeded,

    /// <summary>
    /// No window of the owning application contains the target. Nothing is guessed and, on Windows,
    /// nothing falls back to the display.
    /// </summary>
    NoWindowAtTarget,

    /// <summary>The window's owning process is not the owner the event was attributed to.</summary>
    OwnerMismatch,

    /// <summary>The OS refused or the frame could not be encoded.</summary>
    SourceUnavailable,
}

/// <summary>
/// One captured frame and the honest acquisition evidence that goes with it.
/// </summary>
/// <param name="Jpeg">The encoded frame.</param>
/// <param name="PerceptualHash">
/// dHash of the frame. Computed and carried, never used to skip a frame: whole-frame dedup erased
/// small but process-critical changes upstream and was removed. The v1 evidence namespace defines no
/// key for it, and an unknown key in that namespace fails the archive schema, so it stays in memory.
/// </param>
/// <param name="RequestStartedAt">Wall clock read just after the monotonic start.</param>
/// <param name="MonotonicDurationMillis">Monotonic milliseconds the capture took.</param>
/// <param name="Scope">What the frame covers; always one window.</param>
public sealed record ScreenshotFrame(
    byte[] Jpeg,
    ulong PerceptualHash,
    DateTimeOffset RequestStartedAt,
    long MonotonicDurationMillis,
    ScreenshotWindowScope Scope);

/// <summary>The outcome of one screenshot request: a frame, or a reason there is none.</summary>
/// <param name="Frame">The frame, when one was captured.</param>
/// <param name="Failure">Why not, otherwise.</param>
public sealed record ScreenshotAttempt(ScreenshotFrame? Frame, ScreenshotFailure? Failure)
{
    /// <summary>Free text for the capability observation a failure produces.</summary>
    public string Detail => Failure switch
    {
        ScreenshotFailure.PriorRequestStillInFlight =>
            "a prior physical screenshot request is still in flight",
        ScreenshotFailure.DeadlineExceeded => "focused window screenshot deadline exceeded",
        ScreenshotFailure.NoWindowAtTarget => "no window of the owning application at the target",
        ScreenshotFailure.OwnerMismatch => "captured window is owned by another application",
        ScreenshotFailure.SourceUnavailable => "focused window screenshot returned no image",
        _ => "focused window screenshot unavailable",
    };
}

/// <summary>
/// Sparse one-shot screenshots of the focused window (ANNEX-HOST section 4).
/// </summary>
/// <remarks>
/// <para>
/// <c>PrintWindow(hwnd, hdc, PW_RENDERFULLCONTENT)</c> into a top-down 32-bit DIB, encoded as JPEG
/// at quality 0.85. JPEG rather than PNG because a focused-window frame is several times smaller
/// while staying legible for downstream extraction; the flag is what makes DWM- and GPU-composed
/// windows come back as pixels instead of black. The cursor is never drawn — <c>PrintWindow</c>
/// renders the window, not the screen.
/// </para>
/// <para>
/// <b>There is no display fallback, deliberately.</b> macOS can capture a whole display while
/// filtering named applications out of the frame (<c>SCContentFilter excludingApplications</c>), so
/// a display capture there can still honour the denylist. Windows has no equivalent: a full-screen
/// grab returns whatever happens to be on screen, including a password manager the capture policy
/// promised never to record. macOS already fails closed when it cannot prove the filter covers every
/// running denylisted app, and this client fails closed always. When no suitable window is found,
/// nothing is captured, the event is kept with an unavailable reason, and <c>screen.capture</c> flips
/// to unavailable with <c>source_failure</c>. A display-scope screenshot that cannot honour the
/// denylist is a privacy leak, not a fallback.
/// </para>
/// <para>
/// Owner verification runs before <c>PrintWindow</c>, not after: if the window's owning process is
/// not the owner the event was attributed to, the pixels are never produced at all, let alone
/// offered to the archive.
/// </para>
/// </remarks>
public sealed class ScreenCapture
{
    /// <summary>
    /// Longest the capture path waits for one frame. A screenshot is local enrichment of an event
    /// that already happened; it never holds an admitted journal producer open indefinitely.
    /// </summary>
    public static readonly TimeSpan DefaultBudget = TimeSpan.FromSeconds(2);

    /// <summary>JPEG quality, as the WPF encoder expresses the 0.85 the contract names.</summary>
    private const int JpegQuality = 85;

    private const int BitsPerPixel = 32;
    private const int BytesPerPixel = 4;

    /// <summary>
    /// One physical capture process-wide. Acquisition is non-blocking: a caller that arrives while a
    /// capture is in flight fails immediately rather than queueing behind it.
    /// </summary>
    private readonly SingleFlightGate _physical = new();

    private readonly AppIdentityResolver _identity;
    private readonly Func<DateTimeOffset> _clock;
    private readonly TimeSpan _budget;

    /// <summary>Creates the capture path around the resolver that owns application attribution.</summary>
    /// <param name="identity">Resolves a window's owning process into an application identity.</param>
    /// <param name="clock">Wall clock; injected so a host can make a capture deterministic.</param>
    /// <param name="budget">Capture budget; two seconds unless a caller says otherwise.</param>
    public ScreenCapture(AppIdentityResolver identity, Func<DateTimeOffset> clock, TimeSpan? budget = null)
    {
        _identity = identity ?? throw new ArgumentNullException(nameof(identity));
        _clock = clock ?? throw new ArgumentNullException(nameof(clock));
        _budget = budget ?? DefaultBudget;
    }

    /// <summary>
    /// Captures the window of <paramref name="owner"/> that contains <paramref name="targetRect"/>.
    /// </summary>
    /// <param name="owner">The application the event was attributed to.</param>
    /// <param name="ownerProcessId">The process whose windows are candidates.</param>
    /// <param name="targetRect">
    /// Where the interaction landed, in screen coordinates. For a drag this is the release point,
    /// even though the accessibility attribution stays on the press point.
    /// </param>
    public ScreenshotAttempt CaptureWindow(AppIdentity owner, uint ownerProcessId, BoundingBox? targetRect)
    {
        ArgumentNullException.ThrowIfNull(owner);

        // Monotonic start first, wall anchor second, then the OS request. The elapsed duration
        // therefore includes the pairing delay rather than understating how late the frame is.
        long startedTicks = Stopwatch.GetTimestamp();
        DateTimeOffset requestStartedAt = _clock();

        SingleFlightResult<Acquisition> result = _physical.Run(
            _budget,
            () => Acquire(owner, ownerProcessId, targetRect, startedTicks));

        switch (result.Outcome)
        {
            case SingleFlightOutcome.Busy:
                return Failed(ScreenshotFailure.PriorRequestStillInFlight);
            case SingleFlightOutcome.TimedOut:
                return Failed(ScreenshotFailure.DeadlineExceeded);
        }

        Acquisition acquisition = result.Value!;
        if (acquisition.Failure is { } failure)
        {
            return Failed(failure);
        }

        return new ScreenshotAttempt(
            new ScreenshotFrame(
                acquisition.Jpeg!,
                acquisition.PerceptualHash,
                requestStartedAt,
                acquisition.DurationMillis,
                acquisition.Scope!),
            null);
    }

    private static ScreenshotAttempt Failed(ScreenshotFailure failure) => new(null, failure);

    /// <summary>The physical capture. Runs on the single-flight worker, never on a hook thread.</summary>
    private Acquisition Acquire(
        AppIdentity owner,
        uint ownerProcessId,
        BoundingBox? targetRect,
        long startedTicks)
    {
        ScreenshotWindowCandidate? picked = ScreenshotWindowPicker.Pick(
            Candidates(ownerProcessId),
            targetRect,
            // Always, for pointer events: a picture of the wrong window is worse than no picture.
            requireWindowAtTarget: true);
        if (picked is null)
        {
            return Acquisition.Refused(ScreenshotFailure.NoWindowAtTarget);
        }

        var hwnd = (IntPtr)picked.WindowId;
        if (!OwnedBy(hwnd, owner))
        {
            // Refused before a single pixel exists. The archive is not the only place these bytes
            // must not reach; the cheapest way to keep that promise is never to render them.
            return Acquisition.Refused(ScreenshotFailure.OwnerMismatch);
        }

        Frame? frame = Render(hwnd, picked.Bounds);
        if (frame is null)
        {
            return Acquisition.Refused(ScreenshotFailure.SourceUnavailable);
        }

        byte[]? jpeg = Encode(frame);
        if (jpeg is null)
        {
            return Acquisition.Refused(ScreenshotFailure.SourceUnavailable);
        }

        byte[]? grid = ScreenshotThumbnail.Grayscale(
            frame.Pixels,
            frame.Width,
            frame.Height,
            frame.Stride);
        ulong hash = grid is null
            ? 0
            : PerceptualHash.DHash(grid, PerceptualHash.GridWidth, PerceptualHash.GridHeight);

        return new Acquisition(
            null,
            jpeg,
            hash,
            new ScreenshotWindowScope(owner.Value, picked.WindowId),
            ElapsedMillis(startedTicks));
    }

    /// <summary>
    /// The owning application's top-level windows, in z-order. <c>EnumWindows</c> walks the desktop
    /// from the topmost window down, and the picker relies on that order to resolve an overlap to the
    /// window the user can actually see.
    /// </summary>
    private static List<ScreenshotWindowCandidate> Candidates(uint ownerProcessId)
    {
        var candidates = new List<ScreenshotWindowCandidate>();
        NativeMethods.EnumWindows(
            (hwnd, unused) =>
            {
                _ = NativeMethods.GetWindowThreadProcessId(hwnd, out uint pid);
                if (pid != ownerProcessId)
                {
                    return true;
                }

                if (!NativeMethods.GetWindowRect(hwnd, out NativeMethods.RECT rect))
                {
                    return true;
                }

                long exStyle = NativeMethods.GetWindowLongPtrW(hwnd, NativeMethods.GWL_EXSTYLE).ToInt64();
                candidates.Add(new ScreenshotWindowCandidate(
                    // A HWND is documented as 32-bit significant even in a 64-bit process, so the
                    // truncation is lossless and keeps the identity inside the profile's range.
                    (long)(uint)hwnd.ToInt64(),
                    new BoundingBox(
                        rect.Left,
                        rect.Top,
                        rect.Right - rect.Left,
                        rect.Bottom - rect.Top),
                    // A minimized window is technically visible and renders as a placeholder, which
                    // is exactly the blank frame the picker exists to avoid.
                    NativeMethods.IsWindowVisible(hwnd) && !NativeMethods.IsIconic(hwnd),
                    (exStyle & NativeMethods.WS_EX_TOOLWINDOW) != 0));
                return true;
            },
            IntPtr.Zero);

        return candidates;
    }

    /// <summary>Whether the window's owning process resolves to the application the event names.</summary>
    private bool OwnedBy(IntPtr hwnd, AppIdentity owner)
    {
        AppIdentity? actual = _identity.Resolve(hwnd);
        return actual is not null
            && actual.IsResolved
            && string.Equals(actual.Value, owner.Value, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>Renders one window into a top-down 32-bit DIB and copies the pixels out of GDI.</summary>
    private static Frame? Render(IntPtr hwnd, BoundingBox bounds)
    {
        int width = (int)bounds.Width;
        int height = (int)bounds.Height;
        if (width <= 0 || height <= 0)
        {
            return null;
        }

        IntPtr windowDc = NativeMethods.GetWindowDC(hwnd);
        if (windowDc == IntPtr.Zero)
        {
            return null;
        }

        IntPtr memoryDc = IntPtr.Zero;
        IntPtr bitmap = IntPtr.Zero;
        IntPtr previous = IntPtr.Zero;
        try
        {
            memoryDc = NativeMethods.CreateCompatibleDC(windowDc);
            if (memoryDc == IntPtr.Zero)
            {
                return null;
            }

            var info = new NativeMethods.BITMAPINFO
            {
                Header = new NativeMethods.BITMAPINFOHEADER
                {
                    BiSize = (uint)Marshal.SizeOf<NativeMethods.BITMAPINFOHEADER>(),
                    BiWidth = width,
                    // Negative: a top-down DIB so row 0 is the top of the window and the thumbnail
                    // grid does not have to know which way GDI happened to store the rows.
                    BiHeight = -height,
                    BiPlanes = 1,
                    BiBitCount = BitsPerPixel,
                    BiCompression = NativeMethods.BI_RGB,
                },
            };

            bitmap = NativeMethods.CreateDIBSection(
                memoryDc,
                ref info,
                NativeMethods.DIB_RGB_COLORS,
                out IntPtr bits,
                IntPtr.Zero,
                0);
            if (bitmap == IntPtr.Zero || bits == IntPtr.Zero)
            {
                return null;
            }

            previous = NativeMethods.SelectObject(memoryDc, bitmap);
            if (!NativeMethods.PrintWindow(hwnd, memoryDc, NativeMethods.PW_RENDERFULLCONTENT))
            {
                return null;
            }

            int stride = width * BytesPerPixel;
            var pixels = new byte[stride * height];
            Marshal.Copy(bits, pixels, 0, pixels.Length);
            return new Frame(pixels, width, height, stride);
        }
        finally
        {
            if (previous != IntPtr.Zero)
            {
                _ = NativeMethods.SelectObject(memoryDc, previous);
            }

            if (bitmap != IntPtr.Zero)
            {
                _ = NativeMethods.DeleteObject(bitmap);
            }

            if (memoryDc != IntPtr.Zero)
            {
                _ = NativeMethods.DeleteDC(memoryDc);
            }

            _ = NativeMethods.ReleaseDC(hwnd, windowDc);
        }
    }

    /// <summary>
    /// Encodes the frame as JPEG through WIC. <c>Bgr32</c> discards the alpha channel, which
    /// <c>PrintWindow</c> leaves undefined for most windows; JPEG has no alpha anyway.
    /// </summary>
    private static byte[]? Encode(Frame frame)
    {
        try
        {
            BitmapSource source = BitmapSource.Create(
                frame.Width,
                frame.Height,
                96,
                96,
                PixelFormats.Bgr32,
                null,
                frame.Pixels,
                frame.Stride);
            var encoder = new JpegBitmapEncoder { QualityLevel = JpegQuality };
            encoder.Frames.Add(BitmapFrame.Create(source));
            using var stream = new MemoryStream();
            encoder.Save(stream);
            return stream.ToArray();
        }
        catch (Exception error) when (error is ArgumentException or NotSupportedException or InvalidOperationException or IOException)
        {
            return null;
        }
    }

    /// <summary>
    /// Monotonic milliseconds since the request began, rounded up. Rounding up rather than down
    /// keeps the interval an upper bound on when the frame could have been acquired.
    /// </summary>
    private static long ElapsedMillis(long startedTicks)
    {
        long elapsed = Math.Max(0, Stopwatch.GetTimestamp() - startedTicks);
        return (long)Math.Ceiling(elapsed * 1000.0 / Stopwatch.Frequency);
    }

    private sealed record Frame(byte[] Pixels, int Width, int Height, int Stride);

    private sealed record Acquisition(
        ScreenshotFailure? Failure,
        byte[]? Jpeg,
        ulong PerceptualHash,
        ScreenshotWindowScope? Scope,
        long DurationMillis)
    {
        public static Acquisition Refused(ScreenshotFailure failure) => new(failure, null, 0, null, 0);
    }
}
