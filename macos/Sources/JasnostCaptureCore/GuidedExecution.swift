import Foundation

// MARK: - Server-owned guided execution contract

/// A content-addressed pin to the only process artifact the desktop may guide from. The server
/// reviews and approves the RunbookVersion; the desktop never derives executable instructions from
/// raw ActivityEvents, screenshots, coordinates, or a timeline.
public struct GuidedApprovedRunbookPin: Codable, Equatable, Sendable {
    public var runbookId: String
    public var runbookVersionId: String
    public var contentDigest: String
    public var version: Int
    public var scope: GuidedExecutionScope
    public var status: GuidedRunbookStatus

    public init(
        runbookId: String,
        runbookVersionId: String,
        contentDigest: String,
        version: Int,
        scope: GuidedExecutionScope,
        status: GuidedRunbookStatus
    ) {
        self.runbookId = runbookId
        self.runbookVersionId = runbookVersionId
        self.contentDigest = contentDigest
        self.version = version
        self.scope = scope
        self.status = status
    }
}

public enum GuidedRunbookStatus: String, Codable, Equatable, Sendable {
    case proposed
    case inReview
    case changesRequested
    case approved
    case rejected
    case deprecated
}

public struct GuidedExecutionScope: Codable, Equatable, Sendable {
    public var companyId: String
    public var areaId: String
    public var processId: String

    public init(companyId: String, areaId: String, processId: String) {
        self.companyId = companyId
        self.areaId = areaId
        self.processId = processId
    }
}

public struct GuidedRunbookReference: Codable, Equatable, Sendable {
    public var runbookId: String
    public var runbookVersionId: String
    public var contentDigest: String
    public var version: Int
    public var scope: GuidedExecutionScope
}

public enum GuidedEvidenceKind: String, Codable, Equatable, Sendable {
    case event
    case screenshot
    case transcript
    case observation
    case artifact
    case transcriptSpan = "transcript_span"
    case assertion
    case coachInteraction = "coach_interaction"
}

public struct GuidedEvidenceReference: Codable, Equatable, Sendable {
    public var kind: GuidedEvidenceKind
    public var ref: String
    public var confidence: Double?
}

public struct GuidedCapability: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var version: String

    public init(id: String, version: String) {
        self.id = id
        self.version = version
    }
}

public struct GuidedResolverIdentity: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var version: String

    public init(id: String, version: String) {
        self.id = id
        self.version = version
    }
}

public struct GuidedTrustedCapability: Codable, Equatable, Sendable {
    public var id: String
    public var version: String
    public var evidence: [GuidedEvidenceReference]
}

public struct GuidedCapabilityRequirement: Codable, Equatable, Sendable {
    public var id: String
    public var version: String
    public var required: Bool
}

public struct GuidedPreconditionClaim: Codable, Equatable, Sendable {
    public var conditionId: String
    public var satisfied: Bool
    public var evidence: [GuidedEvidenceReference]
}

public struct GuidedPrecondition: Codable, Equatable, Sendable {
    public var conditionId: String
    public var description: String
    public var required: Bool
    public var evidence: [GuidedEvidenceReference]
}

public enum GuidedLocatorKind: String, Codable, Equatable, Sendable {
    case accessibility
    case dom
    case url
    case businessObject
    case visual
    case coordinate
}

public enum GuidedLocatorUsage: String, Codable, Equatable, Sendable {
    case execution
    case playbackOnly
}

public enum GuidedLocatorSupport: String, Codable, Equatable, Sendable {
    case supported
    case unsupported
}

public struct GuidedSemanticLocator: Codable, Equatable, Sendable {
    public var locatorId: String
    public var order: Int
    public var kind: GuidedLocatorKind
    public var value: String
    public var usage: GuidedLocatorUsage
    public var support: GuidedLocatorSupport
    public var evidence: [GuidedEvidenceReference]
}

public struct GuidedLocatorResolution: Codable, Equatable, Sendable {
    public var stepId: String
    public var locatorId: String
    public var kind: GuidedLocatorKind
    public var matchCount: Int
    public var applicationId: String
    public var resolvedAt: String
    public var evidence: [GuidedEvidenceReference]
}

public enum GuidedApplicationCompatibility: String, Codable, Equatable, Sendable {
    case compatible
    case incompatible
    case unknown
}

public struct GuidedApplicationObservation: Codable, Equatable, Sendable {
    public var applicationId: String
    public var observedVersion: String
    public var environment: String?
    public var matchedVersionConstraint: String
    public var compatibility: GuidedApplicationCompatibility
    public var resolver: GuidedResolverIdentity
    public var observedAt: String
    public var evidence: [GuidedEvidenceReference]
}

public struct GuidedApplicationConstraint: Codable, Equatable, Sendable {
    public var applicationId: String
    public var versionConstraint: String
    public var environment: String?
    public var evidence: [GuidedEvidenceReference]
}

public enum GuidedConstraintState: String, Codable, Equatable, Sendable {
    case unknown
    case defined
}

public struct GuidedApplicationConstraints: Codable, Equatable, Sendable {
    public var state: GuidedConstraintState
    public var constraints: [GuidedApplicationConstraint]
}

public enum GuidedAnchorFreshnessStatus: String, Codable, Equatable, Sendable {
    case fresh
    case stale
    case unknown
}

public struct GuidedAnchorFreshness: Codable, Equatable, Sendable {
    public var status: GuidedAnchorFreshnessStatus
    public var checkedAt: String
    public var expiresAt: String?
}

public enum GuidedBusinessObjectOutcome: String, Codable, Equatable, Sendable {
    case verified
    case missing
    case stale
    case ambiguous
    case deleted
    case permissionDenied = "permission_denied"
    case notFound = "not_found"
}

public enum GuidedBusinessObjectLifecycle: String, Codable, Equatable, Sendable {
    case proposed
    case verified
    case disputed
    case superseded
}

public struct GuidedBusinessObjectInput: Codable, Equatable, Sendable {
    public var role: String
    public var scope: GuidedExecutionScope
    public var systemNamespace: String
    public var connectionId: String
    public var objectType: String
    public var externalId: String
    public var anchorAssertionRef: String
    public var anchorAssertionDigest: String
    public var outcome: GuidedBusinessObjectOutcome
    public var lifecycle: GuidedBusinessObjectLifecycle
    public var freshness: GuidedAnchorFreshness
    public var resolvedAt: String
    public var evidence: [GuidedEvidenceReference]
}

public struct GuidedTrustedAnchorObject: Codable, Equatable, Sendable {
    public var connectionId: String
    public var systemNamespace: String
    public var objectType: String
    public var externalId: String
}

public struct GuidedTrustedAnchorPin: Codable, Equatable, Sendable {
    public var assertionId: String
    public var contentDigest: String
    public var scope: GuidedExecutionScope
    public var outcome: GuidedBusinessObjectOutcome
    public var lifecycle: GuidedBusinessObjectLifecycle
    public var retrievedAt: String
    public var object: GuidedTrustedAnchorObject
    public var freshness: GuidedAnchorFreshness
}

public struct GuidedBusinessObjectSpec: Codable, Equatable, Sendable {
    public var systemNamespace: String
    public var objectType: String
    public var role: String
    public var access: String
    public var anchorRequired: Bool
}

public struct GuidedBusinessObjects: Codable, Equatable, Sendable {
    public var inputs: [GuidedBusinessObjectSpec]
    public var outputs: [GuidedBusinessObjectSpec]
}

public struct GuidedApprovalReceipt: Codable, Equatable, Sendable {
    public var approvalId: String
    public var stepId: String
    public var executionId: String
    public var decision: GuidedApprovalDecision
    public var approverId: String
    public var approverRole: String
    public var approvalPolicy: GuidedApprovalPolicySnapshot
    public var approvalScopeKey: String
    public var decidedAt: String
    public var expiresAt: String
    public var boundRunbookVersionId: String
    public var boundRunbookContentDigest: String
}

public struct GuidedApprovalPolicySnapshot: Codable, Equatable, Sendable {
    public var policyId: String
    public var revision: String
    public var policyDigest: String
    public var policySource: String
    public var approverRole: String
    public var resolvedAt: String
    public var validFrom: String
    public var validUntil: String
    public var aggregation: GuidedApprovalAggregation? = nil
}

public struct GuidedApprovalAggregation: Codable, Equatable, Sendable {
    public var approverIds: [String]
    public var requiredApprovals: Int
    public var denySemantics: String
}

public struct GuidedApprovalHeadPin: Codable, Equatable, Sendable {
    public var approverId: String
    public var approvalId: String
    public var decision: GuidedApprovalDecision
}

public struct GuidedApprovalEvaluation: Codable, Equatable, Sendable {
    public var currentHeadPins: [GuidedApprovalHeadPin]
    public var selectedApprovalIds: [String]
    public var vetoApprovalIds: [String]
}

public enum GuidedOperatorAssignmentState: String, Codable, Equatable, Sendable {
    case active
    case inactive
    case expired
    case revoked
}

public enum GuidedOperatorEligibilityState: String, Codable, Equatable, Sendable {
    case eligible
    case ineligible
}

public struct GuidedNextOperatorAssignment: Codable, Equatable, Sendable {
    public var assignmentId: String
    public var nextAssigneeId: String
    public var eligibleRole: String
    public var evidence: [GuidedEvidenceReference]
}

public struct GuidedOperatorEligibility: Codable, Equatable, Sendable {
    public var snapshotDigest: String
    public var policyId: String
    public var revision: String
    public var policyDigest: String
    public var policySource: String
    public var scope: GuidedExecutionScope
    public var principalId: String
    public var actorRole: String
    public var stepId: String
    public var executionId: String
    public var assignmentId: String
    public var assignmentState: GuidedOperatorAssignmentState
    public var assignmentEvidence: [GuidedEvidenceReference]
    public var eligibilityState: GuidedOperatorEligibilityState
    public var eligibilityEvidence: [GuidedEvidenceReference]
    public var resolvedAt: String
    public var validUntil: String
    public var nextAssignment: GuidedNextOperatorAssignment?
}

public enum GuidedApprovalPolicyStateStatus: String, Codable, Equatable, Sendable {
    case active
    case expired
    case revoked
    case unauthorized
    case superseded
}

public struct GuidedApprovalPolicyState: Codable, Equatable, Sendable {
    public var approvalId: String
    public var policyId: String
    public var revision: String
    public var policyDigest: String
    public var approverRole: String
    public var resolvedAt: String
    public var status: GuidedApprovalPolicyStateStatus
    public var revokedAt: String?
    public var revocationRef: String?
}

public struct GuidedTrustedRuntimeContext: Codable, Equatable, Sendable {
    public var resolver: GuidedResolverIdentity
    public var resolvedAt: String
    public var requestContextDigest: String
    public var capabilities: [GuidedTrustedCapability]
    public var preconditions: [GuidedPreconditionClaim]
    public var locatorResolution: GuidedLocatorResolution?
    public var applicationObservations: [GuidedApplicationObservation]
    public var evidence: [GuidedEvidenceReference]
}

public enum GuidedApprovalDecision: String, Codable, Equatable, Sendable {
    case approved
    case denied
}

public enum GuidedApprovalPolicy: String, Codable, Equatable, Sendable {
    case none
    case perExecution
    case perStep
}

public struct GuidedApprovalRequirement: Codable, Equatable, Sendable {
    public var required: Bool
    public var policy: GuidedApprovalPolicy
    public var approverRole: String?
}

public enum GuidedSideEffectClass: String, Codable, Equatable, Sendable {
    case readOnly
    case reversible
    case irreversible
    case unknown
}

public enum GuidedHandoffMode: String, Codable, Equatable, Sendable {
    case unknown
    case none
    case transfer
}

public struct GuidedHandoffContract: Codable, Equatable, Sendable {
    public var mode: GuidedHandoffMode
    public var recipientRole: String?
    public var acceptanceConditions: [String]
    public var acceptanceProof: [GuidedCompletionProofRequirement]
}

public struct GuidedCompletionProofRequirement: Codable, Equatable, Sendable {
    public var kind: String
    public var description: String
}

public enum GuidedControlFlowMode: String, Codable, Equatable, Sendable {
    case unknown
    case sequential
    case decision
    case terminal
}

public struct GuidedControlFlowBranch: Codable, Equatable, Sendable {
    public var order: Int
    public var branchId: String
    public var condition: String
    public var outcome: String
    public var targetStepId: String?
    public var evidence: [GuidedEvidenceReference]
}

public struct GuidedControlFlow: Codable, Equatable, Sendable {
    public var mode: GuidedControlFlowMode
    public var branches: [GuidedControlFlowBranch]
}

public enum GuidedExceptionPolicyState: String, Codable, Equatable, Sendable {
    case unknown
    case defined
}

public enum GuidedExceptionPathOutcome: String, Codable, Equatable, Sendable {
    case recovery
    case escalation
    case stop
}

