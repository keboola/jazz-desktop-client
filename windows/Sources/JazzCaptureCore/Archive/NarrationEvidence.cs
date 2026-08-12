using JazzCaptureCore.Audio;

namespace JazzCaptureCore.Archive;

/// <summary>
/// Vocabulary of the narration audio artifact, as both desktop clients write it.
/// </summary>
/// <remarks>
/// Unlike a screenshot, narration drags in no versioned evidence profile: a clip covers exactly the
/// interval it declares, so there is nothing about its acquisition a reader has to be warned of. What
/// it does need is a role vocabulary the two clients agree on, because a consumer joining an archive
/// from macOS to one from Windows matches on these tokens and nothing else.
/// </remarks>
public static class NarrationAudioV1
{
    /// <summary>Artifact kind of a think-aloud clip.</summary>
    public const string Kind = "narration_audio";

    /// <summary>Role the citing observation gives the artifact.</summary>
    public const string Role = "narration_audio";

    /// <summary>Role of the capture source that supplied the samples.</summary>
    public const string SourceRole = "microphone_capture";

    /// <summary>Role the artifact attributes to the recorder: they are the one speaking.</summary>
    public const string ActorRole = "narrator";

    /// <summary>
    /// How that attribution was made. Declared rather than observed: the client runs no speaker
    /// identification, it knows only whose machine recorded the clip.
    /// </summary>
    public const string ActorMethod = "session_recorder";

    /// <summary>Capture-policy modality a persisted narration clip requires.</summary>
    public const string Modality = "narration";

    /// <summary>Contract event type of the record that cites the clip.</summary>
    public const string EventType = "narration";
}

/// <summary>
/// Turns one sealed clip into the attachment the capture engine ingests.
/// </summary>
/// <remarks>
/// The checks here run before the bytes become durable, for the same reason the screenshot profile's
/// do: an artifact the contract validator would reject at finalization costs the whole capture, while
/// one refused at this line costs a single clip.
/// </remarks>
public static class NarrationEvidence
{
    /// <summary>Builds the attachment for a clip: the bytes plus everything the archive says of them.</summary>
    /// <param name="clip">The sealed clip.</param>
    /// <param name="policy">The capture policy the session froze.</param>
    /// <exception cref="ArgumentException">
    /// The policy does not admit narration, the interval is not ordered, the clip is empty, or the
    /// bytes are not what <see cref="NarrationClip.MediaType"/> claims they are.
    /// </exception>
    public static ArtifactAttachment Attach(NarrationClip clip, FrozenCapturePolicy policy)
    {
        ArgumentNullException.ThrowIfNull(clip);
        ArgumentNullException.ThrowIfNull(policy);

        foreach (string error in Errors(clip, policy))
        {
            throw new ArgumentException(error, nameof(clip));
        }

        return new ArtifactAttachment(NarrationAudioV1.Kind, clip.MediaType, clip.Bytes)
        {
            Role = NarrationAudioV1.Role,
            SourceRole = NarrationAudioV1.SourceRole,
            ActorRefs = new[]
            {
                new ArtifactActorRef(
                    NarrationAudioV1.ActorRole,
                    ArtifactActorRef.DeclaredBasis,
                    NarrationAudioV1.ActorMethod),
            },

            // A clip is not an approximation of an instant the way a frame is: it covers the
            // interval it declares, exactly, so its quality is complete and carries no reasons.
            CaptureInterval = new ArtifactCaptureInterval(clip.StartedAt, clip.EndedAt),
            Quality = ArtifactQuality.Complete,
            Privacy = ArtifactPrivacy.Captured(policy.PolicyVersion),
        };
    }

    /// <summary>Everything wrong with one clip; empty when it can be attached.</summary>
    /// <param name="clip">The sealed clip.</param>
    /// <param name="policy">The capture policy the session froze.</param>
    public static IReadOnlyList<string> Errors(NarrationClip clip, FrozenCapturePolicy policy)
    {
        ArgumentNullException.ThrowIfNull(clip);
        ArgumentNullException.ThrowIfNull(policy);

        var errors = new List<string>();

        if (!policy.AllowsNarration)
        {
            errors.Add("the session capture policy does not admit the narration modality");
        }

        if (clip.Bytes.IsEmpty)
        {
            errors.Add("a narration clip carries no audio");
        }

        long? startedAt = Timestamps.UnixNanos(clip.StartedAt);
        long? endedAt = Timestamps.UnixNanos(clip.EndedAt);
        if (startedAt is null || endedAt is null)
        {
            errors.Add("a narration interval must be two RFC 3339 instants");
        }
        else if (endedAt < startedAt)
        {
            errors.Add("a narration clip cannot end before it starts");
        }

        // The one claim about an artifact that nobody downstream can check for themselves.
        if (string.Equals(clip.MediaType, NarrationWave.MediaType, StringComparison.Ordinal)
            && !NarrationWave.IsWave(clip.Bytes.Span))
        {
            errors.Add("the clip declares " + NarrationWave.MediaType + " but is not a RIFF/WAVE stream");
        }

        return errors;
    }
}
