using System.Text.Json.Nodes;
using JazzCaptureCore;
using JazzCaptureCore.Archive;

namespace JazzCaptureCoreTests;

/// <summary>
/// Pins the <c>dev.jazz.capture.screenshot.v1</c> evidence profile of ANNEX-ARCHIVE 2.7.
/// </summary>
/// <remarks>
/// Half of these tests assert that something is refused. That is the point: the profile is
/// all-or-nothing, and every rule it states is a way for two producers to disagree about the same
/// pixels. A check nobody has watched fail is not a check.
/// </remarks>
public sealed class ScreenshotEvidenceTests
{
    private const string Owner = "windows.exe-path:c:/program files/contoso/editor.exe";
    private const string SecretApp = "c:/program files/1password/1password.exe";

    private static readonly DateTimeOffset RequestedAt =
        new(2026, 7, 22, 8, 0, 10, TimeSpan.Zero);

    private static readonly byte[] Jpeg = ScreenshotBytes.TinyJpeg;

    private static FrozenCapturePolicy Policy(params string[] excludedApplications) => new(
        "consent-v1",
        new[] { "accessibility", "keyboard", "pointer", "screenshots" },
        excludedApplications);

    // --- The honest path ------------------------------------------------------------------------

    [Fact]
    public void AWindowFrameCarriesTheWholeProfileAndNothingElse()
    {
        ScreenshotEvidence evidence = ScreenshotEvidence.FromMonotonicDuration(
            RequestedAt,
            125,
            new ScreenshotWindowScope(Owner, 4242));

        JsonObject extensions = evidence.Extensions();

        Assert.Equal(
            new[]
            {
                "dev.jazz.capture.screenshot.v1.requestStartedAt",
                "dev.jazz.capture.screenshot.v1.frameCompletedAt",
                "dev.jazz.capture.screenshot.v1.monotonicDurationMillis",
                "dev.jazz.capture.screenshot.v1.scope",
                "dev.jazz.capture.screenshot.v1.ownerBundleId",
                "dev.jazz.capture.screenshot.v1.windowId",
            },
            extensions.Select(pair => pair.Key).ToArray());
        Assert.Equal("2026-07-22T08:00:10.000Z", (string?)extensions[ScreenshotEvidenceV1.RequestStartedAtKey]);
        Assert.Equal("2026-07-22T08:00:10.125Z", (string?)extensions[ScreenshotEvidenceV1.FrameCompletedAtKey]);
        Assert.Equal(125, (long?)extensions[ScreenshotEvidenceV1.MonotonicDurationMillisKey]);
        Assert.Equal("window", (string?)extensions[ScreenshotEvidenceV1.ScopeKey]);
        Assert.Equal(Owner, (string?)extensions[ScreenshotEvidenceV1.OwnerBundleIdKey]);
        Assert.Equal(4242, (long?)extensions[ScreenshotEvidenceV1.WindowIdKey]);
    }

    /// <summary>
    /// The frame is an interval, so the quality says so — and says how wide the interval is, which
    /// is the only thing that stops a reader treating the pixels as the exact mouse-up state.
    /// </summary>
    [Fact]
    public void AFrameIsAlwaysPartialWithItsMeasuredTimingError()
    {
        ArtifactQuality quality = ScreenshotEvidence
            .FromMonotonicDuration(RequestedAt, 42, new ScreenshotWindowScope(Owner, 1))
            .Quality();

        Assert.Equal(ArtifactQualityStatus.Partial, quality.Status);
        Assert.Equal(new[] { ScreenshotEvidenceV1.TemporalIntervalReason }, quality.Reasons);
        Assert.Equal(42, quality.TimingErrorMillis);
    }

