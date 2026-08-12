using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using JazzCaptureCore;

namespace JazzEnrollmentSecurity;

/// <summary>How a verified bundle related to what this device had already accepted.</summary>
public enum EnrollmentAcceptanceDecision
{
    /// <summary>Used only between signature verification and durable replay admission.</summary>
    Pending,

    /// <summary>The first enrollment this device has ever admitted.</summary>
    First,

    /// <summary>A strictly newer generation than the one on record.</summary>
    Advanced,

    /// <summary>The byte-identical envelope at the generation already on record.</summary>
    Idempotent,
}

/// <summary>One device's latest admitted enrollment.</summary>
public sealed record EnrollmentAcceptanceRecord(
    string DeviceId,
    long Generation,
    string BundleId,
    string EnvelopeDigest,
    string AcceptedAt);

/// <summary>Durable replay admission for verified enrollment bundles.</summary>
public interface IEnrollmentAcceptanceStore
{
    /// <summary>
    /// Admits a verified bundle, or throws. This must complete before the caller performs anything
    /// token-bearing with the bundle.
    /// </summary>
    /// <exception cref="SignedEnrollmentException">The bundle was refused or state is unavailable.</exception>
    EnrollmentAcceptanceDecision AuthorizeAndRecord(
        string deviceId,
        long generation,
        string bundleId,
        string envelopeDigest,
        DateTimeOffset acceptedAt);
}

/// <summary>
/// One atomically replaced, non-secret ledger keyed by enrolled device id.
/// </summary>
/// <remarks>
/// <para>
/// Admission is intentionally persisted before the token-bearing closure runs. If the network is
/// offline or the app crashes afterwards, the byte-identical envelope remains idempotently
/// retryable; a different envelope at the same or lower generation cannot exploit that window.
/// </para>
/// <para>
/// Cross-process exclusion uses a sidecar lock file rather than the ledger itself, because
/// persisting the ledger replaces it: every process must coordinate on a path whose identity does
/// not change under them. The macOS client uses <c>flock</c> on that sidecar; .NET's
/// <see cref="FileShare.None"/> maps to the same primitive on Unix and to a mandatory share-mode
/// denial on Windows.
/// </para>
/// </remarks>
public sealed partial class FileEnrollmentAcceptanceStore : IEnrollmentAcceptanceStore
{
    private const long MaximumGeneration = 9_007_199_254_740_991;
    private const int LedgerSchemaVersion = 2;

    private readonly object processLock = new();
    private readonly TimeSpan lockTimeout;

    /// <summary>Creates a store over <paramref name="filePath"/> and its sidecar lock.</summary>
    public FileEnrollmentAcceptanceStore(string filePath, TimeSpan? lockTimeout = null)
    {
        FilePath = filePath;
        this.lockTimeout = lockTimeout ?? TimeSpan.FromSeconds(30);
    }

    /// <summary>The ledger path.</summary>
    public string FilePath { get; }

    /// <summary>
    /// The sidecar whose inode stays stable across the ledger's atomic replacement.
    /// </summary>
    public static string LockFilePath(string filePath) => filePath + ".lock";

    /// <summary>The per-user production ledger location.</summary>
    public static FileEnrollmentAcceptanceStore Production()
    {
        string root = Environment.GetFolderPath(
            Environment.SpecialFolder.LocalApplicationData,
            Environment.SpecialFolderOption.DoNotVerify);
        return new FileEnrollmentAcceptanceStore(
            Path.Combine(root, "Jazz Capture", "Security", "signed-enrollment-acceptance-v2.json"));
    }