public struct GuidedExceptionPath: Codable, Equatable, Sendable {
    public var order: Int
    public var pathId: String
    public var trigger: String
    public var action: String
    public var outcome: GuidedExceptionPathOutcome
    public var targetStepId: String?
    public var evidence: [GuidedEvidenceReference]
}

public struct GuidedExceptionPolicy: Codable, Equatable, Sendable {
    public var state: GuidedExceptionPolicyState
    public var paths: [GuidedExceptionPath]
}

public enum GuidedIdempotencyStrategy: String, Codable, Equatable, Sendable {
    case notApplicable
    case operatorConfirmation
    case businessObjectKey
    case externalKey
}

public enum GuidedRetryPolicy: String, Codable, Equatable, Sendable {
    case neverAfterAttempt
    case retryReadOnlyWhenNotObserved
}

public struct GuidedIdempotencyContract: Codable, Equatable, Sendable {
    public var strategy: GuidedIdempotencyStrategy
    public var keyTemplate: String
    public var retryPolicy: GuidedRetryPolicy
}

public struct GuidedProcessExecutionReference: Codable, Equatable, Sendable {
    public var executionId: String
    public var bindingId: String
    public var bindingContentDigest: String
    public var businessTransactionKey: String
}

public struct GuidedReplayRequest: Codable, Equatable, Sendable {
    public var requestVersion: String
    public var executionId: String
    public var scope: GuidedExecutionScope
    public var runbookVersionId: String
    public var runbookContentDigest: String
    public var operatorId: String
    public var requestedAt: String
    public var idempotencyKey: String
    public var targetStepId: String?
    public var locatorResolution: GuidedLocatorResolution?
    public var capabilities: [GuidedCapability]
    public var preconditions: [GuidedPreconditionClaim]
    public var approvals: [GuidedApprovalReceipt]
    public var applicationObservations: [GuidedApplicationObservation]
    public var businessObjectInputs: [GuidedBusinessObjectInput]
    /// Injected by the server after it resolves a legacy execution alias or canonical `pex_`
    /// identity. Normal clients cannot nominate this binding reference.
    public var processExecution: GuidedProcessExecutionReference? = nil
}

public enum GuidedReplayCheckKind: String, Codable, Equatable, Sendable {
    case runbookReview
    case runtimeAuthority
    case sequence
    case capability
    case precondition
    case locator
    case application
    case businessObject
    case operatorEligibility
    case approval
    case idempotency
}

public enum GuidedReplayCheckStatus: String, Codable, Equatable, Sendable {
    case pass
    case fail
}

public struct GuidedReplayCheck: Codable, Equatable, Sendable {
    public var kind: GuidedReplayCheckKind
    public var key: String
    public var status: GuidedReplayCheckStatus
    public var reason: String
    public var evidence: [GuidedEvidenceReference]
}

public struct GuidedValidationPolicy: Codable, Equatable, Sendable {
    public var maxAgeSeconds: Int
}

public struct GuidedAuthorizedStep: Codable, Equatable, Sendable {
    public var variantRef: String
    public var stepId: String
    public var sequence: Int
    public var signature: String
    public var instruction: String
    public var actorRole: String
    public var expectedOutcome: String
    public var sourceFactRefs: [String]
    public var evidence: [GuidedEvidenceReference]
    public var requiredCapabilities: [GuidedCapabilityRequirement]
    public var preconditions: [GuidedPrecondition]
    public var postconditions: [GuidedPrecondition]
    public var locators: [GuidedSemanticLocator]
    public var businessObjects: GuidedBusinessObjects
    public var controlFlow: GuidedControlFlow
    public var exceptionPolicy: GuidedExceptionPolicy
    public var handoff: GuidedHandoffContract
    public var applicationConstraints: GuidedApplicationConstraints
    public var sideEffectClass: GuidedSideEffectClass
    public var approval: GuidedApprovalRequirement
    public var idempotency: GuidedIdempotencyContract
    public var completionProof: [GuidedCompletionProofRequirement]
    public var gapRefs: [String]
}

public enum GuidedReplayDecisionStatus: String, Codable, Equatable, Sendable {
    case ready
    case blocked
    case duplicate
    case complete
}

public struct GuidedReplayDecision: Codable, Equatable, Sendable {
    public var artifactType: String
    public var schemaVersion: String
    public var decisionId: String
    public var contentDigest: String
    public var requestDigest: String
    public var request: GuidedReplayRequest
    public var runbook: GuidedRunbookReference
    public var evaluatedAt: String
    public var validationPolicy: GuidedValidationPolicy
    public var trustedRuntimeContext: GuidedTrustedRuntimeContext
    public var trustedAnchorPins: [GuidedTrustedAnchorPin]
    public var trustedApprovalStates: [GuidedApprovalPolicyState]
    public var trustedApprovalPolicy: GuidedApprovalPolicySnapshot? = nil
    public var approvalEvaluation: GuidedApprovalEvaluation? = nil
    public var operatorEligibility: GuidedOperatorEligibility? = nil
    public var attemptNumber: Int
    public var logicalOperationKey: String
    public var status: GuidedReplayDecisionStatus
    public var checks: [GuidedReplayCheck]
    public var authorizedStep: GuidedAuthorizedStep?
    public var duplicateOf: String?
    public var retryOf: String?
}

// MARK: - Exclusive server execution lifecycle

/// The immutable lease returned by CLAIM. `claimProofDigest` is safe to retain in server artifacts;
/// the raw proof is absent from the portable/server contract and may exist only in the
/// permission-restricted active local attempt journal until a terminal transition.
public struct GuidedExecutionClaim: Codable, Equatable, Sendable {
    public var artifactType: String
    public var schemaVersion: String
    public var claimId: String
    public var contentDigest: String
    public var claimRequestId: String
    public var claimProofDigest: String
    public var decisionId: String
    public var decisionContentDigest: String
    public var runbook: GuidedRunbookReference
    public var executionId: String
    public var variantRef: String
    public var stepId: String
    public var logicalOperationKey: String
    public var attemptNumber: Int
    public var operatorId: String
    public var replayHostId: String
    public var claimedAt: String
    public var leaseExpiresAt: String
    public var state: String
    public var supersedesClaimId: String?
}

/// The sole server artifact which crosses the action-authority boundary. A READY decision and a
/// claim are preparation only.
public struct GuidedExecutionStartReceipt: Codable, Equatable, Sendable {
    public var artifactType: String
    public var schemaVersion: String
    public var startReceiptId: String
    public var contentDigest: String
    public var startRequestId: String
    public var claimId: String
    public var claimContentDigest: String
    public var decisionId: String
    public var decisionContentDigest: String
    public var runbook: GuidedRunbookReference
    public var executionId: String
    public var variantRef: String
    public var stepId: String
    public var logicalOperationKey: String
    public var attemptNumber: Int
    public var operatorId: String
    public var replayHostId: String
    public var startedAt: String
    public var operatorEligibility: GuidedOperatorEligibility? = nil
    public var authorityDecision: GuidedReplayDecision
}

public enum GuidedExecutionReconciliationResolution: String, Codable, Equatable, Sendable {
    case cancelledBeforeStart
    case reconciliationRequired
    case unknown
}

public struct GuidedReconciliationAuthority: Codable, Equatable, Sendable {
    public var principalId: String
    public var action: String
    public var scope: GuidedExecutionScope
    /// Legacy persisted authority remains readable while new responses carry the exact policy
    /// snapshot fields below.
    public var authorizationSource: String? = nil
    public var policyId: String? = nil
    public var revision: String? = nil
    public var policyDigest: String? = nil
    public var policySource: String? = nil
    public var resolvedAt: String
    public var validFrom: String? = nil
    public var validUntil: String? = nil
    public var evidence: [GuidedEvidenceReference]
    public var authorityDigest: String
}

public struct GuidedTrustedReconciliation: Codable, Equatable, Sendable {
    public var resolver: GuidedResolverIdentity
    public var resolvedAt: String
    public var decisionId: String
    public var resolution: String
    public var observationDigest: String
    public var evidence: [GuidedEvidenceReference]
}

public struct GuidedExecutionReconciliation: Codable, Equatable, Sendable {
    public var artifactType: String
    public var schemaVersion: String
    public var reconciliationId: String
    public var contentDigest: String
    public var reconciliationRequestId: String
    public var claimId: String
    public var claimContentDigest: String
    public var startReceiptId: String?
    public var startReceiptContentDigest: String?
    public var decisionId: String
    public var decisionContentDigest: String
    public var runbook: GuidedRunbookReference
    public var executionId: String
    public var variantRef: String
    public var stepId: String
    public var logicalOperationKey: String
    public var attemptNumber: Int
    public var resolution: GuidedExecutionReconciliationResolution
    public var reason: String
    public var resolvedBy: String
    public var resolvedAt: String
    public var evidence: [GuidedEvidenceReference]
    public var submittedEvidence: [GuidedEvidenceReference]? = nil
    public var requestInputDigest: String? = nil
    public var authoritySnapshot: GuidedReconciliationAuthority?
    public var supersedesReconciliationId: String?
    public var trustedReconciliation: GuidedTrustedReconciliation?
}

public enum GuidedReplayLifecycleState: String, Codable, Equatable, Sendable {
    case claimed
    case expired
    case cancelled
    case started
    case reconciliationRequired = "reconciliation_required"
    case unresolved
    case receipted
    case reconciled
}

public struct GuidedReplayClaimLifecycle: Codable, Equatable, Sendable {
    public var claim: GuidedExecutionClaim
    public var lifecycleState: GuidedReplayLifecycleState
    public var leaseExpired: Bool
    public var startReceipt: GuidedExecutionStartReceipt?
    public var latestReconciliation: GuidedExecutionReconciliation?
    public var receipt: GuidedExecutionReceipt?
}

// MARK: - Runtime revalidation and explicit confirmation

public struct GuidedUserConfirmation: Codable, Equatable, Sendable {
    public var confirmed: Bool
    public var confirmedAt: String
    public var operatorId: String
    public var decisionId: String
    public var stepId: String

    public init(
        confirmed: Bool,
        confirmedAt: String,
        operatorId: String,
        decisionId: String,
        stepId: String
    ) {
        self.confirmed = confirmed
        self.confirmedAt = confirmedAt
        self.operatorId = operatorId
        self.decisionId = decisionId
        self.stepId = stepId
    }
}

/// Fresh local facts sampled immediately before the desktop presents an actionable instruction.
/// No coordinates or captured keystrokes are accepted here.
public struct GuidedRuntimeSnapshot: Codable, Equatable, Sendable {
    public var observedAt: String
    public var operatorId: String
    public var capabilities: [GuidedCapability]
    public var preconditions: [GuidedPreconditionClaim]
    public var locatorResolution: GuidedLocatorResolution
    public var applicationObservations: [GuidedApplicationObservation]
    public var businessObjectInputs: [GuidedBusinessObjectInput]
    public var userConfirmation: GuidedUserConfirmation?

    public init(
        observedAt: String,
        operatorId: String,
        capabilities: [GuidedCapability],
        preconditions: [GuidedPreconditionClaim],
        locatorResolution: GuidedLocatorResolution,
        applicationObservations: [GuidedApplicationObservation],
        businessObjectInputs: [GuidedBusinessObjectInput],
        userConfirmation: GuidedUserConfirmation?
    ) {
        self.observedAt = observedAt
        self.operatorId = operatorId
        self.capabilities = capabilities
        self.preconditions = preconditions
        self.locatorResolution = locatorResolution
        self.applicationObservations = applicationObservations
        self.businessObjectInputs = businessObjectInputs
        self.userConfirmation = userConfirmation
    }
}

/// A locally revalidated PREPARED result. It intentionally omits the instruction and locator value,
/// so code cannot accidentally treat READY as authority to act.
public struct GuidedPreparedReplay: Codable, Equatable, Sendable {
    public var decisionId: String
    public var decisionContentDigest: String
    public var executionId: String
    public var runbookVersionId: String
    public var runbookContentDigest: String
    public var stepId: String
    public var operatorId: String
    public var logicalOperationKey: String
    public var attemptNumber: Int
    public var retryOf: String?
}

public struct GuidedActionPermit: Equatable, Sendable {
    public let decisionId: String
    public let decisionContentDigest: String
    public let claimId: String
    public let claimContentDigest: String
    public let startReceiptId: String
    public let startReceiptContentDigest: String
    public let executionId: String
    public let runbookVersionId: String
    public let runbookContentDigest: String
    public let stepId: String
    public let operatorId: String
    public let idempotencyKey: String
    public let logicalOperationKey: String
    public let attemptNumber: Int
    public let retryOf: String?
    public let replayHostId: String
    public let startedAt: String
    public let instruction: String
    public let actorRole: String
    public let expectedOutcome: String
    public let semanticLocator: GuidedSemanticLocator
    public let sideEffectClass: GuidedSideEffectClass