    [Fact]
    public void ADisplayFrameAddsTheFallbackReasonAndSortsItsExclusions()
    {
        ScreenshotEvidence evidence = ScreenshotEvidence.FromMonotonicDuration(
            RequestedAt,
            7,
            new ScreenshotDisplayScope(3, new[] { "z-app", "a-app" }));

        Assert.Equal(
            new[] { ScreenshotEvidenceV1.TemporalIntervalReason, ScreenshotEvidenceV1.DisplayFallbackReason },
            evidence.Quality().Reasons);
        Assert.Equal(
            new[] { "a-app", "z-app" },
            ((JsonArray)evidence.Extensions()[ScreenshotEvidenceV1.ExcludedApplicationBundleIdsKey]!)
                .Select(node => (string?)node)
                .ToArray());
        Assert.Empty(ScreenshotEvidenceProfile.Errors(
            Attachment(evidence),
            Policy("a-app", "z-app")));
    }

    [Fact]
    public void TheIntervalEndIsDerivedFromTheMonotonicDurationNotASecondClockRead()
    {
        // A wall clock that stepped backwards during acquisition cannot reverse the interval,
        // because the end is never read from the clock a second time.
        ScreenshotEvidence evidence = ScreenshotEvidence.FromMonotonicDuration(
            RequestedAt,
            1_500,
            new ScreenshotWindowScope(Owner, 1));

        Assert.Equal("2026-07-22T08:00:11.500Z", evidence.FrameCompletedAt);
        Assert.Equal(evidence.RequestStartedAt, evidence.CaptureInterval().StartedAt);
        Assert.Equal(evidence.FrameCompletedAt, evidence.CaptureInterval().EndedAt);
    }

    /// <summary>
    /// The wire format carries three fractional digits. An anchor with sub-millisecond precision
    /// would round the rendered start one way and the rendered end the other, which the validator
    /// reads as an interval that disagrees with its own duration.
    /// </summary>
    [Fact]
    public void ASubMillisecondRequestAnchorIsTruncatedBeforeTheDurationIsAdded()
    {
        ScreenshotEvidence evidence = ScreenshotEvidence.FromMonotonicDuration(
            RequestedAt.AddTicks(9_999),
            10,
            new ScreenshotWindowScope(Owner, 1));

        Assert.Equal("2026-07-22T08:00:10.000Z", evidence.RequestStartedAt);
        Assert.Equal("2026-07-22T08:00:10.010Z", evidence.FrameCompletedAt);
        Assert.Empty(ScreenshotEvidenceProfile.Errors(Attachment(evidence), Policy()));
    }

    [Fact]
    public void AZeroLengthCaptureIsStillAnIntervalAndStillPartial()
    {
        ScreenshotEvidence evidence = ScreenshotEvidence.FromMonotonicDuration(
            RequestedAt,
            0,
            new ScreenshotWindowScope(Owner, 0));

        Assert.Equal(evidence.RequestStartedAt, evidence.FrameCompletedAt);
        Assert.Equal(0, evidence.Quality().TimingErrorMillis);
        Assert.Empty(ScreenshotEvidenceProfile.Errors(Attachment(evidence), Policy()));
    }

    [Fact]
    public void ANegativeDurationIsRefusedBeforeAnyEvidenceExists() =>
        Assert.Throws<ArgumentOutOfRangeException>(() => ScreenshotEvidence.FromMonotonicDuration(
            RequestedAt,
            -1,
            new ScreenshotWindowScope(Owner, 1)));

    [Fact]
    public void TheAttachmentNamesTheRolesTheArchiveExpects()
    {
        ArtifactAttachment attachment = Attachment(Evidence());

        Assert.Equal("screenshot", attachment.Kind);
        Assert.Equal("image/jpeg", attachment.MediaType);
        Assert.Equal("screenshot", attachment.Role);
        Assert.Equal("screen_capture", attachment.SourceRole);
        ArtifactActorRef actor = Assert.Single(attachment.ActorRefs);
        Assert.Equal("performer", actor.Role);
        Assert.Equal(ArtifactActorRef.DeclaredBasis, actor.Basis);
        Assert.Equal("session_recorder", actor.Method);
        Assert.Equal(ArtifactPrivacyStatus.Captured, attachment.Privacy!.Status);
        Assert.Equal("consent-v1", attachment.Privacy!.PolicyVersion);
        Assert.Equal(Jpeg, attachment.Bytes.ToArray());
    }

