using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using JazzCaptureCore.Consent;
using Button = System.Windows.Controls.Button;

namespace JazzCapture;

internal enum ConsentChoice
{
    Agree,
    Decline,
    Withdraw,
    Ok,
    Closed,
}

/// <summary>
/// Shows a served consent text or notice. The body is Markdown from the server. It is parsed into
/// headings, paragraphs, bullets, bold and italic and shown as plain WPF text, so nothing in it can
/// load a page or run anything. The client builds no consent text of its own.
/// </summary>
internal sealed class ConsentWindow : Window
{
    private ConsentChoice _choice = ConsentChoice.Closed;

    private ConsentWindow(string title, ServedText text, IReadOnlyList<(string Label, ConsentChoice Choice)> buttons)
    {
        Title = title;
        Width = 640;
        Height = 560;
        MinWidth = 420;
        MinHeight = 320;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        ShowInTaskbar = true;
        Topmost = true;

        var body = new StackPanel { Margin = new Thickness(16) };
        foreach (ConsentBlock block in ConsentMarkdown.Parse(text.Body))
            body.Children.Add(Render(block));

        var buttonRow = new StackPanel
        {
            Orientation = System.Windows.Controls.Orientation.Horizontal,
            HorizontalAlignment = System.Windows.HorizontalAlignment.Right,
            Margin = new Thickness(16, 8, 16, 16),
        };
        foreach ((string label, ConsentChoice choice) in buttons)
        {
            var button = new Button { Content = label, Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(16, 6, 16, 6) };
            button.Click += (_, _) =>
            {
                _choice = choice;
                Close();
            };
            buttonRow.Children.Add(button);
        }

        var layout = new DockPanel();
        DockPanel.SetDock(buttonRow, Dock.Bottom);
        layout.Children.Add(buttonRow);
        layout.Children.Add(new ScrollViewer
        {
            Content = body,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        });
        Content = layout;
    }

    /// <summary>Asks for an answer. "I agree" and "I don't agree" are the only buttons.</summary>
    internal static ConsentChoice AskForAnswer(ServedText text) =>
        Display(
            "Jazz consent",
            text,
            new[] { ("I agree", ConsentChoice.Agree), ("I don't agree", ConsentChoice.Decline) });

    /// <summary>A passive notice. A company-wide notice also offers "Withdraw consent".</summary>
    internal static ConsentChoice ShowNotice(ServedText text, bool offerWithdraw)
    {
        (string, ConsentChoice)[] buttons = offerWithdraw
            ? new[] { ("OK", ConsentChoice.Ok), ("Withdraw consent", ConsentChoice.Withdraw) }
            : new[] { ("OK", ConsentChoice.Ok) };
        return Display("Jazz notice", text, buttons);
    }

    private static ConsentChoice Display(string title, ServedText text, IReadOnlyList<(string Label, ConsentChoice Choice)> buttons)
    {
        var window = new ConsentWindow(title, text, buttons);
        window.ShowDialog();
        return window._choice;
    }

    private static UIElement Render(ConsentBlock block)
    {
        var textBlock = new TextBlock { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 8) };
        if (block.Kind == ConsentBlockKind.ListItem)
        {
            textBlock.Margin = new Thickness(16, 0, 0, 4);
            textBlock.Inlines.Add(new Run("• "));
        }

        foreach (ConsentSpan span in block.Spans)
        {
            var run = new Run(span.Text);
            if (span.Bold || block.Kind == ConsentBlockKind.Heading) run.FontWeight = FontWeights.Bold;
            if (span.Italic) run.FontStyle = FontStyles.Italic;
            textBlock.Inlines.Add(run);
        }

        if (block.Kind == ConsentBlockKind.Heading)
        {
            textBlock.FontSize = block.Level switch { 1 => 20, 2 => 16, _ => 14 };
            textBlock.Margin = new Thickness(0, 8, 0, 6);
        }

        return textBlock;
    }
}
