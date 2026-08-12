using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using JazzCaptureCore;

namespace JazzEnrollmentSecurity;

/// <summary>The device and signed authority a local key set is bound to.</summary>
public sealed record DeviceEnrollmentIdentityBinding
{
    /// <summary>Creates a binding, throwing when either half is malformed.</summary>
    /// <exception cref="DeviceEnrollmentIdentityException">The binding is invalid.</exception>
    public DeviceEnrollmentIdentityBinding(string deviceId, string authorityBindingSha256)
    {
        if (!DeviceEnrollmentIdentityPatterns.DeviceId.IsMatch(deviceId)
            || !DeviceEnrollmentIdentityPatterns.Digest.IsMatch(authorityBindingSha256))
        {
            throw new DeviceEnrollmentIdentityException(DeviceEnrollmentIdentityError.InvalidBinding);
        }

        DeviceId = deviceId;
        AuthorityBindingSha256 = authorityBindingSha256;
    }

    /// <summary>The enrolled device id.</summary>
    public string DeviceId { get; }

    /// <summary>
    /// Lower-hex SHA-256 of the canonical signed authority tuple (issuer, audience, project, stack
    /// and archive origins, Company and Area).
    /// </summary>
    /// <remarks>
    /// A one-time bootstrap id is deliberately absent: re-bootstrapping under the same authority
    /// must prove continuity with the same key set rather than mint a second identity.
    /// </remarks>
    public string AuthorityBindingSha256 { get; }
}

/// <summary>Whether a persisted identity is usable or a tombstone.</summary>
public enum DeviceEnrollmentIdentityState
{
    /// <summary>Both key references are present and usable.</summary>
    Active,

    /// <summary>Both key references have been dropped; only non-secret metadata remains.</summary>
    Revoked,
}

/// <summary>Public, non-secret identity metadata safe to persist or send to the control plane.</summary>
public sealed record DeviceEnrollmentIdentityMetadata(
    long SchemaVersion,
    string Backend,
    DeviceEnrollmentIdentityState State,
    long Revision,
    string DeviceId,
    string AuthorityBindingSha256,
    string KeySetId,
    string? PreviousKeySetId,
    string ProofKeyId,
    string ProofKeyThumbprint,
    string WrappingKeyId,
    string WrappingKeyThumbprint,
    string CreatedAt,
    string UpdatedAt)
{
    /// <summary>Intentionally omits the device and authority binding and every key reference.</summary>
    public override string ToString() =>
        $"DeviceEnrollmentIdentityMetadata(state: {State}, revision: {Revision}, "
        + $"keySetId: {KeySetId}, backend: {Backend})";
}

/// <summary>A generated or restored key pair plus the opaque references that reload it.</summary>
public sealed record DeviceEnrollmentKeyPair(
    byte[] ProofReference,
    byte[] WrappingReference,
    IDeviceEnrollmentProofSigner ProofSigner,
    IDeviceEnrollmentKeyAgreement WrappingAgreement);

/// <summary>
/// The seam a Windows host must implement with CNG before device-bound enrollment can be trusted.
/// </summary>
/// <remarks>
/// <para>
/// A real implementation creates two non-exportable P-256 keys in a hardware key storage provider -
/// the Platform Crypto Provider when a TPM is present - and returns handles, never scalars. Only
/// <see cref="Identifier"/>, the public points, one signature operation and one ECDH operation cross
/// this boundary.
/// </para>
/// <para>
/// The only implementation shipped in this module is
/// <see cref="DevelopmentUnprotectedKeyBackend"/>, which is not one: see its remarks.
/// </para>
/// </remarks>
public interface IDeviceEnrollmentKeyBackend
{
    /// <summary>
    /// A stable name for this backend, recorded in the persisted identity. A vault refuses to load a
    /// record written by a different backend, so identities cannot migrate between them by accident.
    /// </summary>
    string Identifier { get; }

    /// <summary>Whether private keys are held by hardware that will not export them.</summary>
    bool IsHardwareBacked { get; }

    /// <summary>Creates a fresh proof and wrapping pair.</summary>
    DeviceEnrollmentKeyPair Generate();

    /// <summary>Reloads a pair from the references a previous <see cref="Generate"/> returned.</summary>
    DeviceEnrollmentKeyPair Restore(byte[] proofReference, byte[] wrappingReference);
}

/// <summary>The single-slot store holding the persisted identity record.</summary>
/// <remarks>
/// A Windows host backs this with DPAPI-protected local state or the credential store. The record
/// itself is non-secret metadata plus whatever opaque references the key backend returned; with a
/// hardware backend those references are useless off the machine that created them.
/// </remarks>
public interface IDeviceEnrollmentIdentityStore
{
    /// <summary>The stored record, or <see langword="null"/> when the slot is empty.</summary>
    byte[]? Load();

