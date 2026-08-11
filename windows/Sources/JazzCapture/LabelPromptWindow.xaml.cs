using System.Windows;

namespace JazzCapture;

/// <summary>
/// Asks the user to name the task they are about to do, which opens a bracketed label
/// (ANNEX-HOST section 6).
/// </summary>
/// <remarks>
/// The declaration is the only thing in the whole client the user writes themselves, and it is what
/// lets the processor cut the recording into named process steps. The window is therefore kept to a
/// single field: it appears over whatever the user is working in, takes one line, and closes.
/// </remarks>
public partial class LabelPromptWindow : System.Windows.Window
{
    private LabelPromptWindow()
    {
        InitializeComponent();
    }

    /// <summary>The declared text, once the user confirmed it.</summary>
    private string DeclaredText => LabelBox.Text.Trim();

    /// <summary>
    /// Prompts for a task name and returns it, or <see langword="null"/> when the user cancelled.
    /// </summary>
    public static string? Ask()
    {
        var window = new LabelPromptWindow();
        return window.ShowDialog() == true ? window.DeclaredText : null;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        // The window exists to receive one line of text, so the caret starts in the field rather
        // than making the user click into it.
        Activate();
        LabelBox.Focus();
    }

    /// <summary>A blank declaration is not a declaration; the engine would refuse it anyway.</summary>
    private void OnTextChanged(object sender, System.Windows.Controls.TextChangedEventArgs e) =>
        StartButton.IsEnabled = DeclaredText.Length > 0;

    private void OnStart(object sender, RoutedEventArgs e)
    {
        if (DeclaredText.Length == 0)
        {
            return;
        }

        DialogResult = true;
    }

    private void OnCancel(object sender, RoutedEventArgs e) => DialogResult = false;
}
