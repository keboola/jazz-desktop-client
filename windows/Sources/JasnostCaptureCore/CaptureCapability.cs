using System.Text.Json.Nodes;

namespace JasnostCaptureCore;

/// <summary>The five capture modalities whose authorization and availability are canonical evidence.</summary>
public enum Capability
{
    /// <summary>Pointer (mouse) event capture.</summary>
    PointerCapture,

    /// <summary>Keyboard event capture.</summary>
    KeyboardCapture,

    /// <summary>Accessibility / UI Automation context resolution for click targets.</summary>
    AccessibilityContext,

    /// <summary>Screenshot capture.</summary>
    ScreenCapture,

    /// <summary>Microphone capture for narration.</summary>
    AudioCapture,
}

/// <summary>Maps <see cref="Capability"/> onto the contract tokens of the payload schema.</summary>
public static class CapabilityExtensions
{
    /// <summary>The schema token for a capability, e.g. <c>pointer.capture</c>.</summary>
    /// <exception cref="ArgumentOutOfRangeException">The value is not a declared capability.</exception>
    public static string Token(this Capability capability) => capability switch
    {
        Capability.PointerCapture => "pointer.capture",
        Capability.KeyboardCapture => "keyboard.capture",
        Capability.AccessibilityContext => "accessibility.context",
        Capability.ScreenCapture => "screen.capture",
        Capability.AudioCapture => "audio.capture",
        _ => throw new ArgumentOutOfRangeException(nameof(capability), capability, "unknown capability"),
    };
}

/// <summary>Authorization tokens of <c>capture-capability-observation.schema.json</c>.</summary>
public static class CapabilityAuthorization
{
    /// <summary>The OS granted the permission.</summary>
    public const string Granted = "granted";

    /// <summary>The OS refused the permission.</summary>
    public const string Denied = "denied";

    /// <summary>The permission has never been requested.</summary>
    public const string NotDetermined = "not_determined";

    /// <summary>Every legal authorization token.</summary>
    public static readonly IReadOnlyList<string> All = new[] { Granted, Denied, NotDetermined };
}

/// <summary>Availability tokens of <c>capture-capability-observation.schema.json</c>.</summary>
public static class CapabilityAvailability
{
    /// <summary>The modality is currently supplying evidence.</summary>
    public const string Available = "available";

    /// <summary>The modality is not supplying evidence right now.</summary>
    public const string Unavailable = "unavailable";

    /// <summary>Every legal availability token.</summary>
    public static readonly IReadOnlyList<string> All = new[] { Available, Unavailable };
}

/// <summary>Transition tokens of <c>capture-capability-observation.schema.json</c>.</summary>
public static class CapabilityTransition
{
    /// <summary>First observation for a capability within a capture.</summary>
    public const string Initial = "initial";

    /// <summary>Permission moved from not-determined to granted and available.</summary>
    public const string Granted = "granted";

    /// <summary>Permission moved away from granted.</summary>
    public const string Revoked = "revoked";

    /// <summary>The modality became available again.</summary>
    public const string Restored = "restored";

    /// <summary>The OS suppressed a granted modality (hook timeout, secure input).</summary>
    public const string TemporarilyDisabled = "temporarily_disabled";

    /// <summary>A granted modality stopped supplying evidence because its source failed.</summary>
    public const string SourceFailed = "source_failed";

    /// <summary>Any other change of the (authorization, availability) pair.</summary>
    public const string AuthorizationChanged = "authorization_changed";

    /// <summary>Every legal transition token.</summary>
    public static readonly IReadOnlyList<string> All = new[]
    {
        Initial, Granted, Revoked, Restored, TemporarilyDisabled, SourceFailed, AuthorizationChanged,
    };
}

/// <summary>Reason tokens of <c>capture-capability-observation.schema.json</c>.</summary>
public static class CapabilityReason
{
    /// <summary>The permission is granted.</summary>
    public const string PermissionGranted = "permission_granted";