    /// <summary>Creates the slot; returns <see langword="false"/> when another writer got there first.</summary>
    bool AddIfAbsent(byte[] data);

    /// <summary>Atomically replaces an existing slot. A missing slot is an error.</summary>
    void Replace(byte[] data);
}

/// <summary>
/// A loaded key pair. The only private-key capabilities exposed are claim signing and bundle
/// opening; neither can return a key reference or a private scalar.
/// </summary>
public sealed class DeviceEnrollmentIdentity
{
    private readonly Func<DeviceEnrollmentClaimPayload, byte[]> signClaim;
    private readonly Func<byte[], DeviceEnrollmentClaimBinding, DeviceBundleSealDescriptor, DateTimeOffset, byte[]> openBundle;

    internal DeviceEnrollmentIdentity(
        DeviceEnrollmentIdentityMetadata metadata,
        DeviceEnrollmentPublicKey proofKey,
        DeviceEnrollmentPublicKey wrappingKey,
        Func<DeviceEnrollmentClaimPayload, byte[]> signClaim,
        Func<byte[], DeviceEnrollmentClaimBinding, DeviceBundleSealDescriptor, DateTimeOffset, byte[]> openBundle)
    {
        Metadata = metadata;
        ProofKey = proofKey;
        WrappingKey = wrappingKey;
        this.signClaim = signClaim;
        this.openBundle = openBundle;
    }

    /// <summary>Non-secret metadata about this identity.</summary>
    public DeviceEnrollmentIdentityMetadata Metadata { get; }

    /// <summary>The ES256 proof-of-possession public key profile.</summary>
    public DeviceEnrollmentPublicKey ProofKey { get; }

    /// <summary>The ECDH-ES wrapping public key profile.</summary>
    public DeviceEnrollmentPublicKey WrappingKey { get; }

    /// <summary>Deliberately reveals neither the binding nor any key reference.</summary>
    public override string ToString() => $"DeviceEnrollmentIdentity({Metadata})";

    /// <summary>Signs a claim for <paramref name="bootstrapId"/> with this device's proof key.</summary>
    /// <exception cref="DeviceEnrollmentIdentityException">The identity is no longer usable.</exception>
    public byte[] MakeClaim(string bootstrapId, string claimId, string issuedAt, string expiresAt)
    {
        if (Metadata.State != DeviceEnrollmentIdentityState.Active)
        {
            throw new DeviceEnrollmentIdentityException(DeviceEnrollmentIdentityError.Revoked);
        }

        return signClaim(new DeviceEnrollmentClaimPayload(
            bootstrapId,
            claimId,
            Metadata.DeviceId,
            issuedAt,
            expiresAt,
            ProofKey,
            WrappingKey));
    }

    /// <summary>Opens a sealed bundle addressed to this device's wrapping key.</summary>
    /// <exception cref="DeviceEnrollmentIdentityException">The identity is no longer usable.</exception>
    public byte[] OpenSealedBundle(
        byte[] wireBytes,
        DeviceEnrollmentClaimBinding binding,
        DeviceBundleSealDescriptor descriptor,
        DateTimeOffset now)
    {
        if (Metadata.State != DeviceEnrollmentIdentityState.Active)
        {
            throw new DeviceEnrollmentIdentityException(DeviceEnrollmentIdentityError.Revoked);
        }

        return openBundle(wireBytes, binding, descriptor, now);
    }
}

/// <summary>
/// Restart-safe, single-slot identity lifecycle.
/// </summary>
/// <remarks>
/// <para>
/// Every mutation is serialized by a process-wide lock and, in production, a stable file-lock
/// sidecar. The stored value contains both key references and all binding metadata, so first
/// creation, rotation and revocation each have exactly one atomic commit. A caller can never observe
/// or persist only one half of the proof/wrapping pair.
/// </para>
/// <para>
/// An already-loaded <see cref="DeviceEnrollmentIdentity"/> re-reads and re-validates the persisted
/// record before every sign or ECDH, holding the same critical section throughout, so a rotation or
/// revocation cannot commit between the fence check and the private-key use.
/// </para>
/// </remarks>
public sealed class DeviceEnrollmentIdentityVault
{
    private const long MaximumRevision = 9_007_199_254_740_991;
    private const int SchemaVersion = 1;
    private const string RecordKind = "jazz-device-enrollment-identity";

    private static readonly object ProcessLock = new();

    private static readonly string[] RecordKeys =
    {
        "schemaVersion", "kind", "backend", "state", "revision", "deviceId",
        "authorityBindingSHA256", "keySetId", "previousKeySetId",
        "proofKeyId", "proofKeyThumbprint", "proofPublicKey",
        "wrappingKeyId", "wrappingKeyThumbprint", "wrappingPublicKey",
        "createdAt", "updatedAt", "proofKeyReference", "wrappingKeyReference",
    };

