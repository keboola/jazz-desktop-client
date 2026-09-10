using System.Windows;

namespace JazzCapture;

public partial class OnboardingWindow : Window
{
    private readonly Action _acknowledge;
    public string Version => BuildIdentity.ProducerVersion;
    public OnboardingWindow(Action acknowledge) { _acknowledge = acknowledge; DataContext = this; InitializeComponent(); }
    private void Continue_Click(object sender, RoutedEventArgs e) { _acknowledge(); Close(); }
}
