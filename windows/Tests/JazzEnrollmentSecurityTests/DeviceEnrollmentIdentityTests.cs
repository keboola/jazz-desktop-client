using System.Text;
using System.Text.Json.Nodes;
using JazzEnrollmentSecurity;
using JazzEnrollmentSecurityTests.Support;

namespace JazzEnrollmentSecurityTests;

/// <summary>
/// The single-slot device identity: creation races, restart, rotation, revocation and every way the
/// persisted record can be tampered with.
/// </summary>
public sealed class DeviceEnrollmentIdentityTests
{
    private const string BootstrapA = "jbt_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    private const string BootstrapB = "jbt_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    private const string ClaimA = "jcl_11111111111111111111111111111111";

    private static readonly DateTimeOffset CreatedAt =
        SignedEnrollmentRefusalTests.Instant("2026-07-24T08:00:00Z");

    private static readonly DeviceBundleSealDescriptor SealDescriptor = new(
        "jdb_11111111111111111111111111111111",
        1,
        "2026-07-24T09:31:00Z",
        "2026-07-24T09:41:00Z");

    [Fact]
    public void FirstCreateAndRestartReloadTheSameKeys()
    {
        var store = new MemoryIdentityStore();
        var backend = new FakeHardwareKeyBackend();
        DeviceEnrollmentIdentityBinding binding = Binding();

        DeviceEnrollmentIdentity first = Vault(store, backend).LoadOrCreate(binding, CreatedAt);
        DeviceEnrollmentIdentity restarted = Vault(store, backend).LoadOrCreate(
            binding,
            CreatedAt.AddMinutes(1));

        Assert.Equal(first.Metadata, restarted.Metadata);
        Assert.Equal(first.ProofKey, restarted.ProofKey);
        Assert.Equal(first.WrappingKey, restarted.WrappingKey);
        Assert.Equal(1, backend.GenerateCount);
        Assert.Equal(1, store.AddCount);

        byte[] claim = restarted.MakeClaim(BootstrapA, ClaimA, "2026-07-24T08:00:00Z", "2026-07-24T08:05:00Z");
        VerifiedDeviceEnrollmentClaim verified = DeviceBoundEnrollmentCrypto.VerifyClaim(claim);
        Assert.Equal(binding.DeviceId, verified.Payload.DeviceId);
        Assert.Equal(BootstrapA, verified.Payload.BootstrapId);
        Assert.Equal(restarted.Metadata.ProofKeyThumbprint, verified.Binding.ProofKeyThumbprint);
        Assert.Equal(restarted.Metadata.WrappingKeyThumbprint, verified.Binding.WrappingKeyThumbprint);
    }

    [Fact]
    public void ConcurrentFirstCreateReturnsOnlyTheExactWinner()
    {
        var store = new MemoryIdentityStore();
        var backend = new FakeHardwareKeyBackend();
        DeviceEnrollmentIdentityBinding binding = Binding();

        DeviceEnrollmentIdentity[] identities = Enumerable.Range(0, 32)
            .AsParallel()
            .WithDegreeOfParallelism(8)
            .Select(_ => Vault(store, backend).LoadOrCreate(binding, CreatedAt))
            .ToArray();

        Assert.Single(identities.Select(identity => identity.Metadata.KeySetId).Distinct());
        Assert.Single(identities.Select(identity => identity.Metadata.ProofKeyId).Distinct());
        Assert.Single(identities.Select(identity => identity.Metadata.WrappingKeyId).Distinct());
        Assert.Equal(1, backend.GenerateCount);
        Assert.Equal(1, store.AddCount);
    }

    [Fact]
    public void AnExistingSlotRejectsADifferentDeviceOrAuthority()
    {
        var store = new MemoryIdentityStore();
        var backend = new FakeHardwareKeyBackend();
        DeviceEnrollmentIdentityVault vault = Vault(store, backend);
        vault.LoadOrCreate(Binding(), CreatedAt);

        Assert.Equal(
            DeviceEnrollmentIdentityError.BindingConflict,
            Assert.Throws<DeviceEnrollmentIdentityException>(
                () => vault.LoadOrCreate(Binding(authority: new string('b', 64)), CreatedAt)).Reason);
        Assert.Equal(
            DeviceEnrollmentIdentityError.BindingConflict,
            Assert.Throws<DeviceEnrollmentIdentityException>(
                () => vault.LoadOrCreate(Binding(deviceId: "other-device"), CreatedAt)).Reason);
        Assert.Equal(1, backend.GenerateCount);
    }

