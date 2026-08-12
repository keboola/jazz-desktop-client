using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace JazzCaptureCore.Archive;

/// <summary>
/// Vocabulary of the <c>dev.jazz.capture.screenshot.v1</c> evidence profile (ANNEX-ARCHIVE 2.7).
/// </summary>
/// <remarks>
/// The namespace is versioned because macOS, this client and the server have to read the same pixels
/// the same way. Once any key of the namespace appears the profile is all-or-nothing, and an unknown
/// key inside it fails the archive schema outright — so every key a producer may write is named here
/// rather than assembled from string fragments at the call site.
/// </remarks>
public static class ScreenshotEvidenceV1
{
    /// <summary>Extension namespace of the profile.</summary>
    public const string Namespace = "dev.jazz.capture.screenshot.v1";

    /// <summary>Wall-clock anchor of the capture request.</summary>
    public const string RequestStartedAtKey = Namespace + ".requestStartedAt";

    /// <summary>Wall-clock end of the capture, derived from the monotonic duration.</summary>
    public const string FrameCompletedAtKey = Namespace + ".frameCompletedAt";

    /// <summary>How long the capture took, measured on a monotonic clock.</summary>
    public const string MonotonicDurationMillisKey = Namespace + ".monotonicDurationMillis";

    /// <summary>What the frame covers: <c>window</c> or <c>display</c>.</summary>
    public const string ScopeKey = Namespace + ".scope";

    /// <summary>Stable identity of the owning application; window scope only.</summary>
    public const string OwnerBundleIdKey = Namespace + ".ownerBundleId";

    /// <summary>Identity of the captured window; window scope only.</summary>
    public const string WindowIdKey = Namespace + ".windowId";

    /// <summary>Identity of the captured display; display scope only.</summary>
    public const string DisplayIdKey = Namespace + ".displayId";

    /// <summary>Denylisted applications the capture filter actually excluded; display scope only.</summary>
    public const string ExcludedApplicationBundleIdsKey = Namespace + ".excludedApplicationBundleIds";

    /// <summary>Quality reason every persisted screenshot carries: the frame is an interval.</summary>
    public const string TemporalIntervalReason = Namespace + ".temporal_interval";

    /// <summary>Quality reason of a display-scope frame; forbidden on a window-scope one.</summary>
    public const string DisplayFallbackReason = Namespace + ".display_fallback";

    /// <summary>
    /// Observation-quality reason for a frame whose owning application was not the event's
    /// attributed owner. Those pixels are discarded, so this never reaches an artifact.
    /// </summary>
    public const string OwnerMismatchReason = Namespace + ".owner_mismatch";

    /// <summary>
    /// Observation-quality reason for an event whose screenshot could not be acquired. Also never
    /// reaches an artifact: there are no bytes for it to describe.
    /// </summary>
    public const string UnavailableReason = Namespace + ".unavailable";

    /// <summary><c>scope</c> value of a focused-window frame.</summary>
    public const string WindowScopeToken = "window";

    /// <summary><c>scope</c> value of a whole-display frame.</summary>
    public const string DisplayScopeToken = "display";

    /// <summary>Artifact kind that triggers this profile.</summary>
    public const string Kind = "screenshot";

    /// <summary>Media type of the bytes this client captures.</summary>
    public const string MediaType = "image/jpeg";

    /// <summary>Role the citing observation gives the artifact.</summary>
    public const string Role = "screenshot";

    /// <summary>Role of the capture source that supplied the pixels.</summary>
    public const string SourceRole = "screen_capture";

    /// <summary>Role the artifact attributes to the recorder.</summary>
    public const string ActorRole = "performer";

    /// <summary>How that attribution was made.</summary>
    public const string ActorMethod = "session_recorder";

    /// <summary>Capture-policy modality a persisted screenshot requires.</summary>
    public const string Modality = "screenshots";

    /// <summary>Largest window or display identity the profile admits (a Win32 <c>HWND</c> fits).</summary>
    public const long MaxScopeId = 4_294_967_295L;

    /// <summary>Largest integer canonical JSON may carry.</summary>
    public const long MaxSafeInteger = 9_007_199_254_740_991L;