    /// <summary>The permission is denied.</summary>
    public const string PermissionDenied = "permission_denied";

    /// <summary>The permission has not been requested yet.</summary>
    public const string PermissionNotDetermined = "permission_not_determined";

    /// <summary>The OS unhooked the input tap because a callback exceeded its budget.</summary>
    public const string EventTapTimeout = "event_tap_timeout";

    /// <summary>The OS suppressed the input tap because of user input state.</summary>
    public const string EventTapUserInput = "event_tap_user_input";

    /// <summary>A secure input field is active, so keystrokes are not observable.</summary>
    public const string SecureInput = "secure_input";

    /// <summary>The capture source itself failed.</summary>
    public const string SourceFailure = "source_failure";

    /// <summary>The capture source recovered.</summary>
    public const string SourceRecovered = "source_recovered";

    /// <summary>The modality is intentionally switched off by the frozen capture policy.</summary>
    public const string CaptureDisabledByPolicy = "capture_disabled_by_policy";

    /// <summary>Every legal reason token.</summary>
    public static readonly IReadOnlyList<string> All = new[]
    {
        PermissionGranted, PermissionDenied, PermissionNotDetermined, EventTapTimeout,
        EventTapUserInput, SecureInput, SourceFailure, SourceRecovered, CaptureDisabledByPolicy,
    };

    /// <summary>Reasons that describe a temporary OS suppression rather than a source failure.</summary>
    public static readonly IReadOnlyList<string> Suppression = new[]
    {
        EventTapTimeout, EventTapUserInput, SecureInput,
    };
}

/// <summary>
/// One raw poll of an OS capability, as the host observes it. Samples are cheap and repetitive; the
/// reducer decides which of them become canonical evidence.
/// </summary>
/// <param name="Capability">The modality that was polled.</param>
/// <param name="Authorization">A <see cref="CapabilityAuthorization"/> token.</param>
/// <param name="Availability">A <see cref="CapabilityAvailability"/> token.</param>
/// <param name="Reason">A <see cref="CapabilityReason"/> token explaining the sampled state.</param>
/// <param name="Detail">Optional free text; trimmed, non-empty, at most 512 characters.</param>
public sealed record CapabilitySample(
    Capability Capability,
    string Authorization,
    string Availability,
    string Reason,
    string? Detail = null);

