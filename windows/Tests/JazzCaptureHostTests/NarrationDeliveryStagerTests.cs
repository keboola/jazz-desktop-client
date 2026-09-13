using System.Security.Cryptography;
using JazzCapture;
using JazzCaptureCore;
using JazzCaptureCore.Archive;
using JazzCaptureCore.Delivery;

namespace JazzCaptureHostTests;

/// <summary>
/// <see cref="NarrationDeliveryStager"/> is the capture-path boundary: the one call that decides
/// whether the engine withholds a narration event (because this class has taken durable custody of
/// the clip and will emit the row itself later) or emits it immediately with an empty
/// <c>audio_file_id</c>. Round 5 review finding (Copilot): it had no direct coverage, unlike
/// <see cref="ScreenshotDeliveryPreparerTests"/> for the other half of the same seam -- so a
/// regression here could either lose a row or strand custody without any test exercising the real
/// adapter against a real spool.
/// </summary>
/// <remarks>
/// The distinction every test here turns on: <c>true</c> is a promise. The engine drops its own
/// obligation to emit the event the moment this returns <c>true</c>, so returning <c>true</c> for a
/// clip that was not durably staged loses the observation outright, with nothing left anywhere to
/// notice. Every failure mode must therefore return <c>false</c> -- which costs only the audio, and
/// #84's acceptance already allows a row with an empty audio reference.
/// </remarks>
public sealed class NarrationDeliveryStagerTests : IDisposable
{
    // The spool files a pair under a session directory whose name it validates as canonical, so a
    // placeholder like "s-1" is refused before any staging logic runs -- the real minted shape is
    // what this seam actually sees.
    private readonly string session = Identifiers.Prefixed("s");