    /// <summary>Every key the namespace defines. Anything else in it fails the schema.</summary>
    public static readonly IReadOnlySet<string> Keys = new HashSet<string>(StringComparer.Ordinal)
    {
        RequestStartedAtKey,
        FrameCompletedAtKey,
        MonotonicDurationMillisKey,
        ScopeKey,
        OwnerBundleIdKey,
        WindowIdKey,
        DisplayIdKey,
        ExcludedApplicationBundleIdsKey,
    };

    /// <summary>The four keys every profile carries, whatever its scope.</summary>
    public static readonly IReadOnlySet<string> BaseKeys = new HashSet<string>(StringComparer.Ordinal)
    {
        RequestStartedAtKey,
        FrameCompletedAtKey,
        MonotonicDurationMillisKey,
        ScopeKey,
    };

    /// <summary>Reasons that describe a discarded frame and may never reach a persisted artifact.</summary>
    public static readonly IReadOnlySet<string> NonArtifactReasons = new HashSet<string>(StringComparer.Ordinal)
    {
        OwnerMismatchReason,
        UnavailableReason,
    };
}

/// <summary>
/// What one captured frame covers. Closed hierarchy: the profile admits exactly two scopes, and each
/// requires its own pair of keys while forbidding the other pair.
/// </summary>
public abstract record ScreenshotScope
{
    private protected ScreenshotScope()
    {
    }

    /// <summary>The <c>scope</c> token this scope writes.</summary>
    public abstract string Token { get; }

    /// <summary>Writes the scope-specific keys into an extensions bag.</summary>
    internal abstract void Write(JsonObject extensions);

    /// <summary>The quality reasons this scope adds beyond the temporal interval.</summary>
    internal abstract IEnumerable<string> ExtraQualityReasons { get; }
}

/// <summary>
/// One application window. The only scope this client produces: a window capture is the only frame
/// Windows can hand back that is guaranteed not to contain a denylisted application's pixels.
/// </summary>
/// <param name="OwnerBundleId">
/// Stable identity of the owning application. macOS writes a bundle identifier; on Windows there is
/// no such thing, so this carries the same <see cref="AppIdentity.Value"/> the event is attributed
/// to — an AUMID for a packaged app, a normalized executable path otherwise. The key name is part of
/// the v1 wire format and is deliberately not renamed per platform.
/// </param>
/// <param name="WindowId">Identity of the captured window; a Win32 <c>HWND</c> truncated to 32 bits.</param>
public sealed record ScreenshotWindowScope(string OwnerBundleId, long WindowId) : ScreenshotScope
{
    /// <inheritdoc />
    public override string Token => ScreenshotEvidenceV1.WindowScopeToken;

    /// <inheritdoc />
    internal override void Write(JsonObject extensions)
    {
        extensions[ScreenshotEvidenceV1.OwnerBundleIdKey] = OwnerBundleId;
        extensions[ScreenshotEvidenceV1.WindowIdKey] = WindowId;
    }

    /// <inheritdoc />
    internal override IEnumerable<string> ExtraQualityReasons => Array.Empty<string>();
}

/// <summary>
/// One whole display, with the applications the capture filter excluded from it.
/// </summary>
/// <remarks>
/// This client never produces a display-scope frame — see the fail-closed note on the Windows
/// capture host. The scope exists here because the profile is shared with macOS, which does produce
/// one, and because a reader of this archive format has to be able to describe both.
/// </remarks>
/// <param name="DisplayId">Identity of the captured display.</param>
/// <param name="ExcludedApplicationBundleIds">
/// The denylisted applications the native filter actually removed; sorted, unique, and a subset of
/// the frozen capture policy's exclusions.
/// </param>
public sealed record ScreenshotDisplayScope(
    long DisplayId,
    IReadOnlyList<string> ExcludedApplicationBundleIds) : ScreenshotScope
{
    /// <inheritdoc />
    public override string Token => ScreenshotEvidenceV1.DisplayScopeToken;

    /// <inheritdoc />
    internal override void Write(JsonObject extensions)
    {
        extensions[ScreenshotEvidenceV1.DisplayIdKey] = DisplayId;
        var excluded = new JsonArray();
        foreach (string application in ExcludedApplicationBundleIds.Distinct(StringComparer.Ordinal).OrderBy(value => value, StringComparer.Ordinal))
        {
            excluded.Add(application);
        }

        extensions[ScreenshotEvidenceV1.ExcludedApplicationBundleIdsKey] = excluded;
    }

    /// <inheritdoc />
    internal override IEnumerable<string> ExtraQualityReasons =>
        new[] { ScreenshotEvidenceV1.DisplayFallbackReason };
}