    fileprivate init(
        decisionId: String,
        decisionContentDigest: String,
        claimId: String,
        claimContentDigest: String,
        startReceiptId: String,
        startReceiptContentDigest: String,
        executionId: String,
        runbookVersionId: String,
        runbookContentDigest: String,
        stepId: String,
        operatorId: String,
        idempotencyKey: String,
        logicalOperationKey: String,
        attemptNumber: Int,
        retryOf: String?,
        replayHostId: String,
        startedAt: String,
        instruction: String,
        actorRole: String,
        expectedOutcome: String,
        semanticLocator: GuidedSemanticLocator,
        sideEffectClass: GuidedSideEffectClass
    ) {
        self.decisionId = decisionId
        self.decisionContentDigest = decisionContentDigest
        self.claimId = claimId
        self.claimContentDigest = claimContentDigest
        self.startReceiptId = startReceiptId
        self.startReceiptContentDigest = startReceiptContentDigest
        self.executionId = executionId
        self.runbookVersionId = runbookVersionId
        self.runbookContentDigest = runbookContentDigest
        self.stepId = stepId
        self.operatorId = operatorId
        self.idempotencyKey = idempotencyKey
        self.logicalOperationKey = logicalOperationKey
        self.attemptNumber = attemptNumber
        self.retryOf = retryOf
        self.replayHostId = replayHostId
        self.startedAt = startedAt
        self.instruction = instruction
        self.actorRole = actorRole
        self.expectedOutcome = expectedOutcome
        self.semanticLocator = semanticLocator
        self.sideEffectClass = sideEffectClass
    }
}

public struct GuidedExecutionFixture: Codable, Equatable, Sendable {
    public var protocolName: String
    public var protocolVersion: Int
    public var approvedRunbook: GuidedApprovedRunbookPin
    public var decision: GuidedReplayDecision
    public var priorReceipts: [GuidedExecutionReceipt]
    public var runtime: GuidedRuntimeSnapshot
    public var evidencePlayback: [EvidencePlaybackItem]
    /// Historical v1 fixtures contain the pre-claim permit shape. Keep the bytes readable without
    /// admitting that object into the executable permit type.
    public var expectedPermit: JazzArchiveJSONValue

    private enum CodingKeys: String, CodingKey {
        case protocolName = "protocol"
        case protocolVersion, approvedRunbook, decision, priorReceipts, runtime
        case evidencePlayback, expectedPermit
    }
}

// MARK: - Append-only execution receipts

public enum GuidedReceiptStatus: String, Codable, Equatable, Sendable {
    case succeeded
    case partial
    case failed
    case aborted
}

public enum GuidedHandoffOutcomeState: String, Codable, Equatable, Sendable {
    case notApplicable
    case pending
    case accepted
    case rejected
}

public struct GuidedHandoffOutcome: Codable, Equatable, Sendable {
    public var state: GuidedHandoffOutcomeState
    public var recipientRole: String?
    public var nextAssigneeId: String? = nil
    public var eligibleRole: String? = nil
    public var conditionsMet: [String]
    public var evidence: [GuidedEvidenceReference]
}

public struct GuidedExecutionContext: Codable, Equatable, Sendable {
    public var locatorResolution: GuidedLocatorResolution
    public var applicationObservations: [GuidedApplicationObservation]
    public var businessObjectInputs: [GuidedBusinessObjectInput]
    public var trustedRuntimeContext: GuidedTrustedRuntimeContext
    public var trustedAnchorPins: [GuidedTrustedAnchorPin]
    public var trustedApprovalStates: [GuidedApprovalPolicyState]
    public var trustedApprovalPolicy: GuidedApprovalPolicySnapshot? = nil
    public var approvalEvaluation: GuidedApprovalEvaluation? = nil
    public var validationPolicy: GuidedValidationPolicy
}

public enum GuidedBranchDecisionState: String, Codable, Equatable, Sendable {
    case notApplicable
    case selected
}

public struct GuidedBranchDecision: Codable, Equatable, Sendable {
    public var state: GuidedBranchDecisionState
    public var branchId: String?
    public var outcome: String?
    public var targetStepId: String?
    public var evidence: [GuidedEvidenceReference]
}

public enum GuidedSideEffectOutcome: String, Codable, Equatable, Sendable {
    case observed
    case notObserved
    case unknown
}

public struct GuidedSideEffectObservation: Codable, Equatable, Sendable {
    public var classification: GuidedSideEffectClass
    public var outcome: GuidedSideEffectOutcome
    public var description: String
    public var evidence: [GuidedEvidenceReference]
}

public enum GuidedInterventionKind: String, Codable, Equatable, Sendable {
    case `operator`
    case coach
    case processOwner
    case system
}

public struct GuidedIntervention: Codable, Equatable, Sendable {
    public var kind: GuidedInterventionKind
    public var description: String
    public var actorId: String?
    public var occurredAt: String
    public var evidence: [GuidedEvidenceReference]
}

public enum GuidedStructuredResultState: String, Codable, Equatable, Sendable {
    case completed
    case partial
    case failed
    case aborted
}

public struct GuidedStructuredResult: Codable, Equatable, Sendable {
    public var state: GuidedStructuredResultState
    public var summary: String
    public var resumeFromStepId: String?
}

public struct GuidedCompletionProof: Codable, Equatable, Sendable {
    public var kind: String
    public var description: String
    public var proofRef: String
    public var assertedBy: String
    public var assertedAt: String
    public var evidence: [GuidedEvidenceReference]
}

public struct GuidedTrustedCompletion: Codable, Equatable, Sendable {
    public var resolver: GuidedResolverIdentity
    public var resolvedAt: String
    public var decisionId: String
    public var resultDigest: String
    public var evidence: [GuidedEvidenceReference]
}

public enum GuidedExecutionRecoverability: String, Codable, Equatable, Sendable {
    case retryable
    case manual
    case terminal
}

public struct GuidedExecutionException: Codable, Equatable, Sendable {
    public var kind: String
    public var summary: String
    public var pathId: String?
    public var recoverability: GuidedExecutionRecoverability
    public var evidence: [GuidedEvidenceReference]
}

public struct GuidedExecutionReceipt: Codable, Equatable, Sendable {
    public var artifactType: String
    public var schemaVersion: String
    public var receiptId: String
    public var contentDigest: String
    public var claimId: String?
    public var claimContentDigest: String?
    public var startReceiptId: String?
    public var startReceiptContentDigest: String?
    public var recordedVia: GuidedReceiptRecordingMode?
    public var receiptRequestId: String?
    public var executionId: String
    public var decisionId: String
    public var decisionContentDigest: String
    public var requestDigest: String
    public var runbook: GuidedRunbookReference
    public var variantRef: String
    public var stepId: String
    public var operatorId: String
    public var operatorEligibility: GuidedOperatorEligibility? = nil
    public var idempotencyKey: String
    public var logicalOperationKey: String
    public var idempotencyStrategy: GuidedIdempotencyStrategy
    public var idempotencyKeyTemplate: String
    public var retryPolicy: GuidedRetryPolicy
    public var attemptNumber: Int
    public var retryOf: String?
    public var startedAt: String
    public var completedAt: String
    public var status: GuidedReceiptStatus
    public var approvalsUsed: [GuidedApprovalReceipt]
    public var executionContext: GuidedExecutionContext
    public var controlFlowRequirement: GuidedControlFlow
    public var branchDecision: GuidedBranchDecision
    public var handoffRequirement: GuidedHandoffContract
    public var handoffOutcome: GuidedHandoffOutcome
    public var sideEffectClass: GuidedSideEffectClass
    public var sideEffects: [GuidedSideEffectObservation]
    public var interventions: [GuidedIntervention]
    public var result: GuidedStructuredResult
    public var postconditionRequirements: [GuidedPrecondition]
    public var postconditions: [GuidedPreconditionClaim]
    public var completionProofRequirements: [GuidedCompletionProofRequirement]
    public var proofs: [GuidedCompletionProof]
    public var trustedCompletion: GuidedTrustedCompletion
    /// Kept as a lossless JSON subtree because the server owns reconciliation authority and may
    /// extend its audit context independently of the desktop UI.
    public var reconciliation: JazzArchiveJSONValue?
    public var exception: GuidedExecutionException?
}

public enum GuidedReceiptRecordingMode: String, Codable, Equatable, Sendable {
    case direct
    case reconciliation
}

/// A server artifact decoded together with its complete JSON tree and original response bytes.
/// The typed mirror is used only for fields the desktop must understand. Unknown server fields
/// remain in `rawData` and `canonicalData` and therefore remain covered by the server's content
/// address instead of disappearing in a decode/encode cycle.
public struct GuidedReplayDecisionDocument: Equatable, Sendable {
    public let decision: GuidedReplayDecision
    public let rawData: Data
    public let canonicalData: Data

    public init(serverData: Data) throws {
        let decoder = JSONDecoder()
        let source = try decoder.decode(JazzArchiveJSONValue.self, from: serverData)
        try GuidedExecutionContentAddress.validateDecision(source)
        self.decision = try decoder.decode(GuidedReplayDecision.self, from: serverData)
        self.rawData = serverData
        self.canonicalData = try JazzArchiveCanonicalJSON.encode(source)
    }
}

public struct GuidedExecutionReceiptDocument: Equatable, Sendable {
    public let receipt: GuidedExecutionReceipt
    public let rawData: Data
    public let canonicalData: Data

    public init(serverData: Data) throws {
        let decoder = JSONDecoder()
        let source = try decoder.decode(JazzArchiveJSONValue.self, from: serverData)
        try GuidedExecutionContentAddress.validateReceipt(source)
        let receipt = try decoder.decode(GuidedExecutionReceipt.self, from: serverData)
        try GuidedExecutionValidator.validateReceipt(receipt)
        self.receipt = receipt
        self.rawData = serverData
        self.canonicalData = try JazzArchiveCanonicalJSON.encode(source)
    }

    public init(receipt: GuidedExecutionReceipt) throws {
        try self.init(serverData: JazzArchiveCanonicalJSON.encode(receipt))
    }
}

public struct GuidedExecutionClaimDocument: Equatable, Sendable {
    public let claim: GuidedExecutionClaim
    public let rawData: Data
    public let canonicalData: Data

    public init(serverData: Data) throws {
        let source = try JSONDecoder().decode(JazzArchiveJSONValue.self, from: serverData)
        try GuidedExecutionContentAddress.validateClaim(source)
        let claim = try JSONDecoder().decode(GuidedExecutionClaim.self, from: serverData)
        try GuidedExecutionValidator.validateClaim(claim)
        self.claim = claim
        self.rawData = serverData
        self.canonicalData = try JazzArchiveCanonicalJSON.encode(source)
    }
}

public struct GuidedExecutionStartReceiptDocument: Equatable, Sendable {
    public let startReceipt: GuidedExecutionStartReceipt
    public let rawData: Data
    public let canonicalData: Data

    public init(serverData: Data) throws {
        let source = try JSONDecoder().decode(JazzArchiveJSONValue.self, from: serverData)
        try GuidedExecutionContentAddress.validateStartReceipt(source)
        let receipt = try JSONDecoder().decode(GuidedExecutionStartReceipt.self, from: serverData)
        try GuidedExecutionValidator.validateStartReceipt(receipt)
        self.startReceipt = receipt
        self.rawData = serverData
        self.canonicalData = try JazzArchiveCanonicalJSON.encode(source)
    }
}

public struct GuidedExecutionReconciliationDocument: Equatable, Sendable {
    public let reconciliation: GuidedExecutionReconciliation
    public let rawData: Data
    public let canonicalData: Data

    public init(serverData: Data) throws {
        let source = try JSONDecoder().decode(JazzArchiveJSONValue.self, from: serverData)
        try GuidedExecutionContentAddress.validateReconciliation(source)
        let value = try JSONDecoder().decode(GuidedExecutionReconciliation.self, from: serverData)
        try GuidedExecutionValidator.validateReconciliation(value)
        self.reconciliation = value
        self.rawData = serverData
        self.canonicalData = try JazzArchiveCanonicalJSON.encode(source)
    }
}

public struct GuidedReplayClaimLifecycleDocument: Equatable, Sendable {
    public let lifecycle: GuidedReplayClaimLifecycle
    public let claimDocument: GuidedExecutionClaimDocument
    public let startReceiptDocument: GuidedExecutionStartReceiptDocument?
    public let reconciliationDocument: GuidedExecutionReconciliationDocument?
    public let receiptDocument: GuidedExecutionReceiptDocument?
    public let rawData: Data
    public let canonicalData: Data

