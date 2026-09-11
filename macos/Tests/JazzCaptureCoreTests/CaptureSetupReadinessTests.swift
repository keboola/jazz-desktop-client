import Foundation
import XCTest
@testable import JazzCaptureCore

@MainActor
final class CaptureSetupReadinessTests: XCTestCase {
    private let durability = JazzArchiveFilesystemDurability(
        synchronizeRegularFile: { _, _ in }, synchronizeDirectory: { _ in })

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func localInput() -> CaptureSetupInput {
        .init(snapshot: .init(user: "test@example.invalid", machine: "Test Mac", company: "Unassigned",
            area: "General", destination: "Local archive only", enrollmentIdentity: "", enrollmentProfile: "Unassigned",
            continuous: false, screenshots: true, narration: true, coachLive: false,
            delivery: .confirmedArchive, localOnly: true, exclusions: ["test.secret"], managedConfiguration: "{}"),
            accessibilityGranted: true, screenGranted: true, microphoneGranted: true)
    }

    func testCleanInstallAndUpgradeNeverInferNoticeFromCaptureOrContinuousPreferences() throws {
        for upgrade in [false, true] {
            var input = localInput()
            input.snapshot.continuous = upgrade
            input.snapshot.localOnly = false // The user has not chosen a destination yet.
            let owner = CaptureSetupReadiness(root: try root(), durability: durability, input: { input })
            XCTAssertFalse(owner.admit())
            XCTAssertFalse(owner.acknowledge(), "no enrollment and no explicit local choice")
            input.snapshot.localOnly = true
            XCTAssertTrue(owner.status().canAcknowledge)
            XCTAssertFalse(owner.admit(), "neither old capture timestamps nor continuous=true is a notice")
            XCTAssertTrue(owner.acknowledge())
            XCTAssertTrue(owner.admit())
        }
    }

    func testAcknowledgedOfflineRelaunchIsNotResumeOrArchiveConfirmation() throws {
        let root = try root()
        let input = localInput()
        let owner = CaptureSetupReadiness(root: root, durability: durability, input: { input })
        XCTAssertTrue(owner.acknowledge())
        let date = try XCTUnwrap(owner.status().acknowledgedAt)
        let intent = CaptureStartIntent(root: root, continuous: true, durability: durability)
        intent.pause()
        let reopened = CaptureSetupReadiness(root: root, durability: durability, input: { input })
        XCTAssertEqual(reopened.status().acknowledgedAt, date)
        XCTAssertTrue(reopened.admit())
        XCTAssertTrue(intent.userPaused)
        XCTAssertNil(intent.requestStart(explicit: false))
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(Set(names), ["capture-setup.json", "capture-intent.json"], "no archive/queue writes")
    }