/// <summary>
/// The capture policy a capture froze before its first hook existed, as far as a screenshot cares.
/// </summary>
/// <remarks>
/// Persisted pixels are policy-bound evidence: the artifact's privacy block has to name the same
/// policy version the session declares, the policy has to admit the <c>screenshots</c> modality, and
/// a display capture may not claim to have excluded an application the policy never named. All three
/// are cross-checked against this snapshot rather than against whatever the host believes now.
/// </remarks>
/// <param name="PolicyVersion">Consent policy version stamped on every record and artifact.</param>
/// <param name="Modalities">The session's consented modality tokens.</param>
/// <param name="ExcludedApplications">Applications the policy excludes from capture.</param>
public sealed record FrozenCapturePolicy(
    string PolicyVersion,
    IReadOnlyList<string> Modalities,
    IReadOnlyList<string> ExcludedApplications)
{
    /// <summary>Whether the policy admits persisted screenshots at all.</summary>
    public bool AllowsScreenshots =>
        Modalities.Contains(ScreenshotEvidenceV1.Modality, StringComparer.Ordinal);

    /// <summary>Whether the policy admits persisted narration audio at all.</summary>
    public bool AllowsNarration =>
        Modalities.Contains(NarrationAudioV1.Modality, StringComparer.Ordinal);
}

