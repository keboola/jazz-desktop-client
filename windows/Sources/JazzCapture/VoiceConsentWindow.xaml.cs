using System.Windows;

namespace JazzCapture;

/// <summary>Asks whether this label should include microphone narration.</summary>
public partial class VoiceConsentWindow : System.Windows.Window
{
    private VoiceConsentWindow()
    {
        InitializeComponent();
    }

    public bool Record { get; private set; }

    public bool DontAskAgain => DontAskAgainBox.IsChecked == true;

    public static VoiceConsentWindow Ask()
    {
        var window = new VoiceConsentWindow();
        window.ShowDialog();
        return window;
    }

    private void OnYes(object sender, RoutedEventArgs e)
    {
        Record = true;
        DialogResult = true;
    }

    private void OnNotNow(object sender, RoutedEventArgs e)
    {
        Record = false;
        DialogResult = false;
    }
}