    public init(serverData: Data) throws {
        let source = try JSONDecoder().decode(JazzArchiveJSONValue.self, from: serverData)
        guard case let .object(object) = source else {
            throw GuidedExecutionError.invalidField("claimLifecycle")
        }
        func requiredDocument(_ key: String) throws -> Data {
            guard let value = object[key], value != .null else {
                throw GuidedExecutionError.invalidField("claimLifecycle.\(key)")
            }
            return try JazzArchiveCanonicalJSON.encode(value)
        }
        func optionalDocument(_ key: String) throws -> Data? {
            guard let value = object[key], value != .null else { return nil }
            return try JazzArchiveCanonicalJSON.encode(value)
        }

        let lifecycle = try JSONDecoder().decode(GuidedReplayClaimLifecycle.self, from: serverData)
        let claimDocument = try GuidedExecutionClaimDocument(
            serverData: requiredDocument("claim"))
        let startDocument = try optionalDocument("startReceipt").map {
            try GuidedExecutionStartReceiptDocument(serverData: $0)
        }
        let reconciliationDocument = try optionalDocument("latestReconciliation").map {
            try GuidedExecutionReconciliationDocument(serverData: $0)
        }
        let receiptDocument = try optionalDocument("receipt").map {
            try GuidedExecutionReceiptDocument(serverData: $0)
        }
        guard lifecycle.claim == claimDocument.claim,
            lifecycle.startReceipt == startDocument?.startReceipt,
            lifecycle.latestReconciliation == reconciliationDocument?.reconciliation,
            lifecycle.receipt == receiptDocument?.receipt
        else { throw GuidedExecutionError.invalidField("claimLifecycle projection") }
        switch lifecycle.lifecycleState {
        case .claimed, .expired:
            guard startDocument == nil, receiptDocument == nil else {
                throw GuidedExecutionError.invalidField("claimLifecycle pre-start state")
            }
        case .cancelled:
            guard startDocument == nil,
                reconciliationDocument?.reconciliation.resolution == .cancelledBeforeStart
            else { throw GuidedExecutionError.invalidField("claimLifecycle cancelled state") }
        case .started, .reconciliationRequired, .unresolved:
            guard startDocument != nil, receiptDocument == nil else {
                throw GuidedExecutionError.invalidField("claimLifecycle started state")
            }
        case .receipted, .reconciled:
            guard startDocument != nil, receiptDocument != nil else {
                throw GuidedExecutionError.invalidField("claimLifecycle receipt state")
            }
        }
        self.lifecycle = lifecycle
        self.claimDocument = claimDocument
        self.startReceiptDocument = startDocument
        self.reconciliationDocument = reconciliationDocument
        self.receiptDocument = receiptDocument
        self.rawData = serverData
        self.canonicalData = try JazzArchiveCanonicalJSON.encode(source)
    }
}

private enum GuidedExecutionContentAddress {
    static func validateDecision(_ value: JazzArchiveJSONValue) throws {
        let object = try object(value, field: "decision")
        try artifactType(object, expected: "guidedReplayDecision", field: "decision")
        try validateArtifact(
            object,
            idField: "decisionId",
            idPrefix: "grd_",
            field: "decision")
        let request = try required(object, "request", field: "decision")
        try validateDigest(
            expected: try digest(request),
            actual: try string(object, "requestDigest", field: "decision"),
            field: "decision.requestDigest")
        let requestObject = try self.object(request, field: "decision.request")
        var context: [String: JazzArchiveJSONValue] = [:]
        for key in [
            "capabilities", "preconditions", "applicationObservations", "businessObjectInputs",
        ] {
            context[key] = try required(requestObject, key, field: "decision.request")
        }
        if let locator = requestObject["locatorResolution"] {
            context["locatorResolution"] = locator
        }
        let trusted = try self.object(
            try required(object, "trustedRuntimeContext", field: "decision"),
            field: "decision.trustedRuntimeContext")
        try validateDigest(
            expected: try digest(.object(context)),
            actual: try string(
                trusted, "requestContextDigest", field: "decision.trustedRuntimeContext"),
            field: "decision.trustedRuntimeContext.requestContextDigest")
    }

    static func validateReceipt(_ value: JazzArchiveJSONValue) throws {
        let object = try object(value, field: "receipt")
        try artifactType(object, expected: "executionReceipt", field: "receipt")
        try validateArtifact(
            object,
            idField: "receiptId",
            idPrefix: "ger_",
            field: "receipt")
        var result: [String: JazzArchiveJSONValue] = [:]
        for key in [
            "status", "startedAt", "completedAt", "proofs", "postconditions",
            "branchDecision", "handoffOutcome", "sideEffects", "interventions", "result",
        ] {
            result[key] = try required(object, key, field: "receipt")
        }
        if let exception = object["exception"] { result["exception"] = exception }
        let trusted = try self.object(
            try required(object, "trustedCompletion", field: "receipt"),
            field: "receipt.trustedCompletion")
        try validateDigest(
            expected: try digest(.object(result)),
            actual: try string(trusted, "resultDigest", field: "receipt.trustedCompletion"),
            field: "receipt.trustedCompletion.resultDigest")
    }

    static func validateClaim(_ value: JazzArchiveJSONValue) throws {
        let object = try object(value, field: "claim")
        try artifactType(object, expected: "executionClaim", field: "claim")
        try validateArtifact(
            object, idField: "claimId", idPrefix: "gec_", field: "claim")
    }

    static func validateStartReceipt(_ value: JazzArchiveJSONValue) throws {
        let object = try object(value, field: "startReceipt")
        try artifactType(
            object, expected: "executionStartReceipt", field: "startReceipt")
        try validateArtifact(
            object, idField: "startReceiptId", idPrefix: "ges_", field: "startReceipt")
        let authority = try required(object, "authorityDecision", field: "startReceipt")
        try validateDecision(authority)
    }

    static func validateReconciliation(_ value: JazzArchiveJSONValue) throws {
        let object = try object(value, field: "reconciliation")
        try artifactType(
            object, expected: "executionReconciliation", field: "reconciliation")
        try validateArtifact(
            object,
            idField: "reconciliationId",
            idPrefix: "gerc_",
            field: "reconciliation")
    }

    private static func validateArtifact(
        _ object: [String: JazzArchiveJSONValue],
        idField: String,
        idPrefix: String,
        field: String
    ) throws {
        var material = object
        material.removeValue(forKey: idField)
        material.removeValue(forKey: "contentDigest")
        let expected = try digest(.object(material))
        try validateDigest(
            expected: expected,
            actual: try string(object, "contentDigest", field: field),
            field: "\(field).contentDigest")
        let hex = String(expected.dropFirst("sha256:".count))
        guard try string(object, idField, field: field) == idPrefix + hex.prefix(32) else {
            throw GuidedExecutionError.contentAddressMismatch("\(field).\(idField)")
        }
    }

    private static func artifactType(
        _ object: [String: JazzArchiveJSONValue],
        expected: String,
        field: String
    ) throws {
        guard try string(object, "artifactType", field: field) == expected else {
            throw GuidedExecutionError.invalidField("\(field).artifactType")
        }
    }

    private static func digest(_ value: JazzArchiveJSONValue) throws -> String {
        "sha256:" + JazzArchiveDigest.sha256Hex(try JazzArchiveCanonicalJSON.encode(value))
    }

    private static func object(
        _ value: JazzArchiveJSONValue,
        field: String
    ) throws -> [String: JazzArchiveJSONValue] {
        guard case let .object(result) = value else {
            throw GuidedExecutionError.invalidField(field)
        }
        return result
    }

    private static func required(
        _ object: [String: JazzArchiveJSONValue],
        _ key: String,
        field: String
    ) throws -> JazzArchiveJSONValue {
        guard let value = object[key] else {
            throw GuidedExecutionError.invalidField("\(field).\(key)")
        }
        return value
    }

    private static func string(
        _ object: [String: JazzArchiveJSONValue],
        _ key: String,
        field: String
    ) throws -> String {
        guard case let .string(value) = try required(object, key, field: field) else {
            throw GuidedExecutionError.invalidField("\(field).\(key)")
        }
        return value
    }

    private static func validateDigest(
        expected: String,
        actual: String,
        field: String
    ) throws {
        guard expected == actual else {
            throw GuidedExecutionError.contentAddressMismatch(field)
        }
    }
}

/// A serial, append-only NDJSON sink for immutable server execution receipts. Re-appending the
/// exact receipt is idempotent; reusing an identity for different content fails closed. There is no
/// update or delete API.
public actor GuidedExecutionReceiptJournal {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func receipts() throws -> [GuidedExecutionReceipt] {
        try documents().map(\.receipt)
    }

    public func documents() throws -> [GuidedExecutionReceiptDocument] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try data.split(separator: 0x0A).map {
            try GuidedExecutionReceiptDocument(serverData: Data($0))
        }
    }

    @discardableResult
    public func append(_ receipt: GuidedExecutionReceipt) throws -> Bool {
        try append(GuidedExecutionReceiptDocument(receipt: receipt))
    }

    /// Preferred ingress for a server response: every schema field is proven to survive before
    /// the immutable line is admitted to the local journal.
    @discardableResult
    public func appendServerReceipt(_ data: Data) throws -> Bool {
        try append(GuidedExecutionReceiptDocument(serverData: data))
    }

    @discardableResult
    public func append(_ document: GuidedExecutionReceiptDocument) throws -> Bool {
        let receipt = document.receipt
        let existing = try documents()
        if let prior = existing.first(where: { $0.receipt.receiptId == receipt.receiptId }) {
            guard prior.canonicalData == document.canonicalData else {
                throw GuidedExecutionError.receiptIdentityConflict(receipt.receiptId)
            }
            return false
        }
        if let conflict = existing.first(where: {
            $0.receipt.executionId == receipt.executionId
                && $0.receipt.logicalOperationKey == receipt.logicalOperationKey
                && ($0.receipt.stepId != receipt.stepId
                    || $0.receipt.runbook.runbookVersionId != receipt.runbook.runbookVersionId)
        }) {
            throw GuidedExecutionError.idempotencyConflict(conflict.receipt.logicalOperationKey)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        var line = document.canonicalData
        line.append(0x0A)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: line) else {
                throw GuidedExecutionError.receiptWriteFailed
            }
        } else {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.synchronize()
        }
        return true
    }
}

public enum GuidedExecutionError: Error, Equatable, CustomStringConvertible {
    case invalidField(String)
    case runbookNotApproved
    case runbookPinMismatch
    case decisionNotReady
    case startReceiptRequired
    case claimBindingMismatch
    case startReceiptBindingMismatch
    case claimProofMismatch
    case requestIdentityConflict(String)
    case lifecycleStateConflict(String)
    case lifecycleWriteFailed
    case claimProofUnavailable
    case reconciliationRequired
    case failedServerCheck(String)
    case staleObservation(String)
    case missingCapability(String)
    case preconditionFailed(String)
    case unsafeLocator
    case ambiguousLocator
    case incompatibleApplication(String)
    case businessObjectUnverified(String)
    case approvalMissing
    case userConfirmationMissing
    case alreadyCompleted(String)
    case idempotencyConflict(String)
    case handoffNotAccepted
    case receiptIdentityConflict(String)
    case receiptWriteFailed
    case lossyContractDecode(String)
    case contentAddressMismatch(String)
    case refreshBindingMismatch

    public var description: String {
        switch self {
        case let .invalidField(field): "Invalid guided execution field: \(field)"
        case .runbookNotApproved: "RunbookVersion is not approved"
        case .runbookPinMismatch: "Guided decision does not match the exact RunbookVersion digest"
        case .decisionNotReady: "Server guided replay decision is not ready"
        case .startReceiptRequired:
            "A READY decision is preparation only; an exact server start receipt is required"
        case .claimBindingMismatch: "Execution claim is not bound to the prepared decision"
        case .startReceiptBindingMismatch:
            "Execution start receipt is not bound to the exact decision and claim"
        case .claimProofMismatch: "Execution claim proof does not match the stored digest"
        case let .requestIdentityConflict(id):
            "Caller-stable guided execution request identity conflicts: \(id)"
        case let .lifecycleStateConflict(state):
            "Guided execution lifecycle cannot transition from \(state)"
        case .lifecycleWriteFailed: "Guided execution lifecycle could not be persisted"
        case .claimProofUnavailable:
            "The claim proof is unavailable after restart; reconcile instead of retrying the action"
        case .reconciliationRequired:
            "A started execution has no trusted receipt and requires reconciliation"
        case let .failedServerCheck(key): "Server guided replay check failed: \(key)"
        case let .staleObservation(field): "Runtime observation is stale: \(field)"
        case let .missingCapability(id): "Required capability is missing: \(id)"
        case let .preconditionFailed(id): "Required precondition is not satisfied: \(id)"
        case .unsafeLocator: "No supported semantic execution locator is available"
        case .ambiguousLocator: "Semantic locator did not resolve exactly one target"
        case let .incompatibleApplication(id): "Application is incompatible: \(id)"
        case let .businessObjectUnverified(role): "Business object is not verified: \(role)"
        case .approvalMissing: "A bound server approval is required"
        case .userConfirmationMissing: "Explicit operator confirmation is required"
        case let .alreadyCompleted(key): "The side effect is already completed: \(key)"
        case let .idempotencyConflict(key): "Idempotency key conflicts with another step: \(key)"
        case .handoffNotAccepted: "The prior operator's handoff was not accepted"
        case let .receiptIdentityConflict(id): "Receipt identity has different content: \(id)"
        case .receiptWriteFailed: "Execution receipt could not be appended"
        case let .lossyContractDecode(type):
            "Guided execution contract mirror would lose fields from \(type)"
        case let .contentAddressMismatch(field):
            "Guided execution content address does not match: \(field)"
        case .refreshBindingMismatch:
            "Refreshed guided authority is not an exact successor of its predecessor"
        }
    }
}