/// <summary>
/// One screenshot's acquisition evidence: when it was asked for, how long the OS took, and what the
/// frame covers.
/// </summary>
/// <remarks>
/// <para>
/// A screenshot is an interval, not an instant. The frame is finished some measurable time after it
/// was requested, and pretending otherwise would let a later reader treat the pixels as the exact
/// state at mouse-up. So the artifact always carries <c>quality.status = partial</c> with the
/// <see cref="ScreenshotEvidenceV1.TemporalIntervalReason"/> reason and the measured duration as its
/// timing error.
/// </para>
/// <para>
/// The end of the interval is derived from the start plus a monotonic duration
/// (<see cref="FromMonotonicDuration"/>) rather than read from a second wall-clock sample: a clock
/// step during acquisition would otherwise be able to end the interval before it began.
/// </para>
/// </remarks>
/// <param name="RequestStartedAt">Canonical <c>YYYY-MM-DDTHH:mm:ss.SSSZ</c> request anchor.</param>
/// <param name="FrameCompletedAt">Canonical <c>YYYY-MM-DDTHH:mm:ss.SSSZ</c> completion.</param>
/// <param name="MonotonicDurationMillis">Monotonic duration; the exact difference of the two above.</param>
/// <param name="Scope">What the frame covers.</param>
public sealed record ScreenshotEvidence(
    string RequestStartedAt,
    string FrameCompletedAt,
    long MonotonicDurationMillis,
    ScreenshotScope Scope)
{
    private const string CanonicalFormat = "yyyy-MM-dd'T'HH:mm:ss.fff'Z'";

    /// <summary>Number of characters of a canonical millisecond timestamp.</summary>
    private const int CanonicalLength = 24;

    /// <summary>
    /// Builds the evidence from a wall-clock request anchor and a monotonic duration, deriving the
    /// completion so the interval and the duration agree by construction.
    /// </summary>
    /// <param name="requestStartedAt">Wall clock read just after the monotonic start.</param>
    /// <param name="monotonicDurationMillis">Elapsed monotonic milliseconds; never negative.</param>
    /// <param name="scope">What the frame covers.</param>
    /// <exception cref="ArgumentOutOfRangeException">The duration is negative or unrepresentable.</exception>
    public static ScreenshotEvidence FromMonotonicDuration(
        DateTimeOffset requestStartedAt,
        long monotonicDurationMillis,
        ScreenshotScope scope)
    {
        ArgumentNullException.ThrowIfNull(scope);
        if (monotonicDurationMillis < 0 || monotonicDurationMillis > ScreenshotEvidenceV1.MaxSafeInteger)
        {
            throw new ArgumentOutOfRangeException(
                nameof(monotonicDurationMillis),
                monotonicDurationMillis,
                "A screenshot duration must be a non-negative canonical integer.");
        }

        // Truncate the anchor to whole milliseconds before adding the duration: the wire format
        // carries exactly three fractional digits, so a sub-millisecond anchor would otherwise make
        // the rendered difference disagree with the duration by one millisecond.
        DateTimeOffset anchor = Truncate(requestStartedAt);
        return new ScreenshotEvidence(
            Timestamps.IsoMillisUtc(anchor),
            Timestamps.IsoMillisUtc(anchor.AddMilliseconds(monotonicDurationMillis)),
            monotonicDurationMillis,
            scope);
    }

    /// <summary>The extensions bag this evidence contributes to the artifact document.</summary>
    public JsonObject Extensions()
    {
        var extensions = new JsonObject
        {
            [ScreenshotEvidenceV1.RequestStartedAtKey] = RequestStartedAt,
            [ScreenshotEvidenceV1.FrameCompletedAtKey] = FrameCompletedAt,
            [ScreenshotEvidenceV1.MonotonicDurationMillisKey] = MonotonicDurationMillis,
            [ScreenshotEvidenceV1.ScopeKey] = Scope.Token,
        };

        Scope.Write(extensions);
        return extensions;
    }

    /// <summary>The interval the artifact declares; identical to the profile's two timestamps.</summary>
    public ArtifactCaptureInterval CaptureInterval() => new(RequestStartedAt, FrameCompletedAt);

    /// <summary>
    /// The quality the artifact and its citing observation both carry: partial, because the frame is
    /// an interval, with the measured duration as the timing error.
    /// </summary>
    public ArtifactQuality Quality()
    {
        var reasons = new List<string> { ScreenshotEvidenceV1.TemporalIntervalReason };
        reasons.AddRange(Scope.ExtraQualityReasons);
        return new ArtifactQuality(ArtifactQualityStatus.Partial, reasons, MonotonicDurationMillis);
    }

    /// <summary>
    /// Builds the attachment the capture engine ingests: the bytes plus everything the archive says
    /// about them.
    /// </summary>
    /// <param name="jpeg">The encoded frame.</param>
    /// <param name="policy">The capture policy the session froze.</param>
    /// <exception cref="ArgumentException">
    /// The evidence, the policy, or the two together would produce an artifact the contract validator
    /// rejects. Checked here because the bytes are about to become durable, and a profile that only
    /// fails at finalization would cost the whole capture rather than one frame.
    /// </exception>
    public ArtifactAttachment Attach(ReadOnlyMemory<byte> jpeg, FrozenCapturePolicy policy)
    {
        ArgumentNullException.ThrowIfNull(policy);

        var attachment = new ArtifactAttachment(
            ScreenshotEvidenceV1.Kind,
            ScreenshotEvidenceV1.MediaType,
            jpeg)
        {
            Role = ScreenshotEvidenceV1.Role,
            SourceRole = ScreenshotEvidenceV1.SourceRole,
            ActorRefs = new[]
            {
                new ArtifactActorRef(
                    ScreenshotEvidenceV1.ActorRole,
                    ArtifactActorRef.DeclaredBasis,
                    ScreenshotEvidenceV1.ActorMethod),
            },
            CaptureInterval = CaptureInterval(),
            Quality = Quality(),
            Privacy = ArtifactPrivacy.Captured(policy.PolicyVersion),
            Extensions = Extensions(),
        };

        ScreenshotEvidenceProfile.Validate(attachment, policy);
        return attachment;
    }

    /// <summary>
    /// Parses a canonical millisecond timestamp, or returns null. Only the exact
    /// <c>YYYY-MM-DDTHH:mm:ss.SSSZ</c> shape is accepted: sub-millisecond digits would make the
    /// integer duration arithmetic runtime-dependent, which is the one thing v1 exists to prevent.
    /// </summary>
    internal static DateTimeOffset? Canonical(string? value)
    {
        if (value is null || value.Length != CanonicalLength)
        {
            return null;
        }

        return DateTimeOffset.TryParseExact(
            value,
            CanonicalFormat,
            CultureInfo.InvariantCulture,
            DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
            out DateTimeOffset parsed)
            ? parsed
            : null;
    }

    private static DateTimeOffset Truncate(DateTimeOffset value)
    {
        DateTimeOffset utc = value.ToUniversalTime();
        return utc.AddTicks(-(utc.Ticks % TimeSpan.TicksPerMillisecond));
    }
}