    [Fact]
    public void ANewBootstrapUnderTheSameAuthorityReusesTheExactKeySet()
    {
        var store = new MemoryIdentityStore();
        var backend = new FakeHardwareKeyBackend();
        DeviceEnrollmentIdentityVault vault = Vault(store, backend);
        DeviceEnrollmentIdentity identity = vault.LoadOrCreate(Binding(), CreatedAt);

        VerifiedDeviceEnrollmentClaim first = DeviceBoundEnrollmentCrypto.VerifyClaim(
            identity.MakeClaim(BootstrapA, ClaimA, "2026-07-24T08:00:00Z", "2026-07-24T08:05:00Z"));
        VerifiedDeviceEnrollmentClaim second = DeviceBoundEnrollmentCrypto.VerifyClaim(
            identity.MakeClaim(
                BootstrapB,
                "jcl_22222222222222222222222222222222",
                "2026-07-24T08:10:00Z",
                "2026-07-24T08:15:00Z"));

        Assert.Equal(BootstrapA, first.Payload.BootstrapId);
        Assert.Equal(BootstrapB, second.Payload.BootstrapId);
        Assert.Equal(first.Payload.ProofKey, second.Payload.ProofKey);
        Assert.Equal(first.Payload.WrappingKey, second.Payload.WrappingKey);
        Assert.Equal(1, backend.GenerateCount);
        Assert.Equal(
            identity.Metadata.KeySetId,
            vault.LoadOrCreate(Binding(), CreatedAt).Metadata.KeySetId);
    }

    [Fact]
    public void AnIdentityOpensASealAddressedToItsPersistedWrappingKey()
    {
        var store = new MemoryIdentityStore();
        var backend = new FakeHardwareKeyBackend();
        DeviceEnrollmentIdentity identity = Vault(store, backend).LoadOrCreate(Binding(), CreatedAt);
        DeviceEnrollmentClaimBinding binding = DeviceBoundEnrollmentCrypto.VerifyClaim(
            identity.MakeClaim(BootstrapA, ClaimA, "2026-07-24T09:30:00Z", "2026-07-24T09:35:00Z")).Binding;
        byte[] plaintext = Encoding.UTF8.GetBytes("signed-device-bundle-exact-bytes");

        byte[] opened = identity.OpenSealedBundle(
            TestSealer.Seal(plaintext, binding, SealDescriptor),
            binding,
            SealDescriptor,
            SignedEnrollmentRefusalTests.Instant("2026-07-24T09:32:00Z"));

        Assert.Equal(plaintext, opened);
    }

    [Fact]
    public void ASoftwareBackendCannotEnterTheHardwareVault()
    {
        var store = new MemoryIdentityStore();
        var backend = new FakeHardwareKeyBackend(isHardwareBacked: false);

        Assert.Equal(
            DeviceEnrollmentIdentityError.HardwareUnavailable,
            Assert.Throws<DeviceEnrollmentIdentityException>(
                () => DeviceEnrollmentIdentityVault.CreateHardwareBacked(store, backend)).Reason);
        Assert.Null(store.Load());
        Assert.Equal(0, backend.GenerateCount);
    }

    [Fact]
    public void AnIdentityWrittenByTheDevelopmentBackendIsRefusedByAHardwareVault()
    {
        // The development backend stamps its own name into the record. That is what stops an
        // identity created during development from being silently inherited by a real install.
        var store = new MemoryIdentityStore();
        var development = new DevelopmentUnprotectedKeyBackend();
        DeviceEnrollmentIdentityVault developmentVault =
            DeviceEnrollmentIdentityVault.CreateWithUnprotectedDevelopmentKeys(store, development);
        developmentVault.LoadOrCreate(Binding(), CreatedAt);

        Assert.Equal(
            DevelopmentUnprotectedKeyBackend.BackendIdentifier,
            store.Snapshot()["backend"]!.GetValue<string>());
        Assert.Contains("INSECURE", DevelopmentUnprotectedKeyBackend.BackendIdentifier, StringComparison.Ordinal);

        DeviceEnrollmentIdentityVault hardwareVault = Vault(store, new FakeHardwareKeyBackend());
        Assert.Equal(
            DeviceEnrollmentIdentityError.CorruptState,
            Assert.Throws<DeviceEnrollmentIdentityException>(
                () => hardwareVault.LoadOrCreate(Binding(), CreatedAt)).Reason);
    }

