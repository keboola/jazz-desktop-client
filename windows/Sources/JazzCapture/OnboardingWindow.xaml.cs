using System.Windows;
using JazzCaptureCore;

namespace JazzCapture;

public partial class OnboardingWindow : Window
{
    private readonly Action _acknowledge;

    public OnboardingWindow(Action acknowledge, Settings settings, EffectiveCaptureAtLaunch captureAtLaunch)
    {
        ArgumentNullException.ThrowIfNull(acknowledge);
        ArgumentNullException.ThrowIfNull(settings);
        ArgumentNullException.ThrowIfNull(captureAtLaunch);
        _acknowledge = acknowledge;
        DataContext = OnboardingWindowContent.Resolve(settings, captureAtLaunch);
        InitializeComponent();
    }

    /// <summary>
    /// Re-resolves this window's bound content against <paramref name="settings"/> and
    /// <paramref name="captureAtLaunch"/>. The window is modeless, so <see cref="App.ShowStatus"/>
    /// calls this on an already-open instance instead of only ever resolving content once at
    /// construction -- otherwise reopening a window left open across a Settings change or a
    /// capture stop/start would keep asserting whatever was true when it was first shown.
    /// Reassigning <see cref="FrameworkElement.DataContext"/> is enough: WPF re-evaluates every
    /// binding against the new object with no extra plumbing required. This only takes effect the
    /// next time something calls <see cref="App.ShowStatus"/> again -- it is not a push from a
    /// settings change into a window that is already open and never reopened; see that call
    /// site's remarks.
    /// </summary>
    internal void Refresh(Settings settings, EffectiveCaptureAtLaunch captureAtLaunch)
    {
        ArgumentNullException.ThrowIfNull(settings);
        ArgumentNullException.ThrowIfNull(captureAtLaunch);
        DataContext = OnboardingWindowContent.Resolve(settings, captureAtLaunch);
    }

    private void Close_Click(object sender, RoutedEventArgs e) { _acknowledge(); Close(); }
}