/// <summary>
/// The cross-field rules of ANNEX-ARCHIVE 2.7, as a check a producer can run before the bytes become
/// durable.
/// </summary>
/// <remarks>
/// This is a port of <c>_artifact_capture_evidence_errors</c> in
/// <c>contract/archive/validate_archives.py</c>, which stays the normative authority. Running the
/// same checks here is what turns "the archive was rejected after the capture ended" into "this one
/// frame was refused": the errors are reported per artifact, in the producer's own vocabulary, while
/// the recording is still going.
/// </remarks>
public static class ScreenshotEvidenceProfile
{
    /// <summary>Everything wrong with one artifact's screenshot evidence; empty when it is sound.</summary>
    /// <param name="declaration">The artifact as the producer would write it.</param>
    /// <param name="policy">The capture policy the session froze.</param>
    public static IReadOnlyList<string> Errors(ArtifactDeclaration declaration, FrozenCapturePolicy policy)
    {
        ArgumentNullException.ThrowIfNull(declaration);
        ArgumentNullException.ThrowIfNull(policy);

        var errors = new List<string>();
        JsonObject extensions = declaration.Extensions ?? new JsonObject();
        var profileKeys = new HashSet<string>(
            extensions
                .Select(pair => pair.Key)
                .Where(key => key.StartsWith(ScreenshotEvidenceV1.Namespace + ".", StringComparison.Ordinal)),
            StringComparer.Ordinal);

        ArtifactCaptureInterval? interval = declaration.CaptureInterval;
        if (interval is { EndedAt: { } declaredEnd }
            && Timestamps.UnixNanos(interval.StartedAt) is { } startNanos
            && Timestamps.UnixNanos(declaredEnd) is { } endNanos
            && endNanos < startNanos)
        {
            errors.Add("capture interval ends before it starts");
        }

        bool isScreenshot = string.Equals(declaration.Kind, ScreenshotEvidenceV1.Kind, StringComparison.Ordinal);
        if (isScreenshot)
        {
            // The writer stamps captured-under-the-frozen-policy when the caller declares nothing,
            // so an absent privacy block is checked as the block that will actually be written.
            ArtifactPrivacy privacy = declaration.Privacy ?? ArtifactPrivacy.Captured(policy.PolicyVersion);
            if (!string.Equals(privacy.PolicyVersion, policy.PolicyVersion, StringComparison.Ordinal)
                || privacy.Status is not (ArtifactPrivacyStatus.Captured or ArtifactPrivacyStatus.Masked)
                || !policy.AllowsScreenshots)
            {
                errors.Add("screenshot privacy differs from its frozen capture policy");
            }

            if (profileKeys.Count == 0)
            {
                // No legacy admission here: this producer is new, so a screenshot without the
                // profile is a bug rather than an old archive.
                errors.Add("screenshot evidence v1 profile is required");
                return errors;
            }
        }
        else if (profileKeys.Count == 0)
        {
            return errors;
        }

        string[] unknownKeys = profileKeys
            .Except(ScreenshotEvidenceV1.Keys, StringComparer.Ordinal)
            .OrderBy(key => key, StringComparer.Ordinal)
            .ToArray();
        if (unknownKeys.Length > 0)
        {
            errors.Add("unknown screenshot evidence v1 keys [" + string.Join(", ", unknownKeys) + "]");
        }

        string[] missingBase = ScreenshotEvidenceV1.BaseKeys
            .Except(profileKeys, StringComparer.Ordinal)
            .OrderBy(key => key, StringComparer.Ordinal)
            .ToArray();
        if (missingBase.Length > 0)
        {
            errors.Add(
                "incomplete screenshot evidence v1 profile (missing ["
                    + string.Join(", ", missingBase) + "])");
            return errors;
        }

        string? scope = Text(extensions[ScreenshotEvidenceV1.ScopeKey]);
        IReadOnlySet<string> scopeKeys;
        IReadOnlySet<string> forbiddenScopeKeys;
        switch (scope)
        {
            case ScreenshotEvidenceV1.WindowScopeToken:
                scopeKeys = Set(ScreenshotEvidenceV1.OwnerBundleIdKey, ScreenshotEvidenceV1.WindowIdKey);
                forbiddenScopeKeys = Set(
                    ScreenshotEvidenceV1.DisplayIdKey,
                    ScreenshotEvidenceV1.ExcludedApplicationBundleIdsKey);
                break;
            case ScreenshotEvidenceV1.DisplayScopeToken:
                scopeKeys = Set(
                    ScreenshotEvidenceV1.DisplayIdKey,
                    ScreenshotEvidenceV1.ExcludedApplicationBundleIdsKey);
                forbiddenScopeKeys = Set(ScreenshotEvidenceV1.OwnerBundleIdKey, ScreenshotEvidenceV1.WindowIdKey);
                break;
            default:
                errors.Add("invalid screenshot evidence v1 scope");
                return errors;
        }

        if (scopeKeys.Except(profileKeys, StringComparer.Ordinal).Any()
            || forbiddenScopeKeys.Intersect(profileKeys, StringComparer.Ordinal).Any())
        {
            errors.Add("invalid screenshot evidence v1 " + scope + " scope");
        }

        string? requestStartedAt = Text(extensions[ScreenshotEvidenceV1.RequestStartedAtKey]);
        string? frameCompletedAt = Text(extensions[ScreenshotEvidenceV1.FrameCompletedAtKey]);
        bool hasDuration = TryInteger(extensions[ScreenshotEvidenceV1.MonotonicDurationMillisKey], out long duration);
        bool validDuration = hasDuration && duration >= 0 && duration <= ScreenshotEvidenceV1.MaxSafeInteger;
        DateTimeOffset? requestTime = ScreenshotEvidence.Canonical(requestStartedAt);
        DateTimeOffset? frameTime = ScreenshotEvidence.Canonical(frameCompletedAt);

        if (requestTime is not { } request || frameTime is not { } frame || frame < request || !validDuration)
        {
            errors.Add("invalid screenshot evidence v1 timing");
        }
        else if ((frame - request).Ticks / TimeSpan.TicksPerMillisecond != duration)
        {
            errors.Add("screenshot interval differs from its monotonic duration");
        }

        if (!isScreenshot)
        {
            errors.Add("screenshot evidence is bound to a non-screenshot");
        }

        if (interval is null
            || !string.Equals(interval.StartedAt, requestStartedAt, StringComparison.Ordinal)
            || !string.Equals(interval.EndedAt, frameCompletedAt, StringComparison.Ordinal))
        {
            errors.Add("captureInterval differs from its screenshot evidence");
        }

        ArtifactQuality quality = declaration.Quality;
        var reasons = new HashSet<string>(quality.Reasons, StringComparer.Ordinal);
        if (!string.Equals(quality.Status, ArtifactQualityStatus.Partial, StringComparison.Ordinal)
            || !reasons.Contains(ScreenshotEvidenceV1.TemporalIntervalReason)
            || !validDuration
            || quality.TimingErrorMillis != duration)
        {
            errors.Add("quality differs from its screenshot evidence timing");
        }

        string[] forbiddenReasons = reasons
            .Intersect(ScreenshotEvidenceV1.NonArtifactReasons, StringComparer.Ordinal)
            .OrderBy(reason => reason, StringComparer.Ordinal)
            .ToArray();
        if (forbiddenReasons.Length > 0)
        {
            errors.Add(
                "persists non-artifact screenshot reasons [" + string.Join(", ", forbiddenReasons) + "]");
        }

        if (string.Equals(scope, ScreenshotEvidenceV1.WindowScopeToken, StringComparison.Ordinal))
        {
            errors.AddRange(WindowErrors(extensions, reasons));
        }
        else
        {
            errors.AddRange(DisplayErrors(extensions, reasons, policy));
        }

        return errors;
    }