    // --- The rules that must bite ---------------------------------------------------------------

    /// <summary>
    /// The one invariant a producer is most likely to break by accident: rendering both timestamps
    /// from separate clock reads and reporting a duration measured somewhere else.
    /// </summary>
    [Fact]
    public void AnIntervalThatDisagreesWithItsMonotonicDurationIsRejected()
    {
        ArtifactDeclaration declaration = Mutate(
            Evidence(),
            extensions => extensions[ScreenshotEvidenceV1.MonotonicDurationMillisKey] = 124,
            quality => quality with { TimingErrorMillis = 124 });

        Assert.Contains(
            "screenshot interval differs from its monotonic duration",
            ScreenshotEvidenceProfile.Errors(declaration, Policy()));
    }

    [Fact]
    public void ATimingErrorThatDisagreesWithTheDurationIsRejected()
    {
        ArtifactDeclaration declaration = Mutate(
            Evidence(),
            _ => { },
            quality => quality with { TimingErrorMillis = 3 });

        Assert.Contains(
            "quality differs from its screenshot evidence timing",
            ScreenshotEvidenceProfile.Errors(declaration, Policy()));
    }

    [Fact]
    public void ACompleteScreenshotIsRejectedBecauseAFrameIsNeverAnInstant()
    {
        ArtifactDeclaration declaration = Mutate(
            Evidence(),
            _ => { },
            _ => ArtifactQuality.Complete);

        Assert.Contains(
            "quality differs from its screenshot evidence timing",
            ScreenshotEvidenceProfile.Errors(declaration, Policy()));
    }

    [Fact]
    public void AProfileWithoutTheTemporalIntervalReasonIsRejected()
    {
        ArtifactDeclaration declaration = Mutate(
            Evidence(),
            _ => { },
            quality => quality with { Reasons = Array.Empty<string>() });

        Assert.Contains(
            "quality differs from its screenshot evidence timing",
            ScreenshotEvidenceProfile.Errors(declaration, Policy()));
    }

    [Fact]
    public void ADisplayScopeWithoutItsFallbackReasonIsRejected()
    {
        ScreenshotEvidence evidence = ScreenshotEvidence.FromMonotonicDuration(
            RequestedAt,
            5,
            new ScreenshotDisplayScope(1, Array.Empty<string>()));
        ArtifactDeclaration declaration = Mutate(
            evidence,
            _ => { },
            quality => quality with
            {
                Reasons = new[] { ScreenshotEvidenceV1.TemporalIntervalReason },
            });

        Assert.Contains(
            "display evidence lacks its fallback reason",
            ScreenshotEvidenceProfile.Errors(declaration, Policy()));
    }

    [Fact]
    public void AWindowScopeCarryingTheFallbackReasonIsRejected()
    {
        ArtifactDeclaration declaration = Mutate(
            Evidence(),
            _ => { },
            quality => quality with
            {
                Reasons = new[]
                {
                    ScreenshotEvidenceV1.TemporalIntervalReason,
                    ScreenshotEvidenceV1.DisplayFallbackReason,
                },
            });

        Assert.Contains(
            "window evidence has a display fallback reason",
            ScreenshotEvidenceProfile.Errors(declaration, Policy()));
    }

    [Theory]
    [InlineData("2026-07-22T08:00:10Z")]
    [InlineData("2026-07-22T08:00:10.0Z")]
    [InlineData("2026-07-22T08:00:10.00Z")]
    [InlineData("2026-07-22T08:00:10.0000Z")]
    [InlineData("2026-07-22T08:00:10.000000Z")]
    [InlineData("2026-07-22T10:00:10.000+02:00")]
    public void ATimestampWithoutExactlyThreeFractionalDigitsIsRejected(string timestamp)
    {
        ArtifactDeclaration declaration = Mutate(
            Evidence(),
            extensions => extensions[ScreenshotEvidenceV1.RequestStartedAtKey] = timestamp,
            quality => quality);
        declaration = declaration with
        {
            CaptureInterval = new ArtifactCaptureInterval(timestamp, declaration.CaptureInterval!.EndedAt),
        };

        Assert.Contains(
            "invalid screenshot evidence v1 timing",
            ScreenshotEvidenceProfile.Errors(declaration, Policy()));
    }

