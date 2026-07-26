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
        let leaseProvider = TestCaptureIdentityStoreLeaseProvider()
        let first = CaptureIdentityStore(
            root: root,
            durability: foundationTestFilesystemDurability(),
            leaseProvider: leaseProvider)
        let installation = try await first.loadOrCreate(createdAt: firstTime).installation
        let native = try await first.source(kind: "macos.native", createdAt: firstTime)
        let actor = try await first.actor(
            namespace: "oidc.email",
            value: "alice@example.com",
            displayName: "Alice",
            at: firstTime)

        let relaunched = CaptureIdentityStore(
            root: root,
            durability: foundationTestFilesystemDurability(),
            leaseProvider: leaseProvider)
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
        let store = CaptureIdentityStore(
            root: root,
            durability: foundationTestFilesystemDurability(),
            leaseProvider: TestCaptureIdentityStoreLeaseProvider())

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
        let store = CaptureIdentityStore(
            root: root,
            durability: foundationTestFilesystemDurability(),
            leaseProvider: TestCaptureIdentityStoreLeaseProvider())
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
            _ = try await CaptureIdentityStore(
                root: root,
                durability: foundationTestFilesystemDurability(),
                leaseProvider: TestCaptureIdentityStoreLeaseProvider()
            ).loadOrCreate(createdAt: firstTime)
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
        let store = CaptureIdentityStore(
            root: root,
            durability: foundationTestFilesystemDurability(),
            leaseProvider: TestCaptureIdentityStoreLeaseProvider())
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

    func testIdentityDocumentSynchronizesBeforeInstallationIsReturned()
        async throws
    {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let identityDirectory = root.appendingPathComponent(
            ".capture-identity", isDirectory: true)
        let identityURL = identityDirectory.appendingPathComponent(
            "identity.json")
        let recorder = CanonicalDurabilityRecorder()
        let store = CaptureIdentityStore(
            root: root,
            durability: recorder.value(),
            leaseProvider: TestCaptureIdentityStoreLeaseProvider())

        _ = try await store.loadOrCreate(createdAt: firstTime)

        let events = recorder.events()
        let fileIndex = try XCTUnwrap(events.firstIndex(
            of: .file(CanonicalDurabilityRecorder.path(identityURL))))
        let identityDirectoryIndex = try XCTUnwrap(events.firstIndex(
            of: .directory(CanonicalDurabilityRecorder.path(identityDirectory))))
        let rootIndex = try XCTUnwrap(events.firstIndex(
            of: .directory(CanonicalDurabilityRecorder.path(root))))
        XCTAssertLessThan(fileIndex, identityDirectoryIndex)
        XCTAssertLessThan(identityDirectoryIndex, rootIndex)
    }

    func testIdentityWriteFailureIsFailClosedAndRetryKeepsExactPublishedIds()
        async throws
    {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let identityURL = root
            .appendingPathComponent(".capture-identity", isDirectory: true)
            .appendingPathComponent("identity.json")
        let identityFileEvent = CanonicalDurabilityRecorder.Event.file(
            CanonicalDurabilityRecorder.path(identityURL))
        let leaseProvider = TestCaptureIdentityStoreLeaseProvider()
        let initialRecorder = CanonicalDurabilityRecorder()
        initialRecorder.failOnce(on: identityFileEvent)
        let initial = CaptureIdentityStore(
            root: root,
            durability: initialRecorder.value(),
            leaseProvider: leaseProvider)

        do {
            _ = try await initial.loadOrCreate(createdAt: firstTime)
            XCTFail("installation must not return before identity durability")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveFilesystemDurabilityError,
                .synchronizationFailed)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: identityURL.path))

        let healthy = CaptureIdentityStore(
            root: root,
            durability: foundationTestFilesystemDurability(),
            leaseProvider: leaseProvider)
        let recovered = try await healthy.loadOrCreate(createdAt: secondTime)
        let sameInstallation = try await healthy.loadOrCreate(
            createdAt: firstTime).installation
        XCTAssertEqual(sameInstallation, recovered.installation)

        let mutationRecorder = CanonicalDurabilityRecorder()
        mutationRecorder.failOnce(on: identityFileEvent, afterMatches: 1)
        let failingMutation = CaptureIdentityStore(
            root: root,
            durability: mutationRecorder.value(),
            leaseProvider: leaseProvider)
        do {
            _ = try await failingMutation.source(
                kind: "macos.native", createdAt: firstTime)
            XCTFail("source must not return before updated identity durability")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveFilesystemDurabilityError,
                .synchronizationFailed)
        }

        let source = try await healthy.source(
            kind: "macos.native", createdAt: secondTime)
        let snapshot = try await healthy.snapshot()
        XCTAssertEqual(snapshot.installation, recovered.installation)
        XCTAssertEqual(snapshot.sources, [source])
    }

    func testConcurrentStoresConvergeOnOneInstallationSourceAndActorIdentity() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let leaseProvider = TestCaptureIdentityStoreLeaseProvider()
        let first = CaptureIdentityStore(
            root: root,
            durability: foundationTestFilesystemDurability(),
            leaseProvider: leaseProvider)
        let second = CaptureIdentityStore(
            root: root,
            durability: foundationTestFilesystemDurability(),
            leaseProvider: leaseProvider)

        async let firstSnapshot = first.loadOrCreate(createdAt: firstTime)
        async let secondSnapshot = second.loadOrCreate(createdAt: secondTime)
        let (leftInstallation, rightInstallation) = try await (
            firstSnapshot.installation, secondSnapshot.installation
        )
        XCTAssertEqual(leftInstallation.originId, rightInstallation.originId)

        async let firstSource = first.source(kind: "macos.native", createdAt: firstTime)
        async let secondSource = second.source(kind: "macos.native", createdAt: secondTime)
        let (leftSource, rightSource) = try await (firstSource, secondSource)
        XCTAssertEqual(leftSource, rightSource)

        async let firstActor = first.actor(
            namespace: "oidc.subject", value: "person-42", displayName: "Alice", at: firstTime)
        async let secondActor = second.actor(
            namespace: "oidc.subject", value: "person-42", displayName: "Alice", at: secondTime)
        let (leftActor, rightActor) = try await (firstActor, secondActor)
        XCTAssertEqual(leftActor, rightActor)

        let final = try await first.snapshot()
        XCTAssertEqual(final.sources, [leftSource])
        XCTAssertEqual(final.actors, [leftActor])
    }

    func testStoreLoadedBeforeAnotherMutationCannotLoseThatMutation() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let leaseProvider = TestCaptureIdentityStoreLeaseProvider()
        let first = CaptureIdentityStore(
            root: root,
            durability: foundationTestFilesystemDurability(),
            leaseProvider: leaseProvider)
        let stale = CaptureIdentityStore(
            root: root,
            durability: foundationTestFilesystemDurability(),
            leaseProvider: leaseProvider)
        _ = try await first.loadOrCreate(createdAt: firstTime)
        _ = try await stale.loadOrCreate(createdAt: firstTime)

        let source = try await first.source(kind: "macos.native", createdAt: firstTime)
        let actor = try await stale.actor(
            namespace: "oidc.subject", value: "person-42", at: secondTime)

        let final = try await first.snapshot()
        XCTAssertEqual(final.sources, [source])
        XCTAssertEqual(final.actors, [actor])
    }
}