    /// <summary>The same checks over an attachment the engine has not ingested yet.</summary>
    /// <param name="attachment">The attachment as the host built it.</param>
    /// <param name="policy">The capture policy the session froze.</param>
    public static IReadOnlyList<string> Errors(ArtifactAttachment attachment, FrozenCapturePolicy policy)
    {
        ArgumentNullException.ThrowIfNull(attachment);
        return Errors(attachment.Declare(Array.Empty<string>(), Array.Empty<string>()), policy);
    }

    /// <summary>Throws unless the attachment satisfies the whole profile.</summary>
    /// <exception cref="ArgumentException">The attachment would produce an invalid artifact.</exception>
    public static void Validate(ArtifactAttachment attachment, FrozenCapturePolicy policy)
    {
        IReadOnlyList<string> errors = Errors(attachment, policy);
        if (errors.Count > 0)
        {
            throw new ArgumentException(
                "Screenshot evidence profile: " + string.Join("; ", errors) + ".",
                nameof(attachment));
        }
    }

    private static IEnumerable<string> WindowErrors(JsonObject extensions, IReadOnlySet<string> reasons)
    {
        string? owner = Text(extensions[ScreenshotEvidenceV1.OwnerBundleIdKey]);
        bool hasWindowId = TryInteger(extensions[ScreenshotEvidenceV1.WindowIdKey], out long windowId);
        if (string.IsNullOrWhiteSpace(owner)
            || !hasWindowId
            || windowId < 0
            || windowId > ScreenshotEvidenceV1.MaxScopeId)
        {
            yield return "invalid screenshot window identity";
        }

        if (reasons.Contains(ScreenshotEvidenceV1.DisplayFallbackReason))
        {
            yield return "window evidence has a display fallback reason";
        }
    }