/// <summary>
/// A canonical, source-neutral capability observation. Instances are produced by
/// <see cref="CapabilityStateMachine.Observe"/> and always satisfy
/// <c>capture-capability-observation.schema.json</c> v1.
/// </summary>
/// <param name="Capability">The observed modality.</param>
/// <param name="AuthorizationStatus">A <see cref="CapabilityAuthorization"/> token.</param>
/// <param name="Availability">A <see cref="CapabilityAvailability"/> token.</param>
/// <param name="Transition">A <see cref="CapabilityTransition"/> token.</param>
/// <param name="Reason">A <see cref="CapabilityReason"/> token.</param>
/// <param name="ObservedAt">RFC 3339 instant at which the state was observed.</param>
/// <param name="PreviousAuthorization">Previous authorization; null iff the transition is initial.</param>
/// <param name="PreviousAvailability">Previous availability; null iff the transition is initial.</param>
/// <param name="Detail">Optional free text; emitted trimmed.</param>
public sealed record CapabilityObservation(
    Capability Capability,
    string AuthorizationStatus,
    string Availability,
    string Transition,
    string Reason,
    string ObservedAt,
    string? PreviousAuthorization = null,
    string? PreviousAvailability = null,
    string? Detail = null)
{
    /// <summary>The only payload schema version this build emits or accepts.</summary>
    public const int SchemaVersion = 1;

    /// <summary>Archive record type carrying this payload.</summary>
    public const string RecordType = "jazz.capture-capability-observation";

    /// <summary>Payload schema id of this observation.</summary>
    public const string PayloadSchema =
        "https://jasnost.dev/schema/capture-capability-observation.schema.json";

    /// <summary>Longest <c>detail</c> the schema accepts.</summary>
    public const int MaxDetailLength = 512;

    /// <summary>
    /// Serializes the observation into the archive payload. Absent optional fields are omitted
    /// entirely — never written as JSON <c>null</c> — and <c>detail</c> is emitted trimmed so the
    /// bytes always satisfy the schema's <c>minLength</c>/<c>maxLength</c> bounds.
    /// </summary>
    /// <exception cref="InvalidOperationException">The observation violates the schema.</exception>
    public JsonObject ToPayload()
    {
        Validate();
        var payload = new JsonObject
        {
            ["schemaVersion"] = SchemaVersion,
            ["capability"] = Capability.Token(),
            ["authorizationStatus"] = AuthorizationStatus,
            ["availability"] = Availability,
            ["transition"] = Transition,
            ["reason"] = Reason,
            ["observedAt"] = ObservedAt,
        };
        if (PreviousAuthorization is not null)
        {
            payload["previousAuthorization"] = PreviousAuthorization;
        }

        if (PreviousAvailability is not null)
        {
            payload["previousAvailability"] = PreviousAvailability;
        }

        if (Detail is not null)
        {
            payload["detail"] = Detail.Trim();
        }

        return payload;
    }

    /// <summary>
    /// Enforces every conditional invariant of the payload schema: the legal (authorization,
    /// availability, reason) triple per transition, the previous-pair presence rule, and the
    /// <c>detail</c> bounds.
    /// </summary>
    /// <exception cref="InvalidOperationException">The observation violates the schema.</exception>
    public void Validate()
    {
        RequireToken("authorizationStatus", AuthorizationStatus, CapabilityAuthorization.All);
        RequireToken("availability", Availability, CapabilityAvailability.All);
        RequireToken("transition", Transition, CapabilityTransition.All);
        RequireToken("reason", Reason, CapabilityReason.All);
        _ = Capability.Token();

        if (Timestamps.UnixNanos(ObservedAt) is null)
        {
            throw new InvalidOperationException(
                $"captureCapability.observedAt is not an RFC 3339 instant: '{ObservedAt}'");
        }

        // authorization != granted implies the modality cannot be supplying evidence.
        if (AuthorizationStatus != CapabilityAuthorization.Granted
            && Availability != CapabilityAvailability.Unavailable)
        {
            throw new InvalidOperationException(
                "captureCapability.state: authorization '" + AuthorizationStatus
                    + "' requires availability 'unavailable'");
        }

        ValidatePreviousPair();
        ValidateDetail();
        ValidateTransitionTriple();
    }

    private void ValidatePreviousPair()
    {
        var hasAuthorization = PreviousAuthorization is not null;
        var hasAvailability = PreviousAvailability is not null;
        if (hasAuthorization != hasAvailability)
        {
            throw new InvalidOperationException(
                "captureCapability.previousState: previousAuthorization and previousAvailability "
                    + "must both be present or both absent");
        }

        var isInitial = Transition == CapabilityTransition.Initial;
        if (isInitial && hasAuthorization)
        {
            throw new InvalidOperationException(
                "captureCapability.previousState must be absent for transition 'initial'");
        }

        if (!isInitial && !hasAuthorization)
        {
            throw new InvalidOperationException(
                $"captureCapability.previousState is required for transition '{Transition}'");
        }

        if (!hasAuthorization)
        {
            return;
        }

        RequireToken("previousAuthorization", PreviousAuthorization!, CapabilityAuthorization.All);
        RequireToken("previousAvailability", PreviousAvailability!, CapabilityAvailability.All);
        if (PreviousAuthorization == AuthorizationStatus && PreviousAvailability == Availability)
        {
            throw new InvalidOperationException(
                "captureCapability.previousState must differ from the observed state");
        }
    }

    private void ValidateDetail()
    {
        if (Detail is null)
        {
            return;
        }

        var trimmed = Detail.Trim();
        if (trimmed.Length == 0 || trimmed.Length > MaxDetailLength)
        {
            throw new InvalidOperationException(
                "captureCapability.detail must be non-empty after trimming and at most "
                    + $"{MaxDetailLength} characters");
        }
    }

    private void ValidateTransitionTriple()
    {
        var legal = Transition switch
        {
            CapabilityTransition.Initial =>
                IsTriple(CapabilityAuthorization.Granted, CapabilityAvailability.Available, CapabilityReason.PermissionGranted)
                || IsTriple(CapabilityAuthorization.Granted, CapabilityAvailability.Unavailable, CapabilityReason.SourceFailure, CapabilityReason.CaptureDisabledByPolicy)
                || IsTriple(CapabilityAuthorization.Denied, CapabilityAvailability.Unavailable, CapabilityReason.PermissionDenied)
                || IsTriple(CapabilityAuthorization.NotDetermined, CapabilityAvailability.Unavailable, CapabilityReason.PermissionNotDetermined),
            CapabilityTransition.Granted =>
                IsTriple(CapabilityAuthorization.Granted, CapabilityAvailability.Available, CapabilityReason.PermissionGranted),
            CapabilityTransition.Restored =>
                IsTriple(CapabilityAuthorization.Granted, CapabilityAvailability.Available, CapabilityReason.PermissionGranted, CapabilityReason.SourceRecovered),
            CapabilityTransition.Revoked =>
                IsTriple(CapabilityAuthorization.Denied, CapabilityAvailability.Unavailable, CapabilityReason.PermissionDenied)
                || IsTriple(CapabilityAuthorization.NotDetermined, CapabilityAvailability.Unavailable, CapabilityReason.PermissionNotDetermined),
            CapabilityTransition.TemporarilyDisabled =>
                IsTriple(CapabilityAuthorization.Granted, CapabilityAvailability.Unavailable, CapabilityReason.EventTapTimeout, CapabilityReason.EventTapUserInput, CapabilityReason.SecureInput),
            CapabilityTransition.SourceFailed =>
                IsTriple(CapabilityAuthorization.Granted, CapabilityAvailability.Unavailable, CapabilityReason.SourceFailure),
            CapabilityTransition.AuthorizationChanged =>
                IsTriple(CapabilityAuthorization.Denied, CapabilityAvailability.Unavailable, CapabilityReason.PermissionDenied)
                || IsTriple(CapabilityAuthorization.NotDetermined, CapabilityAvailability.Unavailable, CapabilityReason.PermissionNotDetermined)
                || IsTriple(CapabilityAuthorization.Granted, CapabilityAvailability.Unavailable, CapabilityReason.SourceFailure, CapabilityReason.CaptureDisabledByPolicy),
            _ => false,
        };

        if (!legal)
        {
            throw new InvalidOperationException(
                $"captureCapability.transition '{Transition}' is illegal for "
                    + $"({AuthorizationStatus}, {Availability}, {Reason})");
        }
    }

    private bool IsTriple(string authorization, string availability, params string[] reasons)
        => AuthorizationStatus == authorization
            && Availability == availability
            && Array.IndexOf(reasons, Reason) >= 0;

    private static void RequireToken(string field, string value, IReadOnlyList<string> allowed)
    {
        for (var index = 0; index < allowed.Count; index++)
        {
            if (string.Equals(allowed[index], value, StringComparison.Ordinal))
            {
                return;
            }
        }

        throw new InvalidOperationException(
            $"captureCapability.{field} '{value}' is not a contract token");
    }
}

