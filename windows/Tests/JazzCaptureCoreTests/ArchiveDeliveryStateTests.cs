using System.Text;
using System.Text.Json.Nodes;
using JazzCaptureCore.Archive;
using JazzCaptureCore.Delivery;
using JazzCaptureCore.Json;
using JazzCaptureCoreTests.Support;

namespace JazzCaptureCoreTests;

/// <summary>
/// The delivery state document, the working-state file it lives in, and the promise that neither
/// ever reaches a portable archive.
/// </summary>
/// <remarks>
/// Every document produced here is checked against the real
/// <c>contract/archive/schema/delivery-state.schema.json</c> read from the repository, not against a
/// copy of its rules restated in this file.
/// </remarks>
public sealed class ArchiveDeliveryStateTests : IDisposable
{
    private const string DeliveryA = "del-0197f0c0-1c00-7a11-b000-00000000000a";
    private const string DeliveryB = "del-0197f0c0-1c00-7a11-b000-00000000000b";
    private const string CaptureA = "cap-0197f0c0-1c00-7a11-b000-00000000000c";

    private static readonly ContractJsonSchema Schema =
        ContractJsonSchema.Load("delivery-state.schema.json");

    private readonly DeliveryWorkspace _workspace = new();

    public void Dispose() => _workspace.Dispose();

    [Fact]
    public void TheStateOfAFreshlyQueuedDeliveryValidatesAgainstTheContractSchema()
    {
        ConfirmedArchive archive = _workspace.Confirm();
        ArchiveDeliveryRecord record = _workspace.OpenQueue().Require(archive.ArchiveId);

        JsonObject document = record.ToStateDocument().ToJson();

        Assert.Empty(Schema.Validate(document));
        Assert.Equal(1, (long?)document["schemaVersion"]);
        Assert.Equal(DeliveryTransports.JazzArchiveUpload, (string?)document["transport"]);
        Assert.Equal(ArchiveDeliveryRecord.ArchiveUploadMappingVersion, (string?)document["mappingVersion"]);
        Assert.Equal(DeliveryStates.Pending, (string?)document["state"]);
        Assert.Equal(0, (long?)document["attempt"]);

        JsonObject subject = Assert.IsType<JsonObject>(Assert.Single((JsonArray)document["subjectRefs"]!));
        Assert.Equal("capture", (string?)subject["kind"]);
        Assert.Equal(archive.CaptureId, (string?)subject["id"]);
    }

    [Fact]
    public void EveryLifecycleStateThisClientWritesValidates()
    {
        ConfirmedArchive archive = _workspace.Confirm();
        var seen = new List<string>();

        void Capture()
        {
            DeliveryStateDocument document = _workspace.OpenQueue()
                .Require(archive.ArchiveId)
                .ToStateDocument();
            Assert.Empty(Schema.Validate(document.ToJson()));
            seen.Add(DeliveryStates.ToWire(document.State));
        }

        Capture();
        _workspace.OpenQueue().BeginAttempt(archive.ArchiveId);
        Capture();
        _workspace.OpenQueue().MarkRetryable(archive.ArchiveId, "ARCHIVE_BUSY");
        Capture();
        _workspace.OpenQueue().MarkPermanentFailure(archive.ArchiveId, "ARCHIVE_REJECTED");
        Capture();

        Assert.Equal(
            new[]
            {
                DeliveryStates.Pending,
                DeliveryStates.InFlight,
                DeliveryStates.Failed,
                DeliveryStates.PermanentFailure,
            },
            seen);
    }

    [Fact]
    public void AnAcknowledgedStateCarriesTheReceiptAsARemoteBinding()
    {
        ConfirmedArchive archive = _workspace.Confirm();
        ArchiveDeliveryQueue queue = _workspace.OpenQueue();
        queue.BeginAttempt(archive.ArchiveId);
        queue.Acknowledge(archive.ArchiveId, "rcpt-42");

        JsonObject document = _workspace.OpenQueue()
            .Require(archive.ArchiveId)
            .ToStateDocument()
            .ToJson();

        Assert.Empty(Schema.Validate(document));
        Assert.Equal(DeliveryStates.Acked, (string?)document["state"]);
        Assert.Equal("rcpt-42", (string?)document["remoteBindings"]?["receiptId"]);
        Assert.False(document.ContainsKey("errorCode"));
    }

    [Fact]
    public void AnAbsentOptionalFieldIsOmittedRatherThanWrittenAsNull()
    {
        JsonObject document = Document(DeliveryLifecycle.Pending).ToJson();

        Assert.False(document.ContainsKey("errorCode"));
        Assert.False(document.ContainsKey("remoteBindings"));
        Assert.False(document.ContainsKey("serverIngestBinding"));
        Assert.False(document.ContainsKey("extensions"));
        Assert.DoesNotContain("null", JsonCanonicalizer.Canonicalize(document), StringComparison.Ordinal);
    }

    [Fact]
    public void ANullOptionalWouldBeRejectedBySchemaValidation()
    {
        // The guard above only means something if the validator would in fact have caught a null.
        JsonObject document = Document(DeliveryLifecycle.Pending).ToJson();
        document["errorCode"] = null;

        Assert.NotEmpty(Schema.Validate(document));
    }