    /// <summary>
    /// Both reasons describe pixels that were thrown away. Finding either on an artifact means the
    /// bytes it points at are exactly the ones the producer promised never to keep.
    /// </summary>
    [Theory]
    [InlineData("dev.jazz.capture.screenshot.v1.owner_mismatch")]
    [InlineData("dev.jazz.capture.screenshot.v1.unavailable")]
    public void AReasonThatDescribesDiscardedPixelsCannotBePersisted(string reason)
    {
        ArtifactDeclaration declaration = Mutate(
            Evidence(),
            _ => { },
            quality => quality with
            {
                Reasons = new[] { ScreenshotEvidenceV1.TemporalIntervalReason, reason },
            });

        Assert.Contains(
            "persists non-artifact screenshot reasons [" + reason + "]",
            ScreenshotEvidenceProfile.Errors(declaration, Policy()));
    }

    [Fact]
    public void AnExclusionTheCapturePolicyNeverNamedIsRejected()
    {
        ScreenshotEvidence evidence = ScreenshotEvidence.FromMonotonicDuration(
            RequestedAt,
            5,
            new ScreenshotDisplayScope(1, new[] { SecretApp }));

        Assert.Contains(
            "screenshot exclusions escape its frozen capture policy",
            ScreenshotEvidenceProfile.Errors(Attachment(evidence), Policy("some-other-app")));
        Assert.Empty(ScreenshotEvidenceProfile.Errors(Attachment(evidence), Policy(SecretApp)));
    }

    [Fact]
    public void APolicyThatDoesNotAdmitTheScreenshotsModalityRejectsEveryFrame()
    {
        var withoutScreenshots = new FrozenCapturePolicy(
            "consent-v1",
            new[] { "accessibility", "keyboard", "pointer" },
            Array.Empty<string>());

        Assert.Contains(
            "screenshot privacy differs from its frozen capture policy",
            ScreenshotEvidenceProfile.Errors(Attachment(Evidence()), withoutScreenshots));
    }

    [Fact]
    public void APrivacyBlockFromAnotherPolicyVersionIsRejected()
    {
        ArtifactAttachment attachment = Attachment(Evidence()) with
        {
            Privacy = ArtifactPrivacy.Captured("other-consent"),
        };

        Assert.Contains(
            "screenshot privacy differs from its frozen capture policy",
            ScreenshotEvidenceProfile.Errors(attachment, Policy()));
    }

    [Theory]
    [InlineData("omitted")]
    [InlineData("denied")]
    [InlineData("unknown")]
    public void PixelsThePolicyDidNotActuallyCaptureCannotClaimToBeEvidence(string status)
    {
        ArtifactAttachment attachment = Attachment(Evidence()) with
        {
            Privacy = new ArtifactPrivacy(status, "consent-v1", Array.Empty<ArtifactRedaction>()),
        };

        Assert.Contains(
            "screenshot privacy differs from its frozen capture policy",
            ScreenshotEvidenceProfile.Errors(attachment, Policy()));
    }

    [Fact]
    public void AnUnknownKeyInsideTheNamespaceIsRejected()
    {
        ArtifactDeclaration declaration = Mutate(
            Evidence(),
            extensions => extensions[ScreenshotEvidenceV1.Namespace + ".futureGuess"] = true,
            quality => quality);

        Assert.Contains(
            "unknown screenshot evidence v1 keys [dev.jazz.capture.screenshot.v1.futureGuess]",
            ScreenshotEvidenceProfile.Errors(declaration, Policy()));
    }

    [Fact]
    public void AKeyOutsideTheNamespaceIsNoneOfTheProfilesBusiness()
    {
        ArtifactDeclaration declaration = Mutate(
            Evidence(),
            extensions => extensions["dev.example.house-keeping"] = "kept verbatim",
            quality => quality);

        Assert.Empty(ScreenshotEvidenceProfile.Errors(declaration, Policy()));
    }

