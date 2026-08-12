using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using JazzCaptureCore;
using JazzCaptureCore.Screen;
using JazzCapture.Interop;

namespace JazzCapture.Capture;

/// <summary>
/// The opt-in click highlight: a brief outline over the element each click resolved to, so the user
/// can see what the client captured (ANNEX-HOST section 6, mirroring the macOS "Highlight where I
/// click on screen").
/// </summary>
/// <remarks>
/// <para>
/// One borderless window spans the whole virtual screen and is never rebuilt; each flash moves a
/// rectangle inside it and fades that rectangle out. It carries
/// <c>WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE</c>: layered for the
/// alpha, transparent so every click passes straight through to the application being recorded,
/// tool-window so it stays out of the taskbar and Alt+Tab, and no-activate so it can never take the
/// foreground away from what the user is doing.
/// </para>
/// <para>
/// <b>It must never be captured.</b> A client that recorded its own overlay would attribute the
/// user's click to itself and photograph its own decoration. The three exclusion layers of
/// ANNEX-HOST section 7 all catch it, and each one is load-bearing rather than redundant:
/// </para>
/// <list type="number">
/// <item>The foreground WinEvent hook is installed with <c>WINEVENT_SKIPOWNPROCESS</c>, so this
/// window appearing never produces a <c>navigate</c> event.</item>
/// <item>The HWND hit-test in <see cref="UiaResolver"/> rejects the window three times over —
/// <c>WS_EX_TRANSPARENT</c> means <c>WindowFromPoint</c> looks straight past it, and the filter
/// separately rejects <c>WS_EX_TRANSPARENT</c>, <c>WS_EX_TOOLWINDOW</c>, and any window owned by
/// this process.</item>
/// <item>The final check compares the resolved element's owning process id against this one, which
/// catches anything UI Automation returns from our own process by another route and turns it into a
/// "desktop client UI" gap.</item>
/// </list>
/// <para>
/// The screenshot path excludes it as well, for a different reason: frames come from
/// <c>PrintWindow</c> against a window picked from the owning application's process, and that
/// enumeration skips tool windows and never looks at this process at all.
/// </para>
/// <para>
/// Everything here runs on the WPF UI thread. <see cref="Flash"/> is called from the capture
/// coordinator's worker, so the caller marshals; see <c>TrayHost</c>.
/// </para>
/// </remarks>
public sealed class ClickHighlightOverlay : IDisposable
{
    /// <summary>Redraws per second while fading. Matches the macOS overlay's 30 Hz timer.</summary>
    private const int FadeFramesPerSecond = 30;

    /// <summary>Opacity removed per frame; with the frame rate above this is a ~0.65 s fade.</summary>
    private const double FadeStep = 0.05;

    /// <summary>Corner radius of the outline, in device-independent units.</summary>
    private const double CornerRadius = 6.0;

    /// <summary>Thickness of the outline, in device-independent units.</summary>
    private const double StrokeThickness = 2.5;

    /// <summary>Opacity of the outline at the start of a flash.</summary>
    private const double StrokeOpacity = 0.9;

    /// <summary>Opacity of the wash inside the outline at the start of a flash.</summary>
    private const double FillOpacity = 0.16;

    /// <summary>The accent the outline is drawn in; the Windows system accent blue.</summary>
    private static readonly System.Windows.Media.Color HighlightColor =
        System.Windows.Media.Color.FromRgb(0x00, 0x78, 0xD4);

    private readonly DispatcherTimer _fade;

    private System.Windows.Window? _window;
    private Canvas? _canvas;
    private System.Windows.Shapes.Rectangle? _shape;
    private double _opacity;
    private bool _disposed;

    /// <summary>Creates the overlay. No window exists until the first flash.</summary>
    public ClickHighlightOverlay() =>
        _fade = new DispatcherTimer(DispatcherPriority.Render)
        {
            Interval = TimeSpan.FromSeconds(1.0 / FadeFramesPerSecond),
        };

    /// <summary>Outlines one element rectangle and starts it fading.</summary>
    /// <param name="elementRect">The resolved element rectangle, in physical screen pixels.</param>
    /// <remarks>
    /// A rectangle the geometry rejects — the 1×1 pointer fallback, or one entirely off the desktop —
    /// produces no flash at all rather than a one-pixel flicker that says nothing.
    /// </remarks>
    public void Flash(BoundingBox? elementRect)
    {
        if (_disposed || !ClickHighlightGeometry.IsWorthFlashing(elementRect))
        {
            return;
        }

        EnsureWindow();
        if (_window is null || _shape is null)
        {
            return;
        }

        BoundingBox overlay = PositionOverWholeDesktop(_window);
        (double scaleX, double scaleY) = DeviceScale(_window);
        if (ClickHighlightGeometry.ToOverlayLocal(elementRect, overlay, scaleX, scaleY) is not { } local)
        {
            return;
        }

        Canvas.SetLeft(_shape, local.X);
        Canvas.SetTop(_shape, local.Y);
        _shape.Width = local.Width;
        _shape.Height = local.Height;
        _shape.Visibility = Visibility.Visible;

        _opacity = 1.0;
        _shape.Opacity = 1.0;
        _fade.Stop();
        _fade.Start();
    }