    [Fact]
    public void APartialGenerationFailureCannotPublishHalfAKeySet()
    {
        var store = new MemoryIdentityStore();
        var backend = new FakeHardwareKeyBackend(failGeneration: true);

        Assert.Equal(
            DeviceEnrollmentIdentityError.KeyOperationFailed,
            Assert.Throws<DeviceEnrollmentIdentityException>(
                () => Vault(store, backend).LoadOrCreate(Binding(), CreatedAt)).Reason);
        Assert.Null(store.Load());
        Assert.Equal(0, store.AddCount);
    }

    [Fact]
    public void ATamperedKeyReferenceInvalidatesBothReloadAndAnAlreadyLoadedCapability()
    {
        var store = new MemoryIdentityStore();
        var backend = new FakeHardwareKeyBackend();
        DeviceEnrollmentIdentityBinding binding = Binding();
        DeviceEnrollmentIdentity loaded = Vault(store, backend).LoadOrCreate(binding, CreatedAt);

        store.MutateJson(record => record["proofKeyReference"] =
            EnrollmentEncoding.EncodeBase64Url(Encoding.UTF8.GetBytes("unknown-handle")));

        Assert.Equal(
            DeviceEnrollmentIdentityError.CorruptState,
            Assert.Throws<DeviceEnrollmentIdentityException>(
                () => Vault(store, backend).Load(binding)).Reason);

        // The capability handed out before the tamper must stop working too: it re-reads and
        // re-validates the persisted record before every private-key use.
        Assert.Equal(
            DeviceEnrollmentIdentityError.CorruptState,
            Assert.Throws<DeviceEnrollmentIdentityException>(
                () => loaded.MakeClaim(BootstrapA, ClaimA, "2026-07-24T08:00:00Z", "2026-07-24T08:05:00Z")).Reason);
    }

    [Fact]
    public void TamperedMetadataFailsClosed()
    {
        var store = new MemoryIdentityStore();
        var backend = new FakeHardwareKeyBackend();
        Vault(store, backend).LoadOrCreate(Binding(), CreatedAt);

        store.MutateJson(record => record["deviceId"] = "tampered-device");

        Assert.Equal(
            DeviceEnrollmentIdentityError.CorruptState,
            Assert.Throws<DeviceEnrollmentIdentityException>(
                () => Vault(store, backend).Metadata()).Reason);
    }

    [Theory]
    [InlineData("""{"schemaVersion":1,"schemaVersion":1}""")]
    [InlineData("""{"schemaVersion":1}""")]
    [InlineData("not json")]
    public void MalformedPersistedStateFailsClosed(string content)
    {
        var store = new MemoryIdentityStore(Encoding.UTF8.GetBytes(content));

        Assert.Equal(
            DeviceEnrollmentIdentityError.CorruptState,
            Assert.Throws<DeviceEnrollmentIdentityException>(
                () => Vault(store, new FakeHardwareKeyBackend()).Metadata()).Reason);
    }

    [Fact]
    public void RotationFencesTheOldKeySetUnderTheSameAuthority()
    {
        var store = new MemoryIdentityStore();
        var backend = new FakeHardwareKeyBackend();
        DeviceEnrollmentIdentityVault vault = Vault(store, backend);
        DeviceEnrollmentIdentity original = vault.LoadOrCreate(Binding(), CreatedAt);

        DeviceEnrollmentIdentity rotated = vault.Rotate(
            original.Metadata.KeySetId,
            Binding(),
            CreatedAt.AddMinutes(5));

        Assert.Equal(2, rotated.Metadata.Revision);
        Assert.Equal(original.Metadata.KeySetId, rotated.Metadata.PreviousKeySetId);
        Assert.NotEqual(original.Metadata.KeySetId, rotated.Metadata.KeySetId);
        Assert.NotEqual(original.Metadata.ProofKeyId, rotated.Metadata.ProofKeyId);
        Assert.NotEqual(original.Metadata.WrappingKeyId, rotated.Metadata.WrappingKeyId);

        Assert.Equal(
            DeviceEnrollmentIdentityError.StaleKeySet,
            Assert.Throws<DeviceEnrollmentIdentityException>(
                () => original.MakeClaim(BootstrapB, ClaimA, "2026-07-24T08:00:00Z", "2026-07-24T08:05:00Z")).Reason);
        Assert.Equal(
            DeviceEnrollmentIdentityError.StaleKeySet,
            Assert.Throws<DeviceEnrollmentIdentityException>(
                () => vault.Rotate(original.Metadata.KeySetId, Binding(), CreatedAt)).Reason);
    }