public enum GuidedExecutionValidator {
    /// Compatibility entry point for old callers. It intentionally never returns an action
    /// permit: READY stopped being an action-authority state in protocol v2.
    public static func authorize(
        decision: GuidedReplayDecision,
        approvedRunbook: GuidedApprovedRunbookPin,
        runtime: GuidedRuntimeSnapshot,
        priorReceipts: [GuidedExecutionReceipt]
    ) throws -> GuidedActionPermit {
        _ = try prepare(
            decision: decision,
            approvedRunbook: approvedRunbook,
            runtime: runtime,
            priorReceipts: priorReceipts)
        throw GuidedExecutionError.startReceiptRequired
    }

    public static func prepare(
        decision: GuidedReplayDecision,
        approvedRunbook: GuidedApprovedRunbookPin,
        runtime: GuidedRuntimeSnapshot,
        priorReceipts: [GuidedExecutionReceipt]
    ) throws -> GuidedPreparedReplay {
        _ = try validatePrepared(
            decision: decision,
            approvedRunbook: approvedRunbook,
            runtime: runtime,
            priorReceipts: priorReceipts)
        return GuidedPreparedReplay(
            decisionId: decision.decisionId,
            decisionContentDigest: decision.contentDigest,
            executionId: decision.request.executionId,
            runbookVersionId: decision.runbook.runbookVersionId,
            runbookContentDigest: decision.runbook.contentDigest,
            stepId: decision.authorizedStep?.stepId ?? "",
            operatorId: decision.request.operatorId,
            logicalOperationKey: decision.logicalOperationKey,
            attemptNumber: decision.attemptNumber,
            retryOf: decision.retryOf)
    }

    /// Mint an actionable permit only from content-address-validated server documents and the
    /// exact claim/start binding. Typed values alone are intentionally insufficient.
    public static func authorizeStart(
        decisionDocument: GuidedReplayDecisionDocument,
        claimDocument: GuidedExecutionClaimDocument,
        startReceiptDocument: GuidedExecutionStartReceiptDocument,
        approvedRunbook: GuidedApprovedRunbookPin,
        runtime: GuidedRuntimeSnapshot,
        priorReceipts: [GuidedExecutionReceipt]
    ) throws -> GuidedActionPermit {
        let decision = decisionDocument.decision
        let claim = claimDocument.claim
        let start = startReceiptDocument.startReceipt
        let validated = try validatePrepared(
            decision: decision,
            approvedRunbook: approvedRunbook,
            runtime: runtime,
            priorReceipts: priorReceipts)
        try validateBinding(decision: decision, claim: claim, start: start)
        return GuidedActionPermit(
            decisionId: decision.decisionId,
            decisionContentDigest: decision.contentDigest,
            claimId: claim.claimId,
            claimContentDigest: claim.contentDigest,
            startReceiptId: start.startReceiptId,
            startReceiptContentDigest: start.contentDigest,
            executionId: decision.request.executionId,
            runbookVersionId: decision.runbook.runbookVersionId,
            runbookContentDigest: decision.runbook.contentDigest,
            stepId: validated.step.stepId,
            operatorId: runtime.operatorId,
            idempotencyKey: decision.request.idempotencyKey,
            logicalOperationKey: decision.logicalOperationKey,
            attemptNumber: decision.attemptNumber,
            retryOf: decision.retryOf,
            replayHostId: claim.replayHostId,
            startedAt: start.startedAt,
            instruction: validated.step.instruction,
            actorRole: validated.step.actorRole,
            expectedOutcome: validated.step.expectedOutcome,
            semanticLocator: validated.locator,
            sideEffectClass: validated.step.sideEffectClass)
    }

    private static func validatePrepared(
        decision: GuidedReplayDecision,
        approvedRunbook: GuidedApprovedRunbookPin,
        runtime: GuidedRuntimeSnapshot,
        priorReceipts: [GuidedExecutionReceipt]
    ) throws -> (step: GuidedAuthorizedStep, locator: GuidedSemanticLocator) {
        try validateDecisionEnvelope(decision)
        guard approvedRunbook.status == .approved else {
            throw GuidedExecutionError.runbookNotApproved
        }
        try validateDigest(approvedRunbook.contentDigest, field: "approvedRunbook.contentDigest")
        let request = decision.request
        let runbook = decision.runbook
        guard runbook.runbookId == approvedRunbook.runbookId,
            runbook.runbookVersionId == approvedRunbook.runbookVersionId,
            runbook.contentDigest == approvedRunbook.contentDigest,
            runbook.version == approvedRunbook.version,
            runbook.scope == approvedRunbook.scope,
            request.runbookVersionId == runbook.runbookVersionId,
            request.runbookContentDigest == runbook.contentDigest,
            request.scope == runbook.scope
        else { throw GuidedExecutionError.runbookPinMismatch }
        guard decision.status == .ready, let step = decision.authorizedStep else {
            throw GuidedExecutionError.decisionNotReady
        }
        guard decision.attemptNumber >= 1,
            request.idempotencyKey == decision.logicalOperationKey,
            (decision.retryOf == nil || decision.attemptNumber > 1)
        else { throw GuidedExecutionError.invalidField("decision attempt identity") }
        guard request.targetStepId == step.stepId else {
            throw GuidedExecutionError.invalidField("request.targetStepId")
        }
        guard !decision.checks.isEmpty else {
            throw GuidedExecutionError.invalidField("checks")
        }
        if let failed = decision.checks.first(where: { $0.status != .pass }) {
            throw GuidedExecutionError.failedServerCheck(failed.key)
        }
        guard runtime.operatorId == request.operatorId else {
            throw GuidedExecutionError.invalidField("runtime.operatorId")
        }
        let now = try timestamp(runtime.observedAt, field: "runtime.observedAt")
        guard decision.validationPolicy.maxAgeSeconds > 0 else {
            throw GuidedExecutionError.invalidField("validationPolicy.maxAgeSeconds")
        }
        try fresh(
            decision.evaluatedAt,
            now: now,
            maxAgeSeconds: decision.validationPolicy.maxAgeSeconds,
            field: "decision.evaluatedAt")
        try fresh(
            decision.trustedRuntimeContext.resolvedAt,
            now: now,
            maxAgeSeconds: decision.validationPolicy.maxAgeSeconds,
            field: "trustedRuntimeContext.resolvedAt")

        try validatePriorReceipts(
            priorReceipts,
            decision: decision,
            step: step,
            runtimeOperator: runtime.operatorId)
        try validateCapabilities(
            step,
            request: request,
            trusted: decision.trustedRuntimeContext,
            runtime: runtime)
        try validatePreconditions(
            step,
            trusted: decision.trustedRuntimeContext,
            runtime: runtime)
        let locator = try validateLocator(
            step,
            trusted: decision.trustedRuntimeContext,
            runtime: runtime,
            now: now,
            maxAgeSeconds: decision.validationPolicy.maxAgeSeconds)
        try validateApplications(
            step,
            locator: locator,
            trusted: decision.trustedRuntimeContext,
            runtime: runtime,
            now: now,
            maxAgeSeconds: decision.validationPolicy.maxAgeSeconds)
        try validateBusinessObjects(
            step,
            runbookScope: runbook.scope,
            trustedPins: decision.trustedAnchorPins,
            runtime: runtime,
            now: now,
            maxAgeSeconds: decision.validationPolicy.maxAgeSeconds)
        try validateApprovalAndConfirmation(
            decision,
            step: step,
            runtime: runtime,
            now: now,
            maxAgeSeconds: decision.validationPolicy.maxAgeSeconds)
        try nonempty(step.actorRole, field: "authorizedStep.actorRole")
        try nonempty(step.expectedOutcome, field: "authorizedStep.expectedOutcome")

        return (step, locator)
    }

    public static func validateClaim(_ claim: GuidedExecutionClaim) throws {
        guard claim.artifactType == "executionClaim", claim.schemaVersion == "1",
            claim.state == "claimed", claim.attemptNumber >= 1
        else { throw GuidedExecutionError.invalidField("claim protocol") }
        for (value, field) in [
            (claim.claimId, "claim.claimId"),
            (claim.claimRequestId, "claim.claimRequestId"),
            (claim.decisionId, "claim.decisionId"),
            (claim.executionId, "claim.executionId"),
            (claim.variantRef, "claim.variantRef"),
            (claim.stepId, "claim.stepId"),
            (claim.logicalOperationKey, "claim.logicalOperationKey"),
            (claim.operatorId, "claim.operatorId"),
            (claim.replayHostId, "claim.replayHostId"),
        ] {
            try nonempty(value, field: field)
        }
        try validateDigest(claim.contentDigest, field: "claim.contentDigest")
        try validateDigest(claim.claimProofDigest, field: "claim.claimProofDigest")
        try validateDigest(
            claim.decisionContentDigest, field: "claim.decisionContentDigest")
        try validateDigest(claim.runbook.contentDigest, field: "claim.runbook.contentDigest")
        let claimed = try timestamp(claim.claimedAt, field: "claim.claimedAt")
        let expires = try timestamp(claim.leaseExpiresAt, field: "claim.leaseExpiresAt")
        guard expires > claimed, claim.supersedesClaimId != claim.claimId else {
            throw GuidedExecutionError.invalidField("claim lease")
        }
    }

    public static func validateClaim(
        _ document: GuidedExecutionClaimDocument,
        for decisionDocument: GuidedReplayDecisionDocument,
        expectedRequestId: String,
        expectedProofDigest: String,
        replayHostId: String
    ) throws {
        let claim = document.claim
        let decision = decisionDocument.decision
        guard let step = decision.authorizedStep,
            claim.claimRequestId == expectedRequestId,
            claim.claimProofDigest == expectedProofDigest,
            claim.replayHostId == replayHostId,
            claim.decisionId == decision.decisionId,
            claim.decisionContentDigest == decision.contentDigest,
            claim.runbook == decision.runbook,
            claim.executionId == decision.request.executionId,
            claim.variantRef == step.variantRef,
            claim.stepId == step.stepId,
            claim.logicalOperationKey == decision.logicalOperationKey,
            claim.attemptNumber == decision.attemptNumber,
            claim.operatorId == decision.request.operatorId
        else { throw GuidedExecutionError.claimBindingMismatch }
    }

    public static func validateStartReceipt(_ receipt: GuidedExecutionStartReceipt) throws {
        guard receipt.artifactType == "executionStartReceipt", receipt.schemaVersion == "1",
            receipt.attemptNumber >= 1
        else { throw GuidedExecutionError.invalidField("start receipt protocol") }
        for (value, field) in [
            (receipt.startReceiptId, "startReceipt.startReceiptId"),
            (receipt.startRequestId, "startReceipt.startRequestId"),
            (receipt.claimId, "startReceipt.claimId"),
            (receipt.decisionId, "startReceipt.decisionId"),
            (receipt.executionId, "startReceipt.executionId"),
            (receipt.variantRef, "startReceipt.variantRef"),
            (receipt.stepId, "startReceipt.stepId"),
            (receipt.logicalOperationKey, "startReceipt.logicalOperationKey"),
            (receipt.operatorId, "startReceipt.operatorId"),
            (receipt.replayHostId, "startReceipt.replayHostId"),
        ] {
            try nonempty(value, field: field)
        }
        try validateDigest(receipt.contentDigest, field: "startReceipt.contentDigest")
        try validateDigest(
            receipt.claimContentDigest, field: "startReceipt.claimContentDigest")
        try validateDigest(
            receipt.decisionContentDigest, field: "startReceipt.decisionContentDigest")
        try validateDecisionEnvelope(receipt.authorityDecision)
        guard receipt.authorityDecision.status == .ready,
            receipt.authorityDecision.authorizedStep != nil
        else { throw GuidedExecutionError.decisionNotReady }
        let started = try timestamp(receipt.startedAt, field: "startReceipt.startedAt")
        let evaluated = try timestamp(
            receipt.authorityDecision.evaluatedAt,
            field: "startReceipt.authorityDecision.evaluatedAt")
        guard started >= evaluated else {
            throw GuidedExecutionError.invalidField("startReceipt.startedAt")
        }
    }

