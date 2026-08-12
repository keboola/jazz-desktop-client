namespace JazzCaptureCore.Audio;

/// <summary>How an attempt to open the microphone for one bracketed label turned out.</summary>
public enum NarrationStartStatus
{
    /// <summary>The microphone is recording; a clip is open.</summary>
    Started,

    /// <summary>The operating system refused access to the microphone.</summary>
    PermissionDenied,

    /// <summary>The device or the audio stack failed.</summary>
    SourceFailure,
}

/// <summary>
/// The outcome of <see cref="INarrationSource.StartClip"/>. The three statuses are distinguished
/// because they mean different things in the archive: a refusal is a permission fact about the
/// machine, a failure is a fact about the device, and neither may be reported as the other.
/// </summary>
/// <param name="Status">What happened.</param>
/// <param name="Detail">Why, for the capability observation and the gap; absent when nothing failed.</param>
public sealed record NarrationStartResult(NarrationStartStatus Status, string? Detail = null)
{
    /// <summary>The microphone is recording.</summary>
    public static NarrationStartResult Started { get; } = new(NarrationStartStatus.Started);

    /// <summary>The OS refused the microphone.</summary>
    /// <param name="detail">Why, in the host's own words.</param>
    public static NarrationStartResult PermissionDenied(string detail) =>
        new(NarrationStartStatus.PermissionDenied, Require(detail));

    /// <summary>The device or the audio stack failed.</summary>
    /// <param name="detail">Why, in the host's own words.</param>
    public static NarrationStartResult Failed(string detail) =>
        new(NarrationStartStatus.SourceFailure, Require(detail));

    private static string Require(string detail)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(detail);
        return detail;
    }
}

/// <summary>
/// One sealed narration clip: the bytes the microphone produced while exactly one label was open,
/// and the wall-clock stretch they cover.
/// </summary>
/// <remarks>
/// The interval is a pair rather than a single instant because a clip genuinely occupies time, and
/// its end is sampled when recording stops rather than copied from the start: a reader aligning a
/// transcript to the event stream needs both ends to be real observations.
/// </remarks>
/// <param name="StartedAt">RFC 3339 instant the microphone started, in canonical millisecond form.</param>
/// <param name="EndedAt">RFC 3339 instant it stopped; never earlier than <paramref name="StartedAt"/>.</param>
/// <param name="Bytes">The encoded clip. Content-addressed by the archive; never interpreted by it.</param>
/// <param name="MediaType">
/// IANA media type of <paramref name="Bytes"/>. It travels with the bytes rather than being a
/// constant of the archive because it is the one claim a reader cannot verify for itself without it
/// — a container that lies about its own encoding is worse than a large one.
/// </param>
public sealed record NarrationClip(
    string StartedAt,
    string EndedAt,
    ReadOnlyMemory<byte> Bytes,
    string MediaType);

/// <summary>The outcome of <see cref="INarrationSource.SealClip"/>: a clip, or why there is none.</summary>
public sealed record NarrationSealResult
{
    private NarrationSealResult()
    {
    }

    /// <summary>The sealed clip, or <see langword="null"/> when sealing failed.</summary>
    public NarrationClip? Clip { get; private init; }

    /// <summary>Why no clip exists; absent exactly when <see cref="Clip"/> is present.</summary>
    public string? FailureDetail { get; private init; }

    /// <summary>The microphone produced a clip.</summary>
    /// <param name="clip">The sealed clip.</param>
    public static NarrationSealResult Sealed(NarrationClip clip)
    {
        ArgumentNullException.ThrowIfNull(clip);
        return new NarrationSealResult { Clip = clip };
    }

    /// <summary>The clip was expected but did not survive.</summary>
    /// <param name="detail">Why, in the host's own words.</param>
    public static NarrationSealResult Failed(string detail)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(detail);
        return new NarrationSealResult { FailureDetail = detail };
    }
}

/// <summary>
/// The microphone, as the capture engine needs to see it: something that starts a clip when a label
/// opens and seals one when it closes.
/// </summary>
/// <remarks>
/// <para>
/// <b>The microphone records only inside a label.</b> That is the whole shape of this interface —
/// there is no "start recording for the session" and no way to express one. A think-aloud clip whose
/// boundaries are not a user's own declaration of what they were doing is audio nobody can place, and
/// a session-long recording of a person's room is a far larger consent step than the one they agreed
/// to when they said what task they were starting.
/// </para>
/// <para>
/// Implementations are driven from the engine's lock, so both members must return promptly and must
/// not call back into the engine. Neither may throw for an ordinary device problem: a failure is
/// evidence the archive records, not an exception that ends the capture.
/// </para>
/// </remarks>
public interface INarrationSource
{
    /// <summary>Opens a clip for the label that was just declared.</summary>
    /// <param name="labelId">The label the clip belongs to; useful for host-side spool naming.</param>
    NarrationStartResult StartClip(string labelId);

    /// <summary>
    /// Stops the microphone and returns the clip. Called exactly once per successful
    /// <see cref="StartClip"/>, when the owning label closes.
    /// </summary>
    NarrationSealResult SealClip();
}
