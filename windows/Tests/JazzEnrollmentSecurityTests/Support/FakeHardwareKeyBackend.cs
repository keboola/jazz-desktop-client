using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using JazzEnrollmentSecurity;

namespace JazzEnrollmentSecurityTests.Support;

/// <summary>
/// A key backend that claims to be hardware-backed so the vault's deployed path can be exercised.
/// </summary>
/// <remarks>
/// The private keys are ordinary software keys; only <see cref="IsHardwareBacked"/> and
/// <see cref="Identifier"/> pretend otherwise. That is the point: it stands in for the CNG backend a
/// Windows host will supply, so the vault's restart, race, rotation, revocation and corruption
/// behaviour can be tested without one.
/// </remarks>
public sealed class FakeHardwareKeyBackend : IDeviceEnrollmentKeyBackend
{
    private static readonly byte[] ProofReferenceBytes = Encoding.UTF8.GetBytes("proof");
    private static readonly byte[] WrappingReferenceBytes = Encoding.UTF8.GetBytes("wrapping");

    private readonly object mutex = new();
    private readonly bool useGoldenKeys;
    private readonly bool failGeneration;
    private readonly KeyOperationGate? gate;
    private byte[]? proofKey;
    private byte[]? wrappingKey;

    public FakeHardwareKeyBackend(
        bool useGoldenKeys = false,
        bool failGeneration = false,
        bool isHardwareBacked = true,
        KeyOperationGate? gate = null)
    {
        this.useGoldenKeys = useGoldenKeys;
        this.failGeneration = failGeneration;
        IsHardwareBacked = isHardwareBacked;
        this.gate = gate;
    }

    /// <inheritdoc />
    public string Identifier => "test-hardware-p256";

    /// <inheritdoc />
    public bool IsHardwareBacked { get; }

    /// <summary>How many times a fresh pair was generated.</summary>
    public int GenerateCount { get; private set; }

    /// <summary>How many times an existing pair was reloaded from its references.</summary>
    public int RestoreCount { get; private set; }

    /// <inheritdoc />
    public DeviceEnrollmentKeyPair Generate()
    {
        lock (mutex)
        {
            GenerateCount++;
            if (failGeneration)
            {
                throw new InvalidOperationException("The simulated hardware refused to create a key.");
            }

            if (useGoldenKeys)
            {
                // The contract fixture's scalars, so a claim built here matches the sealed bundle's
                // authenticated context byte for byte.
                proofKey = P256TestKeys.Sec1PrivateKey(Scalar(1));
                wrappingKey = P256TestKeys.Sec1PrivateKey(Scalar(2));
            }
            else
            {
                using ECDsa proof = ECDsa.Create(ECCurve.NamedCurves.nistP256);
                using ECDiffieHellman wrapping = ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);
                proofKey = proof.ExportECPrivateKey();
                wrappingKey = wrapping.ExportECPrivateKey();
            }

            return Material();
        }
    }

    /// <inheritdoc />
    public DeviceEnrollmentKeyPair Restore(byte[] proofReference, byte[] wrappingReference)
    {
        lock (mutex)
        {
            RestoreCount++;
            if (!proofReference.AsSpan().SequenceEqual(ProofReferenceBytes)
                || !wrappingReference.AsSpan().SequenceEqual(WrappingReferenceBytes)
                || proofKey is null
                || wrappingKey is null)
            {
                throw new InvalidOperationException("Unknown key reference.");
            }

            return Material();
        }
    }

    private DeviceEnrollmentKeyPair Material() => new(
        ProofReferenceBytes,
        WrappingReferenceBytes,
        new GatedProofSigner(new DevelopmentUnprotectedProofSigner(proofKey!), gate),
        new DevelopmentUnprotectedKeyAgreement(wrappingKey!));

    private static byte[] Scalar(byte value)
    {
        var scalar = new byte[32];
        scalar[31] = value;
        return scalar;
    }

    private sealed class GatedProofSigner : IDeviceEnrollmentProofSigner
    {
        private readonly IDeviceEnrollmentProofSigner inner;
        private readonly KeyOperationGate? gate;

        public GatedProofSigner(IDeviceEnrollmentProofSigner inner, KeyOperationGate? gate)
        {
            this.inner = inner;
            this.gate = gate;
        }

        public byte[] PublicKeyX963 => inner.PublicKeyX963;

        public byte[] SignRaw(byte[] message)
        {
            gate?.Enter();
            return inner.SignRaw(message);
        }
    }
}

/// <summary>
/// Lets a test park a thread inside the private-key operation, so a rotation or revocation can be
/// attempted while the operation is genuinely in flight.
/// </summary>
public sealed class KeyOperationGate : IDisposable
{
    private readonly ManualResetEventSlim entered = new(false);
    private readonly ManualResetEventSlim release = new(true);

    /// <summary>Arms the gate so the next key operation blocks on entry.</summary>
    public void Arm()
    {
        entered.Reset();
        release.Reset();
    }

    /// <summary>Called from inside the key operation.</summary>
    public void Enter()
    {
        entered.Set();
        release.Wait(TimeSpan.FromSeconds(10));
    }

    /// <summary>Waits until a key operation has entered the gate.</summary>
    public bool WaitUntilEntered() => entered.Wait(TimeSpan.FromSeconds(5));

    /// <summary>Lets the parked key operation finish.</summary>
    public void Release() => release.Set();

    public void Dispose()
    {
        Release();
        entered.Dispose();
        release.Dispose();
    }
}

/// <summary>An in-memory single-slot identity store.</summary>
public sealed class MemoryIdentityStore : IDeviceEnrollmentIdentityStore
{
    private readonly object mutex = new();
    private byte[]? data;

    public MemoryIdentityStore(byte[]? initial = null) => data = initial;

    /// <summary>How many times the slot was created.</summary>
    public int AddCount { get; private set; }

    /// <inheritdoc />
    public byte[]? Load()
    {
        lock (mutex)
        {
            return data;
        }
    }

    /// <inheritdoc />
    public bool AddIfAbsent(byte[] value)
    {
        lock (mutex)
        {
            if (data is not null)
            {
                return false;
            }

            data = value;
            AddCount++;
            return true;
        }
    }

    /// <inheritdoc />
    public void Replace(byte[] value)
    {
        lock (mutex)
        {
            if (data is null)
            {
                throw new InvalidOperationException("The identity slot does not exist.");
            }

            data = value;
        }
    }

    /// <summary>Rewrites one member of the persisted record, simulating on-disk tampering.</summary>
    public void MutateJson(Action<JsonObject> mutate)
    {
        lock (mutex)
        {
            var root = (JsonObject)JsonNode.Parse(data ?? throw new InvalidOperationException("empty slot"))!;
            mutate(root);
            data = EnrollmentContract.Canonical(root);
        }
    }

    /// <summary>The persisted record as a JSON object.</summary>
    public JsonObject Snapshot()
    {
        lock (mutex)
        {
            return (JsonObject)JsonNode.Parse(data ?? throw new InvalidOperationException("empty slot"))!;
        }
    }
}

/// <summary>An in-memory pending redemption store.</summary>
public sealed class MemoryRedemptionPendingStore : IDeviceRedemptionPendingStore
{
    private readonly object mutex = new();
    private byte[]? data;

    /// <inheritdoc />
    public byte[]? Load()
    {
        lock (mutex)
        {
            return data;
        }
    }

    /// <inheritdoc />
    public void Replace(byte[] exactBytes)
    {
        lock (mutex)
        {
            data = exactBytes;
        }
    }

    /// <inheritdoc />
    public void Delete()
    {
        lock (mutex)
        {
            data = null;
        }
    }
}
