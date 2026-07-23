import AppKit
import Foundation
import JasnostCaptureCore

enum GuidedExecutionDesktopError: Error, CustomStringConvertible {
    case invalidLaunchPacket(String)
    case accessibilityPermissionMissing
    case unsupportedLocator(String)
    case targetMissing
    case targetAmbiguous(Int)
    case targetUnavailable
    case applicationUnavailable(String)
    case applicationChanged(String)
    case operatorMismatch
    case explicitConfirmationRequired
    case completionEvidenceRequired

    var description: String {
        switch self {
        case let .invalidLaunchPacket(field):
            return "The guided-execution launch packet is invalid: \(field)."
        case .accessibilityPermissionMissing:
            return "Accessibility permission is required for semantic target resolution."
        case let .unsupportedLocator(kind):
            return "This client cannot execute the \(kind) locator. There is no coordinate fallback."
        case .targetMissing:
            return "The approved semantic target is not present."
        case let .targetAmbiguous(count):
            return "The approved semantic target matches \(count) elements."
        case .targetUnavailable:
            return "The approved semantic target is hidden, disabled, or has no visible frame."
        case let .applicationUnavailable(identifier):
            return "The approved application is not running exactly once: \(identifier)."
        case let .applicationChanged(identifier):
            return "The live application no longer matches the server-reviewed observation: \(identifier)."
        case .operatorMismatch:
            return "The configured local identity is not the server-authorized replay operator."
        case .explicitConfirmationRequired:
            return "Explicit operator confirmation is required before PREPARE."
        case .completionEvidenceRequired:
            return "Replace every REQUIRED_EVIDENCE placeholder with current evidence before submission."
        }
    }
}

struct GuidedResolvedDesktopTarget {
    let applicationId: String
    let applicationName: String
    let elementDescription: String
    let frame: CGRect
}

/// Native, read-only resolver for the one supported execution locator. It deliberately has no
/// CGEvent/AX action method: the only output is a frame to highlight for a human operator.
@MainActor
enum GuidedExecutionRuntimeResolver {
    private struct AccessibilityLocator {
        let role: String
        let name: String?
        let identifier: String?
        let index: Int?
    }

    static func revalidateTarget(
        decision: GuidedReplayDecision,
        runtime: GuidedRuntimeSnapshot,
        configuredOperatorId: String,
        operatorConfirmed: Bool
    ) throws -> (GuidedRuntimeSnapshot, GuidedResolvedDesktopTarget) {
        guard operatorConfirmed else {
            throw GuidedExecutionDesktopError.explicitConfirmationRequired
        }
        guard !configuredOperatorId.isEmpty,
            configuredOperatorId == decision.request.operatorId,
            runtime.operatorId == configuredOperatorId
        else { throw GuidedExecutionDesktopError.operatorMismatch }
        guard Accessibility.isTrusted(prompt: false) else {
            throw GuidedExecutionDesktopError.accessibilityPermissionMissing
        }
        guard let step = decision.authorizedStep else {
            throw GuidedExecutionDesktopError.invalidLaunchPacket("authorizedStep")
        }
        let supportedCapabilities: Set<GuidedCapability> = [
            GuidedCapability(id: "human-guided-replay", version: "1"),
            GuidedCapability(id: "macos.accessibility.semantic", version: "1"),
        ]
        for requirement in step.requiredCapabilities where requirement.required {
            let capability = GuidedCapability(
                id: requirement.id, version: requirement.version)
            guard supportedCapabilities.contains(capability) else {
                throw GuidedExecutionDesktopError.unsupportedLocator(
                    "required capability \(requirement.id)@\(requirement.version)")
            }
        }
        for constraint in step.applicationConstraints.constraints {
            _ = try revalidateApplication(
                applicationId: constraint.applicationId,
                runtime: runtime)
        }
        let resolution = runtime.locatorResolution
        guard resolution.matchCount == 1,
            let locator = step.locators.first(where: {
                $0.locatorId == resolution.locatorId && $0.kind == resolution.kind
            })
        else {
            throw GuidedExecutionDesktopError.invalidLaunchPacket("locator binding")
        }
        guard locator.kind == .accessibility,
            locator.usage == .execution,
            locator.support == .supported
        else {
            throw GuidedExecutionDesktopError.unsupportedLocator(locator.kind.rawValue)
        }
        let application = try revalidateApplication(
            applicationId: resolution.applicationId,
            runtime: runtime)
        let parsed = try parseAccessibilityLocator(locator.value)
        let match = Accessibility.resolveSemanticTarget(
            bundleID: resolution.applicationId,
            role: parsed.role,
            name: parsed.name,
            identifier: parsed.identifier,
            index: parsed.index)
        guard match.matchCount > 0 else {
            throw GuidedExecutionDesktopError.targetMissing
        }
        guard match.matchCount == 1, let element = match.element else {
            throw GuidedExecutionDesktopError.targetAmbiguous(match.matchCount)
        }
        guard Accessibility.isGuidanceTargetAvailable(element),
            let frame = Accessibility.currentFrame(of: element)
        else { throw GuidedExecutionDesktopError.targetUnavailable }
        var refreshed = runtime
        refreshed.observedAt = Timestamps.iso8601()
        refreshed.userConfirmation = GuidedUserConfirmation(
            confirmed: true,
            confirmedAt: refreshed.observedAt,
            operatorId: configuredOperatorId,
            decisionId: decision.decisionId,
            stepId: step.stepId)
        return (
            refreshed,
            GuidedResolvedDesktopTarget(
                applicationId: resolution.applicationId,
                applicationName: application.localizedName ?? resolution.applicationId,
                elementDescription: parsed.name ?? parsed.identifier ?? parsed.role,
                frame: frame)
        )
    }