    private readonly IDeviceEnrollmentIdentityStore persistence;
    private readonly IDeviceEnrollmentKeyBackend keyBackend;
    private readonly string? lockFilePath;
    private readonly bool allowUnprotectedDevelopmentKeys;

    private DeviceEnrollmentIdentityVault(
        IDeviceEnrollmentIdentityStore persistence,
        IDeviceEnrollmentKeyBackend keyBackend,
        string? lockFilePath,
        bool allowUnprotectedDevelopmentKeys)
    {
        this.persistence = persistence;
        this.keyBackend = keyBackend;
        this.lockFilePath = lockFilePath;
        this.allowUnprotectedDevelopmentKeys = allowUnprotectedDevelopmentKeys;
    }

    /// <summary>
    /// The deployed constructor. <paramref name="keyBackend"/> must report
    /// <see cref="IDeviceEnrollmentKeyBackend.IsHardwareBacked"/>; there is no software fallback on
    /// this path and no way to ask for one.
    /// </summary>
    /// <exception cref="DeviceEnrollmentIdentityException">The backend is not hardware-backed.</exception>
    public static DeviceEnrollmentIdentityVault CreateHardwareBacked(
        IDeviceEnrollmentIdentityStore persistence,
        IDeviceEnrollmentKeyBackend keyBackend,
        string? lockFilePath = null)
    {
        if (!keyBackend.IsHardwareBacked)
        {
            throw new DeviceEnrollmentIdentityException(DeviceEnrollmentIdentityError.HardwareUnavailable);
        }

        return new DeviceEnrollmentIdentityVault(persistence, keyBackend, lockFilePath, false);
    }

    /// <summary>
    /// DEVELOPMENT ONLY. Builds a vault that accepts a backend whose private keys are not protected
    /// by hardware.
    /// </summary>
    /// <remarks>
    /// Anything created through here is not device-bound in any meaningful sense: the key material
    /// is copyable, so the identity is copyable, so a stolen bootstrap can be redeemed from a second
    /// machine. The backend name is stamped into the persisted record, which means a vault built by
    /// <see cref="CreateHardwareBacked"/> will refuse to load it rather than inherit the weakness.
    /// This exists so the module can be exercised before the CNG backend is written; it is not a
    /// fallback a shipped client may take.
    /// </remarks>
    public static DeviceEnrollmentIdentityVault CreateWithUnprotectedDevelopmentKeys(
        IDeviceEnrollmentIdentityStore persistence,
        IDeviceEnrollmentKeyBackend keyBackend,
        string? lockFilePath = null) =>
        new(persistence, keyBackend, lockFilePath, true);

    /// <summary>Loads the existing identity for <paramref name="binding"/>, or creates the first one.</summary>
    /// <exception cref="DeviceEnrollmentIdentityException">The identity is unusable.</exception>
    public DeviceEnrollmentIdentity LoadOrCreate(DeviceEnrollmentIdentityBinding binding, DateTimeOffset now) =>
        WithExclusiveLock(() =>
        {
            byte[]? existing = LoadData();
            if (existing is not null)
            {
                return ActiveIdentity(existing, binding);
            }

            DeviceEnrollmentKeyPair generated = GenerateKeyPair();
            PersistedRecord record = MakeRecord(generated, binding, revision: 1, previousKeySetId: string.Empty, createdAt: now, updatedAt: now);
            if (persistence.AddIfAbsent(Encode(record)))
            {
                return Identity(record, generated);
            }

            // Another writer won the create race. Never keep or return the losing pair; reload the
            // winner exactly and enforce the requested binding against it.
            byte[] winner = LoadData()
                ?? throw new DeviceEnrollmentIdentityException(DeviceEnrollmentIdentityError.PersistenceUnavailable);
            return ActiveIdentity(winner, binding);
        });

    /// <summary>The existing identity for <paramref name="binding"/>, or <see langword="null"/>.</summary>
    public DeviceEnrollmentIdentity? Load(DeviceEnrollmentIdentityBinding binding) =>
        WithExclusiveLock(() =>
        {
            byte[]? data = LoadData();
            return data is null ? null : ActiveIdentity(data, binding);
        });

