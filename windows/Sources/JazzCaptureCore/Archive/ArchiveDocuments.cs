using System.Text.Json.Nodes;
using JazzCaptureCore.Journal;

namespace JazzCaptureCore.Archive;

/// <summary>
/// The payload contracts an importer is allowed to dispatch (ANNEX-ARCHIVE section 2.4). The
/// validator checks <c>manifest.contracts</c> against this hard allowlist, so a producer never
/// invents a record type.
/// </summary>
public static class ArchiveContracts
{
    /// <summary>Record type of the v1 desktop activity event.</summary>
    public const string ActivityEventRecordType = "jazz.activity-event";

    /// <summary>Payload schema of the v1 desktop activity event.</summary>
    public const string ActivityEventPayloadSchema =
        "https://jazz.dev/schema/activity-event.schema.json";

    /// <summary>The only payload contract version this build emits.</summary>
    public const int SchemaVersion = 1;

    /// <summary>Source role of the evidence that triggered an activity event.</summary>
    public const string TriggerRole = "trigger";

    /// <summary>Source role of a capability observation.</summary>
    public const string CapabilityMonitorRole = "capability_monitor";

    /// <summary>Source role of an artifact the producer captured itself.</summary>
    public const string CaptureRole = "capture";

    private static readonly (string RecordType, string SchemaId)[] Allowlist =
    {
        (ActivityEventRecordType, ActivityEventPayloadSchema),
        (CapabilityObservation.RecordType, CapabilityObservation.PayloadSchema),
    };

    /// <summary>
    /// The manifest contract entries for the record types actually present, in allowlist order.
    /// Declaring a contract that no record uses is legal but pointless; declaring one outside the
    /// allowlist fails validation.
    /// </summary>
    /// <exception cref="ArgumentException">A record type is not on the allowlist.</exception>
    public static JsonArray For(IEnumerable<string> recordTypes)
    {
        ArgumentNullException.ThrowIfNull(recordTypes);

        var present = new HashSet<string>(recordTypes, StringComparer.Ordinal);
        foreach (string recordType in present)
        {
            if (!Allowlist.Any(entry => string.Equals(entry.RecordType, recordType, StringComparison.Ordinal)))
            {
                throw new ArgumentException(
                    $"record type '{recordType}' is not an importable payload contract",
                    nameof(recordTypes));
            }
        }

        var contracts = new JsonArray();
        foreach ((string recordType, string schemaId) in Allowlist)
        {
            if (present.Contains(recordType))
            {
                contracts.Add(new JsonObject
                {
                    ["recordType"] = recordType,
                    ["schemaId"] = schemaId,
                    ["schemaVersion"] = SchemaVersion,
                });
            }
        }

        return contracts;
    }
}

/// <summary>
/// Every identifier one finalized archive needs. All of them are minted offline before the capture
/// starts, so a crash never leaves the archive without a stable identity.
/// </summary>
/// <param name="ArchiveId">Package identity; same id plus same contentDigest is idempotent.</param>
/// <param name="OriginId">Identity of the capture installation, not of a tenant.</param>
/// <param name="CaptureId">Identity of the recording.</param>
/// <param name="StreamId">The single evidence stream this producer writes; bound to the capture forever.</param>
/// <param name="SessionId">Legacy transport session id; also the on-disk session directory name.</param>
/// <param name="ActorId">The recorder actor.</param>
/// <param name="SourceId">The capture source.</param>
/// <param name="CommitId">Identity of the closure proof.</param>
public sealed record ArchiveIdentity(
    string ArchiveId,
    string OriginId,
    string CaptureId,
    string StreamId,
    string SessionId,
    string ActorId,
    string SourceId,
    string CommitId)
{
    /// <summary>Mints a fresh set of UUIDv7-based identifiers with the contract prefixes.</summary>
    public static ArchiveIdentity Mint() => new(
        Identifiers.Prefixed("ar"),
        Identifiers.Prefixed("origin"),
        Identifiers.Prefixed("cap"),
        Identifiers.Prefixed("stream"),
        Identifiers.Prefixed("s"),
        Identifiers.Prefixed("actor"),
        Identifiers.Prefixed("src"),
        Identifiers.Prefixed("cmt"));
}