    [Fact]
    public async Task RotationCannotCommitBetweenTheFenceAndTheSigningOperation()
    {
        using var gate = new KeyOperationGate();
        var store = new MemoryIdentityStore();
        var backend = new FakeHardwareKeyBackend(gate: gate);
        DeviceEnrollmentIdentityVault vault = Vault(store, backend);
        DeviceEnrollmentIdentity original = vault.LoadOrCreate(Binding(), CreatedAt);

        gate.Arm();
        Task<byte[]> claim = Task.Run(() =>
            original.MakeClaim(BootstrapA, ClaimA, "2026-07-24T08:00:00Z", "2026-07-24T08:05:00Z"));
        Assert.True(gate.WaitUntilEntered());

        Task<DeviceEnrollmentIdentity> rotation = Task.Run(() =>
            vault.Rotate(original.Metadata.KeySetId, Binding(), CreatedAt.AddMinutes(5)));

        // The signature is parked inside the critical section, so the rotation cannot land yet.
        Assert.False(await Completes(rotation, TimeSpan.FromMilliseconds(250)));

        gate.Release();
        byte[] claimBytes = await claim.WaitAsync(TimeSpan.FromSeconds(5));
        await rotation.WaitAsync(TimeSpan.FromSeconds(5));

        DeviceBoundEnrollmentCrypto.VerifyClaim(claimBytes);
        Assert.Equal(
            DeviceEnrollmentIdentityError.StaleKeySet,
            Assert.Throws<DeviceEnrollmentIdentityException>(
                () => original.MakeClaim(
                    BootstrapB,
                    "jcl_22222222222222222222222222222222",
                    "2026-07-24T08:10:00Z",
                    "2026-07-24T08:15:00Z")).Reason);
    }

    [Fact]
    public void RotationCannotMoveTheIdentityToAnotherDeviceOrAuthority()
    {
        var store = new MemoryIdentityStore();
        var backend = new FakeHardwareKeyBackend();
        DeviceEnrollmentIdentityVault vault = Vault(store, backend);
        DeviceEnrollmentIdentity original = vault.LoadOrCreate(Binding(), CreatedAt);

        Assert.Equal(
            DeviceEnrollmentIdentityError.BindingConflict,
            Assert.Throws<DeviceEnrollmentIdentityException>(
                () => vault.Rotate(
                    original.Metadata.KeySetId,
                    Binding(deviceId: "other-device"),
                    CreatedAt)).Reason);
        Assert.Equal(
            DeviceEnrollmentIdentityError.BindingConflict,
            Assert.Throws<DeviceEnrollmentIdentityException>(
                () => vault.Rotate(
                    original.Metadata.KeySetId,
                    Binding(authority: new string('b', 64)),
                    CreatedAt)).Reason);
        Assert.Equal(1, backend.GenerateCount);
    }

    [Fact]
    public void RevocationPersistsATombstoneAndInvalidatesALoadedIdentity()
    {
        var store = new MemoryIdentityStore();
        var backend = new FakeHardwareKeyBackend();
        DeviceEnrollmentIdentityVault vault = Vault(store, backend);
        DeviceEnrollmentIdentity identity = vault.LoadOrCreate(Binding(), CreatedAt);

        DeviceEnrollmentIdentityMetadata revoked = vault.Revoke(
            identity.Metadata.KeySetId,
            CreatedAt.AddMinutes(1));

        Assert.Equal(DeviceEnrollmentIdentityState.Revoked, revoked.State);
        Assert.Equal(2, revoked.Revision);
        Assert.Equal(revoked, vault.Revoke(identity.Metadata.KeySetId, CreatedAt.AddMinutes(2)));

        JsonObject persisted = store.Snapshot();
        Assert.Equal(string.Empty, persisted["proofKeyReference"]!.GetValue<string>());
        Assert.Equal(string.Empty, persisted["wrappingKeyReference"]!.GetValue<string>());

        Assert.Equal(
            DeviceEnrollmentIdentityError.Revoked,
            Assert.Throws<DeviceEnrollmentIdentityException>(
                () => identity.MakeClaim(BootstrapA, ClaimA, "2026-07-24T08:00:00Z", "2026-07-24T08:05:00Z")).Reason);
        Assert.Equal(
            DeviceEnrollmentIdentityError.Revoked,
            Assert.Throws<DeviceEnrollmentIdentityException>(
                () => Vault(store, backend).LoadOrCreate(Binding(), CreatedAt)).Reason);
    }