    private static IEnumerable<string> DisplayErrors(
        JsonObject extensions,
        IReadOnlySet<string> reasons,
        FrozenCapturePolicy policy)
    {
        bool hasDisplayId = TryInteger(extensions[ScreenshotEvidenceV1.DisplayIdKey], out long displayId);
        List<string>? excluded = Strings(extensions[ScreenshotEvidenceV1.ExcludedApplicationBundleIdsKey]);
        if (!hasDisplayId
            || displayId < 0
            || displayId > ScreenshotEvidenceV1.MaxScopeId
            || excluded is null
            || excluded.Any(string.IsNullOrWhiteSpace)
            || !excluded.SequenceEqual(excluded.OrderBy(value => value, StringComparer.Ordinal), StringComparer.Ordinal)
            || excluded.Distinct(StringComparer.Ordinal).Count() != excluded.Count)
        {
            yield return "invalid screenshot display scope";
        }

        if (excluded is not null
            && !excluded.All(application => policy.ExcludedApplications.Contains(application, StringComparer.Ordinal)))
        {
            yield return "screenshot exclusions escape its frozen capture policy";
        }

        if (!reasons.Contains(ScreenshotEvidenceV1.DisplayFallbackReason))
        {
            yield return "display evidence lacks its fallback reason";
        }
    }

    private static IReadOnlySet<string> Set(params string[] values) =>
        new HashSet<string>(values, StringComparer.Ordinal);

    private static string? Text(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue(out string? text) ? text : null;

    /// <summary>
    /// Reads a JSON integer. A <see cref="JsonValue"/> only converts to the exact CLR type it was
    /// built from, so the widths a producer might reasonably have written are tried in turn; a
    /// parsed document answers through its <see cref="JsonElement"/>, which rejects a fractional
    /// literal on its own. Floats never appear in a canonical archive document, so a value that is
    /// not an integer is simply not a duration.
    /// </summary>
    private static bool TryInteger(JsonNode? node, out long value)
    {
        value = 0;
        if (node is not JsonValue jsonValue)
        {
            return false;
        }

        if (jsonValue.TryGetValue(out long wide))
        {
            value = wide;
            return true;
        }

        if (jsonValue.TryGetValue(out int narrow))
        {
            value = narrow;
            return true;
        }

        return jsonValue.TryGetValue(out JsonElement element)
            && element.ValueKind == JsonValueKind.Number
            && element.TryGetInt64(out value);
    }

    private static List<string>? Strings(JsonNode? node)
    {
        if (node is not JsonArray array)
        {
            return null;
        }

        var values = new List<string>(array.Count);
        foreach (JsonNode? item in array)
        {
            if (Text(item) is not { } text)
            {
                return null;
            }

            values.Add(text);
        }

        return values;
    }
}