/// <summary>
/// A capability the source could not supply, declared on the manifest source so an absent modality
/// is explicit rather than merely missing.
/// </summary>
/// <param name="Capability">Capability token, for example <c>screen.capture</c>.</param>
/// <param name="Reason">
/// One of <c>not_supported</c>, <c>permission_denied</c>, <c>disabled_by_policy</c>,
/// <c>temporarily_unavailable</c>, <c>not_requested</c>, <c>unknown</c>.
/// </param>
/// <param name="Detail">Optional free text; omitted from the document when null.</param>
public sealed record UnavailableCapability(string Capability, string Reason, string? Detail = null);

/// <summary>One inventory row: a canonical file and the digest of its bytes exactly as written.</summary>
/// <param name="Path">POSIX-relative path inside the archive.</param>
/// <param name="ByteLength">Length of the file on disk.</param>
/// <param name="Sha256">Lowercase hex SHA-256 of the raw file bytes.</param>
public sealed record InventoryEntry(string Path, long ByteLength, string Sha256);

/// <summary>
/// One bracketed label: what the user said they were doing, and the stretch of the stream that
/// declaration covers.
/// </summary>
/// <remarks>
/// The interval endpoints are the <c>label_start</c> and <c>label_end</c> observations themselves,
/// so a label is <em>derived from</em> the record stream rather than stored alongside it. That is
/// what lets the segment survive the journal: the boundaries are durable evidence like any other
/// observation, and the label document is only a reduction over them.
/// </remarks>
/// <param name="LabelId">Label identity, <c>l-</c> plus a UUIDv7.</param>
/// <param name="Text">The declared task name; never empty.</param>
/// <param name="DeclaredAt">When the declaration was made; the <c>label_start</c> timestamp.</param>
/// <param name="StartObservationId">The <c>label_start</c> observation.</param>
/// <param name="StartStreamSequence">Stream position of <paramref name="StartObservationId"/>.</param>
/// <param name="EndObservationId">The <c>label_end</c> observation; null while the segment is open.</param>
/// <param name="EndStreamSequence">Stream position of <paramref name="EndObservationId"/>.</param>
public sealed record LabelSegment(
    string LabelId,
    string Text,
    string DeclaredAt,
    string StartObservationId,
    long StartStreamSequence,
    string? EndObservationId = null,
    long? EndStreamSequence = null)
{
    /// <summary>Prefix required by the schema's <c>labelId</c> pattern.</summary>
    public const string IdPrefix = "l";

    /// <summary>Whether the closing boundary reached the stream, which is what makes it closed.</summary>
    public bool IsClosed => EndObservationId is not null && EndStreamSequence is not null;
}

