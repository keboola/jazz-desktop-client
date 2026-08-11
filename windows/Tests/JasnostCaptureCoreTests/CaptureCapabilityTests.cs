using System.Text.Json.Nodes;
using JasnostCaptureCore;

namespace JasnostCaptureCoreTests;

/// <summary>
/// Contract tests for the capture capability reducer. The values asserted here are literals from
/// <c>contract/schema/capture-capability-observation.schema.json</c> on purpose: the schema is the
/// specification, so the tests must not import the production constants that they verify.
/// </summary>
public class CaptureCapabilityTests
{
    private const string ObservedAt = "2026-06-13T10:00:00.000Z";
    private const string LaterObservedAt = "2026-06-13T10:00:03.000Z";
    private const string LatestObservedAt = "2026-06-13T10:00:06.000Z";

    private static CapabilitySample Sample(
        Capability capability,
        string authorization,
        string availability,
        string reason,
        string? detail = null)
        => new(capability, authorization, availability, reason, detail);

    private static CapabilitySample PointerGranted()
        => Sample(Capability.PointerCapture, "granted", "available", "permission_granted");

    // ---------------------------------------------------------------- tokens

    [Theory]
    [InlineData(Capability.PointerCapture, "pointer.capture")]
    [InlineData(Capability.KeyboardCapture, "keyboard.capture")]
    [InlineData(Capability.AccessibilityContext, "accessibility.context")]
    [InlineData(Capability.ScreenCapture, "screen.capture")]
    [InlineData(Capability.AudioCapture, "audio.capture")]
    public void Token_MapsEachCapabilityToItsContractLiteral(Capability capability, string token)
    {
        Assert.Equal(token, capability.Token());
    }

    // ------------------------------------------------------------ transitions

    [Fact]
    public void Observe_FirstSample_EmitsInitialWithoutPreviousState()
    {
        var machine = new CapabilityStateMachine();

        var observation = machine.Observe(PointerGranted(), ObservedAt);

        Assert.NotNull(observation);
        Assert.Equal(Capability.PointerCapture, observation!.Capability);
        Assert.Equal("granted", observation.AuthorizationStatus);
        Assert.Equal("available", observation.Availability);
        Assert.Equal("initial", observation.Transition);
        Assert.Equal("permission_granted", observation.Reason);
        Assert.Equal(ObservedAt, observation.ObservedAt);
        Assert.Null(observation.PreviousAuthorization);
        Assert.Null(observation.PreviousAvailability);
        Assert.Null(observation.Detail);
    }

    [Fact]
    public void Observe_RepeatedIdenticalPoll_ReturnsNull()
    {
        var machine = new CapabilityStateMachine();

        Assert.NotNull(machine.Observe(PointerGranted(), ObservedAt));
        Assert.Null(machine.Observe(PointerGranted(), LaterObservedAt));
        Assert.Null(machine.Observe(PointerGranted(), LatestObservedAt));
    }

    [Fact]
    public void Observe_UnchangedStateWithDifferentReason_ReturnsNull()
    {
        var machine = new CapabilityStateMachine();
        machine.Observe(
            Sample(Capability.ScreenCapture, "granted", "unavailable", "source_failure"),
            ObservedAt);

        // Only the (authorization, availability) pair is canonical evidence; a re-worded reason
        // for the same state stays silent.
        var repeat = machine.Observe(
            Sample(
                Capability.ScreenCapture,
                "granted",
                "unavailable",
                "capture_disabled_by_policy"),
            LaterObservedAt);

        Assert.Null(repeat);
    }

    [Fact]
    public void Observe_GrantedThenDenied_EmitsRevokedCarryingPreviousPair()
    {
        var machine = new CapabilityStateMachine();
        machine.Observe(PointerGranted(), ObservedAt);

        var observation = machine.Observe(
            Sample(Capability.PointerCapture, "denied", "unavailable", "permission_denied"),
            LaterObservedAt);

        Assert.NotNull(observation);
        Assert.Equal("revoked", observation!.Transition);
        Assert.Equal("denied", observation.AuthorizationStatus);
        Assert.Equal("unavailable", observation.Availability);
        Assert.Equal("permission_denied", observation.Reason);
        Assert.Equal("granted", observation.PreviousAuthorization);
        Assert.Equal("available", observation.PreviousAvailability);
    }

