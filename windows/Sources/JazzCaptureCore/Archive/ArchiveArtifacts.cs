using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace JazzCaptureCore.Archive;

/// <summary>
/// How an artifact came to exist (ANNEX-ARCHIVE section 2.5). The origin decides both whether a
/// <c>derivation</c> block is required and what provenance the artifact may claim, so it is the one
/// field a producer has to get right before anything else about the artifact matters.
/// </summary>
public static class ArtifactOrigins
{
    /// <summary>The producer captured the bytes itself.</summary>
    public const string Captured = "captured";

    /// <summary>The bytes came from outside the capture.</summary>
    public const string Imported = "imported";

    /// <summary>The bytes were computed from other archive material.</summary>
    public const string Derived = "derived";

    /// <summary>
    /// The provenance <c>factClass</c> implied by <paramref name="origin"/>. Derived artifacts must
    /// declare derived provenance — the schema enforces the pair — and the other two have exactly
    /// one honest answer each, so the caller is never asked for it separately.
    /// </summary>
    public static string FactClass(string origin) => origin switch
    {
        Captured => "observed",
        Imported => "imported",
        Derived => "derived",
        _ => throw new ArgumentException("Unknown artifact origin '" + origin + "'.", nameof(origin)),
    };
}

/// <summary>
/// One observation's citation of an artifact. The reference lives on the record envelope so a
/// reader can find the material an observation produced without parsing the payload contract.
/// </summary>
/// <param name="ArtifactId">The artifact cited; must belong to the same capture.</param>
/// <param name="Role">What the artifact is to this observation, for example <c>screenshot</c>.</param>
public sealed record ArtifactRef(string ArtifactId, string Role);

/// <summary>Status vocabulary of the shared <c>quality</c> block.</summary>
public static class ArtifactQualityStatus
{
    /// <summary>Everything the producer set out to capture is present.</summary>
    public const string Complete = "complete";

    /// <summary>Something is present but incomplete or approximate; the reasons say what.</summary>
    public const string Partial = "partial";

    /// <summary>Nothing was captured.</summary>
    public const string Missing = "missing";

    /// <summary>What was captured cannot be trusted.</summary>
    public const string Invalid = "invalid";

    internal static readonly IReadOnlySet<string> All = new HashSet<string>(StringComparer.Ordinal)
    {
        Complete,
        Partial,
        Missing,
        Invalid,
    };
}

/// <summary>Status vocabulary of the shared <c>privacy</c> block.</summary>
public static class ArtifactPrivacyStatus
{
    /// <summary>The content was captured as it was.</summary>
    public const string Captured = "captured";

    /// <summary>Parts of the content were masked; the redactions say which.</summary>
    public const string Masked = "masked";

    /// <summary>The content was left out.</summary>
    public const string Omitted = "omitted";

    /// <summary>Capture was refused.</summary>
    public const string Denied = "denied";

    /// <summary>The producer could not tell.</summary>
    public const string Unknown = "unknown";

    internal static readonly IReadOnlySet<string> All = new HashSet<string>(StringComparer.Ordinal)
    {
        Captured,
        Masked,
        Omitted,
        Denied,
        Unknown,
    };
}

/// <summary>
/// The stretch of wall-clock time an artifact covers. A screenshot is an interval and not an
/// instant — the frame is finished some measurable time after it was asked for — so this is
/// deliberately a pair rather than a single timestamp.
/// </summary>
/// <param name="StartedAt">When capture of the content began (RFC 3339).</param>
/// <param name="EndedAt">When it finished; omitted when the producer cannot say.</param>
public sealed record ArtifactCaptureInterval(string StartedAt, string? EndedAt = null);

/// <summary>
/// How good the artifact is, in the archive's shared vocabulary.
/// </summary>
/// <remarks>
/// The reasons are not decoration: the screenshot evidence profile requires <c>partial</c> together
/// with a specific reason token, so a producer that could only ever emit an empty reason list could
/// not describe a screenshot at all.
/// </remarks>
/// <param name="Status">One of <see cref="ArtifactQualityStatus"/>.</param>
/// <param name="Reasons">Lower-case reason tokens; unique, and never null.</param>
/// <param name="TimingErrorMillis">
/// Known timing error in milliseconds; omitted when null. An integer because canonical archive
/// documents avoid floats entirely.
/// </param>
public sealed record ArtifactQuality(
    string Status,
    IReadOnlyList<string> Reasons,
    long? TimingErrorMillis = null)
{
    /// <summary>Nothing went wrong and there is nothing to say about it.</summary>
    public static ArtifactQuality Complete { get; } =
        new(ArtifactQualityStatus.Complete, Array.Empty<string>());
}

/// <summary>One redaction applied to the content, addressed by JSON pointer.</summary>
/// <param name="Path">JSON pointer into the content; must start with <c>/</c>.</param>
/// <param name="Action"><c>masked</c> or <c>omitted</c>.</param>
/// <param name="Reason">Why the redaction was applied.</param>
public sealed record ArtifactRedaction(string Path, string Action, string Reason)
{
    /// <summary>The content was replaced by a placeholder.</summary>
    public const string Masked = "masked";