/// <summary>
/// Pure, per-capture transition reducer. Repeated permission polls are silent; only a changed
/// (authorization, availability) pair becomes a canonical observation, so the archive records state
/// changes rather than the polling cadence.
/// </summary>
/// <remarks>
/// The accepted state advances only after the derived observation has validated: a sample that
/// would produce an illegal record is rejected outright and stays retryable instead of turning the
/// next identical poll into silence.
/// </remarks>
public sealed class CapabilityStateMachine
{
    private readonly Dictionary<Capability, CapabilityState> _states = new();

    /// <summary>Forgets all accepted state; the next sample of every capability is initial again.</summary>
    public void Reset() => _states.Clear();

    /// <summary>
    /// Reduces one OS sample. Returns <see langword="null"/> when the (authorization, availability)
    /// pair is unchanged for that capability, otherwise the canonical observation to persist.
    /// </summary>
    /// <param name="sample">The polled capability state.</param>
    /// <param name="observedAt">RFC 3339 instant at which the sample was taken.</param>
    /// <exception cref="InvalidOperationException">
    /// The sample carries an unknown token, an illegal (authorization, availability) pair, an
    /// unparseable <paramref name="observedAt"/>, an out-of-bounds detail, or a reason that is
    /// illegal for the derived transition.
    /// </exception>
    public CapabilityObservation? Observe(CapabilitySample sample, string observedAt)
    {
        ArgumentNullException.ThrowIfNull(sample);

        var current = new CapabilityState(sample.Authorization, sample.Availability);
        ValidateSampleState(current);

        var hasPrevious = _states.TryGetValue(sample.Capability, out var previous);
        if (hasPrevious && previous == current)
        {
            return null;
        }

        var observation = new CapabilityObservation(
            sample.Capability,
            current.Authorization,
            current.Availability,
            DeriveTransition(hasPrevious ? previous : (CapabilityState?)null, current, sample.Reason),
            sample.Reason,
            observedAt,
            hasPrevious ? previous.Authorization : null,
            hasPrevious ? previous.Availability : null,
            sample.Detail);
        observation.Validate();

        _states[sample.Capability] = current;
        return observation;
    }

