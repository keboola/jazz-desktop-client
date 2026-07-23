import XCTest

@testable import JasnostCaptureCore

final class CaptureIdentityStoreTests: XCTestCase {
    private let firstTime = "2026-07-22T10:00:00.000Z"
    private let secondTime = "2026-07-23T10:00:00.000Z"

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-identity-tests-\(UUID().uuidString)")
    }

    func testInstallationSourceAndActorIdentitiesSurviveRelaunch() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = CaptureIdentityStore(root: root)
        let installation = try await first.loadOrCreate(createdAt: firstTime).installation
        let native = try await first.source(kind: "macos.native", createdAt: firstTime)
        let actor = try await first.actor(
            namespace: "oidc.email",
            value: "alice@example.com",
            displayName: "Alice",
            at: firstTime)

        let relaunched = CaptureIdentityStore(root: root)
        let snapshot = try await relaunched.loadOrCreate(createdAt: secondTime)

        XCTAssertEqual(snapshot.installation, installation)
        XCTAssertEqual(snapshot.sources, [native])
        XCTAssertEqual(snapshot.actors, [actor])
        let sameSource = try await relaunched.source(
            kind: "macos.native", createdAt: secondTime)
        let sameActor = try await relaunched.actor(
            namespace: "oidc.email", value: "alice@example.com", at: secondTime)
        XCTAssertEqual(sameSource, native)
        XCTAssertEqual(sameActor.actorId, actor.actorId)
    }

    func testActorAndSourceConceptsRemainIndependent() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureIdentityStore(root: root)

        let native = try await store.source(kind: "macos.native", createdAt: firstTime)
        let meeting = try await store.source(kind: "meeting.share", createdAt: firstTime)
        let performer = try await store.actor(
            namespace: "oidc.email", value: "performer@example.com", at: firstTime)
        let narrator = try await store.actor(
            namespace: "oidc.email", value: "narrator@example.com", at: firstTime)

        XCTAssertNotEqual(native.sourceId, meeting.sourceId)
        XCTAssertNotEqual(performer.actorId, narrator.actorId)
        XCTAssertFalse([native.sourceId, meeting.sourceId].contains(performer.actorId))
    }

    func testDisplayNameChangeKeepsActorIdentityAndRecordsUpdateTime() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureIdentityStore(root: root)
        let original = try await store.actor(
            namespace: "oidc.subject", value: "person-42", displayName: "Alice", at: firstTime)
        let renamed = try await store.actor(
            namespace: "oidc.subject", value: "person-42", displayName: "Alice Cooper",
            at: secondTime)

        XCTAssertEqual(renamed.actorId, original.actorId)
        XCTAssertEqual(renamed.displayName, "Alice Cooper")
        XCTAssertEqual(renamed.updatedAt, secondTime)
    }

    func testCorruptIdentityFileFailsClosedInsteadOfMintingAnotherOrigin() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let identityDirectory = root.appendingPathComponent(".capture-identity")
        try FileManager.default.createDirectory(
            at: identityDirectory, withIntermediateDirectories: true)
        try Data("{broken".utf8).write(
            to: identityDirectory.appendingPathComponent("identity.json"))

        do {
            _ = try await CaptureIdentityStore(root: root).loadOrCreate(createdAt: firstTime)
            XCTFail("expected corrupt identity store")
        } catch {
            guard case CaptureIdentityStoreError.corrupt = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testInvalidSourceAndBlankExternalActorIdentityAreRejected() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureIdentityStore(root: root)
        _ = try await store.loadOrCreate(createdAt: firstTime)

        do {
            _ = try await store.source(kind: "Meeting Share", createdAt: firstTime)
            XCTFail("expected invalid source kind")
        } catch {
            XCTAssertEqual(error as? CaptureIdentityStoreError, .invalidField("source.kind"))
        }
        do {
            _ = try await store.actor(
                namespace: "oidc.email", value: "  ", displayName: nil, at: firstTime)
            XCTFail("expected invalid actor value")
        } catch {
            XCTAssertEqual(error as? CaptureIdentityStoreError, .invalidField("actor.value"))
        }
    }
}