    /// <inheritdoc />
    public EnrollmentAcceptanceDecision AuthorizeAndRecord(
        string deviceId,
        long generation,
        string bundleId,
        string envelopeDigest,
        DateTimeOffset acceptedAt)
    {
        lock (processLock)
        {
            if (!DeviceIdPattern().IsMatch(deviceId)
                || generation is < 1 or > MaximumGeneration
                || !BundleIdPattern().IsMatch(bundleId)
                || !DigestPattern().IsMatch(envelopeDigest))
            {
                throw new SignedEnrollmentException(SignedEnrollmentError.InvalidPayload);
            }

            return WithExclusiveFileLock(() =>
            {
                Ledger ledger = Load();
                ledger.Devices.TryGetValue(deviceId, out EnrollmentAcceptanceRecord? prior);
                ledger.Bundles.TryGetValue(bundleId, out BundleIdentityRecord? priorIdentity);

                if (priorIdentity is not null
                    && (priorIdentity.DeviceId != deviceId
                        || priorIdentity.Generation != generation
                        || priorIdentity.EnvelopeDigest != envelopeDigest))
                {
                    throw new SignedEnrollmentException(SignedEnrollmentError.Collision);
                }

                if (prior is not null)
                {
                    if (generation < prior.Generation)
                    {
                        throw new SignedEnrollmentException(SignedEnrollmentError.Rollback);
                    }

                    if (generation == prior.Generation)
                    {
                        if (bundleId != prior.BundleId || envelopeDigest != prior.EnvelopeDigest)
                        {
                            throw new SignedEnrollmentException(SignedEnrollmentError.Collision);
                        }

                        return EnrollmentAcceptanceDecision.Idempotent;
                    }

                    if (priorIdentity is not null)
                    {
                        throw new SignedEnrollmentException(SignedEnrollmentError.Collision);
                    }
                }
                else if (priorIdentity is not null)
                {
                    // A globally known bundle can never become the first enrollment of another
                    // device, nor can a ledger lose its owning device's latest record and continue
                    // permissively.
                    throw new SignedEnrollmentException(SignedEnrollmentError.Collision);
                }

                EnrollmentAcceptanceDecision decision = prior is null
                    ? EnrollmentAcceptanceDecision.First
                    : EnrollmentAcceptanceDecision.Advanced;
                ledger.Devices[deviceId] = new EnrollmentAcceptanceRecord(
                    deviceId,
                    generation,
                    bundleId,
                    envelopeDigest,
                    Timestamps.IsoMillisUtc(acceptedAt));
                ledger.Bundles[bundleId] = new BundleIdentityRecord(deviceId, generation, envelopeDigest);
                Persist(ledger);
                return decision;
            });
        }
    }

    /// <summary>The latest admitted enrollment per device.</summary>
    /// <exception cref="SignedEnrollmentException">The ledger is unreadable or inconsistent.</exception>
    public IReadOnlyDictionary<string, EnrollmentAcceptanceRecord> Records()
    {
        lock (processLock)
        {
            return WithExclusiveFileLock(() => (IReadOnlyDictionary<string, EnrollmentAcceptanceRecord>)Load().Devices);
        }
    }