    public static func validateStartReceipt(
        _ document: GuidedExecutionStartReceiptDocument,
        for decisionDocument: GuidedReplayDecisionDocument,
        claimDocument: GuidedExecutionClaimDocument,
        expectedRequestId: String
    ) throws {
        guard document.startReceipt.startRequestId == expectedRequestId else {
            throw GuidedExecutionError.requestIdentityConflict(expectedRequestId)
        }
        try validateBinding(
            decision: decisionDocument.decision,
            claim: claimDocument.claim,
            start: document.startReceipt)
    }

    public static func validateReconciliation(
        _ reconciliation: GuidedExecutionReconciliation
    ) throws {
        guard reconciliation.artifactType == "executionReconciliation",
            reconciliation.schemaVersion == "1",
            reconciliation.attemptNumber >= 1
        else { throw GuidedExecutionError.invalidField("reconciliation protocol") }
        try validateDigest(
            reconciliation.contentDigest, field: "reconciliation.contentDigest")
        try validateDigest(
            reconciliation.claimContentDigest, field: "reconciliation.claimContentDigest")
        try validateDigest(
            reconciliation.decisionContentDigest,
            field: "reconciliation.decisionContentDigest")
        _ = try timestamp(reconciliation.resolvedAt, field: "reconciliation.resolvedAt")
        let hasStart = reconciliation.startReceiptId != nil
        guard hasStart == (reconciliation.startReceiptContentDigest != nil) else {
            throw GuidedExecutionError.invalidField("reconciliation start binding")
        }
        if reconciliation.resolution == .cancelledBeforeStart {
            guard !hasStart, reconciliation.authoritySnapshot == nil,
                reconciliation.trustedReconciliation == nil
            else { throw GuidedExecutionError.invalidField("pre-start reconciliation") }
        } else {
            guard hasStart, let authority = reconciliation.authoritySnapshot,
                authority.action == "replay.reconcile",
                authority.principalId == reconciliation.resolvedBy,
                authority.scope == reconciliation.runbook.scope,
                authority.resolvedAt == reconciliation.resolvedAt
            else { throw GuidedExecutionError.invalidField("reconciliation authority") }
            try validateDigest(
                authority.authorityDigest,
                field: "reconciliation.authoritySnapshot.authorityDigest")
            let legacyAuthority =
                authority.authorizationSource?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty == false
            let policyAuthority =
                [
                    authority.policyId,
                    authority.revision,
                    authority.policySource,
                ].allSatisfy {
                    $0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                }
                && authority.policyDigest != nil
                && authority.validFrom != nil
                && authority.validUntil != nil
            guard legacyAuthority != policyAuthority else {
                throw GuidedExecutionError.invalidField("reconciliation authority shape")
            }
            if policyAuthority {
                try validateDigest(
                    authority.policyDigest!,
                    field: "reconciliation.authoritySnapshot.policyDigest")
                let validFrom = try timestamp(
                    authority.validFrom!,
                    field: "reconciliation.authoritySnapshot.validFrom")
                let resolvedAt = try timestamp(
                    authority.resolvedAt,
                    field: "reconciliation.authoritySnapshot.resolvedAt")
                let validUntil = try timestamp(
                    authority.validUntil!,
                    field: "reconciliation.authoritySnapshot.validUntil")
                guard validFrom <= resolvedAt, resolvedAt < validUntil else {
                    throw GuidedExecutionError.invalidField(
                        "reconciliation authority validity")
                }
            }
        }
        guard
            (reconciliation.submittedEvidence == nil)
                == (reconciliation.requestInputDigest == nil)
        else {
            throw GuidedExecutionError.invalidField("reconciliation submitted evidence")
        }
        if let digest = reconciliation.requestInputDigest {
            try validateDigest(digest, field: "reconciliation.requestInputDigest")
        }
        if reconciliation.resolution == .unknown {
            guard let trusted = reconciliation.trustedReconciliation,
                trusted.decisionId == reconciliation.decisionId,
                trusted.resolution == "unknown"
            else { throw GuidedExecutionError.invalidField("trusted reconciliation") }
            try validateDigest(
                trusted.observationDigest,
                field: "reconciliation.trustedReconciliation.observationDigest")
        } else if reconciliation.trustedReconciliation != nil {
            throw GuidedExecutionError.invalidField("trusted reconciliation")
        }
    }

    public static func validateReceipt(_ receipt: GuidedExecutionReceipt) throws {
        guard receipt.artifactType == "executionReceipt",
            receipt.schemaVersion == "1" || receipt.schemaVersion == "2"
        else {
            throw GuidedExecutionError.invalidField("receipt protocol")
        }
        if receipt.schemaVersion == "2" {
            guard let claimId = receipt.claimId, !claimId.isEmpty,
                let claimDigest = receipt.claimContentDigest,
                let startId = receipt.startReceiptId, !startId.isEmpty,
                let startDigest = receipt.startReceiptContentDigest,
                receipt.recordedVia != nil,
                let requestId = receipt.receiptRequestId, !requestId.isEmpty
            else { throw GuidedExecutionError.invalidField("receipt v2 lifecycle binding") }
            try validateDigest(claimDigest, field: "receipt.claimContentDigest")
            try validateDigest(startDigest, field: "receipt.startReceiptContentDigest")
            if receipt.recordedVia == .reconciliation {
                guard receipt.reconciliation != nil else {
                    throw GuidedExecutionError.invalidField("receipt.reconciliation")
                }
            } else if receipt.reconciliation != nil {
                throw GuidedExecutionError.invalidField("receipt.reconciliation")
            }
        } else if receipt.claimId != nil || receipt.claimContentDigest != nil
            || receipt.startReceiptId != nil || receipt.startReceiptContentDigest != nil
            || receipt.recordedVia != nil || receipt.receiptRequestId != nil
            || receipt.reconciliation != nil
        {
            throw GuidedExecutionError.invalidField("receipt v1 lifecycle binding")
        }
        try nonempty(receipt.receiptId, field: "receiptId")
        try validateDigest(receipt.contentDigest, field: "receipt.contentDigest")
        try validateDigest(
            receipt.decisionContentDigest, field: "receipt.decisionContentDigest")
        try validateDigest(receipt.requestDigest, field: "receipt.requestDigest")
        try validateDigest(receipt.runbook.contentDigest, field: "receipt.runbook.contentDigest")
        try nonempty(receipt.logicalOperationKey, field: "receipt.logicalOperationKey")
        guard receipt.idempotencyKey == receipt.logicalOperationKey,
            receipt.attemptNumber >= 1,
            (receipt.retryOf == nil || receipt.attemptNumber > 1),
            !receipt.sideEffects.isEmpty,
            !receipt.postconditionRequirements.isEmpty,
            !receipt.completionProofRequirements.isEmpty,
            !receipt.trustedCompletion.evidence.isEmpty,
            receipt.trustedCompletion.decisionId == receipt.decisionId
        else { throw GuidedExecutionError.invalidField("receipt execution contract") }
        try validateDigest(
            receipt.trustedCompletion.resultDigest,
            field: "receipt.trustedCompletion.resultDigest")
        _ = try timestamp(receipt.startedAt, field: "receipt.startedAt")
        let completed = try timestamp(receipt.completedAt, field: "receipt.completedAt")
        let started = try timestamp(receipt.startedAt, field: "receipt.startedAt")
        guard completed >= started else {
            throw GuidedExecutionError.invalidField("receipt.completedAt")
        }
    }

    public static func validateReceipt(
        _ document: GuidedExecutionReceiptDocument,
        for permit: GuidedActionPermit
    ) throws {
        let receipt = document.receipt
        try validateReceipt(receipt)
        guard receipt.schemaVersion == "2",
            receipt.claimId == permit.claimId,
            receipt.claimContentDigest == permit.claimContentDigest,
            receipt.startReceiptId == permit.startReceiptId,
            receipt.startReceiptContentDigest == permit.startReceiptContentDigest,
            receipt.executionId == permit.executionId,
            receipt.decisionId == permit.decisionId,
            receipt.decisionContentDigest == permit.decisionContentDigest,
            receipt.runbook.runbookVersionId == permit.runbookVersionId,
            receipt.runbook.contentDigest == permit.runbookContentDigest,
            receipt.stepId == permit.stepId,
            receipt.operatorId == permit.operatorId,
            receipt.idempotencyKey == permit.idempotencyKey,
            receipt.logicalOperationKey == permit.logicalOperationKey,
            receipt.attemptNumber == permit.attemptNumber,
            receipt.retryOf == permit.retryOf,
            receipt.startedAt == permit.startedAt
        else { throw GuidedExecutionError.startReceiptBindingMismatch }
    }

    private static func validateBinding(
        decision: GuidedReplayDecision,
        claim: GuidedExecutionClaim,
        start: GuidedExecutionStartReceipt
    ) throws {
        guard let step = decision.authorizedStep,
            claim.decisionId == decision.decisionId,
            claim.decisionContentDigest == decision.contentDigest,
            claim.runbook == decision.runbook,
            claim.executionId == decision.request.executionId,
            claim.variantRef == step.variantRef,
            claim.stepId == step.stepId,
            claim.logicalOperationKey == decision.logicalOperationKey,
            claim.attemptNumber == decision.attemptNumber,
            claim.operatorId == decision.request.operatorId
        else { throw GuidedExecutionError.claimBindingMismatch }

        let authority = start.authorityDecision
        guard let authorityStep = authority.authorizedStep else {
            throw GuidedExecutionError.startReceiptBindingMismatch
        }
        var preparedRequestWithoutApprovals = decision.request
        preparedRequestWithoutApprovals.approvals = []
        var authorityRequestWithoutApprovals = authority.request
        authorityRequestWithoutApprovals.approvals = []
        let preparedRequestBytes = try JazzArchiveCanonicalJSON.encode(
            preparedRequestWithoutApprovals)
        let authorityRequestBytes = try JazzArchiveCanonicalJSON.encode(
            authorityRequestWithoutApprovals)
        let preparedRunbookBytes = try JazzArchiveCanonicalJSON.encode(
            decision.runbook)
        let authorityRunbookBytes = try JazzArchiveCanonicalJSON.encode(
            authority.runbook)
        let preparedStepBytes = try JazzArchiveCanonicalJSON.encode(step)
        let authorityStepBytes = try JazzArchiveCanonicalJSON.encode(authorityStep)
        // START re-evaluates current server authority and therefore content-addresses a new
        // decision. The receipt's top-level decision fields remain the exact PREPARE/CLAIM
        // predecessor. Only approval receipts may be refreshed inside the nested authority; every
        // other request field remains the exact PREPARE request so fresh authority cannot retarget
        // the desktop's already resolved instruction, locator, business object, or capability set.
        guard start.claimId == claim.claimId,
            start.claimContentDigest == claim.contentDigest,
            start.decisionId == decision.decisionId,
            start.decisionContentDigest == decision.contentDigest,
            start.runbook == decision.runbook,
            start.executionId == claim.executionId,
            start.variantRef == claim.variantRef,
            start.stepId == claim.stepId,
            start.logicalOperationKey == claim.logicalOperationKey,
            start.attemptNumber == claim.attemptNumber,
            start.operatorId == claim.operatorId,
            start.replayHostId == claim.replayHostId,
            start.operatorEligibility == authority.operatorEligibility,
            authority.status == .ready,
            !authority.checks.isEmpty,
            authority.checks.allSatisfy({ $0.status == .pass }),
            authorityRunbookBytes == preparedRunbookBytes,
            authorityRequestBytes == preparedRequestBytes,
            authorityStepBytes == preparedStepBytes,
            authority.logicalOperationKey == decision.logicalOperationKey,
            authority.attemptNumber == decision.attemptNumber,
            authority.retryOf == decision.retryOf
        else { throw GuidedExecutionError.startReceiptBindingMismatch }
        let claimed = try timestamp(claim.claimedAt, field: "claim.claimedAt")
        let expires = try timestamp(claim.leaseExpiresAt, field: "claim.leaseExpiresAt")
        let started = try timestamp(start.startedAt, field: "startReceipt.startedAt")
        let authorityEvaluated = try timestamp(
            authority.evaluatedAt,
            field: "startReceipt.authorityDecision.evaluatedAt")
        let authorityResolved = try timestamp(
            authority.trustedRuntimeContext.resolvedAt,
            field: "startReceipt.authorityDecision.trustedRuntimeContext.resolvedAt")
        let authorityMaxAge = TimeInterval(authority.validationPolicy.maxAgeSeconds)
        guard authorityMaxAge > 0,
            started >= claimed,
            started < expires,
            started >= authorityEvaluated,
            started.timeIntervalSince(authorityEvaluated) < authorityMaxAge,
            started >= authorityResolved,
            started.timeIntervalSince(authorityResolved) < authorityMaxAge
        else {
            throw GuidedExecutionError.startReceiptBindingMismatch
        }
        if let eligibility = authority.operatorEligibility {
            let eligibilityResolved = try timestamp(
                eligibility.resolvedAt,
                field: "startReceipt.authorityDecision.operatorEligibility.resolvedAt")
            let eligibilityValidUntil = try timestamp(
                eligibility.validUntil,
                field: "startReceipt.authorityDecision.operatorEligibility.validUntil")
            guard eligibilityResolved <= started, started < eligibilityValidUntil else {
                throw GuidedExecutionError.startReceiptBindingMismatch
            }
        }
    }