    /// <summary>The content was left out entirely.</summary>
    public const string Omitted = "omitted";
}

/// <summary>
/// What the capture policy allowed to survive into this artifact.
/// </summary>
/// <remarks>
/// <see cref="PolicyVersion"/> is cross-checked against the session's frozen capture policy for
/// screenshot artifacts, so it travels with the artifact rather than being stamped on at write time.
/// </remarks>
/// <param name="Status">One of <see cref="ArtifactPrivacyStatus"/>.</param>
/// <param name="PolicyVersion">Consent policy version the artifact was captured under.</param>
/// <param name="Redactions">Redactions applied to the content; never null.</param>
public sealed record ArtifactPrivacy(
    string Status,
    string PolicyVersion,
    IReadOnlyList<ArtifactRedaction> Redactions)
{
    /// <summary>Nothing was masked or dropped under <paramref name="policyVersion"/>.</summary>
    public static ArtifactPrivacy Captured(string policyVersion) => new(
        ArtifactPrivacyStatus.Captured,
        policyVersion,
        Array.Empty<ArtifactRedaction>());
}

/// <summary>
/// An actor the artifact is attributed to. The MVP archive declares exactly one actor — the
/// recorder — so the identity is bound by the writer and the caller only says in what capacity.
/// </summary>
/// <param name="Role">Role token, for example <c>performer</c> or <c>speaker</c>.</param>
/// <param name="Basis"><c>observed</c> when measured, <c>declared</c> when asserted.</param>
/// <param name="Method">How the attribution was made; omitted when null.</param>
public sealed record ArtifactActorRef(string Role, string Basis, string? Method = null)
{
    /// <summary>The attribution was measured by the producer.</summary>
    public const string ObservedBasis = "observed";

    /// <summary>The attribution was asserted rather than measured.</summary>
    public const string DeclaredBasis = "declared";
}

/// <summary>One input a derived artifact was computed from.</summary>
/// <param name="Kind">
/// One of <c>archive</c>, <c>capture</c>, <c>commit</c>, <c>label</c>, <c>observation</c>,
/// <c>artifact</c>, <c>assertion</c>, <c>actor</c>, <c>source</c>.
/// </param>
/// <param name="Id">Identifier of the input; must resolve inside the archive.</param>
public sealed record ArtifactInputRef(string Kind, string Id);

/// <summary>
/// How a derived artifact was produced. Required exactly when the origin is
/// <see cref="ArtifactOrigins.Derived"/>, and forbidden otherwise.
/// </summary>
/// <param name="ProducerName">Name of the deriving component.</param>
/// <param name="ProducerVersion">Its version.</param>
/// <param name="ComputedAt">When the derivation ran (RFC 3339).</param>
/// <param name="InputRefs">At least one input; each must resolve inside the archive.</param>
/// <param name="ParametersDigest">SHA-256 of the derivation parameters; omitted when null.</param>
public sealed record ArtifactDerivation(
    string ProducerName,
    string ProducerVersion,
    string ComputedAt,
    IReadOnlyList<ArtifactInputRef> InputRefs,
    string? ParametersDigest = null);

/// <summary>
/// Everything about one artifact except its bytes: what it is, what it belongs to, and what the
/// producer is prepared to claim about it.
/// </summary>
/// <remarks>
/// <para>
/// The two artifact kinds that exist are <c>screenshot</c> and <c>narration_audio</c>. This type
/// carries what both of them need — an interval, a settable quality with reasons, a privacy block
/// with its own policy version, and a verbatim extensions bag — without knowing anything about
/// either. In particular, <c>kind == "screenshot"</c> triggers the mandatory
/// <c>dev.jazz.capture.screenshot.v1.*</c> evidence profile with its cross-field invariants; that
/// profile lives in <see cref="Extensions"/> and is the screenshot producer's responsibility, not
/// this builder's.
/// </para>
/// </remarks>
/// <param name="Kind">Artifact kind token, for example <c>screenshot</c>.</param>
/// <param name="MediaType">IANA media type of the bytes, for example <c>image/jpeg</c>.</param>
public sealed record ArtifactDeclaration(string Kind, string MediaType)
{
    private static readonly Regex TokenPattern = new(
        "^[a-z][a-z0-9._-]*$",
        RegexOptions.CultureInvariant | RegexOptions.Compiled);

    private static readonly Regex MediaTypePattern = new(
        @"^[^/\s]+/[^\s]+$",
        RegexOptions.CultureInvariant | RegexOptions.Compiled);

    /// <summary>One of <see cref="ArtifactOrigins"/>; captured unless the caller says otherwise.</summary>
    public string Origin { get; init; } = ArtifactOrigins.Captured;

    /// <summary>Role of the capture source that supplied the bytes.</summary>
    public string SourceRole { get; init; } = ArchiveContracts.CaptureRole;

    /// <summary>Schema the content itself conforms to; omitted when null.</summary>
    public string? ContentSchema { get; init; }

    /// <summary>Bracketed labels this artifact belongs to.</summary>
    public IReadOnlyList<string> LabelRefs { get; init; } = Array.Empty<string>();