    private T WithExclusiveFileLock<T>(Func<T> operation)
    {
        string lockPath = LockFilePath(FilePath);
        string? directory = Path.GetDirectoryName(lockPath);
        try
        {
            if (!string.IsNullOrEmpty(directory))
            {
                Directory.CreateDirectory(directory);
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or NotSupportedException)
        {
            throw new SignedEnrollmentException(SignedEnrollmentError.AcceptanceStateUnavailable);
        }

        using FileStream handle = OpenExclusive(lockPath);
        return operation();
    }

    private FileStream OpenExclusive(string lockPath)
    {
        DateTime deadline = DateTime.UtcNow + lockTimeout;
        while (true)
        {
            try
            {
                return new FileStream(
                    lockPath,
                    FileMode.OpenOrCreate,
                    FileAccess.ReadWrite,
                    FileShare.None);
            }
            catch (IOException) when (DateTime.UtcNow < deadline)
            {
                // Another process (or another store in this one) holds the sidecar. Blocking here
                // is the point: the whole admission decision must be serialized, not just the write.
                Thread.Sleep(5);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or NotSupportedException)
            {
                throw new SignedEnrollmentException(SignedEnrollmentError.AcceptanceStateUnavailable);
            }
        }
    }

    private Ledger Load()
    {
        if (!File.Exists(FilePath))
        {
            return Ledger.Empty();
        }

        byte[] bytes;
        try
        {
            bytes = File.ReadAllBytes(FilePath);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            throw new SignedEnrollmentException(SignedEnrollmentError.AcceptanceStateUnavailable);
        }

        JsonObject? root = StrictJson.TryParseObject(bytes);
        if (root is null
            || !StrictJson.HasExactlyKeys(root, new[] { "schemaVersion", "devices", "bundles" })
            || StrictJson.IntegerOrNull(root, "schemaVersion") != LedgerSchemaVersion
            || StrictJson.ObjectOrNull(root, "devices") is not JsonObject devicesObject
            || StrictJson.ObjectOrNull(root, "bundles") is not JsonObject bundlesObject)
        {
            throw new SignedEnrollmentException(SignedEnrollmentError.AcceptanceStateUnavailable);
        }

        var ledger = Ledger.Empty();
        foreach (KeyValuePair<string, JsonNode?> entry in devicesObject)
        {
            if (StrictJson.ObjectOrNull(devicesObject, entry.Key) is not JsonObject record
                || !StrictJson.HasExactlyKeys(
                    record,
                    new[] { "deviceId", "generation", "bundleId", "envelopeDigest", "acceptedAt" }))
            {
                throw new SignedEnrollmentException(SignedEnrollmentError.AcceptanceStateUnavailable);
            }

            string? recordDeviceId = StrictJson.StringOrNull(record, "deviceId");
            long? generation = StrictJson.IntegerOrNull(record, "generation");
            string? bundleId = StrictJson.StringOrNull(record, "bundleId");
            string? digest = StrictJson.StringOrNull(record, "envelopeDigest");
            string? acceptedAt = StrictJson.StringOrNull(record, "acceptedAt");
            if (recordDeviceId is null || generation is null || bundleId is null
                || digest is null || acceptedAt is null
                || recordDeviceId != entry.Key
                || !DeviceIdPattern().IsMatch(entry.Key)
                || generation is < 1 or > MaximumGeneration
                || !BundleIdPattern().IsMatch(bundleId)
                || !DigestPattern().IsMatch(digest)
                || Timestamps.TryParseRfc3339(acceptedAt) is null)
            {
                throw new SignedEnrollmentException(SignedEnrollmentError.AcceptanceStateUnavailable);
            }

            ledger.Devices[entry.Key] = new EnrollmentAcceptanceRecord(
                recordDeviceId, generation.Value, bundleId, digest, acceptedAt);
        }

        foreach (KeyValuePair<string, JsonNode?> entry in bundlesObject)
        {
            if (StrictJson.ObjectOrNull(bundlesObject, entry.Key) is not JsonObject record
                || !StrictJson.HasExactlyKeys(
                    record,
                    new[] { "deviceId", "generation", "envelopeDigest" }))
            {
                throw new SignedEnrollmentException(SignedEnrollmentError.AcceptanceStateUnavailable);
            }

            string? recordDeviceId = StrictJson.StringOrNull(record, "deviceId");
            long? generation = StrictJson.IntegerOrNull(record, "generation");
            string? digest = StrictJson.StringOrNull(record, "envelopeDigest");
            if (recordDeviceId is null || generation is null || digest is null
                || !BundleIdPattern().IsMatch(entry.Key)
                || !DeviceIdPattern().IsMatch(recordDeviceId)
                || generation is < 1 or > MaximumGeneration
                || !DigestPattern().IsMatch(digest))
            {
                throw new SignedEnrollmentException(SignedEnrollmentError.AcceptanceStateUnavailable);
            }

            ledger.Bundles[entry.Key] = new BundleIdentityRecord(recordDeviceId, generation.Value, digest);
        }

        foreach (EnrollmentAcceptanceRecord record in ledger.Devices.Values)
        {
            if (!ledger.Bundles.TryGetValue(record.BundleId, out BundleIdentityRecord? identity)
                || identity != new BundleIdentityRecord(record.DeviceId, record.Generation, record.EnvelopeDigest))
            {
                throw new SignedEnrollmentException(SignedEnrollmentError.AcceptanceStateUnavailable);
            }
        }

        foreach (KeyValuePair<string, BundleIdentityRecord> entry in ledger.Bundles)
        {
            if (!ledger.Devices.TryGetValue(entry.Value.DeviceId, out EnrollmentAcceptanceRecord? latest))
            {
                throw new SignedEnrollmentException(SignedEnrollmentError.AcceptanceStateUnavailable);
            }

            bool consistent = entry.Value.Generation < latest.Generation
                || (entry.Value.Generation == latest.Generation
                    && latest.BundleId == entry.Key
                    && latest.EnvelopeDigest == entry.Value.EnvelopeDigest);
            if (!consistent)
            {
                throw new SignedEnrollmentException(SignedEnrollmentError.AcceptanceStateUnavailable);
            }
        }

        return ledger;
    }

    private void Persist(Ledger ledger)
    {
        var devices = new JsonObject();
        foreach (KeyValuePair<string, EnrollmentAcceptanceRecord> entry in ledger.Devices)
        {
            devices[entry.Key] = new JsonObject
            {
                ["deviceId"] = entry.Value.DeviceId,
                ["generation"] = entry.Value.Generation,
                ["bundleId"] = entry.Value.BundleId,
                ["envelopeDigest"] = entry.Value.EnvelopeDigest,
                ["acceptedAt"] = entry.Value.AcceptedAt,
            };
        }

        var bundles = new JsonObject();
        foreach (KeyValuePair<string, BundleIdentityRecord> entry in ledger.Bundles)
        {
            bundles[entry.Key] = new JsonObject
            {
                ["deviceId"] = entry.Value.DeviceId,
                ["generation"] = entry.Value.Generation,
                ["envelopeDigest"] = entry.Value.EnvelopeDigest,
            };
        }

        var root = new JsonObject
        {
            ["schemaVersion"] = LedgerSchemaVersion,
            ["devices"] = devices,
            ["bundles"] = bundles,
        };

        byte[]? encoded = EnrollmentEncoding.TryCanonicalJson(root);
        if (encoded is null)
        {
            throw new SignedEnrollmentException(SignedEnrollmentError.AcceptanceStateUnavailable);
        }

        try
        {
            string? directory = Path.GetDirectoryName(FilePath);
            if (!string.IsNullOrEmpty(directory))
            {
                Directory.CreateDirectory(directory);
            }

            // Write-then-replace so a crash mid-write can never leave a half-parsed ledger, which
            // Load() would reject and which would then block every future import.
            string temporary = FilePath + ".tmp-" + Guid.NewGuid().ToString("N");
            File.WriteAllBytes(temporary, encoded);
            File.Move(temporary, FilePath, overwrite: true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or NotSupportedException)
        {
            throw new SignedEnrollmentException(SignedEnrollmentError.AcceptanceStateUnavailable);
        }
    }

    private sealed record BundleIdentityRecord(string DeviceId, long Generation, string EnvelopeDigest);

    private sealed class Ledger
    {
        public Dictionary<string, EnrollmentAcceptanceRecord> Devices { get; } = new(StringComparer.Ordinal);

        public Dictionary<string, BundleIdentityRecord> Bundles { get; } = new(StringComparer.Ordinal);

        public static Ledger Empty() => new();
    }

    [GeneratedRegex("^[a-z0-9][a-z0-9-]{0,63}$")]
    private static partial Regex DeviceIdPattern();

    [GeneratedRegex("^jdb_[a-f0-9]{32}$")]
    private static partial Regex BundleIdPattern();

    [GeneratedRegex("^[a-f0-9]{64}$")]
    private static partial Regex DigestPattern();
}

/// <summary>
/// Production gate: signature, time and scope verification plus durable replay admission all happen
/// before the caller's operation can observe the token-bearing bundle.
/// </summary>
public sealed class SignedEnrollmentImporter
{
    private readonly SignedEnrollmentVerifier? verifier;
    private readonly IEnrollmentAcceptanceStore? acceptanceStore;

    /// <summary>Creates an importer; a missing policy or store makes every import fail closed.</summary>
    public SignedEnrollmentImporter(
        EnrollmentTrustPolicy? trustPolicy,
        IEnrollmentAcceptanceStore? acceptanceStore)
    {
        verifier = trustPolicy is null ? null : new SignedEnrollmentVerifier(trustPolicy);
        this.acceptanceStore = acceptanceStore;
    }

    /// <summary>The deployed importer, reading trust from the code-signed host assembly.</summary>
    public static SignedEnrollmentImporter Production(System.Reflection.Assembly hostAssembly) =>
        new(
            EnrollmentTrustBootstrap.Load(EnrollmentTrustBootstrap.LoadEmbeddedConfiguration(hostAssembly)),
            FileEnrollmentAcceptanceStore.Production());

    /// <summary>Verifies and durably admits <paramref name="text"/>.</summary>
    /// <exception cref="SignedEnrollmentException">The bundle was refused.</exception>
    public AuthorizedSignedDeviceBundle Authorize(string text, DateTimeOffset now)
    {
        if (verifier is null)
        {
            throw new SignedEnrollmentException(SignedEnrollmentError.TrustUnavailable);
        }

        if (acceptanceStore is null)
        {
            throw new SignedEnrollmentException(SignedEnrollmentError.AcceptanceStateUnavailable);
        }

        AuthorizedSignedDeviceBundle verified = verifier.Verify(text, now);
        EnrollmentAcceptanceDecision decision = acceptanceStore.AuthorizeAndRecord(
            verified.Payload.DeviceId,
            verified.Payload.Generation,
            verified.Payload.BundleId,
            verified.EnvelopeDigest,
            now);
        return verified with { Acceptance = decision };
    }

    /// <summary>
    /// Runs <paramref name="operation"/> only after <see cref="Authorize(string, DateTimeOffset)"/>
    /// has both verified the signature and committed replay admission.
    /// </summary>
    /// <remarks>
    /// The ordering is the security property, not a convenience: every refusal reason - rollback, a
    /// reused bundle id, a substituted authority - has to be reached before anything carrying the
    /// bundle's token leaves the machine. A check performed after the request is not a check.
    /// </remarks>
    public async Task<(AuthorizedSignedDeviceBundle Authorized, T Result)> AuthorizeThenAsync<T>(
        string text,
        DateTimeOffset now,
        Func<AuthorizedSignedDeviceBundle, Task<T>> operation)
    {
        AuthorizedSignedDeviceBundle authorized = Authorize(text, now);
        T result = await operation(authorized).ConfigureAwait(false);
        return (authorized, result);
    }
}