/// <summary>
/// The frozen policy and producer facts a finalized archive declares about one capture. Everything
/// here is decided before recording starts, so the writer never has to guess.
/// </summary>
/// <param name="StartedAt">Session start (RFC 3339).</param>
/// <param name="EndedAt">Session and commit end (RFC 3339); the two must agree.</param>
/// <param name="ConsentedAt">When the capture policy was consented to.</param>
/// <param name="PolicyVersion">Consent policy version stamped on every record's privacy block.</param>
/// <param name="Modalities">Consented modality tokens of the session capture policy.</param>
/// <param name="ExcludedApplications">Applications the policy excludes from capture.</param>
/// <param name="ProducerName">Producer name written to the manifest and the source.</param>
/// <param name="ProducerVersion">Producer version.</param>
/// <param name="SourceKind">Source kind token, for example <c>windows.capture-controller</c>.</param>
/// <param name="SourceCapabilities">Capability tokens the source actually supplied.</param>
/// <param name="UnavailableCapabilities">Capabilities the source could not supply, with reasons.</param>
public sealed record SessionMetadata(
    string StartedAt,
    string EndedAt,
    string ConsentedAt,
    string PolicyVersion,
    IReadOnlyList<string> Modalities,
    IReadOnlyList<string> ExcludedApplications,
    string ProducerName,
    string ProducerVersion,
    string SourceKind,
    IReadOnlyList<string> SourceCapabilities,
    IReadOnlyList<UnavailableCapability> UnavailableCapabilities)
{
    /// <summary>Whether the capture policy admitted business data; false for the MVP.</summary>
    public bool BusinessDataCapture { get; init; }

    /// <summary>Optional producer platform string; omitted when null.</summary>
    public string? ProducerPlatform { get; init; }

    /// <summary>Optional producer build string; omitted when null.</summary>
    public string? ProducerBuild { get; init; }

    /// <summary>Manifest <c>createdAt</c>; defaults to <see cref="StartedAt"/>.</summary>
    public string? CreatedAt { get; init; }

    /// <summary>Manifest <c>snapshotAt</c>; defaults to <see cref="EndedAt"/>.</summary>
    public string? SnapshotAt { get; init; }
}

/// <summary>
/// Factories for the canonical archive documents. Every factory emits keys in one fixed order and
/// omits absent optional keys entirely — a JSON <c>null</c> fails the format checks — so the bytes
/// on disk stay byte-stable across runs and platforms.
/// </summary>
public static class ArchiveDocuments
{
    /// <summary>The only document schema version this build emits.</summary>
    public const int SchemaVersion = 1;

    /// <summary>Archive format token.</summary>
    public const string Format = "dev.jazz.archive";

    /// <summary>Archive format version.</summary>
    public const int FormatVersion = 1;

    /// <summary>Only revision a first-finalization archive can carry.</summary>
    public const int InitialRevision = 1;

    /// <summary>Declaration mode of a label the user typed in their own words.</summary>
    public const string FreeTextDeclarationMode = "free_text";

    /// <summary>Status of a label whose closing boundary reached the stream.</summary>
    public const string ClosedLabelStatus = "closed";

    /// <summary>Status of a label the capture ended inside; the segment has no closing boundary.</summary>
    public const string InterruptedLabelStatus = "interrupted";

    /// <summary>Builds one observation envelope around an already-built payload.</summary>
    /// <param name="ids">Identifiers of the archive being written.</param>
    /// <param name="observationId">Identity of this observation.</param>
    /// <param name="streamSequence">Position on <see cref="ArchiveIdentity.StreamId"/>.</param>
    /// <param name="capturedAt">When the producer captured the evidence.</param>
    /// <param name="recordType">An <see cref="ArchiveContracts"/> record type.</param>
    /// <param name="payloadSchema">The payload schema bound to <paramref name="recordType"/>.</param>
    /// <param name="sourceRole">Role of the source that supplied the evidence.</param>
    /// <param name="payload">The payload document; taken as-is, never rewritten.</param>
    /// <param name="policyVersion">Consent policy version for the privacy block.</param>
    /// <param name="labelRefs">
    /// Labels this observation belongs to; empty when no bracketed label was open. Carrying the
    /// reference on the envelope means a reader can segment the stream without parsing payloads.
    /// </param>
    public static JsonObject Record(
        ArchiveIdentity ids,
        string observationId,
        long streamSequence,
        string capturedAt,
        string recordType,
        string payloadSchema,
        string sourceRole,
        JsonObject payload,
        string policyVersion,
        IReadOnlyList<string>? labelRefs = null)
    {
        ArgumentNullException.ThrowIfNull(ids);
        ArgumentNullException.ThrowIfNull(payload);

        var labels = new JsonArray();
        foreach (string labelId in labelRefs ?? Array.Empty<string>())
        {
            labels.Add(labelId);
        }

        return new JsonObject
        {
            ["schemaVersion"] = SchemaVersion,
            ["observationId"] = observationId,
            ["originId"] = ids.OriginId,
            ["recordType"] = recordType,
            ["payloadSchema"] = payloadSchema,
            ["captureId"] = ids.CaptureId,
            ["streamId"] = ids.StreamId,
            ["streamSequence"] = streamSequence,
            ["capturedAt"] = capturedAt,
            ["sourceRefs"] = new JsonArray
            {
                new JsonObject
                {
                    ["sourceId"] = ids.SourceId,
                    ["role"] = sourceRole,
                },
            },
            ["actorRefs"] = new JsonArray(),
            ["labelRefs"] = labels,
            ["artifactRefs"] = new JsonArray(),
            ["payload"] = payload.DeepClone(),
            ["provenance"] = new JsonObject
            {
                ["factClass"] = "observed",
                ["sources"] = new JsonArray { ids.SourceId },
            },
            ["quality"] = new JsonObject
            {
                ["status"] = "complete",
                ["reasons"] = new JsonArray(),
            },
            ["privacy"] = new JsonObject
            {
                ["status"] = "captured",
                ["policyVersion"] = policyVersion,
                ["redactions"] = new JsonArray(),
            },
        };
    }