    [Theory]
    [InlineData("dev.jazz.capture.screenshot.v1.requestStartedAt")]
    [InlineData("dev.jazz.capture.screenshot.v1.frameCompletedAt")]
    [InlineData("dev.jazz.capture.screenshot.v1.monotonicDurationMillis")]
    [InlineData("dev.jazz.capture.screenshot.v1.scope")]
    public void AProfileMissingAnyOfItsFourBaseKeysIsIncomplete(string key)
    {
        ArtifactDeclaration declaration = Mutate(
            Evidence(),
            extensions => extensions.Remove(key),
            quality => quality);

        Assert.Contains(
            "incomplete screenshot evidence v1 profile (missing [" + key + "])",
            ScreenshotEvidenceProfile.Errors(declaration, Policy()));
    }

    [Fact]
    public void AScreenshotWithNoProfileAtAllIsRejected()
    {
        var declaration = new ArtifactDeclaration(ScreenshotEvidenceV1.Kind, ScreenshotEvidenceV1.MediaType);

        Assert.Contains(
            "screenshot evidence v1 profile is required",
            ScreenshotEvidenceProfile.Errors(declaration, Policy()));
    }

    [Fact]
    public void AProfileOnSomethingThatIsNotAScreenshotIsRejected()
    {
        ArtifactDeclaration declaration = Mutate(Evidence(), _ => { }, quality => quality) with
        {
            Kind = "narration_audio",
        };

        Assert.Contains(
            "screenshot evidence is bound to a non-screenshot",
            ScreenshotEvidenceProfile.Errors(declaration, Policy()));
    }

    [Fact]
    public void AnArtifactWithNeitherProfileNorScreenshotKindIsLeftAlone()
    {
        var declaration = new ArtifactDeclaration("narration_audio", "audio/mp4");

        Assert.Empty(ScreenshotEvidenceProfile.Errors(declaration, Policy()));
    }

    [Fact]
    public void AWindowScopeCarryingDisplayKeysIsRejected()
    {
        ArtifactDeclaration declaration = Mutate(
            Evidence(),
            extensions => extensions[ScreenshotEvidenceV1.DisplayIdKey] = 1,
            quality => quality);

        Assert.Contains(
            "invalid screenshot evidence v1 window scope",
            ScreenshotEvidenceProfile.Errors(declaration, Policy()));
    }

    [Fact]
    public void ADisplayScopeCarryingWindowKeysIsRejected()
    {
        ScreenshotEvidence evidence = ScreenshotEvidence.FromMonotonicDuration(
            RequestedAt,
            5,
            new ScreenshotDisplayScope(1, Array.Empty<string>()));
        ArtifactDeclaration declaration = Mutate(
            evidence,
            extensions => extensions[ScreenshotEvidenceV1.WindowIdKey] = 9,
            quality => quality);

        Assert.Contains(
            "invalid screenshot evidence v1 display scope",
            ScreenshotEvidenceProfile.Errors(declaration, Policy()));
    }

    [Fact]
    public void AnUnknownScopeTokenIsRejected()
    {
        ArtifactDeclaration declaration = Mutate(
            Evidence(),
            extensions => extensions[ScreenshotEvidenceV1.ScopeKey] = "monitor",
            quality => quality);

        Assert.Contains(
            "invalid screenshot evidence v1 scope",
            ScreenshotEvidenceProfile.Errors(declaration, Policy()));
    }

    [Theory]
    [InlineData(-1L)]
    [InlineData(4_294_967_296L)]
    public void AWindowIdOutsideTheThirtyTwoBitRangeIsRejected(long windowId)
    {
        ArtifactDeclaration declaration = Mutate(
            Evidence(),
            extensions => extensions[ScreenshotEvidenceV1.WindowIdKey] = windowId,
            quality => quality);

        Assert.Contains(
            "invalid screenshot window identity",
            ScreenshotEvidenceProfile.Errors(declaration, Policy()));
    }