    func testEveryMaterialChangeInvalidatesDurablyAndRetainsPriorReceipt() throws {
        let changes: [(inout CaptureSetupSnapshot) -> Void] = [
            { $0.user = "other@example.invalid" }, { $0.machine = "Other Mac" },
            { $0.company = "other" }, { $0.area = "other" }, { $0.destination = "https://other.invalid" },
            { $0.enrollmentIdentity = "other-device" }, { $0.enrollmentProfile = "other-profile" },
            { $0.screenshots = false }, { $0.narration = false }, { $0.continuous = true },
            { $0.exclusions = [] }, { $0.noticeVersion += 1 }, { $0.managedConfiguration = "new" },
        ]
        for change in changes {
            let root = try root()
            var input = localInput()
            let old = input
            let owner = CaptureSetupReadiness(root: root, durability: durability, input: { input })
            XCTAssertTrue(owner.acknowledge())
            XCTAssertTrue(owner.admit())
            var revoked = 0
            owner.onRevocation = { revoked += 1 }
            change(&input.snapshot)
            XCTAssertFalse(owner.permitsAdmission())
            XCTAssertEqual(revoked, 1)
            input = old
            XCTAssertFalse(owner.status().ready, "reverting cannot resurrect notice")
            let reopened = CaptureSetupReadiness(root: root, durability: durability, input: { input })
            XCTAssertFalse(reopened.status().ready)
            XCTAssertTrue(reopened.acknowledge())
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
                root.appendingPathComponent("capture-setup.json"))) as? [String: Any])
            XCTAssertEqual((json["receipts"] as? [Any])?.count, 2, "old notice evidence retained")
        }
    }

    func testStaleDisplayedNoticeCannotAcknowledgeChangedInput() throws {
        var input = localInput()
        let owner = CaptureSetupReadiness(root: try root(), durability: durability, input: { input })
        let presented = owner.status().snapshot
        input.snapshot.narration = false
        XCTAssertFalse(owner.acknowledge(expected: presented))
        XCTAssertNil(owner.status().acknowledgedAt)
        XCTAssertTrue(owner.acknowledge(expected: owner.status().snapshot))
    }

    func testMissingAndDeniedPermissionsBlockOnlyRequestedModalities() throws {
        for missing in ["accessibility", "screen", "microphone"] {
            var input = localInput()
            let owner = CaptureSetupReadiness(root: try root(), durability: durability, input: { input })
            XCTAssertTrue(owner.acknowledge())
            XCTAssertTrue(owner.admit())
            switch missing {
            case "accessibility": input.accessibilityGranted = false
            case "screen": input.screenGranted = false
            default: input.microphoneGranted = false
            }
            XCTAssertFalse(owner.permitsAdmission())
            XCTAssertFalse(owner.acknowledge())
            input.snapshot.screenshots = false
            input.snapshot.narration = false
            XCTAssertEqual(owner.acknowledge(), missing != "accessibility")
        }
    }

    func testManagedRemovalAndEnrollmentRemovalNeverPermitLocalFallbackAcrossRelaunch() throws {
        for managed in [false, true] {
            let root = try root()
            var input = localInput()
            input.snapshot.localOnly = false
            input.managedPresent = managed
            input.enrollmentPresent = true
            input.enrollmentUsable = true
            let owner = CaptureSetupReadiness(root: root, durability: durability, input: { input })
            XCTAssertTrue(owner.acknowledge())
            XCTAssertTrue(owner.admit())
            input.managedPresent = false
            input.enrollmentPresent = false
            input.enrollmentUsable = false
            input.snapshot.localOnly = true
            XCTAssertFalse(owner.permitsAdmission())
            let reopened = CaptureSetupReadiness(root: root, durability: durability, input: { input })
            XCTAssertTrue(reopened.requiresEnrollment)
            XCTAssertFalse(reopened.acknowledge())
            XCTAssertFalse(reopened.admit())
        }
    }

    func testLocalOnlyCannotEnableNetworkCoachOrLiveProjection() throws {
        var input = localInput()
        let owner = CaptureSetupReadiness(root: try root(), durability: durability, input: { input })
        XCTAssertTrue(owner.acknowledge())
        input.snapshot.coachLive = true
        XCTAssertFalse(owner.acknowledge())
        input.snapshot.coachLive = false
        input.snapshot.delivery = .liveCompatibility
        XCTAssertFalse(owner.acknowledge())
    }

    func testCorruptAndFailedStoreFailClosedWithoutOverwritingEvidence() throws {
        let corrupt = Data("not a setup document".utf8)
        for readFails in [false, true] {
            var writes = 0
            let owner = CaptureSetupReadiness(input: { self.localInput() }, read: {
                if readFails { throw CocoaError(.fileReadNoPermission) }
                return corrupt
            }, write: { _ in writes += 1 })
            XCTAssertFalse(owner.acknowledge())
            XCTAssertFalse(owner.admit())
            XCTAssertEqual(writes, 0)
        }
        let root = try root()
        let owner = CaptureSetupReadiness(root: root, durability: .init(
            synchronizeRegularFile: { file, _ in
                if file.lastPathComponent == "capture-setup.json" { throw CocoaError(.fileWriteOutOfSpace) }
            }, synchronizeDirectory: { _ in }), input: { self.localInput() })
        XCTAssertFalse(owner.acknowledge())
        XCTAssertFalse(owner.admit())
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("capture-setup.json").path))
        let reopened = CaptureSetupReadiness(root: root, durability: durability, input: { self.localInput() })
        XCTAssertFalse(reopened.admit(), "pending durability marker survives even after atomic replacement")
        XCTAssertFalse(reopened.acknowledge(), "operator storage repair required, not silent reset")
    }

    func testFailedManagedHistoryWriteBlocksUnmanagedFallback() {
        var input = localInput()
        input.managedPresent = true
        let owner = CaptureSetupReadiness(input: { input }, read: { nil }, write: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        XCTAssertFalse(owner.status().ready)
        input.managedPresent = false
        XCTAssertFalse(owner.acknowledge())
        XCTAssertFalse(owner.admit())
    }

    func testWorkshopCannotExpandAcknowledgedModalitiesAndLabelsNeedNoNewNotice() throws {
        var input = localInput()
        input.snapshot.narration = false
        let owner = CaptureSetupReadiness(root: try root(), durability: durability, input: { input })
        XCTAssertTrue(owner.acknowledge())
        XCTAssertTrue(owner.admit())
        XCTAssertFalse(owner.admit(workshop: true))
        input.snapshot.narration = true
        XCTAssertFalse(owner.admit(workshop: true))
        XCTAssertTrue(owner.acknowledge())
        let date = owner.status().acknowledgedAt
        XCTAssertTrue(owner.admit(workshop: true))
        for _ in 0..<3 { XCTAssertTrue(owner.permitsAdmission(workshop: true)) }
        XCTAssertEqual(owner.status().acknowledgedAt, date)
    }

    func testDeviceBoundProvenanceRequiresActualRecordedActivationAndSurvivesRelaunch() throws {
        let root = try root()
        let owner = CaptureSetupReadiness(root: root, durability: durability, input: { self.localInput() })
        XCTAssertFalse(owner.hasDeviceBoundActivation(identity: "accepted-authority"))
        owner.recordDeviceBoundActivation(identity: "accepted-authority")
        let reopened = CaptureSetupReadiness(root: root, durability: durability, input: { self.localInput() })
        XCTAssertTrue(reopened.hasDeviceBoundActivation(identity: "accepted-authority"))
        XCTAssertFalse(reopened.hasDeviceBoundActivation(identity: "other-authority"))
        XCTAssertFalse(reopened.admit(), "local activation receipt does not establish trust or permit local fallback")
    }

    func testManagedRestrictionsStrictlyRejectPermissiveUnknownAndMalformedValues() throws {
        let good = #"{"version":1,"requireEnrollment":true,"requireReview":true,"screenshots":false}"#
        XCTAssertEqual(try CaptureManagedRestrictions.decode(Data(good.utf8)).screenshots, false)
        for bad in [good.replacingOccurrences(of: "false", with: "true"),
            good.replacingOccurrences(of: "false", with: "0"),
            good.replacingOccurrences(of: "false", with: "null"),
            good.replacingOccurrences(of: "false", with: "\"false\""),
            good.replacingOccurrences(of: "\"requireReview\":true", with: "\"requireReview\":false"),
            good.replacingOccurrences(of: "\"version\":1", with: "\"version\":2"),
            good.replacingOccurrences(of: "screenshots", with: "companyUpload"), "{}"] {
            XCTAssertThrowsError(try CaptureManagedRestrictions.decode(Data(bad.utf8)))
        }
    }
}