    /// <summary>
    /// Explicit rotation. Changes key bytes but never the device or signed authority binding;
    /// <paramref name="expectedKeySetId"/> fences a stale caller out.
    /// </summary>
    /// <exception cref="DeviceEnrollmentIdentityException">Rotation is not permitted.</exception>
    public DeviceEnrollmentIdentity Rotate(
        string expectedKeySetId,
        DeviceEnrollmentIdentityBinding binding,
        DateTimeOffset now) =>
        WithExclusiveLock(() =>
        {
            byte[] currentData = LoadData()
                ?? throw new DeviceEnrollmentIdentityException(DeviceEnrollmentIdentityError.PersistenceUnavailable);
            LoadedRecord current = DecodeAndValidate(currentData, restoreKeys: true);
            if (current.Record.KeySetId != expectedKeySetId)
            {
                throw new DeviceEnrollmentIdentityException(DeviceEnrollmentIdentityError.StaleKeySet);
            }

            if (current.Record.DeviceId != binding.DeviceId
                || current.Record.AuthorityBindingSha256 != binding.AuthorityBindingSha256)
            {
                throw new DeviceEnrollmentIdentityException(DeviceEnrollmentIdentityError.BindingConflict);
            }

            if (current.Record.Revision >= MaximumRevision)
            {
                throw new DeviceEnrollmentIdentityException(DeviceEnrollmentIdentityError.CorruptState);
            }

            DeviceEnrollmentKeyPair generated = GenerateKeyPair();
            PersistedRecord record = MakeRecord(
                generated,
                binding,
                current.Record.Revision + 1,
                current.Record.KeySetId,
                now,
                now);
            persistence.Replace(Encode(record));
            return Identity(record, generated);
        });

    /// <summary>
    /// Revocation. Atomically drops both key references and leaves a non-secret tombstone; an exact
    /// retry is idempotent and a different expected key set is fenced.
    /// </summary>
    /// <exception cref="DeviceEnrollmentIdentityException">Revocation is not permitted.</exception>
    public DeviceEnrollmentIdentityMetadata Revoke(string expectedKeySetId, DateTimeOffset now) =>
        WithExclusiveLock(() =>
        {
            byte[] currentData = LoadData()
                ?? throw new DeviceEnrollmentIdentityException(DeviceEnrollmentIdentityError.PersistenceUnavailable);
            LoadedRecord current = DecodeAndValidate(currentData, restoreKeys: true);
            if (current.Record.KeySetId != expectedKeySetId)
            {
                throw new DeviceEnrollmentIdentityException(DeviceEnrollmentIdentityError.StaleKeySet);
            }

            if (current.Record.State == DeviceEnrollmentIdentityState.Revoked)
            {
                return ToMetadata(current.Record);
            }

            if (current.Record.Revision >= MaximumRevision)
            {
                throw new DeviceEnrollmentIdentityException(DeviceEnrollmentIdentityError.CorruptState);
            }

            PersistedRecord tombstone = current.Record with
            {
                State = DeviceEnrollmentIdentityState.Revoked,
                Revision = current.Record.Revision + 1,
                UpdatedAt = Timestamps.IsoSecondsUtc(now),
                ProofKeyReference = string.Empty,
                WrappingKeyReference = string.Empty,
            };
            ValidateRecord(tombstone);
            persistence.Replace(Encode(tombstone));
            return ToMetadata(tombstone);
        });

    /// <summary>Non-secret metadata about the persisted identity, or <see langword="null"/>.</summary>
    public DeviceEnrollmentIdentityMetadata? Metadata() =>
        WithExclusiveLock(() =>
        {
            byte[]? data = LoadData();
            return data is null ? null : ToMetadata(DecodeAndValidate(data, restoreKeys: true).Record);
        });

    private DeviceEnrollmentIdentity ActiveIdentity(byte[] data, DeviceEnrollmentIdentityBinding binding)
    {
        LoadedRecord loaded = DecodeAndValidate(data, restoreKeys: true);
        if (loaded.Record.DeviceId != binding.DeviceId
            || loaded.Record.AuthorityBindingSha256 != binding.AuthorityBindingSha256)
        {
            throw new DeviceEnrollmentIdentityException(DeviceEnrollmentIdentityError.BindingConflict);
        }

        if (loaded.Record.State != DeviceEnrollmentIdentityState.Active || loaded.KeyPair is null)
        {
            throw new DeviceEnrollmentIdentityException(DeviceEnrollmentIdentityError.Revoked);
        }

        return Identity(loaded.Record, loaded.KeyPair);
    }

    private byte[]? LoadData()
    {
        try
        {
            return persistence.Load();
        }
        catch (Exception ex) when (ex is not DeviceEnrollmentIdentityException)
        {
            throw new DeviceEnrollmentIdentityException(DeviceEnrollmentIdentityError.PersistenceUnavailable);
        }
    }

    private DeviceEnrollmentKeyPair GenerateKeyPair()
    {
        if (!keyBackend.IsHardwareBacked && !allowUnprotectedDevelopmentKeys)
        {
            throw new DeviceEnrollmentIdentityException(DeviceEnrollmentIdentityError.HardwareUnavailable);
        }

        try
        {
            return keyBackend.Generate();
        }
        catch (DeviceEnrollmentIdentityException)
        {
            throw;
        }
        catch (Exception)
        {
            throw new DeviceEnrollmentIdentityException(DeviceEnrollmentIdentityError.KeyOperationFailed);
        }
    }