    private static func validateDecisionEnvelope(_ decision: GuidedReplayDecision) throws {
        guard decision.artifactType == "guidedReplayDecision", decision.schemaVersion == "1",
            decision.request.requestVersion == "1"
        else { throw GuidedExecutionError.invalidField("guided decision protocol") }
        try nonempty(decision.decisionId, field: "decisionId")
        try validateDigest(decision.contentDigest, field: "decision.contentDigest")
        try validateDigest(decision.requestDigest, field: "decision.requestDigest")
        try validateDigest(decision.runbook.contentDigest, field: "runbook.contentDigest")
        try validateDigest(
            decision.trustedRuntimeContext.requestContextDigest,
            field: "trustedRuntimeContext.requestContextDigest")
        _ = try timestamp(decision.request.requestedAt, field: "request.requestedAt")
        _ = try timestamp(decision.evaluatedAt, field: "decision.evaluatedAt")
        _ = try timestamp(
            decision.trustedRuntimeContext.resolvedAt,
            field: "trustedRuntimeContext.resolvedAt")
        guard !decision.trustedRuntimeContext.evidence.isEmpty else {
            throw GuidedExecutionError.invalidField("trustedRuntimeContext.evidence")
        }
        if let processExecution = decision.request.processExecution {
            guard processExecution.executionId == decision.request.executionId,
                processExecution.executionId.hasPrefix("pex_"),
                processExecution.bindingId.hasPrefix("peb_"),
                processExecution.businessTransactionKey.hasPrefix("btx_")
            else {
                throw GuidedExecutionError.invalidField("request.processExecution")
            }
            try validateDigest(
                processExecution.bindingContentDigest,
                field: "request.processExecution.bindingContentDigest")
        }
        if let eligibility = decision.operatorEligibility {
            guard let step = decision.authorizedStep,
                eligibility.scope == decision.runbook.scope,
                eligibility.principalId == decision.request.operatorId,
                eligibility.actorRole == step.actorRole,
                eligibility.stepId == step.stepId,
                eligibility.executionId == decision.request.executionId,
                eligibility.assignmentState == .active,
                eligibility.eligibilityState == .eligible,
                !eligibility.assignmentEvidence.isEmpty,
                !eligibility.eligibilityEvidence.isEmpty,
                decision.checks.contains(where: {
                    $0.kind == .operatorEligibility && $0.status == .pass
                })
            else {
                throw GuidedExecutionError.invalidField("operatorEligibility")
            }
            try validateDigest(
                eligibility.snapshotDigest,
                field: "operatorEligibility.snapshotDigest")
            try validateDigest(
                eligibility.policyDigest,
                field: "operatorEligibility.policyDigest")
            let eligibilityResolved = try timestamp(
                eligibility.resolvedAt,
                field: "operatorEligibility.resolvedAt")
            let eligibilityValidUntil = try timestamp(
                eligibility.validUntil,
                field: "operatorEligibility.validUntil")
            guard eligibilityResolved < eligibilityValidUntil else {
                throw GuidedExecutionError.invalidField("operatorEligibility.validUntil")
            }
        }
    }

    private static func validatePriorReceipts(
        _ receipts: [GuidedExecutionReceipt],
        decision: GuidedReplayDecision,
        step: GuidedAuthorizedStep,
        runtimeOperator: String
    ) throws {
        var ids = Set<String>()
        for receipt in receipts {
            try validateReceipt(receipt)
            guard ids.insert(receipt.receiptId).inserted else {
                throw GuidedExecutionError.receiptIdentityConflict(receipt.receiptId)
            }
            guard receipt.runbook == decision.runbook,
                receipt.executionId == decision.request.executionId
            else { throw GuidedExecutionError.runbookPinMismatch }
            if receipt.status == .succeeded,
                receipt.stepId == step.stepId
                    || receipt.logicalOperationKey == decision.logicalOperationKey
            {
                if receipt.stepId == step.stepId {
                    throw GuidedExecutionError.alreadyCompleted(decision.request.idempotencyKey)
                }
                throw GuidedExecutionError.idempotencyConflict(decision.request.idempotencyKey)
            }
        }
        guard let previous = receipts.filter({ $0.status == .succeeded }).last else {
            return
        }
        let transferRequired = previous.handoffRequirement.mode == .transfer
        guard transferRequired || previous.operatorId != runtimeOperator else {
            return
        }
        guard transferRequired else {
            throw GuidedExecutionError.handoffNotAccepted
        }
        let assignmentMatches: Bool
        switch (
            previous.handoffOutcome.nextAssigneeId,
            previous.handoffOutcome.eligibleRole
        ) {
        case (nil, nil):
            // Historical receipt v1 had only recipientRole. Keep that exact legacy shape readable.
            assignmentMatches = true
        case let (nextAssigneeId?, eligibleRole?):
            assignmentMatches =
                nextAssigneeId == runtimeOperator
                && eligibleRole == step.actorRole
        default:
            assignmentMatches = false
        }
        guard previous.handoffOutcome.state == .accepted,
            previous.handoffOutcome.recipientRole == step.actorRole,
            assignmentMatches,
            !previous.handoffOutcome.conditionsMet.isEmpty,
            !previous.handoffOutcome.evidence.isEmpty
        else { throw GuidedExecutionError.handoffNotAccepted }
    }

    private static func validateCapabilities(
        _ step: GuidedAuthorizedStep,
        request: GuidedReplayRequest,
        trusted: GuidedTrustedRuntimeContext,
        runtime: GuidedRuntimeSnapshot
    ) throws {
        for requirement in step.requiredCapabilities where requirement.required {
            guard request.capabilities.contains(where: {
                textExactlyEqual($0.id, requirement.id)
                    && textExactlyEqual($0.version, requirement.version)
            }),
                runtime.capabilities.contains(where: {
                    textExactlyEqual($0.id, requirement.id)
                        && textExactlyEqual($0.version, requirement.version)
                }),
                trusted.capabilities.contains(where: {
                    textExactlyEqual($0.id, requirement.id)
                        && textExactlyEqual($0.version, requirement.version)
                        && !$0.evidence.isEmpty
                })
            else { throw GuidedExecutionError.missingCapability(requirement.id) }
        }
    }

    private static func validatePreconditions(
        _ step: GuidedAuthorizedStep,
        trusted: GuidedTrustedRuntimeContext,
        runtime: GuidedRuntimeSnapshot
    ) throws {
        for requirement in step.preconditions where requirement.required {
            guard let claim = runtime.preconditions.first(where: {
                textExactlyEqual($0.conditionId, requirement.conditionId)
            }), claim.satisfied, !claim.evidence.isEmpty,
                let trustedClaim = trusted.preconditions.first(where: {
                    textExactlyEqual($0.conditionId, requirement.conditionId)
                }), trustedClaim.satisfied, !trustedClaim.evidence.isEmpty
            else { throw GuidedExecutionError.preconditionFailed(requirement.conditionId) }
        }
    }

    private static func validateLocator(
        _ step: GuidedAuthorizedStep,
        trusted: GuidedTrustedRuntimeContext,
        runtime: GuidedRuntimeSnapshot,
        now: Date,
        maxAgeSeconds: Int
    ) throws -> GuidedSemanticLocator {
        let resolution = runtime.locatorResolution
        guard canonicalBytesEqual(
            trusted.locatorResolution,
            Optional(resolution))
        else {
            throw GuidedExecutionError.ambiguousLocator
        }
        guard textExactlyEqual(resolution.stepId, step.stepId),
            resolution.matchCount == 1
        else {
            throw GuidedExecutionError.ambiguousLocator
        }
        guard resolution.kind != .coordinate,
            let locator = step.locators.first(where: {
                textExactlyEqual($0.locatorId, resolution.locatorId)
                    && $0.kind == resolution.kind
                    && $0.kind != .coordinate
                    && $0.usage == .execution
                    && $0.support == .supported
            })
        else { throw GuidedExecutionError.unsafeLocator }
        try fresh(
            resolution.resolvedAt,
            now: now,
            maxAgeSeconds: maxAgeSeconds,
            field: "locatorResolution")
        return locator
    }

    private static func validateApplications(
        _ step: GuidedAuthorizedStep,
        locator: GuidedSemanticLocator,
        trusted: GuidedTrustedRuntimeContext,
        runtime: GuidedRuntimeSnapshot,
        now: Date,
        maxAgeSeconds: Int
    ) throws {
        guard step.applicationConstraints.state == .defined,
            !step.applicationConstraints.constraints.isEmpty
        else { throw GuidedExecutionError.incompatibleApplication("unknown") }
        for constraint in step.applicationConstraints.constraints {
            guard let observation = runtime.applicationObservations.first(where: {
                textExactlyEqual($0.applicationId, constraint.applicationId)
            }), observation.compatibility == .compatible,
                textExactlyEqual(
                    observation.matchedVersionConstraint,
                    constraint.versionConstraint),
                constraint.environment == nil
                    || optionalTextExactlyEqual(
                        observation.environment,
                        constraint.environment)
            else { throw GuidedExecutionError.incompatibleApplication(constraint.applicationId) }
            guard trusted.applicationObservations.contains(where: {
                canonicalBytesEqual($0, observation)
            }) else {
                throw GuidedExecutionError.incompatibleApplication(constraint.applicationId)
            }
            try fresh(
                observation.observedAt,
                now: now,
                maxAgeSeconds: maxAgeSeconds,
                field: "application.\(constraint.applicationId)")
        }
        let resolutionApp = runtime.locatorResolution.applicationId
        guard step.applicationConstraints.constraints.contains(where: {
            textExactlyEqual($0.applicationId, resolutionApp)
        }), locator.kind != .coordinate
        else { throw GuidedExecutionError.incompatibleApplication(resolutionApp) }
    }

    private static func validateBusinessObjects(
        _ step: GuidedAuthorizedStep,
        runbookScope: GuidedExecutionScope,
        trustedPins: [GuidedTrustedAnchorPin],
        runtime: GuidedRuntimeSnapshot,
        now: Date,
        maxAgeSeconds: Int
    ) throws {
        for specification in step.businessObjects.inputs where specification.anchorRequired {
            guard let input = runtime.businessObjectInputs.first(where: {
                textExactlyEqual($0.role, specification.role)
                    && textExactlyEqual(
                        $0.systemNamespace,
                        specification.systemNamespace)
                    && textExactlyEqual($0.objectType, specification.objectType)
            }), canonicalBytesEqual(input.scope, runbookScope),
                input.outcome == .verified,
                input.lifecycle == .verified,
                input.freshness.status == .fresh,
                !input.anchorAssertionRef.isEmpty
            else { throw GuidedExecutionError.businessObjectUnverified(specification.role) }
            guard trustedPins.contains(where: {
                textExactlyEqual($0.assertionId, input.anchorAssertionRef)
                    && textExactlyEqual(
                        $0.contentDigest,
                        input.anchorAssertionDigest)
                    && canonicalBytesEqual($0.scope, input.scope)
                    && $0.outcome == .verified
                    && $0.lifecycle == .verified
                    && textExactlyEqual(
                        $0.object.connectionId,
                        input.connectionId)
                    && textExactlyEqual(
                        $0.object.systemNamespace,
                        input.systemNamespace)
                    && textExactlyEqual(
                        $0.object.objectType,
                        input.objectType)
                    && textExactlyEqual(
                        $0.object.externalId,
                        input.externalId)
                    && canonicalBytesEqual($0.freshness, input.freshness)
            }) else { throw GuidedExecutionError.businessObjectUnverified(specification.role) }
            try validateDigest(
                input.anchorAssertionDigest,
                field: "businessObject.\(specification.role).anchorAssertionDigest")
            try fresh(
                input.resolvedAt,
                now: now,
                maxAgeSeconds: maxAgeSeconds,
                field: "businessObject.\(specification.role)")
            try fresh(
                input.freshness.checkedAt,
                now: now,
                maxAgeSeconds: maxAgeSeconds,
                field: "businessObject.\(specification.role).freshness")
            if let expiresAt = input.freshness.expiresAt {
                guard try timestamp(expiresAt, field: "businessObject.expiresAt") >= now else {
                    throw GuidedExecutionError.businessObjectUnverified(specification.role)
                }
            }
        }
    }