    [Fact]
    public void ADocumentRoundTripsThroughItsOwnJson()
    {
        DeliveryStateDocument original = Document(DeliveryLifecycle.Failed) with
        {
            ErrorCode = "ARCHIVE_BUSY",
            Attempt = 3,
            RemoteBindings = new DeliveryRemoteBindings(ReceiptId: "rcpt-7"),
        };

        DeliveryStateDocument parsed = DeliveryStateDocument.FromJson(
            (JsonObject)JsonStrictParser.Parse(original.ToNdjsonLine())!);

        Assert.Equal(original.ToNdjsonLine(), parsed.ToNdjsonLine());
        Assert.Equal("rcpt-7", parsed.RemoteBindings?.ReceiptId);
    }

    [Theory]
    [InlineData("del-not-a-uuid")]
    [InlineData("uop-0197f0c0-1c00-7a11-b000-00000000000a")]
    public void ADocumentWithAnIdentityTheContractForbidsIsRefused(string deliveryId)
    {
        DeliveryStateDocument document = Document(DeliveryLifecycle.Pending) with { DeliveryId = deliveryId };

        Assert.Throws<FormatException>(() => document.ToJson());
    }

    [Fact]
    public void ADocumentWithATransportOrSubjectKindOutsideTheContractIsRefused()
    {
        Assert.Throws<FormatException>(
            () => (Document(DeliveryLifecycle.Pending) with { Transport = "sftp" }).ToJson());
        Assert.Throws<FormatException>(
            () => (Document(DeliveryLifecycle.Pending) with
            {
                SubjectRefs = new[] { new DeliverySubjectRef("session", CaptureA) },
            }).ToJson());
        Assert.Throws<FormatException>(
            () => (Document(DeliveryLifecycle.Pending) with
            {
                SubjectRefs = Array.Empty<DeliverySubjectRef>(),
            }).ToJson());
    }

    [Fact]
    public void TheSyncLogIsLineFeedOnlyUtf8WithoutABom()
    {
        ConfirmedArchive archive = _workspace.Confirm();

        byte[] bytes = File.ReadAllBytes(ArchiveDeliverySyncLog.PathFor(archive.ArchiveDirectory));

        Assert.NotEmpty(bytes);
        Assert.NotEqual(0xEF, bytes[0]);
        Assert.DoesNotContain((byte)'\r', bytes);
        Assert.Equal((byte)'\n', bytes[^1]);
        Assert.Single(Encoding.UTF8.GetString(bytes).Split('\n', StringSplitOptions.RemoveEmptyEntries));
    }

    [Fact]
    public void TheSyncLogFollowsTheDurableRecord()
    {
        ConfirmedArchive archive = _workspace.Confirm();
        _workspace.OpenQueue().BeginAttempt(archive.ArchiveId);
        _workspace.OpenQueue().Acknowledge(archive.ArchiveId, "rcpt-9");

        DeliveryStateDocument document = Assert.Single(
            ArchiveDeliverySyncLog.Read(archive.ArchiveDirectory));
        ArchiveDeliveryRecord record = _workspace.OpenQueue().Require(archive.ArchiveId);

        Assert.Empty(Schema.Validate(document.ToJson()));
        Assert.Equal(record.DeliveryId, document.DeliveryId);
        Assert.Equal(DeliveryLifecycle.Acked, document.State);
        Assert.Equal(1, document.Attempt);
        Assert.Equal("rcpt-9", document.RemoteBindings?.ReceiptId);
        Assert.Equal(record.UpdatedAt, document.UpdatedAt);
    }

    [Fact]
    public void ASecondDeliveryReplacesOnlyItsOwnLine()
    {
        ConfirmedArchive archive = _workspace.Confirm();
        ArchiveDeliverySyncLog.Publish(archive.ArchiveDirectory, Document(DeliveryLifecycle.Pending));

        ArchiveDeliverySyncLog.Publish(
            archive.ArchiveDirectory,
            Document(DeliveryLifecycle.Acked) with
            {
                DeliveryId = DeliveryB,
                RemoteBindings = new DeliveryRemoteBindings(ReceiptId: "rcpt-b"),
            });
        ArchiveDeliverySyncLog.Publish(
            archive.ArchiveDirectory,
            Document(DeliveryLifecycle.Failed) with { ErrorCode = "ARCHIVE_BUSY", Attempt = 2 });

        IReadOnlyList<DeliveryStateDocument> documents =
            ArchiveDeliverySyncLog.Read(archive.ArchiveDirectory);

        // The archive's own delivery, plus the two written here, each present exactly once.
        Assert.Equal(3, documents.Count);
        Assert.Equal(3, documents.Select(document => document.DeliveryId).Distinct().Count());
        Assert.Equal(
            DeliveryLifecycle.Failed,
            documents.Single(document => document.DeliveryId == DeliveryA).State);
        Assert.Equal(
            DeliveryLifecycle.Acked,
            documents.Single(document => document.DeliveryId == DeliveryB).State);
        Assert.All(documents, document => Assert.Empty(Schema.Validate(document.ToJson())));
    }

