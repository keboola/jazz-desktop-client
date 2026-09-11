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

    private void Close_Click(object sender, RoutedEventArgs e) { _acknowledge(); Close(); }
}