    private static func canonicalBytesEqual<T: Encodable>(
        _ lhs: T,
        _ rhs: T
    ) -> Bool {
        guard let left = try? JazzArchiveCanonicalJSON.encode(lhs),
            let right = try? JazzArchiveCanonicalJSON.encode(rhs)
        else {
            return false
        }
        return left == right
    }

    private static func textExactlyEqual(_ lhs: String, _ rhs: String) -> Bool {
        Data(lhs.utf8) == Data(rhs.utf8)
    }

    private static func optionalTextExactlyEqual(
        _ lhs: String?,
        _ rhs: String?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            true
        case let (left?, right?):
            textExactlyEqual(left, right)
        default:
            false
        }
    }

    private static func validateApprovalAndConfirmation(
        _ decision: GuidedReplayDecision,
        step: GuidedAuthorizedStep,
        runtime: GuidedRuntimeSnapshot,
        now: Date,
        maxAgeSeconds: Int
    ) throws {
        let externallyVisible = step.sideEffectClass != .readOnly
        if step.approval.required || externallyVisible {
            switch (decision.trustedApprovalPolicy, decision.approvalEvaluation) {
            case let (policy?, evaluation?):
                try validateAggregateApproval(
                    decision,
                    step: step,
                    policy: policy,
                    evaluation: evaluation,
                    now: now)
            case (nil, nil):
                try validateLegacyApproval(decision, step: step, now: now)
            default:
                // Aggregate authority is one atomic server statement. Never combine one current
                // aggregate half with the legacy first-approved-receipt fallback.
                throw GuidedExecutionError.approvalMissing
            }
            guard let confirmation = runtime.userConfirmation,
                confirmation.confirmed,
                confirmation.operatorId == runtime.operatorId,
                confirmation.decisionId == decision.decisionId,
                confirmation.stepId == step.stepId
            else { throw GuidedExecutionError.userConfirmationMissing }
            try fresh(
                confirmation.confirmedAt,
                now: now,
                maxAgeSeconds: maxAgeSeconds,
                field: "userConfirmation")
        }
    }

    private static func validateLegacyApproval(
        _ decision: GuidedReplayDecision,
        step: GuidedAuthorizedStep,
        now: Date
    ) throws {
        guard let approval = decision.request.approvals.first(where: {
            $0.decision == .approved
                && $0.stepId == step.stepId
                && $0.executionId == decision.request.executionId
                && $0.boundRunbookVersionId == decision.runbook.runbookVersionId
                && $0.boundRunbookContentDigest == decision.runbook.contentDigest
                && $0.approverRole == step.approval.approverRole
        }), decision.trustedApprovalStates.contains(where: {
            $0.approvalId == approval.approvalId
                && $0.status == .active
                && $0.policyId == approval.approvalPolicy.policyId
                && $0.revision == approval.approvalPolicy.revision
                && $0.policyDigest == approval.approvalPolicy.policyDigest
                && $0.approverRole == approval.approverRole
                && approval.approvalPolicy.approverRole == approval.approverRole
        }) else { throw GuidedExecutionError.approvalMissing }
        try validateDigest(
            approval.approvalPolicy.policyDigest,
            field: "approval.approvalPolicy.policyDigest")
        let validFrom = try timestamp(
            approval.approvalPolicy.validFrom,
            field: "approval.approvalPolicy.validFrom")
        let validUntil = try timestamp(
            approval.approvalPolicy.validUntil,
            field: "approval.approvalPolicy.validUntil")
        let decidedAt = try timestamp(approval.decidedAt, field: "approval.decidedAt")
        let policyResolvedAt = try timestamp(
            approval.approvalPolicy.resolvedAt,
            field: "approval.approvalPolicy.resolvedAt")
        let trustedState = decision.trustedApprovalStates.first(where: {
            $0.approvalId == approval.approvalId
                && $0.policyId == approval.approvalPolicy.policyId
                && $0.revision == approval.approvalPolicy.revision
                && $0.policyDigest == approval.approvalPolicy.policyDigest
                && $0.approverRole == approval.approverRole
        })
        guard validFrom <= validUntil,
            validFrom <= now,
            now <= validUntil,
            validFrom <= decidedAt,
            decidedAt <= now,
            decidedAt <= validUntil,
            policyResolvedAt <= now,
            let trustedState,
            try timestamp(
                trustedState.resolvedAt,
                field: "trustedApprovalState.resolvedAt") <= now,
            try timestamp(approval.expiresAt, field: "approval.expiresAt") >= now
        else {
            throw GuidedExecutionError.approvalMissing
        }
    }

    private static func validateAggregateApproval(
        _ decision: GuidedReplayDecision,
        step: GuidedAuthorizedStep,
        policy: GuidedApprovalPolicySnapshot,
        evaluation: GuidedApprovalEvaluation,
        now: Date
    ) throws {
        guard let role = step.approval.approverRole,
            !role.isEmpty,
            policy.approverRole == role,
            let aggregation = policy.aggregation,
            aggregation.denySemantics == "anyDenyVeto",
            !aggregation.approverIds.isEmpty,
            aggregation.requiredApprovals >= 1,
            aggregation.requiredApprovals <= aggregation.approverIds.count
        else { throw GuidedExecutionError.approvalMissing }

        let eligibleApprovers = Set(aggregation.approverIds)
        guard eligibleApprovers.count == aggregation.approverIds.count,
            aggregation.approverIds.allSatisfy({ !$0.isEmpty })
        else { throw GuidedExecutionError.approvalMissing }

        try validateDigest(
            policy.policyDigest,
            field: "trustedApprovalPolicy.policyDigest")
        let validFrom = try timestamp(
            policy.validFrom,
            field: "trustedApprovalPolicy.validFrom")
        let validUntil = try timestamp(
            policy.validUntil,
            field: "trustedApprovalPolicy.validUntil")
        let resolvedAt = try timestamp(
            policy.resolvedAt,
            field: "trustedApprovalPolicy.resolvedAt")
        guard validFrom <= resolvedAt,
            resolvedAt <= now,
            validFrom <= now,
            now <= validUntil
        else { throw GuidedExecutionError.approvalMissing }

        let expectedScopeKey: String
        switch step.approval.policy {
        case .perStep:
            expectedScopeKey = "step:\(step.stepId)"
        case .perExecution:
            // Server authority is scoped by the current approver role so the same approval can
            // govern later steps in the execution which resolve to that role.
            expectedScopeKey = "execution:\(role)"
        case .none:
            throw GuidedExecutionError.approvalMissing
        }

        let approvals = decision.request.approvals.filter {
            (step.approval.policy == .perExecution || $0.stepId == step.stepId)
                && $0.executionId == decision.request.executionId
                && $0.boundRunbookVersionId == decision.runbook.runbookVersionId
                && $0.boundRunbookContentDigest == decision.runbook.contentDigest
                && $0.approverRole == role
                && $0.approvalScopeKey == expectedScopeKey
                && eligibleApprovers.contains($0.approverId)
                && approvalPolicyAuthorityMatches($0.approvalPolicy, policy)
        }
        guard Set(approvals.map(\.approvalId)).count == approvals.count else {
            throw GuidedExecutionError.approvalMissing
        }

        var currentByApprover: [String: GuidedApprovalReceipt] = [:]
        for approval in approvals {
            let states = decision.trustedApprovalStates.filter {
                $0.approvalId == approval.approvalId
                    && $0.policyId == policy.policyId
                    && $0.revision == policy.revision
                    && $0.policyDigest == policy.policyDigest
                    && $0.approverRole == role
            }
            guard states.count == 1 else {
                throw GuidedExecutionError.approvalMissing
            }
            let state = states[0]
            let stateResolvedAt = try timestamp(
                state.resolvedAt,
                field: "trustedApprovalState.resolvedAt")
            guard stateResolvedAt <= now else {
                throw GuidedExecutionError.approvalMissing
            }
            guard state.status == .active else { continue }

            let approvalResolvedAt = try timestamp(
                approval.approvalPolicy.resolvedAt,
                field: "approval.approvalPolicy.resolvedAt")
            let decidedAt = try timestamp(
                approval.decidedAt,
                field: "approval.decidedAt")
            let expiresAt = try timestamp(
                approval.expiresAt,
                field: "approval.expiresAt")
            guard validFrom <= approvalResolvedAt,
                approvalResolvedAt <= decidedAt,
                decidedAt <= now,
                decidedAt <= validUntil,
                decidedAt <= expiresAt,
                expiresAt >= now,
                currentByApprover[approval.approverId] == nil
            else { throw GuidedExecutionError.approvalMissing }
            currentByApprover[approval.approverId] = approval
        }

        let currentHeads = currentByApprover.values.sorted {
            if $0.approverId == $1.approverId {
                return $0.approvalId < $1.approvalId
            }
            return $0.approverId < $1.approverId
        }
        let expectedPins = currentHeads.map {
            GuidedApprovalHeadPin(
                approverId: $0.approverId,
                approvalId: $0.approvalId,
                decision: $0.decision)
        }
        let approvedHeads = currentHeads.filter { $0.decision == .approved }
        let expectedSelected = approvedHeads
            .prefix(aggregation.requiredApprovals)
            .map(\.approvalId)
            .sorted()
        let expectedVetoes = currentHeads
            .filter { $0.decision == .denied }
            .map(\.approvalId)
            .sorted()

        guard evaluation.currentHeadPins == expectedPins,
            evaluation.selectedApprovalIds == expectedSelected,
            evaluation.vetoApprovalIds == expectedVetoes,
            Set(evaluation.selectedApprovalIds).count == evaluation.selectedApprovalIds.count,
            Set(evaluation.vetoApprovalIds).count == evaluation.vetoApprovalIds.count,
            expectedVetoes.isEmpty,
            approvedHeads.count >= aggregation.requiredApprovals,
            expectedSelected.count == aggregation.requiredApprovals
        else { throw GuidedExecutionError.approvalMissing }
    }

    private static func approvalPolicyAuthorityMatches(
        _ receiptPolicy: GuidedApprovalPolicySnapshot,
        _ trustedPolicy: GuidedApprovalPolicySnapshot
    ) -> Bool {
        receiptPolicy.policyId == trustedPolicy.policyId
            && receiptPolicy.revision == trustedPolicy.revision
            && receiptPolicy.policyDigest == trustedPolicy.policyDigest
            && receiptPolicy.policySource == trustedPolicy.policySource
            && receiptPolicy.approverRole == trustedPolicy.approverRole
            && receiptPolicy.validFrom == trustedPolicy.validFrom
            && receiptPolicy.validUntil == trustedPolicy.validUntil
            && receiptPolicy.aggregation == trustedPolicy.aggregation
    }

    private static func fresh(
        _ value: String,
        now: Date,
        maxAgeSeconds: Int,
        field: String
    ) throws {
        let observed = try timestamp(value, field: field)
        let age = now.timeIntervalSince(observed)
        guard age >= 0, age < TimeInterval(maxAgeSeconds) else {
            throw GuidedExecutionError.staleObservation(field)
        }
    }

    private static func timestamp(_ value: String, field: String) throws -> Date {
        guard let date = Timestamps.parse(value) else {
            throw GuidedExecutionError.invalidField(field)
        }
        return date
    }

    private static func validateDigest(_ value: String, field: String) throws {
        guard value.hasPrefix("sha256:"), value.count == 71,
            value.dropFirst(7).allSatisfy({ "0123456789abcdef".contains($0) })
        else { throw GuidedExecutionError.invalidField(field) }
    }

    private static func nonempty(_ value: String, field: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GuidedExecutionError.invalidField(field)
        }
    }
}

// MARK: - Read-only evidence playback

public enum EvidencePlaybackKind: String, Codable, Equatable, Sendable {
    case event
    case screenshot
    case narration
    case transcript
    case label
    case coachInteraction = "coach_interaction"
    case gap
}

/// Playback items contain references and timing only. There is deliberately no executable action,
/// input payload, coordinate target, or OS automation hook.
public struct EvidencePlaybackItem: Codable, Equatable, Sendable {
    public var playbackId: String
    public var offsetMillis: Int64
    public var kind: EvidencePlaybackKind
    public var evidenceRef: String?
    public var gapReason: String?
    public var label: String?
}

public enum EvidencePlaybackValidator {
    public static func validate(_ items: [EvidencePlaybackItem]) throws {
        var ids = Set<String>()
        var previous: Int64 = -1
        for item in items {
            guard ids.insert(item.playbackId).inserted, item.offsetMillis >= previous else {
                throw GuidedExecutionError.invalidField("evidencePlayback ordering")
            }
            previous = item.offsetMillis
            if item.kind == .gap {
                guard item.evidenceRef == nil,
                    !(item.gapReason ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { throw GuidedExecutionError.invalidField("evidencePlayback gap") }
            } else if item.evidenceRef == nil {
                throw GuidedExecutionError.invalidField("evidencePlayback evidenceRef")
            }
        }
    }
}
