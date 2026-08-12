using System.Windows;
using JazzCaptureCore;

namespace JazzCapture;

/// <summary>
/// The local review pane for one committed archive: it shows the committed state and the last
/// exported archive path, and offers Confirm, Reject, Save correction and Export (ANNEX-HOST
/// sections 5 and 6).
/// </summary>
/// <remarks>
/// Every decision becomes an append-only assertion the archive itself carries. Confirm authors it and
/// then finalizes the directory around it and exports the container into the delivery queue; Export
/// re-runs the byte-identical container export. Reject records the decision and queues nothing. Save
/// correction files the reason as a correction and leaves the capture reviewable, so a confirmation
/// afterwards supersedes it. Nothing here reaches the network — the MVP has no delivery configured,
/// which the status line says.
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
        CorrectButton.IsEnabled = _engine.State == EngineState.Committed;
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

    private void OnCorrect(object sender, RoutedEventArgs e)
    {
        // A correction is the one decision whose text is the decision: an empty box would file a
        // claim that says nothing, so it is refused here rather than by the engine.
        if (string.IsNullOrWhiteSpace(ReasonBox.Text))
        {
            System.Windows.MessageBox.Show(
                this,
                "Describe the correction first.",
                "Correction",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
            return;
        }

        try
        {
            _engine.Correct(ReasonBox.Text.Trim());
            StatusText.Text = "Correction saved - confirm to export, or reject";
        }
        catch (Exception ex)
        {
            System.Windows.MessageBox.Show(this, ex.Message, "Correction failed", MessageBoxButton.OK, MessageBoxImage.Error);
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
