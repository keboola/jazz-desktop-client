using System.Windows;
using JazzCaptureCore;

namespace JazzCapture;

/// <summary>
/// The local review pane for one committed archive: it shows the committed state and the last
/// exported archive path, and offers Confirm, Reject and Export (ANNEX-HOST sections 5 and 6).
/// </summary>
/// <remarks>
/// Confirm and Export map straight onto the engine's reviewer-gated finalization: Confirm writes the
/// finalized directory and the review decision and exports the container into the delivery queue, and
/// Export re-runs the byte-identical container export. Reject records the decision and queues nothing.
/// Nothing here reaches the network — the MVP has no delivery configured, which the status line says.
/// </remarks>
public partial class ReviewWindow : System.Windows.Window
{
    private readonly CaptureEngine _engine;
    private readonly Settings _settings;

    /// <summary>Creates the review window for a committed capture.</summary>
    /// <param name="engine">The committed engine under review.</param>
    /// <param name="settings">The host configuration, for the delivery queue directory.</param>
    public ReviewWindow(CaptureEngine engine, Settings settings)
    {
        _engine = engine ?? throw new ArgumentNullException(nameof(engine));
        _settings = settings ?? throw new ArgumentNullException(nameof(settings));
        InitializeComponent();
        Refresh();
    }

    private void Refresh()
    {
        bool confirmed = _engine.State == EngineState.Confirmed;
        bool rejected = _engine.State == EngineState.Rejected;

        StatusText.Text = _engine.State switch
        {
            EngineState.Committed => "Committed - awaiting review",
            EngineState.Confirmed => "Confirmed and sealed locally - upload is not configured",
            EngineState.Rejected => "Rejected during local review - nothing was queued",
            _ => _engine.State.ToString(),
        };

        SummaryText.Text = "Archive " + _engine.Identity.ArchiveId;
        ArchivePathText.Text = _engine.ArchiveDirectory is { } directory
            ? "Finalized: " + directory
            : string.Empty;

        ConfirmButton.IsEnabled = _engine.State == EngineState.Committed;
        RejectButton.IsEnabled = _engine.State == EngineState.Committed;
        ExportButton.IsEnabled = confirmed;
        ReasonBox.IsEnabled = !confirmed && !rejected;
    }

    private void OnConfirm(object sender, RoutedEventArgs e)
    {
        try
        {
            string zipPath = _engine.ConfirmAndExport(_settings.QueueDirectory);
            ArchivePathText.Text = "Exported: " + zipPath;
            Refresh();
        }
        catch (Exception ex)
        {
            System.Windows.MessageBox.Show(this, ex.Message, "Confirm failed", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void OnReject(object sender, RoutedEventArgs e)
    {
        string reason = string.IsNullOrWhiteSpace(ReasonBox.Text)
            ? "Rejected during local review"
            : ReasonBox.Text.Trim();
        try
        {
            _engine.Reject(reason);
            Refresh();
        }
        catch (Exception ex)
        {
            System.Windows.MessageBox.Show(this, ex.Message, "Reject failed", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void OnExport(object sender, RoutedEventArgs e)
    {
        try
        {
            string zipPath = _engine.ConfirmAndExport(_settings.QueueDirectory);
            ArchivePathText.Text = "Exported: " + zipPath;
        }
        catch (Exception ex)
        {
            System.Windows.MessageBox.Show(this, ex.Message, "Export failed", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }
}