    /// <summary>Builds the observation envelope of a capture capability observation.</summary>
    public static JsonObject CapabilityRecord(
        ArchiveIdentity ids,
        string observationId,
        long streamSequence,
        CapabilityObservation observation,
        string policyVersion)
    {
        ArgumentNullException.ThrowIfNull(observation);

        return Record(
            ids,
            observationId,
            streamSequence,
            observation.ObservedAt,
            CapabilityObservation.RecordType,
            CapabilityObservation.PayloadSchema,
            ArchiveContracts.CapabilityMonitorRole,
            observation.ToPayload(),
            policyVersion);
    }

    /// <summary>
    /// Builds one label document: the user's declaration plus the observation interval it brackets.
    /// </summary>
    /// <param name="ids">Identifiers of the archive being written.</param>
    /// <param name="segment">The reduced segment, as the engine observed its two boundaries.</param>
    /// <remarks>
    /// The declaring actor is the recorder — the MVP has exactly one human in the archive and the
    /// declaration came from the tray in front of them. The text is a claim about intent rather than
    /// something the producer measured, so its provenance is <c>declared</c> even though the interval
    /// around it is observed.
    /// </remarks>
    public static JsonObject Label(ArchiveIdentity ids, LabelSegment segment)
    {
        ArgumentNullException.ThrowIfNull(ids);
        ArgumentNullException.ThrowIfNull(segment);

        var interval = new JsonObject
        {
            ["startObservationId"] = segment.StartObservationId,
            ["startStreamSequence"] = segment.StartStreamSequence,
        };

        // The two end keys are written together or not at all: each one requires the other, so a
        // half-filled interval would fail the schema rather than merely read oddly.
        if (segment is
            {
                EndObservationId: { } endObservationId,
                EndStreamSequence: { } endStreamSequence,
            })
        {
            interval["endObservationId"] = endObservationId;
            interval["endStreamSequence"] = endStreamSequence;
        }

        return new JsonObject
        {
            ["schemaVersion"] = SchemaVersion,
            ["labelId"] = segment.LabelId,
            ["captureId"] = ids.CaptureId,
            ["status"] = segment.IsClosed ? ClosedLabelStatus : InterruptedLabelStatus,
            ["declaration"] = new JsonObject
            {
                ["text"] = segment.Text,
                ["declaredByActorId"] = ids.ActorId,
                ["declaredAt"] = segment.DeclaredAt,
                ["mode"] = FreeTextDeclarationMode,
            },
            ["interval"] = interval,
            // The MVP records no narration, so a label brackets screen activity and nothing else.
            ["narrationArtifactRefs"] = new JsonArray(),
            ["provenance"] = new JsonObject
            {
                ["factClass"] = "declared",
                ["sources"] = new JsonArray { ids.SourceId },
            },
        };
    }