    [Fact]
    public void Observe_SourceFailureThenRecovery_EmitsSourceFailedThenRestored()
    {
        var machine = new CapabilityStateMachine();
        machine.Observe(
            Sample(Capability.AccessibilityContext, "granted", "available", "permission_granted"),
            ObservedAt);

        var failed = machine.Observe(
            Sample(
                Capability.AccessibilityContext,
                "granted",
                "unavailable",
                "source_failure",
                "resolver worker crashed"),
            LaterObservedAt);

        var restored = machine.Observe(
            Sample(
                Capability.AccessibilityContext,
                "granted",
                "available",
                "source_recovered",
                "resolver worker restarted"),
            LatestObservedAt);

        Assert.NotNull(failed);
        Assert.Equal("source_failed", failed!.Transition);
        Assert.Equal("source_failure", failed.Reason);
        Assert.Equal("resolver worker crashed", failed.Detail);
        Assert.Equal("available", failed.PreviousAvailability);

        Assert.NotNull(restored);
        Assert.Equal("restored", restored!.Transition);
        Assert.Equal("source_recovered", restored.Reason);
        Assert.Equal("granted", restored.AuthorizationStatus);
        Assert.Equal("available", restored.Availability);
        Assert.Equal("unavailable", restored.PreviousAvailability);
    }

    [Fact]
    public void Observe_HookSuppression_EmitsTemporarilyDisabledNotSourceFailed()
    {
        var machine = new CapabilityStateMachine();
        machine.Observe(
            Sample(Capability.KeyboardCapture, "granted", "available", "permission_granted"),
            ObservedAt);

        var suppressed = machine.Observe(
            Sample(Capability.KeyboardCapture, "granted", "unavailable", "event_tap_timeout"),
            LaterObservedAt);

        Assert.NotNull(suppressed);
        Assert.Equal("temporarily_disabled", suppressed!.Transition);
    }

    [Theory]
    [InlineData("event_tap_timeout")]
    [InlineData("event_tap_user_input")]
    [InlineData("secure_input")]
    public void Observe_EachSuppressionReason_IsTemporarilyDisabled(string reason)
    {
        var machine = new CapabilityStateMachine();
        machine.Observe(PointerGranted(), ObservedAt);

        var suppressed = machine.Observe(
            Sample(Capability.PointerCapture, "granted", "unavailable", reason),
            LaterObservedAt);

        Assert.Equal("temporarily_disabled", suppressed!.Transition);
    }

    [Fact]
    public void Observe_NotDeterminedThenGranted_EmitsGranted()
    {
        var machine = new CapabilityStateMachine();
        machine.Observe(
            Sample(
                Capability.PointerCapture,
                "not_determined",
                "unavailable",
                "permission_not_determined"),
            ObservedAt);

        var granted = machine.Observe(PointerGranted(), LaterObservedAt);

        Assert.NotNull(granted);
        Assert.Equal("granted", granted!.Transition);
        Assert.Equal("permission_granted", granted.Reason);
        Assert.Equal("not_determined", granted.PreviousAuthorization);
        Assert.Equal("unavailable", granted.PreviousAvailability);
    }

    [Fact]
    public void Observe_DeniedThenGranted_EmitsRestored()
    {
        var machine = new CapabilityStateMachine();
        machine.Observe(
            Sample(Capability.PointerCapture, "denied", "unavailable", "permission_denied"),
            ObservedAt);

        var restored = machine.Observe(PointerGranted(), LaterObservedAt);

        Assert.NotNull(restored);
        Assert.Equal("restored", restored!.Transition);
        Assert.Equal("permission_granted", restored.Reason);
        Assert.Equal("denied", restored.PreviousAuthorization);
    }

    [Fact]
    public void Observe_PolicyDisabledModality_EmitsInitialDisabledByPolicy()
    {
        var machine = new CapabilityStateMachine();

        var observation = machine.Observe(
            Sample(
                Capability.ScreenCapture,
                "granted",
                "unavailable",
                "capture_disabled_by_policy",
                "screenshots disabled in MVP"),
            ObservedAt);

        Assert.NotNull(observation);
        Assert.Equal("initial", observation!.Transition);
        Assert.Equal("granted", observation.AuthorizationStatus);
        Assert.Equal("unavailable", observation.Availability);
        Assert.Equal("capture_disabled_by_policy", observation.Reason);
        Assert.Equal("screenshots disabled in MVP", observation.Detail);
        Assert.Null(observation.PreviousAuthorization);
    }

