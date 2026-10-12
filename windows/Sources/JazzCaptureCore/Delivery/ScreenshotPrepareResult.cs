namespace JazzCaptureCore.Delivery;

/// <summary>How one screenshot delivery prepare ended.</summary>
public enum ScreenshotPrepareOutcome
{
    /// <summary>A Files id was allocated and the bytes staged for upload.</summary>
    Prepared,

    /// <summary>
    /// No delivery is configured: no preparer instance or no provisioned credential at all. Expected
    /// on an unenrolled machine, so it is reported apart from a failure.
    /// </summary>
    NotConfigured,

    /// <summary>
    /// Delivery is configured but this prepare produced no id: an expired credential, a timeout, a
    /// prepare or staging refusal, a shutdown in progress, or an exception.
    /// </summary>
    Failed,
}

/// <summary>
/// The result of <c>EngineConfig.ScreenshotDeliveryPreparer</c>: the Files id on success, and on
/// every other path the reason there is none, so the projected <c>screenshot.status</c> can tell an
/// unconfigured machine from a real delivery failure.
/// </summary>
/// <param name="Outcome">How the prepare ended.</param>
/// <param name="FilesId">The Keboola Files id; set only for <see cref="ScreenshotPrepareOutcome.Prepared"/>.</param>
public sealed record ScreenshotPrepareResult(ScreenshotPrepareOutcome Outcome, string? FilesId)
{
    /// <summary>No delivery is configured.</summary>
    public static ScreenshotPrepareResult NotConfigured { get; } = new(ScreenshotPrepareOutcome.NotConfigured, null);

    /// <summary>Delivery is configured, but this prepare produced no id.</summary>
    public static ScreenshotPrepareResult Failed { get; } = new(ScreenshotPrepareOutcome.Failed, null);

    /// <summary>A Files id was allocated and its bytes staged.</summary>
    public static ScreenshotPrepareResult Prepared(string filesId) => new(ScreenshotPrepareOutcome.Prepared, filesId);
}
