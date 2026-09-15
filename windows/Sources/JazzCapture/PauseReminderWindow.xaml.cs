using System.Windows;

namespace JazzCapture;

/// <summary>Visible pause reminder. Tray balloons are often swallowed on Windows 11.</summary>
public partial class PauseReminderWindow : System.Windows.Window
{
    public PauseReminderWindow()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            var work = SystemParameters.WorkArea;
            Left = work.Right - ActualWidth - 16;
            Top = work.Bottom - ActualHeight - 16;
        };
    }

    private void OnOk(object sender, RoutedEventArgs e) => Close();
}
