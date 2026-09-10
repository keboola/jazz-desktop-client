using System.Windows;

namespace JazzCapture;

public partial class OnboardingWindow : Window
{
    private readonly Action _acknowledge;
    public string Version => BuildIdentity.ProducerVersion;
    public string CaptureDirectory { get; }
    public string QueueDirectory { get; }
    public string Modalities { get; }
    public string Exclusions { get; }
    public OnboardingWindow(Action acknowledge, Settings settings)
    {
        _acknowledge = acknowledge; CaptureDirectory = settings.CaptureRoot; QueueDirectory = settings.QueueDirectory;
        Modalities = $"Screenshots: {(settings.ScreenshotsEnabled ? "enabled" : "off")}; narration: {(settings.NarrationEnabled ? "enabled" : "off")}";
        Exclusions = string.Join(", ", settings.ExcludedApplications); DataContext = this; InitializeComponent();
    }
    private void Continue_Click(object sender, RoutedEventArgs e) { _acknowledge(); Close(); }
}
