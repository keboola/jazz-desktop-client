using System.Windows;
using System.Windows.Controls;
using Button = System.Windows.Controls.Button;
using TextBox = System.Windows.Controls.TextBox;

namespace JazzCapture;

/// <summary>Small recovery-only paste surface. It never renders a saved token or endpoint.</summary>
public sealed class ManualProvisioningWindow : Window
{
    private readonly TextBox bundle = new() { AcceptsReturn = true, MaxLength = DeviceCredentialStore.MaximumProvisioningBundleBytes, MinHeight = 180, TextWrapping = TextWrapping.Wrap, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    private readonly TextBlock status = new();
    private readonly Button accept = new() { Content = "Verify and save", IsDefault = true };
    private readonly CancellationTokenSource cancellation = new();
    private readonly Func<string, CancellationToken, Task<DeviceCredentialStatus>> authorize;

    public ManualProvisioningWindow(Func<string, CancellationToken, Task<DeviceCredentialStatus>> authorize)
    {
        this.authorize = authorize;
        Title = "Provision device bundle";
        Width = 520; Height = 330; WindowStartupLocation = WindowStartupLocation.CenterScreen;
        var panel = new StackPanel { Margin = new Thickness(16) };
        panel.Children.Add(new TextBlock { Text = "Paste a provisioned device bundle. It is verified before being saved." });
        panel.Children.Add(bundle);
        panel.Children.Add(status);
        var buttons = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, HorizontalAlignment = System.Windows.HorizontalAlignment.Right };
        buttons.Children.Add(accept);
        var cancel = new Button { Content = "Cancel", IsCancel = true };
        cancel.Click += (_, _) => Close();
        buttons.Children.Add(cancel);
        panel.Children.Add(buttons);
        Content = panel;
        accept.Click += async (_, _) => await AcceptAsync();
        Closed += (_, _) => { bundle.Clear(); cancellation.Cancel(); cancellation.Dispose(); };
    }

    private async Task AcceptAsync()
    {
        accept.IsEnabled = false;
        status.Text = "Verifying device bundle…";
        DeviceCredentialStatus result;
        try { result = await authorize(bundle.Text, cancellation.Token); }
        catch (OperationCanceledException) { return; }
        catch { status.Text = "The device bundle could not be verified."; accept.IsEnabled = true; return; }
        status.Text = result.Reason;
        if (result.State is DeviceCredentialState.Active or DeviceCredentialState.Expiring)
        {
            bundle.Clear();
            Close();
        }
        else accept.IsEnabled = true;
    }
}