    [Fact]
    public void ADamagedLineDoesNotHideTheStatesBesideIt()
    {
        ConfirmedArchive archive = _workspace.Confirm();
        string path = ArchiveDeliverySyncLog.PathFor(archive.ArchiveDirectory);
        File.AppendAllText(path, "{\"schemaVersion\":1,\n");
        ArchiveDeliverySyncLog.Publish(archive.ArchiveDirectory, Document(DeliveryLifecycle.Pending));

        IReadOnlyList<DeliveryStateDocument> documents =
            ArchiveDeliverySyncLog.Read(archive.ArchiveDirectory);

        Assert.Equal(2, documents.Count);
        Assert.Contains(documents, document => document.DeliveryId == DeliveryA);
    }

    [Fact]
    public void SyncNeverAppearsInAnExportedContainer()
    {
        ConfirmedArchive archive = _workspace.Confirm();
        _workspace.OpenQueue().BeginAttempt(archive.ArchiveId);
        Assert.True(File.Exists(ArchiveDeliverySyncLog.PathFor(archive.ArchiveDirectory)));

        string exported = Path.Combine(_workspace.Root, "re-exported.jazz-archive");
        JazzArchiveContainer.Export(archive.ArchiveDirectory, exported);

        string expanded = Path.Combine(_workspace.Root, "expanded");
        Directory.CreateDirectory(expanded);
        IReadOnlyDictionary<string, JazzArchiveFileFingerprint> entries =
            JazzArchiveContainerReader.Extract(exported, expanded, new JazzArchiveImportLimits());

        Assert.Contains("manifest.json", entries.Keys);
        Assert.Contains("inventory.json", entries.Keys);
        Assert.DoesNotContain(
            entries.Keys,
            name => name.StartsWith(ArchiveDeliverySyncLog.DirectoryName + "/", StringComparison.Ordinal));
        Assert.False(Directory.Exists(Path.Combine(expanded, ArchiveDeliverySyncLog.DirectoryName)));
    }

    [Fact]
    public void DeliveryStateChangesNoByteOfThePackageOrTheInventory()
    {
        // The queue package was written before any delivery state existed. If the state were part of
        // the archive, re-exporting the same directory now would differ.
        ConfirmedArchive archive = _workspace.Confirm();
        byte[] atConfirmation = File.ReadAllBytes(archive.PackagePath);

        ArchiveDeliveryQueue queue = _workspace.OpenQueue();
        queue.BeginAttempt(archive.ArchiveId);
        queue.MarkRetryable(archive.ArchiveId, "ARCHIVE_BUSY");
        queue.BeginAttempt(archive.ArchiveId);
        queue.Acknowledge(archive.ArchiveId, "rcpt-1");

        string exported = Path.Combine(_workspace.Root, "after-delivery.jazz-archive");
        JazzArchiveContainer.Export(archive.ArchiveDirectory, exported);

        Assert.Equal(atConfirmation, File.ReadAllBytes(exported));
        Assert.Equal(
            _workspace.OpenQueue().Require(archive.ArchiveId).RawSha256,
            JazzArchiveContainer.Sha256File(exported));

        JsonObject inventory = (JsonObject)JsonStrictParser.Parse(
            File.ReadAllBytes(Path.Combine(archive.ArchiveDirectory, "inventory.json")))!;
        var entries = (JsonArray)inventory["entries"]!;
        Assert.NotEmpty(entries);
        Assert.DoesNotContain(
            entries,
            entry => ((string?)entry?["path"])?.StartsWith(
                ArchiveDeliverySyncLog.DirectoryName + "/",
                StringComparison.Ordinal) == true);
    }

    [Fact]
    public void ADeliveryWhoseArchiveDirectoryIsGoneStillProgresses()
    {
        ConfirmedArchive archive = _workspace.Confirm();
        Directory.Delete(archive.ArchiveDirectory, recursive: true);

        ArchiveDeliveryQueue queue = _workspace.OpenQueue();
        queue.BeginAttempt(archive.ArchiveId);
        ArchiveDeliveryRecord record = queue.Acknowledge(archive.ArchiveId, "rcpt-1");

        // The queue owns the package and the record; the projection was only ever a courtesy.
        Assert.Equal(DeliveryLifecycle.Acked, record.State);
        Assert.Equal(DeliveryLifecycle.Acked, _workspace.OpenQueue().Require(archive.ArchiveId).State);
    }

    private static DeliveryStateDocument Document(DeliveryLifecycle state) => new()
    {
        DeliveryId = DeliveryA,
        Transport = DeliveryTransports.JazzArchiveUpload,
        MappingVersion = ArchiveDeliveryRecord.ArchiveUploadMappingVersion,
        SubjectRefs = new[] { new DeliverySubjectRef(DeliverySubjectKinds.Capture, CaptureA) },
        State = state,
        Attempt = state == DeliveryLifecycle.Pending ? 0 : 1,
        UpdatedAt = "2026-08-12T09:00:00.000Z",
    };
}
