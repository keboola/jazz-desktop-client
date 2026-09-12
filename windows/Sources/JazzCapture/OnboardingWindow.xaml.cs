using System.Windows;

namespace JazzCapture;

public partial class OnboardingWindow : Window
{
    private readonly Action _acknowledge;

    public OnboardingWindow(Action acknowledge, Settings settings)
    {
        ArgumentNullException.ThrowIfNull(acknowledge);
        ArgumentNullException.ThrowIfNull(settings);
        _acknowledge = acknowledge;
        DataContext = OnboardingWindowContent.Resolve(settings);
        InitializeComponent();
    }

    /// <summary>
    /// Re-resolves this window's bound content against <paramref name="settings"/>. The window is
    /// modeless, so <see cref="App.ShowStatus"/> calls this on an already-open instance instead of
    /// only ever resolving content once at construction -- otherwise a window left open across a
    /// Settings change or a capture stop/start would keep asserting whatever was true when it was
    /// first shown. Reassigning <see cref="FrameworkElement.DataContext"/> is enough: WPF
    /// re-evaluates every binding against the new object with no extra plumbing required.
    /// </summary>
    internal void Refresh(Settings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
        DataContext = OnboardingWindowContent.Resolve(settings);
    }

    private void Close_Click(object sender, RoutedEventArgs e) { _acknowledge(); Close(); }
}