    private sealed record LoadedRecord(PersistedRecord Record, DeviceEnrollmentKeyPair? KeyPair);

    private LoadedRecord DecodeAndValidate(byte[] data, bool restoreKeys)
    {
        PersistedRecord record;
        try
        {
            record = DecodeRecord(data);
            ValidateRecord(record);
        }
        catch (DeviceEnrollmentIdentityException)
        {
            throw;
        }
        catch (Exception)
        {
            throw new DeviceEnrollmentIdentityException(DeviceEnrollmentIdentityError.CorruptState);
        }

        if (!restoreKeys || record.State != DeviceEnrollmentIdentityState.Active)
        {
            return new LoadedRecord(record, null);
        }

        byte[]? proofReference = DecodeReference(record.ProofKeyReference);
        byte[]? wrappingReference = DecodeReference(record.WrappingKeyReference);
        if (proofReference is null || wrappingReference is null)
        {
            throw new DeviceEnrollmentIdentityException(DeviceEnrollmentIdentityError.CorruptState);
        }

        DeviceEnrollmentKeyPair restored;
        try
        {
            restored = keyBackend.Restore(proofReference, wrappingReference);
        }
        catch (Exception)
        {
            throw new DeviceEnrollmentIdentityException(DeviceEnrollmentIdentityError.CorruptState);
        }

        if (!restored.ProofReference.AsSpan().SequenceEqual(proofReference)
            || !restored.WrappingReference.AsSpan().SequenceEqual(wrappingReference))
        {
            throw new DeviceEnrollmentIdentityException(DeviceEnrollmentIdentityError.CorruptState);
        }

        ValidateAgainstKeyPair(record, restored);
        return new LoadedRecord(record, restored);
    }

    private PersistedRecord MakeRecord(
        DeviceEnrollmentKeyPair generated,
        DeviceEnrollmentIdentityBinding binding,
        long revision,
        string previousKeySetId,
        DateTimeOffset createdAt,
        DateTimeOffset updatedAt)
    {
        DeviceEnrollmentPublicKey proof = ProfileFor(generated.ProofSigner.PublicKeyX963, proofKey: true);
        DeviceEnrollmentPublicKey wrapping = ProfileFor(generated.WrappingAgreement.PublicKeyX963, proofKey: false);
        var record = new PersistedRecord(
            SchemaVersion,
            RecordKind,
            keyBackend.Identifier,
            DeviceEnrollmentIdentityState.Active,
            revision,
            binding.DeviceId,
            binding.AuthorityBindingSha256,
            KeySetId(binding, proof.PublicKey, wrapping.PublicKey),
            previousKeySetId,
            KeyId("jpk", proof.PublicKey),
            Thumbprint(proof.PublicKey),
            proof.PublicKey,
            KeyId("jwk", wrapping.PublicKey),
            Thumbprint(wrapping.PublicKey),
            wrapping.PublicKey,
            Timestamps.IsoSecondsUtc(createdAt),
            Timestamps.IsoSecondsUtc(updatedAt),
            EnrollmentEncoding.EncodeBase64Url(generated.ProofReference),
            EnrollmentEncoding.EncodeBase64Url(generated.WrappingReference));
        ValidateAgainstKeyPair(record, generated);
        return record;
    }

    private void ValidateRecord(PersistedRecord record)
    {
        DateTimeOffset? createdAt = ParseTimestamp(record.CreatedAt);
        DateTimeOffset? updatedAt = ParseTimestamp(record.UpdatedAt);
        bool structurallyValid =
            record.SchemaVersion == SchemaVersion
            && record.Kind == RecordKind
            && record.Backend == keyBackend.Identifier
            && record.Revision is >= 1 and <= MaximumRevision
            && DeviceEnrollmentIdentityPatterns.DeviceId.IsMatch(record.DeviceId)
            && DeviceEnrollmentIdentityPatterns.Digest.IsMatch(record.AuthorityBindingSha256)
            && DeviceEnrollmentIdentityPatterns.KeySetId.IsMatch(record.KeySetId)
            && (record.PreviousKeySetId.Length == 0
                || DeviceEnrollmentIdentityPatterns.KeySetId.IsMatch(record.PreviousKeySetId))
            && DeviceEnrollmentIdentityPatterns.ProofKeyId.IsMatch(record.ProofKeyId)
            && DeviceEnrollmentIdentityPatterns.WrappingKeyId.IsMatch(record.WrappingKeyId)
            && EnrollmentEncoding.DecodeBase64Url(record.ProofKeyThumbprint, 32)?.Length == 32
            && EnrollmentEncoding.DecodeBase64Url(record.WrappingKeyThumbprint, 32)?.Length == 32
            && createdAt is not null
            && updatedAt is not null
            && updatedAt >= createdAt;
        if (!structurallyValid)
        {
            throw new DeviceEnrollmentIdentityException(DeviceEnrollmentIdentityError.CorruptState);
        }

        var binding = new DeviceEnrollmentIdentityBinding(record.DeviceId, record.AuthorityBindingSha256);
        bool derivedValid =
            record.KeySetId == KeySetId(binding, record.ProofPublicKey, record.WrappingPublicKey)
            && record.ProofKeyId == KeyId("jpk", record.ProofPublicKey)
            && record.WrappingKeyId == KeyId("jwk", record.WrappingPublicKey)
            && record.ProofKeyThumbprint == Thumbprint(record.ProofPublicKey)
            && record.WrappingKeyThumbprint == Thumbprint(record.WrappingPublicKey)
            && record.ProofPublicKey != record.WrappingPublicKey;
        if (!derivedValid)
        {
            throw new DeviceEnrollmentIdentityException(DeviceEnrollmentIdentityError.CorruptState);
        }

        bool referencesValid = record.State switch
        {
            DeviceEnrollmentIdentityState.Active =>
                DecodeReference(record.ProofKeyReference) is not null
                && DecodeReference(record.WrappingKeyReference) is not null,
            _ => record.ProofKeyReference.Length == 0 && record.WrappingKeyReference.Length == 0,
        };
        if (!referencesValid)
        {
            throw new DeviceEnrollmentIdentityException(DeviceEnrollmentIdentityError.CorruptState);
        }
    }