    [Fact]
    public void Observe_GrantedThenPolicyDisabled_EmitsAuthorizationChanged()
    {
        var machine = new CapabilityStateMachine();
        machine.Observe(
            Sample(Capability.AudioCapture, "not_determined", "unavailable", "permission_not_determined"),
            ObservedAt);

        // Authorization becomes granted while the modality stays off: neither `granted` nor
        // `restored` is legal (both demand availability == available).
        var changed = machine.Observe(
            Sample(
                Capability.AudioCapture,
                "granted",
                "unavailable",
                "capture_disabled_by_policy"),
            LaterObservedAt);

        Assert.NotNull(changed);
        Assert.Equal("authorization_changed", changed!.Transition);
        Assert.Equal("not_determined", changed.PreviousAuthorization);
        Assert.Equal("unavailable", changed.PreviousAvailability);
    }

    [Fact]
    public void Observe_DeniedThenNotDetermined_EmitsAuthorizationChanged()
    {
        var machine = new CapabilityStateMachine();
        machine.Observe(
            Sample(Capability.ScreenCapture, "denied", "unavailable", "permission_denied"),
            ObservedAt);

        var changed = machine.Observe(
            Sample(
                Capability.ScreenCapture,
                "not_determined",
                "unavailable",
                "permission_not_determined"),
            LaterObservedAt);

        Assert.NotNull(changed);
        Assert.Equal("authorization_changed", changed!.Transition);
    }

    [Fact]
    public void Observe_TracksEachCapabilityIndependently()
    {
        var machine = new CapabilityStateMachine();
        machine.Observe(PointerGranted(), ObservedAt);

        var keyboard = machine.Observe(
            Sample(Capability.KeyboardCapture, "granted", "available", "permission_granted"),
            LaterObservedAt);

        Assert.NotNull(keyboard);
        Assert.Equal("initial", keyboard!.Transition);
        Assert.Null(machine.Observe(PointerGranted(), LatestObservedAt));
    }

    [Fact]
    public void Reset_ForgetsAllStateSoNextSampleIsInitialAgain()
    {
        var machine = new CapabilityStateMachine();
        machine.Observe(PointerGranted(), ObservedAt);

        machine.Reset();

        var observation = machine.Observe(PointerGranted(), LaterObservedAt);
        Assert.NotNull(observation);
        Assert.Equal("initial", observation!.Transition);
    }

    // --------------------------------------------------------------- payload

    [Fact]
    public void ToPayload_InitialObservation_HasExactlyTheRequiredKeys()
    {
        var machine = new CapabilityStateMachine();
        var payload = machine.Observe(PointerGranted(), ObservedAt)!.ToPayload();

        Assert.Equal(
            new[]
            {
                "schemaVersion",
                "capability",
                "authorizationStatus",
                "availability",
                "transition",
                "reason",
                "observedAt",
            },
            payload.Select(pair => pair.Key).ToArray());
        Assert.Equal(1, payload["schemaVersion"]!.GetValue<int>());
        Assert.Equal("pointer.capture", payload["capability"]!.GetValue<string>());
        Assert.Equal("granted", payload["authorizationStatus"]!.GetValue<string>());
        Assert.Equal("available", payload["availability"]!.GetValue<string>());
        Assert.Equal("initial", payload["transition"]!.GetValue<string>());
        Assert.Equal("permission_granted", payload["reason"]!.GetValue<string>());
        Assert.Equal(ObservedAt, payload["observedAt"]!.GetValue<string>());
    }

    [Fact]
    public void ToPayload_SchemaVersion_IsAJsonNumberNotAString()
    {
        var machine = new CapabilityStateMachine();
        var payload = machine.Observe(PointerGranted(), ObservedAt)!.ToPayload();

        Assert.Contains("\"schemaVersion\":1", payload.ToJsonString());
    }

    [Fact]
    public void ToPayload_NonInitialObservation_CarriesBothPreviousKeysAndDetail()
    {
        var machine = new CapabilityStateMachine();
        machine.Observe(PointerGranted(), ObservedAt);
        var payload = machine
            .Observe(
                Sample(
                    Capability.PointerCapture,
                    "granted",
                    "unavailable",
                    "event_tap_timeout",
                    "event tap re-armed 1"),
                LaterObservedAt)!
            .ToPayload();

        Assert.Equal(
            new[]
            {
                "schemaVersion",
                "capability",
                "authorizationStatus",
                "availability",
                "transition",
                "reason",
                "observedAt",
                "previousAuthorization",
                "previousAvailability",
                "detail",
            },
            payload.Select(pair => pair.Key).ToArray());
        Assert.Equal("granted", payload["previousAuthorization"]!.GetValue<string>());
        Assert.Equal("available", payload["previousAvailability"]!.GetValue<string>());
        Assert.Equal("event tap re-armed 1", payload["detail"]!.GetValue<string>());
    }