    /// <summary>
    /// Builds one artifact document around bytes the journal has already made durable.
    /// </summary>
    /// <param name="ids">Identifiers of the archive being written.</param>
    /// <param name="artifactId">Identity reserved for this artifact.</param>
    /// <param name="content">Where the bytes live and what they hash to.</param>
    /// <param name="declaration">Everything about the artifact except its bytes.</param>
    /// <param name="policyVersion">
    /// Consent policy version used when <see cref="ArtifactDeclaration.Privacy"/> is absent.
    /// </param>
    /// <remarks>
    /// The declaration is validated here rather than at the write gate because an artifact that
    /// cannot be a valid document is a producer bug, and the producer is still on the stack. The
    /// single declared source and the single declared actor are bound from
    /// <paramref name="ids"/>: the MVP archive has exactly one of each, so a caller cannot name a
    /// source the session never declared.
    /// </remarks>
    /// <exception cref="ArgumentException">The declaration cannot produce a valid artifact.</exception>
    public static JsonObject Artifact(
        ArchiveIdentity ids,
        string artifactId,
        ArtifactFingerprint content,
        ArtifactDeclaration declaration,
        string policyVersion)
    {
        ArgumentNullException.ThrowIfNull(ids);
        ArgumentException.ThrowIfNullOrEmpty(artifactId);
        ArgumentNullException.ThrowIfNull(content);
        ArgumentNullException.ThrowIfNull(declaration);
        ArgumentException.ThrowIfNullOrEmpty(policyVersion);

        declaration.Validate();

        var document = new JsonObject
        {
            ["schemaVersion"] = SchemaVersion,
            ["artifactId"] = artifactId,
            ["captureId"] = ids.CaptureId,
            ["origin"] = declaration.Origin,
            ["kind"] = declaration.Kind,
        };

        if (declaration.ContentSchema is { } contentSchema)
        {
            document["contentSchema"] = contentSchema;
        }

        document["content"] = new JsonObject
        {
            ["path"] = content.ContentPath,
            ["mediaType"] = declaration.MediaType,
            ["byteLength"] = content.ByteLength,
            ["sha256"] = content.Sha256,
        };

        document["sourceRefs"] = new JsonArray
        {
            new JsonObject
            {
                ["sourceId"] = ids.SourceId,
                ["role"] = declaration.SourceRole,
            },
        };

        var actorRefs = new JsonArray();
        foreach (ArtifactActorRef actor in declaration.ActorRefs)
        {
            var reference = new JsonObject
            {
                ["actorId"] = ids.ActorId,
                ["role"] = actor.Role,
                ["basis"] = actor.Basis,
            };

            if (actor.Method is { } method)
            {
                reference["method"] = method;
            }

            actorRefs.Add(reference);
        }

        document["actorRefs"] = actorRefs;
        document["labelRefs"] = Strings(declaration.LabelRefs);
        document["observationRefs"] = Strings(declaration.ObservationRefs);

        if (declaration.CaptureInterval is { } interval)
        {
            var value = new JsonObject { ["startedAt"] = interval.StartedAt };
            if (interval.EndedAt is { } endedAt)
            {
                value["endedAt"] = endedAt;
            }

            document["captureInterval"] = value;
        }

        if (declaration.Derivation is { } derivation)
        {
            var inputs = new JsonArray();
            foreach (ArtifactInputRef input in derivation.InputRefs)
            {
                inputs.Add(new JsonObject
                {
                    ["kind"] = input.Kind,
                    ["id"] = input.Id,
                });
            }

            var value = new JsonObject
            {
                ["producer"] = new JsonObject
                {
                    ["name"] = derivation.ProducerName,
                    ["version"] = derivation.ProducerVersion,
                },
                ["computedAt"] = derivation.ComputedAt,
                ["inputRefs"] = inputs,
            };

            if (derivation.ParametersDigest is { } parametersDigest)
            {
                value["parametersDigest"] = parametersDigest;
            }

            document["derivation"] = value;
        }

        document["provenance"] = new JsonObject
        {
            ["factClass"] = ArtifactOrigins.FactClass(declaration.Origin),
            ["sources"] = new JsonArray { ids.SourceId },
        };

        var quality = new JsonObject
        {
            ["status"] = declaration.Quality.Status,
            ["reasons"] = Strings(declaration.Quality.Reasons),
        };

        if (declaration.Quality.TimingErrorMillis is { } timingErrorMillis)
        {
            quality["timingErrorMillis"] = timingErrorMillis;
        }

        document["quality"] = quality;

        ArtifactPrivacy privacy = declaration.Privacy ?? ArtifactPrivacy.Captured(policyVersion);
        var redactions = new JsonArray();
        foreach (ArtifactRedaction redaction in privacy.Redactions)
        {
            redactions.Add(new JsonObject
            {
                ["path"] = redaction.Path,
                ["action"] = redaction.Action,
                ["reason"] = redaction.Reason,
            });
        }

        document["privacy"] = new JsonObject
        {
            ["status"] = privacy.Status,
            ["policyVersion"] = privacy.PolicyVersion,
            ["redactions"] = redactions,
        };

        // Verbatim: the extensions bag is where a versioned evidence profile lives, and rewriting
        // any part of it would break the cross-field invariants that profile is validated against.
        if (declaration.Extensions is { } extensions)
        {
            document["extensions"] = extensions.DeepClone();
        }

        return document;
    }