    private readonly string root = Path.Combine(Path.GetTempPath(), "jazz-stager-narration-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            try { Directory.Delete(root, recursive: true); }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
        }
    }

    [Fact]
    public void CustodyIsTakenAndThePairIsStagedWithTheDescriptorsOwnBytes()
    {
        var spool = new NarrationSpool(Settings());
        int nudges = 0;
        var stager = new NarrationDeliveryStager(spool, () => nudges++, CancellationToken.None);
        byte[] clip = NarrationBytes.TinyClip(16);

        Assert.True(stager.TryTakeCustody(Descriptor(clip), Event(), Context()));

        Assert.Equal(1, spool.Status.PendingCount);
        Assert.Equal(1, nudges);

        // A relaunch, not the same instance: custody means *durable* custody, so the clip and
        // everything needed to rebuild its row must survive the process that took it.
        var reopened = new NarrationSpool(Settings());
        StagedNarrationHandle handle = Assert.Single(reopened.Drain());
        Assert.True(reopened.TryReadBlob(handle.Key, out byte[] readBack));
        Assert.True(clip.SequenceEqual(readBack));
        Assert.Null(handle.Meta.FilesId);
    }

    /// <summary>
    /// The journal artifact id must never reach the sidecar as the value a reader could mistake for
    /// a Files id. The engine hands this class the event <em>before</em> its own
    /// <c>AudioFileId = null</c> rewrite, precisely so the artifact id is available for the Files
    /// <c>artifact:</c> tag -- and it is taken from the descriptor, never from the event.
    /// </summary>
    [Fact]
    public void TheEventsAudioFileIdIsDiscardedRatherThanStaged()
    {
        var spool = new NarrationSpool(Settings());
        var stager = new NarrationDeliveryStager(spool, () => { }, CancellationToken.None);

        Assert.True(stager.TryTakeCustody(
            Descriptor(NarrationBytes.TinyClip()),
            Event() with { AudioFileId = "artifact-not-a-files-id" },
            Context()));

        StagedNarrationHandle handle = Assert.Single(new NarrationSpool(Settings()).Drain());
        Assert.Null(handle.Meta.FilesId);
        Assert.Equal("art-1", handle.Meta.ArtifactId);
    }

    /// <summary>
    /// A spool that could not be constructed at startup is the <c>Unavailable</c> state, and it must
    /// decline rather than throw: the engine then emits the event itself with no audio reference.
    /// </summary>
    [Fact]
    public void ANullSpoolDeclinesCustodyWithoutThrowing()
    {
        var stager = new NarrationDeliveryStager(null, () => { }, CancellationToken.None);

        Assert.False(stager.TryTakeCustody(Descriptor(NarrationBytes.TinyClip()), Event(), Context()));
    }

    [Fact]
    public void AShutdownInProgressDeclinesCustody()
    {
        using var shutdown = new CancellationTokenSource();
        shutdown.Cancel();
        var spool = new NarrationSpool(Settings());
        var stager = new NarrationDeliveryStager(spool, () => { }, shutdown.Token);

        Assert.False(stager.TryTakeCustody(Descriptor(NarrationBytes.TinyClip()), Event(), Context()));
        Assert.Equal(0, spool.Status.PendingCount);
    }

    /// <summary>
    /// A refusal is the case that matters most: the clip is genuinely not staged, so returning
    /// <c>true</c> would lose the row entirely. It must also still nudge -- the refusal itself is a
    /// reportable outcome the spool is holding, and only the drain worker ever reports it.
    /// </summary>
    [Fact]
    public void ASpoolRefusalDeclinesCustodyAndStillNudges()
    {
        // A clip larger than MaximumClipBytes is refused outright rather than staged.
        var spool = new NarrationSpool(Settings(maximumClipBytes: 8));
        int nudges = 0;
        var stager = new NarrationDeliveryStager(spool, () => nudges++, CancellationToken.None);

        Assert.False(stager.TryTakeCustody(Descriptor(NarrationBytes.TinyClip(64)), Event(), Context()));

        Assert.Equal(0, spool.Status.PendingCount);
        Assert.Equal(1, nudges);
    }

    /// <summary>
    /// Never throws onto the capture path, whatever goes wrong -- #62 constraint 4. A nudge delegate
    /// that throws is the reachable version of this: the stage itself already succeeded, so custody
    /// is genuinely held and must still be reported as taken, or the engine would emit a second row
    /// for a clip this spool is going to emit one for.
    /// </summary>
    [Fact]
    public void AThrowingNudgeDoesNotCostCustodyAlreadyTaken()
    {
        var spool = new NarrationSpool(Settings());
        var stager = new NarrationDeliveryStager(
            spool, () => throw new InvalidOperationException("scheduler is gone"), CancellationToken.None);

        Assert.True(stager.TryTakeCustody(Descriptor(NarrationBytes.TinyClip()), Event(), Context()));
        Assert.Equal(1, spool.Status.PendingCount);
    }

    [Fact]
    public void NullArgumentsDeclineCustodyRatherThanThrowing()
    {
        var spool = new NarrationSpool(Settings());
        var stager = new NarrationDeliveryStager(spool, () => { }, CancellationToken.None);

        Assert.False(stager.TryTakeCustody(null!, Event(), Context()));
        Assert.False(stager.TryTakeCustody(Descriptor(NarrationBytes.TinyClip()), null!, Context()));
        Assert.False(stager.TryTakeCustody(Descriptor(NarrationBytes.TinyClip()), Event(), null!));
        Assert.Equal(0, spool.Status.PendingCount);
    }

    /// <summary>
    /// An absent <see cref="ActivityEvent.Sequence"/> floors to zero rather than declining: zero is
    /// a legitimate sequence throughout this path (<c>NarrationSpool</c> and <c>EventSpool</c> both
    /// floor the same way, for the same reason), and the clip is worth keeping.
    /// </summary>
    [Fact]
    public void AnAbsentSequenceIsStagedAsZeroAndSurvivesARelaunch()
    {
        var spool = new NarrationSpool(Settings());
        var stager = new NarrationDeliveryStager(spool, () => { }, CancellationToken.None);

        Assert.True(stager.TryTakeCustody(
            Descriptor(NarrationBytes.TinyClip()), Event() with { Sequence = null }, Context()));

        StagedNarrationHandle handle = Assert.Single(new NarrationSpool(Settings()).Drain());
        Assert.Equal(0, handle.Meta.Sequence);
    }

    /// <summary>
    /// The staged sidecar must be adoptable by the very validation <c>NarrationSpool</c> applies at
    /// launch. This is the test that would catch a field this class stops populating: the spool's
    /// own adoption rejects an incomplete sidecar as a verification failure, so a relaunch that
    /// still finds the pair pending is the evidence that every required field survived.
    /// </summary>
    [Fact]
    public void TheStagedSidecarPassesTheSpoolsOwnAdoptionValidation()
    {
        var spool = new NarrationSpool(Settings());
        // Deliberately the real clock, not a pinned one: StagedAt is what SpoolRetention ages the
        // entry against, so pinning it to the same fixed instant the event timestamps use would
        // stage a pair already months past retention and have adoption evict it -- a correct
        // eviction that would read here as a validation failure and test nothing.
        var stager = new NarrationDeliveryStager(spool, () => { }, CancellationToken.None);

        Assert.True(stager.TryTakeCustody(Descriptor(NarrationBytes.TinyClip()), Event(), Context()));

        var reopened = new NarrationSpool(Settings());
        Assert.Equal(1, reopened.Status.PendingCount);
        Assert.Empty(reopened.DrainPendingVerificationFailures());

        StagedNarrationHandle handle = Assert.Single(reopened.Drain());
        Assert.Equal("0123456789abcdef0123456789abcdef", handle.Meta.TraceId);
        Assert.Equal("0123456789abcdef", handle.Meta.SpanId);
        Assert.Equal("audio/wav", handle.Meta.MediaType);
        Assert.Equal("jazz-capture", handle.Meta.ServiceName);
    }

    private ArtifactDeliveryDescriptor Descriptor(byte[] payload) => new(
        archiveId: "arc-1",
        captureId: "cap-1",
        sessionId: session,
        artifactId: "art-1",
        kind: NarrationAudioV1.Kind,
        mediaType: "audio/wav",
        sha256: Convert.ToHexString(SHA256.HashData(payload)).ToLowerInvariant(),
        byteLength: payload.Length,
        bytes: payload);

    private ActivityEvent Event() => new()
    {
        SessionId = session,
        EventId = "evt-1",
        Sequence = 1,
        Timestamp = "2026-03-01T12:00:00.000Z",
        EventType = NarrationAudioV1.EventType,
        Url = "jazz://session",
    };

    private SessionContext Context() => new(
        session,
        "0123456789abcdef0123456789abcdef",
        "0123456789abcdef",
        "2026-03-01T11:00:00.000Z",
        null,
        "user1",
        "machine1",
        null,
        null,
        "jazz-capture");

    private NarrationDeliverySettings Settings(long? maximumClipBytes = null) => new()
    {
        SpoolDirectory = root,
        MaximumClipBytes = maximumClipBytes ?? 60L * 1024 * 1024,
        SpoolByteCeiling = 512L * 1024 * 1024,
        SpoolRetention = TimeSpan.FromHours(48),
    };
}