    private void ValidateAgainstKeyPair(PersistedRecord record, DeviceEnrollmentKeyPair keyPair)
    {
        ValidateRecord(record);
        DeviceEnrollmentPublicKey proof = ProfileFor(keyPair.ProofSigner.PublicKeyX963, proofKey: true);
        DeviceEnrollmentPublicKey wrapping = ProfileFor(keyPair.WrappingAgreement.PublicKeyX963, proofKey: false);
        if (proof.PublicKey != record.ProofPublicKey || wrapping.PublicKey != record.WrappingPublicKey)
        {
            throw new DeviceEnrollmentIdentityException(DeviceEnrollmentIdentityError.CorruptState);
        }
    }

    private DeviceEnrollmentIdentity Identity(PersistedRecord record, DeviceEnrollmentKeyPair keyPair)
    {
        ValidateAgainstKeyPair(record, keyPair);
        return new DeviceEnrollmentIdentity(
            ToMetadata(record),
            ProfileFor(keyPair.ProofSigner.PublicKeyX963, proofKey: true),
            ProfileFor(keyPair.WrappingAgreement.PublicKeyX963, proofKey: false),
            payload => WithAuthorizedKeyUse(
                record.KeySetId,
                current => DeviceBoundEnrollmentCrypto.MakeClaim(payload, current.ProofSigner)),
            (wireBytes, binding, descriptor, now) => WithAuthorizedKeyUse(
                record.KeySetId,
                current => DeviceBoundEnrollmentCrypto.OpenSealedBundle(
                    wireBytes,
                    current.WrappingAgreement,
                    binding,
                    descriptor,
                    now)));
    }

    private T WithAuthorizedKeyUse<T>(string expectedKeySetId, Func<DeviceEnrollmentKeyPair, T> operation) =>
        WithExclusiveLock(() =>
        {
            byte[] data = LoadData()
                ?? throw new DeviceEnrollmentIdentityException(DeviceEnrollmentIdentityError.PersistenceUnavailable);

            // Both handles are reconstructed here, not just the fence compared. An already-loaded
            // capability must stop working if either reference was corrupted or replaced after it
            // was handed out.
            LoadedRecord loaded = DecodeAndValidate(data, restoreKeys: true);
            if (loaded.Record.State != DeviceEnrollmentIdentityState.Active)
            {
                throw new DeviceEnrollmentIdentityException(DeviceEnrollmentIdentityError.Revoked);
            }

            if (loaded.Record.KeySetId != expectedKeySetId)
            {
                throw new DeviceEnrollmentIdentityException(DeviceEnrollmentIdentityError.StaleKeySet);
            }

            if (loaded.KeyPair is null)
            {
                throw new DeviceEnrollmentIdentityException(DeviceEnrollmentIdentityError.CorruptState);
            }

            // The critical section stays held across the private-key operation, so a rotation or a
            // revocation cannot commit between the fence check and the signature or ECDH.
            return operation(loaded.KeyPair);
        });

    private static DeviceEnrollmentIdentityMetadata ToMetadata(PersistedRecord record) => new(
        record.SchemaVersion,
        record.Backend,
        record.State,
        record.Revision,
        record.DeviceId,
        record.AuthorityBindingSha256,
        record.KeySetId,
        record.PreviousKeySetId.Length == 0 ? null : record.PreviousKeySetId,
        record.ProofKeyId,
        record.ProofKeyThumbprint,
        record.WrappingKeyId,
        record.WrappingKeyThumbprint,
        record.CreatedAt,
        record.UpdatedAt);