    /// <summary>Builds the capture commit — the closure proof of one capture revision.</summary>
    /// <param name="ids">Identifiers of the archive being written.</param>
    /// <param name="revision">Commit revision; equals the manifest revision.</param>
    /// <param name="endedAt">Must equal the session's <c>endedAt</c>.</param>
    /// <param name="summaries">One summary per stream declared by the session.</param>
    /// <param name="orderedObservationDigest">From <see cref="ArchiveDigests.OrderedObservationDigest"/>.</param>
    /// <param name="artifactCount">Number of artifacts belonging to the capture.</param>
    /// <param name="artifactSetDigest">From <see cref="ArchiveDigests.ArtifactSetDigest"/>.</param>
    /// <param name="gaps">Explicitly unobserved sequence ranges; an empty array is a no-gap claim.</param>
    public static JsonObject Commit(
        ArchiveIdentity ids,
        int revision,
        string endedAt,
        IReadOnlyList<StreamSummary> summaries,
        string orderedObservationDigest,
        int artifactCount,
        string artifactSetDigest,
        IReadOnlyList<GapEntry> gaps)
    {
        ArgumentNullException.ThrowIfNull(ids);
        ArgumentNullException.ThrowIfNull(summaries);
        ArgumentNullException.ThrowIfNull(gaps);

        var summaryArray = new JsonArray();
        foreach (StreamSummary summary in summaries)
        {
            summaryArray.Add(new JsonObject
            {
                ["streamId"] = summary.StreamId,
                ["firstSequence"] = summary.FirstSequence,
                ["lastSequence"] = summary.LastSequence,
                ["observationCount"] = summary.ObservationCount,
            });
        }

        var gapArray = new JsonArray();
        foreach (GapEntry gap in gaps)
        {
            var value = new JsonObject
            {
                ["streamId"] = gap.StreamId,
                ["firstSequence"] = gap.FirstSequence,
                ["lastSequence"] = gap.LastSequence,
                ["reason"] = gap.Reason,
            };

            if (gap.Detail is not null)
            {
                value["detail"] = gap.Detail;
            }

            gapArray.Add(value);
        }

        return new JsonObject
        {
            ["schemaVersion"] = SchemaVersion,
            ["commitId"] = ids.CommitId,
            ["captureId"] = ids.CaptureId,
            ["revision"] = revision,
            ["endedAt"] = endedAt,
            ["streamSummaries"] = summaryArray,
            ["orderedObservationDigest"] = orderedObservationDigest,
            ["artifactCount"] = artifactCount,
            ["artifactSetDigest"] = artifactSetDigest,
            ["gaps"] = gapArray,
        };
    }