    [Fact]
    public void ABlankOwnerIdentityIsRejected()
    {
        ArtifactDeclaration declaration = Mutate(
            Evidence(),
            extensions => extensions[ScreenshotEvidenceV1.OwnerBundleIdKey] = "   ",
            quality => quality);

        Assert.Contains(
            "invalid screenshot window identity",
            ScreenshotEvidenceProfile.Errors(declaration, Policy()));
    }

    [Fact]
    public void ACaptureIntervalThatDoesNotMatchTheProfileIsRejected()
    {
        ArtifactDeclaration declaration = Mutate(Evidence(), _ => { }, quality => quality) with
        {
            CaptureInterval = new ArtifactCaptureInterval(
                "2026-07-22T08:00:09.000Z",
                "2026-07-22T08:00:10.125Z"),
        };

        Assert.Contains(
            "captureInterval differs from its screenshot evidence",
            ScreenshotEvidenceProfile.Errors(declaration, Policy()));
    }

    [Fact]
    public void AnIntervalThatEndsBeforeItStartsIsRejected()
    {
        ArtifactDeclaration declaration = Mutate(
            Evidence(),
            extensions =>
            {
                extensions[ScreenshotEvidenceV1.RequestStartedAtKey] = "2026-07-22T08:00:10.125Z";
                extensions[ScreenshotEvidenceV1.FrameCompletedAtKey] = "2026-07-22T08:00:10.000Z";
            },
            quality => quality) with
        {
            CaptureInterval = new ArtifactCaptureInterval(
                "2026-07-22T08:00:10.125Z",
                "2026-07-22T08:00:10.000Z"),
        };

        IReadOnlyList<string> errors = ScreenshotEvidenceProfile.Errors(declaration, Policy());

        Assert.Contains("capture interval ends before it starts", errors);
        Assert.Contains("invalid screenshot evidence v1 timing", errors);
    }

    [Fact]
    public void ANonIntegerDurationIsRejected()
    {
        ArtifactDeclaration declaration = Mutate(
            Evidence(),
            extensions => extensions[ScreenshotEvidenceV1.MonotonicDurationMillisKey] = "125",
            quality => quality);

        Assert.Contains(
            "invalid screenshot evidence v1 timing",
            ScreenshotEvidenceProfile.Errors(declaration, Policy()));
    }

    [Fact]
    public void AttachRefusesToHandBackAnAttachmentThatWouldNotValidate()
    {
        ScreenshotEvidence broken = Evidence() with { FrameCompletedAt = "2026-07-22T08:00:09.000Z" };

        ArgumentException error = Assert.Throws<ArgumentException>(
            () => broken.Attach(Jpeg, Policy()));
        Assert.Contains("Screenshot evidence profile", error.Message, StringComparison.Ordinal);
    }

    // --- Helpers --------------------------------------------------------------------------------

    private static ScreenshotEvidence Evidence() => ScreenshotEvidence.FromMonotonicDuration(
        RequestedAt,
        125,
        new ScreenshotWindowScope(Owner, 4242));

    private static ArtifactAttachment Attachment(ScreenshotEvidence evidence) =>
        evidence.Attach(Jpeg, Policy(SecretApp, "a-app", "z-app"));

    /// <summary>
    /// A declaration built from sound evidence and then deliberately broken. Going through the real
    /// builder first keeps every one of these tests about the single rule it names.
    /// </summary>
    private static ArtifactDeclaration Mutate(
        ScreenshotEvidence evidence,
        Action<JsonObject> breakExtensions,
        Func<ArtifactQuality, ArtifactQuality> breakQuality)
    {
        JsonObject extensions = evidence.Extensions();
        breakExtensions(extensions);
        return new ArtifactDeclaration(ScreenshotEvidenceV1.Kind, ScreenshotEvidenceV1.MediaType)
        {
            SourceRole = ScreenshotEvidenceV1.SourceRole,
            CaptureInterval = evidence.CaptureInterval(),
            Quality = breakQuality(evidence.Quality()),
            Privacy = ArtifactPrivacy.Captured("consent-v1"),
            Extensions = extensions,
        };
    }
}