    private static DeviceEnrollmentPublicKey ProfileFor(byte[] x963, bool proofKey)
    {
        try
        {
            return proofKey
                ? DeviceBoundEnrollmentCrypto.ProofKeyProfile(x963)
                : DeviceBoundEnrollmentCrypto.WrappingKeyProfile(x963);
        }
        catch (DeviceBoundEnrollmentException)
        {
            throw new DeviceEnrollmentIdentityException(DeviceEnrollmentIdentityError.CorruptState);
        }
    }

    private static string Thumbprint(string encodedPublicKey)
    {
        try
        {
            return DeviceBoundEnrollmentCrypto.KeyThumbprint(encodedPublicKey);
        }
        catch (DeviceBoundEnrollmentException)
        {
            throw new DeviceEnrollmentIdentityException(DeviceEnrollmentIdentityError.CorruptState);
        }
    }

    private static byte[]? DecodeReference(string value) =>
        value.Length == 0 ? null : EnrollmentEncoding.DecodeBase64Url(value, maximumBytes: 16_384);

    private static byte[] Encode(PersistedRecord record)
    {
        // No member is ever written as JSON null: previousKeySetId and the two references use the
        // empty string for "absent", exactly as the macOS record does.
        var json = new JsonObject
        {
            ["schemaVersion"] = record.SchemaVersion,
            ["kind"] = record.Kind,
            ["backend"] = record.Backend,
            ["state"] = record.State == DeviceEnrollmentIdentityState.Active ? "active" : "revoked",
            ["revision"] = record.Revision,
            ["deviceId"] = record.DeviceId,
            ["authorityBindingSHA256"] = record.AuthorityBindingSha256,
            ["keySetId"] = record.KeySetId,
            ["previousKeySetId"] = record.PreviousKeySetId,
            ["proofKeyId"] = record.ProofKeyId,
            ["proofKeyThumbprint"] = record.ProofKeyThumbprint,
            ["proofPublicKey"] = record.ProofPublicKey,
            ["wrappingKeyId"] = record.WrappingKeyId,
            ["wrappingKeyThumbprint"] = record.WrappingKeyThumbprint,
            ["wrappingPublicKey"] = record.WrappingPublicKey,
            ["createdAt"] = record.CreatedAt,
            ["updatedAt"] = record.UpdatedAt,
            ["proofKeyReference"] = record.ProofKeyReference,
            ["wrappingKeyReference"] = record.WrappingKeyReference,
        };
        byte[] encoded = EnrollmentEncoding.TryCanonicalJson(json)
            ?? throw new DeviceEnrollmentIdentityException(DeviceEnrollmentIdentityError.CorruptState);
        if (encoded.Length > 65_536)
        {
            throw new DeviceEnrollmentIdentityException(DeviceEnrollmentIdentityError.CorruptState);
        }

        return encoded;
    }

    private static PersistedRecord DecodeRecord(byte[] data)
    {
        JsonObject? root = data.Length is > 0 and <= 65_536 ? StrictJson.TryParseObject(data) : null;
        if (root is null || !StrictJson.HasExactlyKeys(root, RecordKeys))
        {
            throw new DeviceEnrollmentIdentityException(DeviceEnrollmentIdentityError.CorruptState);
        }

        long? schemaVersion = StrictJson.IntegerOrNull(root, "schemaVersion");
        long? revision = StrictJson.IntegerOrNull(root, "revision");
        string? state = StrictJson.StringOrNull(root, "state");
        string?[] text =
        {
            StrictJson.StringOrNull(root, "kind"),
            StrictJson.StringOrNull(root, "backend"),
            StrictJson.StringOrNull(root, "deviceId"),
            StrictJson.StringOrNull(root, "authorityBindingSHA256"),
            StrictJson.StringOrNull(root, "keySetId"),
            StrictJson.StringOrNull(root, "previousKeySetId"),
            StrictJson.StringOrNull(root, "proofKeyId"),
            StrictJson.StringOrNull(root, "proofKeyThumbprint"),
            StrictJson.StringOrNull(root, "proofPublicKey"),
            StrictJson.StringOrNull(root, "wrappingKeyId"),
            StrictJson.StringOrNull(root, "wrappingKeyThumbprint"),
            StrictJson.StringOrNull(root, "wrappingPublicKey"),
            StrictJson.StringOrNull(root, "createdAt"),
            StrictJson.StringOrNull(root, "updatedAt"),
            StrictJson.StringOrNull(root, "proofKeyReference"),
            StrictJson.StringOrNull(root, "wrappingKeyReference"),
        };
        if (schemaVersion is null || revision is null || state is not ("active" or "revoked")
            || Array.Exists(text, value => value is null))
        {
            throw new DeviceEnrollmentIdentityException(DeviceEnrollmentIdentityError.CorruptState);
        }

        return new PersistedRecord(
            schemaVersion.Value,
            text[0]!,
            text[1]!,
            state == "active" ? DeviceEnrollmentIdentityState.Active : DeviceEnrollmentIdentityState.Revoked,
            revision.Value,
            text[2]!,
            text[3]!,
            text[4]!,
            text[5]!,
            text[6]!,
            text[7]!,
            text[8]!,
            text[9]!,
            text[10]!,
            text[11]!,
            text[12]!,
            text[13]!,
            text[14]!,
            text[15]!);
    }