    /// <summary>Builds the reference that binds the manifest and the session to one commit file.</summary>
    public static JsonObject CaptureCommitRef(ArchiveIdentity ids, string path, string digest)
    {
        ArgumentNullException.ThrowIfNull(ids);

        return new JsonObject
        {
            ["commitId"] = ids.CommitId,
            ["captureId"] = ids.CaptureId,
            ["path"] = path,
            ["digest"] = digest,
        };
    }

    /// <summary>Builds the session document of a finished capture.</summary>
    /// <param name="ids">Identifiers of the archive being written.</param>
    /// <param name="meta">Frozen policy and producer facts.</param>
    /// <param name="status">
    /// <see cref="JournalSessionStatus.Closed"/> when the producer finished the capture itself,
    /// <see cref="JournalSessionStatus.Recovered"/> when crash recovery did.
    /// </param>
    /// <param name="captureCommitRef">The commit reference; deep-equal to the manifest's.</param>
    public static JsonObject Session(
        ArchiveIdentity ids,
        SessionMetadata meta,
        string status,
        JsonObject captureCommitRef)
    {
        ArgumentNullException.ThrowIfNull(ids);
        ArgumentNullException.ThrowIfNull(meta);
        ArgumentNullException.ThrowIfNull(captureCommitRef);

        var modalities = new JsonArray();
        foreach (string modality in meta.Modalities)
        {
            modalities.Add(modality);
        }

        var excluded = new JsonArray();
        foreach (string application in meta.ExcludedApplications)
        {
            excluded.Add(application);
        }

        return new JsonObject
        {
            ["schemaVersion"] = SchemaVersion,
            ["captureId"] = ids.CaptureId,
            ["legacySessionId"] = ids.SessionId,
            ["archiveId"] = ids.ArchiveId,
            ["streamIds"] = new JsonArray { ids.StreamId },
            ["startedAt"] = meta.StartedAt,
            ["endedAt"] = meta.EndedAt,
            ["status"] = status,
            ["recorderActorId"] = ids.ActorId,
            ["sourceIds"] = new JsonArray { ids.SourceId },
            ["capturePolicy"] = new JsonObject
            {
                ["policyVersion"] = meta.PolicyVersion,
                ["consentedAt"] = meta.ConsentedAt,
                ["modalities"] = modalities,
                ["excludedApplications"] = excluded,
                ["businessDataCapture"] = meta.BusinessDataCapture,
            },
            ["captureCommit"] = captureCommitRef.DeepClone(),
            ["quality"] = new JsonObject
            {
                ["status"] = "complete",
                ["reasons"] = new JsonArray(),
            },
        };
    }

    /// <summary>Builds the inventory document over the canonical files, ordered by path.</summary>
    public static JsonObject Inventory(IReadOnlyList<InventoryEntry> entries)
    {
        ArgumentNullException.ThrowIfNull(entries);

        var rows = new JsonArray();
        foreach (InventoryEntry entry in entries)
        {
            rows.Add(new JsonObject
            {
                ["path"] = entry.Path,
                ["byteLength"] = entry.ByteLength,
                ["sha256"] = entry.Sha256,
            });
        }

        return new JsonObject
        {
            ["algorithm"] = "sha256",
            ["entries"] = rows,
        };
    }