    [Fact]
    public void ExplicitRotationCanRecoverFromARevokedTombstone()
    {
        var store = new MemoryIdentityStore();
        var backend = new FakeHardwareKeyBackend();
        DeviceEnrollmentIdentityVault vault = Vault(store, backend);
        DeviceEnrollmentIdentity original = vault.LoadOrCreate(Binding(), CreatedAt);
        vault.Revoke(original.Metadata.KeySetId, CreatedAt.AddMinutes(1));

        DeviceEnrollmentIdentity replacement = vault.Rotate(
            original.Metadata.KeySetId,
            Binding(),
            CreatedAt.AddMinutes(2));

        Assert.Equal(DeviceEnrollmentIdentityState.Active, replacement.Metadata.State);
        Assert.Equal(3, replacement.Metadata.Revision);
        Assert.Equal(original.Metadata.KeySetId, replacement.Metadata.PreviousKeySetId);
    }

    [Fact]
    public void DescriptionsAndErrorsNeverExposeTheBindingOrAKeyReference()
    {
        var store = new MemoryIdentityStore();
        var backend = new FakeHardwareKeyBackend();
        DeviceEnrollmentIdentity identity = Vault(store, backend).LoadOrCreate(Binding(), CreatedAt);
        JsonObject persisted = store.Snapshot();
        string proofReference = persisted["proofKeyReference"]!.GetValue<string>();
        string wrappingReference = persisted["wrappingKeyReference"]!.GetValue<string>();

        string rendered = identity.ToString();
        foreach (string secret in new[] { "device-a", new string('a', 64), proofReference, wrappingReference })
        {
            Assert.DoesNotContain(secret, rendered, StringComparison.Ordinal);
            Assert.DoesNotContain(secret, identity.Metadata.ToString(), StringComparison.Ordinal);
        }

        foreach (DeviceEnrollmentIdentityError reason in Enum.GetValues<DeviceEnrollmentIdentityError>())
        {
            string text = DeviceEnrollmentIdentityException.Describe(reason);
            Assert.DoesNotContain(proofReference, text, StringComparison.Ordinal);
            Assert.DoesNotContain(wrappingReference, text, StringComparison.Ordinal);
        }
    }

    [Fact]
    public void AnInvalidBindingIsRefusedBeforeItReachesTheVault()
    {
        Assert.Equal(
            DeviceEnrollmentIdentityError.InvalidBinding,
            Assert.Throws<DeviceEnrollmentIdentityException>(
                () => new DeviceEnrollmentIdentityBinding("UPPERCASE", new string('a', 64))).Reason);
        Assert.Equal(
            DeviceEnrollmentIdentityError.InvalidBinding,
            Assert.Throws<DeviceEnrollmentIdentityException>(
                () => new DeviceEnrollmentIdentityBinding("device-a", "not-a-digest")).Reason);
    }

    /// <summary>Whether <paramref name="task"/> finished within <paramref name="timeout"/>.</summary>
    private static async Task<bool> Completes(Task task, TimeSpan timeout) =>
        await Task.WhenAny(task, Task.Delay(timeout)).ConfigureAwait(false) == task;

    private static DeviceEnrollmentIdentityVault Vault(
        MemoryIdentityStore store,
        FakeHardwareKeyBackend backend) =>
        DeviceEnrollmentIdentityVault.CreateHardwareBacked(store, backend);

    private static DeviceEnrollmentIdentityBinding Binding(
        string deviceId = "device-a",
        string? authority = null) =>
        new(deviceId, authority ?? new string('a', 64));
}