    /// <summary>Tears the overlay down. Called when capture stops, and again on dispose.</summary>
    public void Hide()
    {
        _fade.Stop();
        _opacity = 0;

        if (_shape is not null)
        {
            _shape.Visibility = Visibility.Collapsed;
        }

        _window?.Close();
        _window = null;
        _canvas = null;
        _shape = null;
    }

    /// <inheritdoc />
    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _fade.Tick -= OnFadeTick;
        Hide();
    }

    private void EnsureWindow()
    {
        if (_window is not null)
        {
            return;
        }

        var shape = new System.Windows.Shapes.Rectangle
        {
            RadiusX = CornerRadius,
            RadiusY = CornerRadius,
            StrokeThickness = StrokeThickness,
            Stroke = new SolidColorBrush(HighlightColor) { Opacity = StrokeOpacity },
            Fill = new SolidColorBrush(HighlightColor) { Opacity = FillOpacity },
            Visibility = Visibility.Collapsed,
            IsHitTestVisible = false,
        };

        var canvas = new Canvas { IsHitTestVisible = false };
        canvas.Children.Add(shape);

        var window = new System.Windows.Window
        {
            WindowStyle = WindowStyle.None,
            AllowsTransparency = true,
            Background = System.Windows.Media.Brushes.Transparent,
            ResizeMode = ResizeMode.NoResize,
            ShowInTaskbar = false,
            ShowActivated = false,
            Topmost = true,
            IsHitTestVisible = false,
            Content = canvas,
        };

        // The extended styles have to be applied to a window that already has a handle, and before
        // it is first shown, or the first flash is briefly clickable and briefly focusable.
        window.SourceInitialized += (_, _) => ApplyClickThroughStyles(window);
        window.Show();

        _window = window;
        _canvas = canvas;
        _shape = shape;
        _fade.Tick -= OnFadeTick;
        _fade.Tick += OnFadeTick;
    }

    private static void ApplyClickThroughStyles(System.Windows.Window window)
    {
        IntPtr hwnd = new WindowInteropHelper(window).Handle;
        if (hwnd == IntPtr.Zero)
        {
            return;
        }

        long style = NativeMethods.GetWindowLongPtrW(hwnd, NativeMethods.GWL_EXSTYLE).ToInt64();
        style |= NativeMethods.WS_EX_LAYERED
            | NativeMethods.WS_EX_TRANSPARENT
            | NativeMethods.WS_EX_TOOLWINDOW
            | NativeMethods.WS_EX_NOACTIVATE;
        NativeMethods.SetWindowLongPtrW(hwnd, NativeMethods.GWL_EXSTYLE, new IntPtr(style));
    }

    /// <summary>
    /// Stretches the overlay across every monitor and returns the bounds it now occupies, in
    /// physical pixels.
    /// </summary>
    /// <remarks>
    /// Placed through <c>SetWindowPos</c> rather than WPF's <c>Left</c>/<c>Top</c>/<c>Width</c>/
    /// <c>Height</c> because those are device-independent units interpreted against one monitor's
    /// scale, and a desktop can span monitors at different scales. The virtual-screen metrics are
    /// physical pixels, which is also the space UI Automation reports element rectangles in, so
    /// placing the window this way keeps both sides of the conversion in the same units.
    /// </remarks>
    private static BoundingBox PositionOverWholeDesktop(System.Windows.Window window)
    {
        int x = NativeMethods.GetSystemMetrics(NativeMethods.SM_XVIRTUALSCREEN);
        int y = NativeMethods.GetSystemMetrics(NativeMethods.SM_YVIRTUALSCREEN);
        int width = NativeMethods.GetSystemMetrics(NativeMethods.SM_CXVIRTUALSCREEN);
        int height = NativeMethods.GetSystemMetrics(NativeMethods.SM_CYVIRTUALSCREEN);

        IntPtr hwnd = new WindowInteropHelper(window).Handle;
        if (hwnd != IntPtr.Zero)
        {
            NativeMethods.SetWindowPos(
                hwnd,
                NativeMethods.HWND_TOPMOST,
                x,
                y,
                width,
                height,
                NativeMethods.SWP_NOACTIVATE
                    | NativeMethods.SWP_NOOWNERZORDER
                    | NativeMethods.SWP_SHOWWINDOW);
        }

        return new BoundingBox(x, y, width, height);
    }

    /// <summary>Physical pixels per device-independent unit, as the compositor reports them.</summary>
    private static (double X, double Y) DeviceScale(System.Windows.Window window)
    {
        if (PresentationSource.FromVisual(window) is { CompositionTarget: { } target })
        {
            Matrix matrix = target.TransformToDevice;
            if (matrix.M11 > 0 && matrix.M22 > 0)
            {
                return (matrix.M11, matrix.M22);
            }
        }

        return (1.0, 1.0);
    }

    private void OnFadeTick(object? sender, EventArgs e)
    {
        _opacity -= FadeStep;
        if (_opacity <= 0)
        {
            _opacity = 0;
            _fade.Stop();
            if (_shape is not null)
            {
                _shape.Visibility = Visibility.Collapsed;
            }

            return;
        }

        if (_shape is not null)
        {
            _shape.Opacity = _opacity;
        }
    }
}