    /// <summary>
    /// Builds the finalized manifest without <c>contentDigest</c>. The caller computes that digest
    /// over this document and then appends it as the last key.
    /// </summary>
    /// <param name="ids">Identifiers of the archive being written.</param>
    /// <param name="meta">Frozen policy and producer facts.</param>
    /// <param name="recordTypes">Record types actually present in <c>records.ndjson</c>.</param>
    /// <param name="sessionPath">Relative path of the session document.</param>
    /// <param name="captureCommitRef">The commit reference; deep-equal to the session's.</param>
    /// <param name="inventoryDigest">SHA-256 of the canonical form of the inventory document.</param>
    public static JsonObject Manifest(
        ArchiveIdentity ids,
        SessionMetadata meta,
        IReadOnlyList<string> recordTypes,
        string sessionPath,
        JsonObject captureCommitRef,
        string inventoryDigest)
    {
        ArgumentNullException.ThrowIfNull(ids);
        ArgumentNullException.ThrowIfNull(meta);
        ArgumentNullException.ThrowIfNull(recordTypes);
        ArgumentNullException.ThrowIfNull(captureCommitRef);

        var capabilities = new JsonArray();
        foreach (string capability in meta.SourceCapabilities)
        {
            capabilities.Add(capability);
        }

        var unavailable = new JsonArray();
        foreach (UnavailableCapability capability in meta.UnavailableCapabilities)
        {
            var value = new JsonObject
            {
                ["capability"] = capability.Capability,
                ["reason"] = capability.Reason,
            };

            if (capability.Detail is not null)
            {
                value["detail"] = capability.Detail;
            }

            unavailable.Add(value);
        }

        return new JsonObject
        {
            ["format"] = Format,
            ["formatVersion"] = FormatVersion,
            ["archiveId"] = ids.ArchiveId,
            ["originId"] = ids.OriginId,
            ["revision"] = InitialRevision,
            ["state"] = "finalized",
            ["createdAt"] = meta.CreatedAt ?? meta.StartedAt,
            ["snapshotAt"] = meta.SnapshotAt ?? meta.EndedAt,
            ["producer"] = Producer(meta),
            ["contracts"] = ArchiveContracts.For(recordTypes),
            ["actors"] = new JsonArray
            {
                // The MVP never claims a person identity: the recorder is a declared, anonymous
                // human actor, which is what "we know someone recorded this" means in the contract.
                new JsonObject
                {
                    ["actorId"] = ids.ActorId,
                    ["kind"] = "human",
                    ["identityStatus"] = "anonymous",
                    ["provenance"] = new JsonObject
                    {
                        ["factClass"] = "declared",
                        ["sources"] = new JsonArray(),
                    },
                },
            },
            ["sources"] = new JsonArray
            {
                new JsonObject
                {
                    ["sourceId"] = ids.SourceId,
                    ["kind"] = meta.SourceKind,
                    ["actorId"] = ids.ActorId,
                    ["producer"] = Producer(meta),
                    ["capabilities"] = capabilities,
                    ["unavailableCapabilities"] = unavailable,
                    ["provenance"] = new JsonObject
                    {
                        ["factClass"] = "observed",
                        ["sources"] = new JsonArray(),
                    },
                },
            },
            ["sessions"] = new JsonArray
            {
                new JsonObject
                {
                    ["captureId"] = ids.CaptureId,
                    ["legacySessionId"] = ids.SessionId,
                    ["path"] = sessionPath,
                },
            },
            ["captureCommits"] = new JsonArray { captureCommitRef.DeepClone() },
            ["inventory"] = new JsonObject
            {
                ["path"] = "inventory.json",
                ["algorithm"] = "sha256",
                ["digest"] = inventoryDigest,
            },
        };
    }

    private static JsonArray Strings(IReadOnlyList<string> values)
    {
        var array = new JsonArray();
        foreach (string value in values)
        {
            array.Add(value);
        }

        return array;
    }

    private static JsonObject Producer(SessionMetadata meta)
    {
        var producer = new JsonObject
        {
            ["name"] = meta.ProducerName,
            ["version"] = meta.ProducerVersion,
        };

        if (meta.ProducerBuild is not null)
        {
            producer["build"] = meta.ProducerBuild;
        }

        if (meta.ProducerPlatform is not null)
        {
            producer["platform"] = meta.ProducerPlatform;
        }

        return producer;
    }
}