    private T WithExclusiveLock<T>(Func<T> operation)
    {
        lock (ProcessLock)
        {
            if (lockFilePath is null)
            {
                return operation();
            }

            try
            {
                string? directory = Path.GetDirectoryName(lockFilePath);
                if (!string.IsNullOrEmpty(directory))
                {
                    Directory.CreateDirectory(directory);
                }
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or NotSupportedException)
            {
                throw new DeviceEnrollmentIdentityException(DeviceEnrollmentIdentityError.PersistenceUnavailable);
            }

            DateTime deadline = DateTime.UtcNow + TimeSpan.FromSeconds(30);
            while (true)
            {
                FileStream handle;
                try
                {
                    handle = new FileStream(lockFilePath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
                }
                catch (IOException) when (DateTime.UtcNow < deadline)
                {
                    Thread.Sleep(5);
                    continue;
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or NotSupportedException)
                {
                    throw new DeviceEnrollmentIdentityException(DeviceEnrollmentIdentityError.PersistenceUnavailable);
                }

                using (handle)
                {
                    return operation();
                }
            }
        }
    }

    private static string KeySetId(
        DeviceEnrollmentIdentityBinding binding,
        string proofPublicKey,
        string wrappingPublicKey)
    {
        var material = new List<byte>();
        material.AddRange(Utf8("JAZZ-DEVICE-KEYSET-V1\0"));
        material.AddRange(Utf8(binding.DeviceId));
        material.Add(0);
        material.AddRange(Utf8(binding.AuthorityBindingSha256));
        material.Add(0);
        material.AddRange(Utf8(proofPublicKey));
        material.Add(0);
        material.AddRange(Utf8(wrappingPublicKey));
        return "jks_" + EnrollmentEncoding.HexSha256(material.ToArray());
    }

    private static string KeyId(string prefix, string publicKey) =>
        prefix + "_" + EnrollmentEncoding.HexSha256(Utf8($"JAZZ-DEVICE-KEY-ID-V1\0{prefix}\0{publicKey}"));

    private static DateTimeOffset? ParseTimestamp(string value) =>
        DeviceEnrollmentIdentityPatterns.SecondsTimestamp.IsMatch(value)
            ? Timestamps.TryParseRfc3339(value)
            : null;

    private static byte[] Utf8(string value) => new UTF8Encoding(false).GetBytes(value);

    private sealed record PersistedRecord(
        long SchemaVersion,
        string Kind,
        string Backend,
        DeviceEnrollmentIdentityState State,
        long Revision,
        string DeviceId,
        string AuthorityBindingSha256,
        string KeySetId,
        string PreviousKeySetId,
        string ProofKeyId,
        string ProofKeyThumbprint,
        string ProofPublicKey,
        string WrappingKeyId,
        string WrappingKeyThumbprint,
        string WrappingPublicKey,
        string CreatedAt,
        string UpdatedAt,
        string ProofKeyReference,
        string WrappingKeyReference);
}

/// <summary>Shared identity patterns; grouped so the vault and the binding cannot drift apart.</summary>
internal static partial class DeviceEnrollmentIdentityPatterns
{
    internal static readonly Regex DeviceId = DeviceIdPattern();

    internal static readonly Regex Digest = DigestPattern();

    internal static readonly Regex KeySetId = KeySetIdPattern();

    internal static readonly Regex ProofKeyId = ProofKeyIdPattern();

    internal static readonly Regex WrappingKeyId = WrappingKeyIdPattern();

    internal static readonly Regex SecondsTimestamp = SecondsTimestampPattern();

    [GeneratedRegex("^[a-z0-9][a-z0-9-]{0,63}$")]
    private static partial Regex DeviceIdPattern();

    [GeneratedRegex("^[a-f0-9]{64}$")]
    private static partial Regex DigestPattern();

    [GeneratedRegex("^jks_[a-f0-9]{64}$")]
    private static partial Regex KeySetIdPattern();

    [GeneratedRegex("^jpk_[a-f0-9]{64}$")]
    private static partial Regex ProofKeyIdPattern();

    [GeneratedRegex("^jwk_[a-f0-9]{64}$")]
    private static partial Regex WrappingKeyIdPattern();

    [GeneratedRegex(@"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")]
    private static partial Regex SecondsTimestampPattern();
}