    /// <summary>Derivation table of ANNEX-HOST section 5, evaluated top to bottom.</summary>
    private static string DeriveTransition(
        CapabilityState? previous,
        CapabilityState current,
        string reason)
    {
        if (previous is not { } before)
        {
            return CapabilityTransition.Initial;
        }

        var wasGranted = before.Authorization == CapabilityAuthorization.Granted;
        var isGranted = current.Authorization == CapabilityAuthorization.Granted;

        if (wasGranted && !isGranted)
        {
            return CapabilityTransition.Revoked;
        }

        if (!wasGranted && isGranted && current.Availability == CapabilityAvailability.Available)
        {
            // A permission that was never requested is newly granted; a denied one is restored.
            return before.Authorization == CapabilityAuthorization.NotDetermined
                ? CapabilityTransition.Granted
                : CapabilityTransition.Restored;
        }

        if (before.Availability == CapabilityAvailability.Available
            && current.Availability == CapabilityAvailability.Unavailable)
        {
            return CapabilityReason.Suppression.Contains(reason)
                ? CapabilityTransition.TemporarilyDisabled
                : CapabilityTransition.SourceFailed;
        }

        if (before.Availability == CapabilityAvailability.Unavailable
            && current.Availability == CapabilityAvailability.Available)
        {
            return CapabilityTransition.Restored;
        }

        return CapabilityTransition.AuthorizationChanged;
    }

    private static void ValidateSampleState(CapabilityState state)
    {
        RequireToken("authorization", state.Authorization, CapabilityAuthorization.All);
        RequireToken("availability", state.Availability, CapabilityAvailability.All);
        if (state.Authorization != CapabilityAuthorization.Granted
            && state.Availability != CapabilityAvailability.Unavailable)
        {
            throw new InvalidOperationException(
                "captureCapability.sample: authorization '" + state.Authorization
                    + "' requires availability 'unavailable'");
        }
    }

    private static void RequireToken(string field, string value, IReadOnlyList<string> allowed)
    {
        for (var index = 0; index < allowed.Count; index++)
        {
            if (string.Equals(allowed[index], value, StringComparison.Ordinal))
            {
                return;
            }
        }

        throw new InvalidOperationException(
            $"captureCapability.{field} '{value}' is not a contract token");
    }

    private readonly record struct CapabilityState(string Authorization, string Availability);
}