    [Fact]
    public void ToPayload_TrimsDetailAndNeverEmitsAnAbsentKeyAsNull()
    {
        var machine = new CapabilityStateMachine();
        var payload = machine
            .Observe(
                Sample(
                    Capability.AudioCapture,
                    "granted",
                    "unavailable",
                    "capture_disabled_by_policy",
                    "  narration is out of MVP scope \n"),
                ObservedAt)!
            .ToPayload();

        Assert.Equal("narration is out of MVP scope", payload["detail"]!.GetValue<string>());
        Assert.False(payload.ContainsKey("previousAuthorization"));
        Assert.False(payload.ContainsKey("previousAvailability"));
    }

    [Fact]
    public void ToPayload_MatchesTheContractSchemaEnumsAndRequiredKeys()
    {
        var schema = LoadSchema();
        var required = schema["required"]!.AsArray()
            .Select(node => node!.GetValue<string>())
            .ToArray();
        var allowed = schema["properties"]!.AsObject()
            .Select(pair => pair.Key)
            .ToHashSet(StringComparer.Ordinal);

        var machine = new CapabilityStateMachine();
        machine.Observe(
            Sample(Capability.ScreenCapture, "granted", "available", "permission_granted"),
            ObservedAt);
        var payload = machine
            .Observe(
                Sample(Capability.ScreenCapture, "denied", "unavailable", "permission_denied"),
                LaterObservedAt)!
            .ToPayload();

        Assert.Equal(1, schema["properties"]!["schemaVersion"]!["const"]!.GetValue<int>());
        foreach (var key in required)
        {
            Assert.True(payload.ContainsKey(key), $"payload is missing required key '{key}'");
        }

        foreach (var pair in payload)
        {
            Assert.True(allowed.Contains(pair.Key), $"payload has undeclared key '{pair.Key}'");
        }

        AssertInSchemaEnum(schema, "capability", payload);
        AssertInSchemaEnum(schema, "authorizationStatus", payload);
        AssertInSchemaEnum(schema, "availability", payload);
        AssertInSchemaEnum(schema, "transition", payload);
        AssertInSchemaEnum(schema, "reason", payload);
        AssertInSchemaEnum(schema, "previousAuthorization", payload);
        AssertInSchemaEnum(schema, "previousAvailability", payload);
    }

    // ------------------------------------------------------- illegal triples

    [Theory]
    [InlineData("denied", "available", "permission_denied")]
    [InlineData("not_determined", "available", "permission_not_determined")]
    public void Observe_AuthorizationNotGrantedWithAvailableModality_Throws(
        string authorization,
        string availability,
        string reason)
    {
        var machine = new CapabilityStateMachine();

        Assert.Throws<InvalidOperationException>(
            () => machine.Observe(
                Sample(Capability.PointerCapture, authorization, availability, reason),
                ObservedAt));
    }

    [Theory]
    [InlineData("Granted", "available", "permission_granted")]
    [InlineData("unknown", "available", "permission_granted")]
    [InlineData("granted", "AVAILABLE", "permission_granted")]
    [InlineData("granted", "available", "because_reasons")]
    [InlineData("", "", "")]
    public void Observe_UnknownEnumToken_Throws(
        string authorization,
        string availability,
        string reason)
    {
        var machine = new CapabilityStateMachine();

        Assert.Throws<InvalidOperationException>(
            () => machine.Observe(
                Sample(Capability.PointerCapture, authorization, availability, reason),
                ObservedAt));
    }

    [Theory]
    // initial must be one of the four legal triples.
    [InlineData("granted", "unavailable", "event_tap_timeout")]
    [InlineData("granted", "unavailable", "source_recovered")]
    [InlineData("denied", "unavailable", "permission_not_determined")]
    [InlineData("not_determined", "unavailable", "source_failure")]
    public void Observe_InitialWithIllegalReason_Throws(
        string authorization,
        string availability,
        string reason)
    {
        var machine = new CapabilityStateMachine();

        Assert.Throws<InvalidOperationException>(
            () => machine.Observe(
                Sample(Capability.ScreenCapture, authorization, availability, reason),
                ObservedAt));
    }

