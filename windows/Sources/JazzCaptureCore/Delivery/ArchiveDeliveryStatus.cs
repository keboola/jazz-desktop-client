using System.Globalization;

namespace JazzCaptureCore.Delivery;

/// <summary>
/// What the notification area says about delivery.
/// </summary>
/// <remarks>
/// <para>
/// The summary lives in the portable core rather than in the tray host so the wording is testable
/// on any machine, and so the host does nothing with the queue beyond rendering one line.
/// </para>
/// <para>
/// Two numbers matter to a user and both are here: how much has not left the machine yet, and what
/// went wrong last. A queue depth on its own would let a delivery fail permanently in silence, and
/// an error on its own would not say whether anything is still waiting.
/// </para>
/// </remarks>
/// <param name="Pending">Queued, never attempted.</param>
/// <param name="InFlight">Attempted, outcome not yet known.</param>
/// <param name="Failed">Waiting out a retry backoff.</param>
/// <param name="Acked">Delivered and acknowledged.</param>
/// <param name="PermanentlyFailed">Stopped; another identical attempt cannot help.</param>
/// <param name="Unreadable">Records the queue could not parse.</param>
/// <param name="LastErrorCode">Code of the most recently updated delivery that carries one.</param>
public sealed record ArchiveDeliveryStatus(
    int Pending,
    int InFlight,
    int Failed,
    int Acked,
    int PermanentlyFailed,
    int Unreadable,
    string? LastErrorCode)
{
    /// <summary>Line shown when nothing is queued and nothing has gone wrong.</summary>
    public const string IdleText = "Delivery: idle";

    /// <summary>Deliveries that have not left the machine and have not been abandoned.</summary>
    public int QueueDepth => Pending + InFlight + Failed;

    /// <summary>Summarizes a queue listing.</summary>
    public static ArchiveDeliveryStatus From(ArchiveDeliveryListing listing)
    {
        ArgumentNullException.ThrowIfNull(listing);

        var pending = 0;
        var inFlight = 0;
        var failed = 0;
        var acked = 0;
        var permanent = 0;
        ArchiveDeliveryRecord? latestFailure = null;

        foreach (ArchiveDeliveryRecord record in listing.Records)
        {
            switch (record.State)
            {
                case DeliveryLifecycle.Pending: pending++; break;
                case DeliveryLifecycle.InFlight: inFlight++; break;
                case DeliveryLifecycle.Failed: failed++; break;
                case DeliveryLifecycle.Acked: acked++; break;
                case DeliveryLifecycle.PermanentFailure: permanent++; break;
            }

            if (record.ErrorCode is null)
            {
                continue;
            }

            if (latestFailure is null
                || string.CompareOrdinal(record.UpdatedAt, latestFailure.UpdatedAt) >= 0)
            {
                latestFailure = record;
            }
        }

        return new ArchiveDeliveryStatus(
            pending,
            inFlight,
            failed,
            acked,
            permanent,
            listing.Unreadable.Count,
            latestFailure?.ErrorCode);
    }

    /// <summary>Reads the queue and summarizes it. Metadata only; no package is hashed.</summary>
    public static ArchiveDeliveryStatus From(ArchiveDeliveryQueue queue)
    {
        ArgumentNullException.ThrowIfNull(queue);
        return From(queue.List());
    }

    /// <summary>The one line the tray shows.</summary>
    public string Describe()
    {
        var parts = new List<string>(3);

        if (QueueDepth > 0)
        {
            parts.Add(string.Format(
                CultureInfo.InvariantCulture,
                "{0} queued",
                QueueDepth));
        }

        if (PermanentlyFailed > 0)
        {
            parts.Add(string.Format(
                CultureInfo.InvariantCulture,
                "{0} stopped",
                PermanentlyFailed));
        }

        if (Unreadable > 0)
        {
            parts.Add(string.Format(
                CultureInfo.InvariantCulture,
                "{0} unreadable",
                Unreadable));
        }

        if (parts.Count == 0 && LastErrorCode is null)
        {
            return IdleText;
        }

        string body = parts.Count == 0 ? "idle" : string.Join(", ", parts);
        return LastErrorCode is null
            ? "Delivery: " + body
            : "Delivery: " + body + " - last error " + LastErrorCode;
    }
}