    /// <summary>Observations this artifact is evidence for.</summary>
    public IReadOnlyList<string> ObservationRefs { get; init; } = Array.Empty<string>();

    /// <summary>Actor attributions; empty when the artifact is attributed to nobody in particular.</summary>
    public IReadOnlyList<ArtifactActorRef> ActorRefs { get; init; } = Array.Empty<ArtifactActorRef>();

    /// <summary>The wall-clock stretch the content covers; omitted when null.</summary>
    public ArtifactCaptureInterval? CaptureInterval { get; init; }

    /// <summary>Quality of the content; complete unless the caller says otherwise.</summary>
    public ArtifactQuality Quality { get; init; } = ArtifactQuality.Complete;

    /// <summary>
    /// Privacy of the content; when null the writer stamps <c>captured</c> under the session's
    /// frozen policy version.
    /// </summary>
    public ArtifactPrivacy? Privacy { get; init; }

    /// <summary>
    /// Portable extensions, written verbatim. Screenshot producers put the whole
    /// <c>dev.jazz.capture.screenshot.v1.*</c> profile here.
    /// </summary>
    public JsonObject? Extensions { get; init; }

    /// <summary>Required when <see cref="Origin"/> is derived, and forbidden otherwise.</summary>
    public ArtifactDerivation? Derivation { get; init; }

    /// <summary>
    /// Rejects a declaration the archive schema would reject later, when the producer that built it
    /// is long gone.
    /// </summary>
    /// <exception cref="ArgumentException">The declaration cannot produce a valid artifact.</exception>
    public void Validate()
    {
        RequireToken(Kind, nameof(Kind));
        RequireToken(SourceRole, nameof(SourceRole));

        if (!MediaTypePattern.IsMatch(MediaType))
        {
            throw new ArgumentException("'" + MediaType + "' is not a media type.", nameof(MediaType));
        }

        // Reading the fact class is the origin check: an unknown one has no honest provenance.
        _ = ArtifactOrigins.FactClass(Origin);

        if (string.Equals(Origin, ArtifactOrigins.Derived, StringComparison.Ordinal) != (Derivation is not null))
        {
            throw new ArgumentException(
                "A derived artifact requires a derivation and a non-derived one must not carry it.",
                nameof(Derivation));
        }

        if (Derivation is { } derivation && derivation.InputRefs.Count == 0)
        {
            throw new ArgumentException("A derivation must name at least one input.", nameof(Derivation));
        }

        if (!ArtifactQualityStatus.All.Contains(Quality.Status))
        {
            throw new ArgumentException("Unknown quality status '" + Quality.Status + "'.", nameof(Quality));
        }

        foreach (string reason in Quality.Reasons)
        {
            RequireToken(reason, nameof(Quality));
        }

        if (Quality.Reasons.Distinct(StringComparer.Ordinal).Count() != Quality.Reasons.Count)
        {
            throw new ArgumentException("Quality reasons must be unique.", nameof(Quality));
        }

        if (Quality.TimingErrorMillis is < 0)
        {
            throw new ArgumentException("A timing error cannot be negative.", nameof(Quality));
        }

        if (Privacy is { } privacy)
        {
            if (!ArtifactPrivacyStatus.All.Contains(privacy.Status))
            {
                throw new ArgumentException("Unknown privacy status '" + privacy.Status + "'.", nameof(Privacy));
            }

            ArgumentException.ThrowIfNullOrEmpty(privacy.PolicyVersion, nameof(Privacy));

            foreach (ArtifactRedaction redaction in privacy.Redactions)
            {
                if (!redaction.Path.StartsWith('/'))
                {
                    throw new ArgumentException(
                        "A redaction path must be a JSON pointer: '" + redaction.Path + "'.",
                        nameof(Privacy));
                }

                if (redaction.Action is not (ArtifactRedaction.Masked or ArtifactRedaction.Omitted))
                {
                    throw new ArgumentException(
                        "Unknown redaction action '" + redaction.Action + "'.",
                        nameof(Privacy));
                }
            }
        }

        foreach (ArtifactActorRef actor in ActorRefs)
        {
            RequireToken(actor.Role, nameof(ActorRefs));
            if (actor.Basis is not (ArtifactActorRef.ObservedBasis or ArtifactActorRef.DeclaredBasis))
            {
                throw new ArgumentException("Unknown actor basis '" + actor.Basis + "'.", nameof(ActorRefs));
            }
        }

        RequireUnique(LabelRefs, nameof(LabelRefs));
        RequireUnique(ObservationRefs, nameof(ObservationRefs));
    }

    private static void RequireToken(string value, string parameterName)
    {
        if (!TokenPattern.IsMatch(value))
        {
            throw new ArgumentException("'" + value + "' is not a lower-case token.", parameterName);
        }
    }

    private static void RequireUnique(IReadOnlyList<string> values, string parameterName)
    {
        if (values.Distinct(StringComparer.Ordinal).Count() != values.Count)
        {
            throw new ArgumentException("References must be unique.", parameterName);
        }
    }
}
