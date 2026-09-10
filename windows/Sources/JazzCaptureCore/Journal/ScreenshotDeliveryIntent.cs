using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using JazzCaptureCore.Delivery;

namespace JazzCaptureCore.Journal;

/// <summary>Sanitized, journal-owned handoff for a screenshot that has been made durable locally
/// but has not necessarily reached the Files spool. It contains canonical evidence metadata only;
/// bytes remain exclusively in the journal draft and no credential, endpoint, or filesystem path
/// is represented here.</summary>
public sealed record ScreenshotDeliveryIntent(
    string ArchiveId,
    string CaptureId,
    string ObservationId,
    string ArtifactId,
    string ScreenshotId,
    string MediaType,
    string Sha256,
    long ByteLength,
    ActivityEvent CanonicalEvent,
    SessionContext Context)
{
    /// <summary>Set only after a separate spool has durably admitted this exact intent.</summary>
    public bool Admitted { get; init; }

    public static ScreenshotDeliveryIntent Create(
        ArtifactDeliveryDescriptor descriptor,
        string observationId,
        ActivityEvent canonicalEvent,
        SessionContext context)
    {
        ArgumentNullException.ThrowIfNull(descriptor);
        ArgumentException.ThrowIfNullOrWhiteSpace(observationId);
        ArgumentNullException.ThrowIfNull(canonicalEvent);
        ArgumentNullException.ThrowIfNull(context);
        if (descriptor.ScreenshotId != descriptor.ArtifactId)
        {
            throw new ArgumentException("Screenshot delivery intent requires its canonical artifact id.", nameof(descriptor));
        }

        return new ScreenshotDeliveryIntent(
            descriptor.ArchiveId,
            descriptor.CaptureId,
            observationId,
            descriptor.ArtifactId,
            descriptor.ScreenshotId,
            descriptor.MediaType,
            descriptor.Sha256,
            descriptor.ByteLength,
            canonicalEvent,
            context);
    }
}