    /// Completion may legitimately remove the original element. Verify the reviewed application
    /// binding here; exact postconditions and connector/object evidence are validated by the server
    /// from the structured result rather than inferred from a disappeared button.
    static func revalidateApplication(
        applicationId: String,
        runtime: GuidedRuntimeSnapshot
    ) throws -> NSRunningApplication {
        let applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: applicationId
        ).filter { !$0.isTerminated }
        guard applications.count == 1, let application = applications.first else {
            throw GuidedExecutionDesktopError.applicationUnavailable(applicationId)
        }
        guard let observation = runtime.applicationObservations.first(where: {
            $0.applicationId == applicationId
        }), observation.compatibility == .compatible,
            let liveVersion = application.bundleURL.flatMap(Bundle.init(url:))?
                .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            liveVersion == observation.observedVersion
        else { throw GuidedExecutionDesktopError.applicationChanged(applicationId) }
        return application
    }

    private static func parseAccessibilityLocator(
        _ value: String
    ) throws -> AccessibilityLocator {
        let parts = value.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard let role = parts.first, role.hasPrefix("AX"), !role.isEmpty else {
            throw GuidedExecutionDesktopError.invalidLaunchPacket("accessibility locator role")
        }
        var name: String?
        var identifier: String?
        var index: Int?
        for component in parts.dropFirst() {
            let pair = component.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2, !pair[1].isEmpty else {
                throw GuidedExecutionDesktopError.invalidLaunchPacket("accessibility locator value")
            }
            switch pair[0] {
            case "title", "name":
                guard name == nil else {
                    throw GuidedExecutionDesktopError.invalidLaunchPacket(
                        "duplicate accessibility name")
                }
                name = pair[1]
            case "identifier":
                guard identifier == nil else {
                    throw GuidedExecutionDesktopError.invalidLaunchPacket(
                        "duplicate accessibility identifier")
                }
                identifier = pair[1]
            case "index":
                guard index == nil, let parsed = Int(pair[1]), parsed >= 0 else {
                    throw GuidedExecutionDesktopError.invalidLaunchPacket(
                        "accessibility locator index")
                }
                index = parsed
            default:
                throw GuidedExecutionDesktopError.invalidLaunchPacket(
                    "unsupported accessibility locator key \(pair[0])")
            }
        }
        guard name != nil || identifier != nil else {
            throw GuidedExecutionDesktopError.invalidLaunchPacket(
                "accessibility locator identity")
        }
        return AccessibilityLocator(
            role: role, name: name, identifier: identifier, index: index)
    }
}