/// Deterministic stand-in for the executable's file lock. Sharing one provider between two store
/// instances models two processes contending for the same identity-registry lease.
private final class TestCaptureIdentityStoreLeaseProvider:
    @unchecked Sendable, CaptureIdentityStoreLeaseProvider
{
    private let condition = NSCondition()
    private var isHeld = false

    func acquire(
        root _: URL,
        fileManager _: FileManager
    ) throws -> any CaptureIdentityStoreLease {
        condition.lock()
        while isHeld {
            condition.wait()
        }
        isHeld = true
        condition.unlock()
        return TestCaptureIdentityStoreLease(provider: self)
    }

    fileprivate func release() {
        condition.lock()
        precondition(isHeld, "capture identity test lease released without ownership")
        isHeld = false
        condition.signal()
        condition.unlock()
    }
}

private final class TestCaptureIdentityStoreLease:
    @unchecked Sendable, CaptureIdentityStoreLease
{
    private let mutex = NSLock()
    private var provider: TestCaptureIdentityStoreLeaseProvider?

    init(provider: TestCaptureIdentityStoreLeaseProvider) {
        self.provider = provider
    }

    func release() {
        mutex.lock()
        let provider = provider
        self.provider = nil
        mutex.unlock()
        provider?.release()
    }

    deinit { release() }
}
