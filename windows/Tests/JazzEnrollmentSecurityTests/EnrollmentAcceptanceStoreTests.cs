using System.Text;
using JazzEnrollmentSecurity;

namespace JazzEnrollmentSecurityTests;

/// <summary>The durable replay ledger: rollback, bundle-id reuse, cross-process locking, corruption.</summary>
public sealed class EnrollmentAcceptanceStoreTests : IDisposable
{
    private static readonly DateTimeOffset Now = SignedEnrollmentRefusalTests.Instant("2026-07-24T09:35:00Z");

    private const string FirstBundle = "jdb_11111111111111111111111111111111";
    private const string SecondBundle = "jdb_22222222222222222222222222222222";

    private readonly string root = Path.Combine(
        Path.GetTempPath(),
        "jazz-enrollment-ledger-" + Guid.NewGuid().ToString("N"));

    private string LedgerPath => Path.Combine(root, "acceptance.json");

    [Fact]
    public void GlobalBundleIdentityHistorySurvivesRestart()
    {
        var store = new FileEnrollmentAcceptanceStore(LedgerPath);
        string firstDigest = new('a', 64);
        string secondDigest = new('b', 64);
        string changedDigest = new('c', 64);

        Assert.Equal(
            EnrollmentAcceptanceDecision.First,
            store.AuthorizeAndRecord("mac-finance-01", 1, FirstBundle, firstDigest, Now));
        Assert.Equal(
            EnrollmentAcceptanceDecision.Advanced,
            store.AuthorizeAndRecord("mac-finance-01", 2, SecondBundle, secondDigest, Now));

        // A fresh store over the same file is what a restart looks like.
        var restarted = new FileEnrollmentAcceptanceStore(LedgerPath);

        // The bundle id is retired for good, even at a newer generation with new content.
        Assert.Equal(
            SignedEnrollmentError.Collision,
            Assert.Throws<SignedEnrollmentException>(() =>
                restarted.AuthorizeAndRecord("mac-finance-01", 3, FirstBundle, changedDigest, Now)).Reason);

        // And it cannot be re-used to bootstrap a different device either.
        Assert.Equal(
            SignedEnrollmentError.Collision,
            Assert.Throws<SignedEnrollmentException>(() =>
                restarted.AuthorizeAndRecord("mac-operations-02", 1, FirstBundle, firstDigest, Now)).Reason);

        Assert.Equal(2, restarted.Records()["mac-finance-01"].Generation);
    }

    [Fact]
    public void RollbackAndSameGenerationCollisionAreDistinctRefusals()
    {
        var store = new FileEnrollmentAcceptanceStore(LedgerPath);
        string digest = new('a', 64);
        store.AuthorizeAndRecord("mac-finance-01", 5, FirstBundle, digest, Now);

        Assert.Equal(
            SignedEnrollmentError.Rollback,
            Assert.Throws<SignedEnrollmentException>(() =>
                store.AuthorizeAndRecord("mac-finance-01", 4, SecondBundle, new string('b', 64), Now)).Reason);

        Assert.Equal(
            SignedEnrollmentError.Collision,
            Assert.Throws<SignedEnrollmentException>(() =>
                store.AuthorizeAndRecord("mac-finance-01", 5, SecondBundle, new string('b', 64), Now)).Reason);

        Assert.Equal(
            EnrollmentAcceptanceDecision.Idempotent,
            store.AuthorizeAndRecord("mac-finance-01", 5, FirstBundle, digest, Now));
    }

    [Fact]
    public void MalformedAdmissionArgumentsFailClosedWithoutTouchingTheLedger()
    {
        var store = new FileEnrollmentAcceptanceStore(LedgerPath);
        string digest = new('a', 64);

        Assert.Equal(
            SignedEnrollmentError.InvalidPayload,
            Assert.Throws<SignedEnrollmentException>(() =>
                store.AuthorizeAndRecord("MAC-FINANCE-01", 1, FirstBundle, digest, Now)).Reason);
        Assert.Equal(
            SignedEnrollmentError.InvalidPayload,
            Assert.Throws<SignedEnrollmentException>(() =>
                store.AuthorizeAndRecord("mac-finance-01", 0, FirstBundle, digest, Now)).Reason);
        Assert.Equal(
            SignedEnrollmentError.InvalidPayload,
            Assert.Throws<SignedEnrollmentException>(() =>
                store.AuthorizeAndRecord("mac-finance-01", 1, "not-a-bundle-id", digest, Now)).Reason);
        Assert.Equal(
            SignedEnrollmentError.InvalidPayload,
            Assert.Throws<SignedEnrollmentException>(() =>
                store.AuthorizeAndRecord("mac-finance-01", 1, FirstBundle, "ABC", Now)).Reason);

        Assert.False(File.Exists(LedgerPath));
    }