    [Fact]
    public void Observe_RevokedWithGrantedReason_Throws()
    {
        var machine = new CapabilityStateMachine();
        machine.Observe(PointerGranted(), ObservedAt);

        Assert.Throws<InvalidOperationException>(
            () => machine.Observe(
                Sample(Capability.PointerCapture, "denied", "unavailable", "source_failure"),
                LaterObservedAt));
    }

    [Fact]
    public void Observe_SourceFailedWithSuppressionReason_IsDerivedAsTemporarilyDisabledInstead()
    {
        // Guard against a derivation that would emit `source_failed` with a suppression reason,
        // which the schema forbids.
        var machine = new CapabilityStateMachine();
        machine.Observe(PointerGranted(), ObservedAt);

        var observation = machine.Observe(
            Sample(Capability.PointerCapture, "granted", "unavailable", "secure_input"),
            LaterObservedAt);

        Assert.Equal("temporarily_disabled", observation!.Transition);
    }

    [Fact]
    public void Observe_IllegalDerivedTriple_LeavesPreviousStateUntouched()
    {
        var machine = new CapabilityStateMachine();
        machine.Observe(PointerGranted(), ObservedAt);

        // granted+available -> granted+unavailable derives `temporarily_disabled` /
        // `source_failed`; `permission_granted` is legal for neither.
        Assert.Throws<InvalidOperationException>(
            () => machine.Observe(
                Sample(Capability.PointerCapture, "granted", "unavailable", "permission_granted"),
                LaterObservedAt));

        // The rejected sample must not have advanced the accepted state.
        Assert.Null(machine.Observe(PointerGranted(), LatestObservedAt));
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("\t\n")]
    public void Observe_BlankDetail_Throws(string detail)
    {
        var machine = new CapabilityStateMachine();

        Assert.Throws<InvalidOperationException>(
            () => machine.Observe(
                Sample(
                    Capability.PointerCapture,
                    "granted",
                    "available",
                    "permission_granted",
                    detail),
                ObservedAt));
    }

    [Fact]
    public void Observe_DetailLongerThan512Characters_Throws()
    {
        var machine = new CapabilityStateMachine();

        Assert.Throws<InvalidOperationException>(
            () => machine.Observe(
                Sample(
                    Capability.PointerCapture,
                    "granted",
                    "available",
                    "permission_granted",
                    new string('x', 513)),
                ObservedAt));
    }

    [Fact]
    public void Observe_DetailOfExactly512Characters_IsAccepted()
    {
        var machine = new CapabilityStateMachine();

        var observation = machine.Observe(
            Sample(
                Capability.PointerCapture,
                "granted",
                "available",
                "permission_granted",
                new string('x', 512)),
            ObservedAt);

        Assert.Equal(512, observation!.Detail!.Length);
    }

    [Theory]
    [InlineData("")]
    [InlineData("not-a-date")]
    [InlineData("2026-06-13")]
    public void Observe_UnparseableObservedAt_Throws(string observedAt)
    {
        var machine = new CapabilityStateMachine();

        Assert.Throws<InvalidOperationException>(
            () => machine.Observe(PointerGranted(), observedAt));
    }

    // ---------------------------------------------------------------- helpers

    private static void AssertInSchemaEnum(JsonObject schema, string key, JsonObject payload)
    {
        if (!payload.ContainsKey(key))
        {
            return;
        }

        var allowed = schema["properties"]![key]!["enum"]!.AsArray()
            .Select(node => node!.GetValue<string>())
            .ToArray();
        Assert.Contains(payload[key]!.GetValue<string>(), allowed);
    }

    private static JsonObject LoadSchema()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        for (var depth = 0; depth < 8 && directory is not null; depth++)
        {
            var candidate = Path.Combine(
                directory.FullName,
                "contract",
                "schema",
                "capture-capability-observation.schema.json");
            if (File.Exists(candidate))
            {
                return JsonNode.Parse(File.ReadAllText(candidate))!.AsObject();
            }

            directory = directory.Parent;
        }

        throw new InvalidOperationException(
            "contract/schema/capture-capability-observation.schema.json not found above "
                + AppContext.BaseDirectory);
    }
}