    [Fact]
    public void IndependentStoresSerializeTheWholeAdmissionUnderTheSidecarLock()
    {
        Directory.CreateDirectory(root);
        string lockPath = FileEnrollmentAcceptanceStore.LockFilePath(LedgerPath);

        var outcomes = new System.Collections.Concurrent.ConcurrentBag<string>();
        var started = new CountdownEvent(2);
        Task[] admissions;

        using (var held = new FileStream(lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None))
        {
            admissions = new[] { FirstBundle, SecondBundle }
                .Select((bundleId, index) => Task.Run(() =>
                {
                    var store = new FileEnrollmentAcceptanceStore(LedgerPath);
                    started.Signal();
                    try
                    {
                        outcomes.Add("decision:" + store.AuthorizeAndRecord(
                            "mac-finance-01",
                            1,
                            bundleId,
                            new string(index == 0 ? 'a' : 'b', 64),
                            Now));
                    }
                    catch (SignedEnrollmentException error)
                    {
                        outcomes.Add("error:" + error.Reason);
                    }
                }))
                .ToArray();

            Assert.True(started.Wait(TimeSpan.FromSeconds(5)));

            // Neither admission may make progress while the sidecar is held: the decision is what
            // has to be serialized, not merely the write that follows it.
            Assert.False(Task.WaitAll(admissions, TimeSpan.FromMilliseconds(250)));
            Assert.Empty(outcomes);
        }

        Assert.True(Task.WaitAll(admissions, TimeSpan.FromSeconds(10)));

        string[] sorted = outcomes.OrderBy(value => value, StringComparer.Ordinal).ToArray();
        Assert.Equal(new[] { "decision:First", "error:Collision" }, sorted);

        IReadOnlyDictionary<string, EnrollmentAcceptanceRecord> records =
            new FileEnrollmentAcceptanceStore(LedgerPath).Records();
        Assert.Equal(1, records["mac-finance-01"].Generation);
        Assert.Contains(records["mac-finance-01"].BundleId, new[] { FirstBundle, SecondBundle });
    }

    [Fact]
    public void LockAcquisitionFailureFailsClosedBeforeAnyLedgerMutation()
    {
        // A directory where the sidecar file belongs makes the lock unopenable. Any inability to
        // take the lock has to stop the import, never let it proceed unserialized.
        Directory.CreateDirectory(FileEnrollmentAcceptanceStore.LockFilePath(LedgerPath));
        var store = new FileEnrollmentAcceptanceStore(LedgerPath, TimeSpan.FromMilliseconds(50));

        Assert.Equal(
            SignedEnrollmentError.AcceptanceStateUnavailable,
            Assert.Throws<SignedEnrollmentException>(() =>
                store.AuthorizeAndRecord("mac-finance-01", 1, FirstBundle, new string('a', 64), Now)).Reason);
        Assert.False(File.Exists(LedgerPath));
        Assert.Equal(
            SignedEnrollmentError.AcceptanceStateUnavailable,
            Assert.Throws<SignedEnrollmentException>(() => store.Records()).Reason);
    }

    [Theory]
    [InlineData("""{"bundles":{"jdb_11111111111111111111111111111111":{"deviceId":"INVALID","envelopeDigest":"ABC","generation":1}},"devices":{},"schemaVersion":2}""")]
    [InlineData("""{"bundles":{},"devices":{},"schemaVersion":1}""")]
    [InlineData("""{"bundles":{},"devices":{}}""")]
    [InlineData("not json at all")]
    [InlineData("""{"bundles":{},"devices":{},"schemaVersion":2,"extra":1}""")]
    public void CorruptLedgerContentFailsClosed(string content)
    {
        Directory.CreateDirectory(root);
        File.WriteAllBytes(LedgerPath, Encoding.UTF8.GetBytes(content));
        var store = new FileEnrollmentAcceptanceStore(LedgerPath);

        Assert.Equal(
            SignedEnrollmentError.AcceptanceStateUnavailable,
            Assert.Throws<SignedEnrollmentException>(() => store.Records()).Reason);
        Assert.Equal(
            SignedEnrollmentError.AcceptanceStateUnavailable,
            Assert.Throws<SignedEnrollmentException>(() =>
                store.AuthorizeAndRecord("mac-finance-01", 1, FirstBundle, new string('a', 64), Now)).Reason);
    }

    [Fact]
    public void ALedgerWhoseIndexesDisagreeFailsClosed()
    {
        Directory.CreateDirectory(root);

        // The device says it accepted FirstBundle, but the bundle index attributes FirstBundle to a
        // different digest. One of the two is a forgery and neither may be trusted.
        File.WriteAllText(
            LedgerPath,
            """
            {"bundles":{"jdb_11111111111111111111111111111111":{"deviceId":"mac-finance-01","envelopeDigest":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","generation":1}},"devices":{"mac-finance-01":{"acceptedAt":"2026-07-24T09:35:00.000Z","bundleId":"jdb_11111111111111111111111111111111","deviceId":"mac-finance-01","envelopeDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","generation":1}},"schemaVersion":2}
            """);

        Assert.Equal(
            SignedEnrollmentError.AcceptanceStateUnavailable,
            Assert.Throws<SignedEnrollmentException>(
                () => new FileEnrollmentAcceptanceStore(LedgerPath).Records()).Reason);
    }

    [Fact]
    public void ThePersistedLedgerIsCanonicalJsonWithNoNullMembers()
    {
        var store = new FileEnrollmentAcceptanceStore(LedgerPath);
        store.AuthorizeAndRecord("mac-finance-01", 1, FirstBundle, new string('a', 64), Now);

        string text = File.ReadAllText(LedgerPath);

        Assert.DoesNotContain("null", text, StringComparison.Ordinal);
        Assert.StartsWith("""{"bundles":{""", text, StringComparison.Ordinal);
        Assert.EndsWith("""schemaVersion":2}""", text, StringComparison.Ordinal);
    }

    public void Dispose()
    {
        try
        {
            if (Directory.Exists(root))
            {
                Directory.Delete(root, recursive: true);
            }
        }
        catch (IOException)
        {
            // Leftover temporary state is not worth failing a test over.
        }
    }
}
