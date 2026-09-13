import AppKit
import Combine
import Darwin
import JazzCaptureCore
import JazzEnrollmentSecurity

/// One latest PCM chunk, not a Task/mailbox per callback. No disk or archive traffic.
final class DirectPilotPCM: @unchecked Sendable {
    private let lock = NSLock()
    private var chunk: CaptureCoachLivePCMChunk?
    private var lost = 0
    func offer(_ value: CaptureCoachLivePCMChunk) {
        lock.withLock {
            guard value.bytes.count <= 64_000, value.bytes.count % 2 == 0 else { lost += 1; return }
            if chunk != nil { lost += 1 }
            chunk = value
        }
    }
    func take() -> CaptureCoachLivePCMChunk? { lock.withLock { defer { chunk = nil }; return chunk } }
    var drops: Int { lock.withLock { lost } }
    static func wave(_ pcm: Data) -> Data {
        precondition(pcm.count <= 64_000 && pcm.count % 2 == 0)
        var data = Data("RIFF".utf8)
        func u32(_ n: UInt32) { var v = n.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func u16(_ n: UInt16) { var v = n.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        u32(UInt32(36 + pcm.count)); data.append(Data("WAVEfmt ".utf8)); u32(16)
        u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
        data.append(Data("data".utf8)); u32(UInt32(pcm.count)); data.append(pcm)
        return data
    }
}

extension CaptureController {
    /// Alternate native owner selected BEFORE constructing the archive controller. Uses the same
    /// tap, SCK/AX admission, PCM encoder, intent/environment fences and bounded transport. No WAL,
    /// EventSpool, archive/upload manager, legacy Keychain vault, reconnect worker or local service.
    @MainActor final class DirectPilot: ObservableObject {
        @Published private(set) var status = "Pilot blocked — signed capability/trust required"
        @Published private(set) var capturing = false
        @Published private(set) var accepted = 0
        @Published private(set) var dropped = 0
        @Published private(set) var mediaGaps = 0
        @Published private(set) var peakRSS = 0
        private(set) var starting = false
        private let environment = CaptureSourceEnvironment()
        private let tap = EventTap()
        private var ax = CaptureAXAdmission()
        private var intent: CaptureStartIntent?
        private var driver: BestEffortTransportDriver?
        private var authority: AuthorizedSignedDeviceBundle?
        private var epoch: JazzBestEffortEpoch?
        private var client: KeboolaClient?
        private var allowedApps = Set<String>()
        private var timer: Timer?
        private var mediaTask: Task<Void, Never>?
        private var audio: NarrationLivePCMAdapter?
        private var audioDrain: Task<Void, Never>?
        private var pcm = DirectPilotPCM()
        private var sequence = 0
        private var source = Identifiers.newSourceId()
        private var stream = Identifiers.newStreamId()
        private var lastImage: UInt64?
        private var lastImageAt = Date.distantPast
        private var lastAudioAt = Date.distantPast
        private var pendingPointer: (id: String, bundle: String)?
        private var generation = UUID()
        private var deadline: TimeInterval = 0
        private var attempts = 0
        private var nativeAudioDrops = 0
        private var appObserver: NSObjectProtocol?
        static var limits: BestEffortTransport.Limits {
            try! .init(units: 32, bytes: 8 * 1024 * 1024, partBytes: 1024 * 1024,
                encodingParts: 2, inFlight: 2, inFlightBytes: 2 * 1024 * 1024)
        }

        init() {
            environment.onRevocation = { [weak self] in
                guard let self else { return }; self.stop(self.environment.deliveryFence)
            }
            environment.observe()
            tap.canAdmit = { [weak self] in self?.eligible == true }
            tap.onPointerSample = { [weak self] sample in
                guard let self, let app = self.frontBundle() else { return }
                self.pendingPointer = (sample.sampleId, app)
            }
            tap.onPointerResolution = { [weak self] sample in
                guard let self else { return }
                guard let pending = self.pendingPointer, pending.id == sample.sampleId else { self.dropped += 1; return }
                self.pendingPointer = nil
                self.captureEvent(sample.kind == .drag ? "drag" : "click", bundle: pending.bundle, at: sample.occurredAt)
            }
            tap.onEvent = { [weak self] event in
                guard let self, let app = self.frontBundle() else { return }
                // Sample activity only: NEVER copy raw keys, clipboard, AX text or document titles.
                let type: String
                switch event.kind {
                case .key: type = "keydown"
                case .rightClick: type = "contextmenu"
                case .click: type = "click"
                case .drag: type = "drag"
                case .copy: type = "copy"
                case .cut: type = "cut"
                case .paste: type = "paste"
                case .scroll: type = "scroll"
                }
                self.captureEvent(type, bundle: app, at: event.occurredAt)
            }
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            RunLoop.main.add(timer, forMode: .common); self.timer = timer
            appObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let self, self.capturing, self.frontBundle() == nil { self.stop(.stop) }
                }
            }
        }

        deinit {
            timer?.invalidate()
            if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) }
        }

        var quiescent: Bool {
            !starting && mediaTask == nil && audioDrain == nil && audio == nil
                && ScreenCapture.physicalCapture.isClosedAndQuiescent
                && (intent?.bestEffortIsQuiescent ?? true) && ax.isClosedAndQuiescent
        }
        private var eligible: Bool {
            capturing && environment.permitsCapture && ProcessInfo.processInfo.systemUptime < deadline
                && peakRSS <= 512 * 1024 * 1024 && frontBundle() != nil
                && Permissions.status(.accessibility) == .granted
        }
        private func frontBundle() -> String? {
            guard let app = NSWorkspace.shared.frontmostApplication,
                app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                let bundle = app.bundleIdentifier, allowedApps.contains(bundle) else { return nil }
            return bundle
        }

        /// Called only by the pilot Import menu. Trust is code-signed metadata, never in this input.
        func importBundle(_ raw: String) async {
            guard !capturing, !starting, quiescent, raw.utf8.count <= 65_536 else { return }
            starting = true; defer { starting = false }
            do {
                let profile = try DirectPilotProfile.check()
                let importer = SignedEnrollmentImporter(trustPolicy: EnrollmentTrustBootstrap.load(),
                    acceptanceStore: FileEnrollmentAcceptanceStore(fileURL: DirectPilotProfile.root.appendingPathComponent("acceptance.json")))
                let authorized = try importer.authorize(raw)
                let p = authorized.payload
                guard p.projectId == "3044", p.deviceId == profile.device,
                    p.streamSourceId == profile.source, p.bestEffortCapability?.sourceId == profile.source,
                    p.bestEffortCapability?.ongoingTransmission == true else { throw JazzBestEffortContract.Failure.authority }
                guard let verified = await KeboolaClient.verifyToken(token: p.token, stacks: [p.stackURL]) else {
                    throw JazzBestEffortContract.Failure.authority
                }
                try authorized.bundle.validateVerifiedCredential(verified.verify)
                try Keychain.set(raw, account: DirectPilotProfile.credentialAccount)
                status = "Pilot authorized — explicit Start transmits sampled activity; loss/coverage unknown"
            } catch { status = "Pilot blocked — signature/scope/expiry/narrow-token verification failed" }
        }

        func start() {
            guard !capturing, !starting, quiescent else { return }
            starting = true; generation = UUID(); let requested = generation
            Task {
                defer { starting = false }
                do {
                    let profile = try DirectPilotProfile.check()
                    guard let raw = try Keychain.get(account: DirectPilotProfile.credentialAccount) else { throw JazzBestEffortContract.Failure.authority }
                    let importer = SignedEnrollmentImporter(trustPolicy: EnrollmentTrustBootstrap.load(),
                        acceptanceStore: FileEnrollmentAcceptanceStore(fileURL: DirectPilotProfile.root.appendingPathComponent("acceptance.json")))
                    let auth = try importer.authorize(raw); let p = auth.payload
                    guard p.projectId == "3044", p.deviceId == profile.device,
                        p.streamSourceId == profile.source, let capability = p.bestEffortCapability,
                        let endpoint = p.streamEndpoint, let base = StreamEndpoint.normalize(endpoint),
                        let url = URL(string: base + "/v1/logs"), url.scheme == "https",
                        let routing = try auth.bundle.archiveEnrollmentRouting(verifiedStackURL: p.stackURL, verifiedProjectId: p.projectId)
                    else { throw JazzBestEffortContract.Failure.authority }
                    guard let verified = await KeboolaClient.verifyToken(token: p.token, stacks: [p.stackURL]), requested == generation else { throw JazzBestEffortContract.Failure.authority }
                    try auth.bundle.validateVerifiedCredential(verified.verify)
                    guard Permissions.status(.accessibility) == .granted,
                        Permissions.status(.screenRecording) == .granted,
                        environment.acknowledgeCurrentUser() else { throw JazzBestEffortContract.Failure.authority }
                    let signed = try JazzArchiveSignedEnrollmentAuthority(issuer: p.issuer, audience: p.audience,
                        bundleId: p.bundleId, generation: p.generation, envelopeDigest: auth.envelopeDigest)
                    let signedRouting = routing.bindingSignedAuthority(signed)
                    let route = try signedRouting.signedUploadRouteBinding()
                    let binding = try JazzBestEffortBinding(route: route, sourceId: profile.source)
                    let proposed = try JazzBestEffortContract.makeEpoch(binding: binding, capability: capability)
                    let epoch = try auth.authorizeBestEffortEpoch(JazzArchiveCanonicalJSON.encode(proposed), observedSourceId: profile.source, now: Date())
                    let expiries = [p.expiresAt, p.bundleExpiresAt, capability.expiresAt].compactMap(Timestamps.parse)
                    guard expiries.count == 3, let expiry = expiries.min(), expiry > Date() else { throw JazzBestEffortContract.Failure.authority }
                    deadline = ProcessInfo.processInfo.systemUptime + expiry.timeIntervalSinceNow
                    var request = URLRequest(url: url); request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    let driver = try BestEffortTransportDriver(limits: Self.limits,
                        eventRequest: request, authorityDeadline: deadline)
                    let intent = CaptureStartIntent(root: DirectPilotProfile.root, continuous: true,
                        durability: JazzArchiveFilesystemPlatform.durability)
                    intent.completeRecovery(succeeded: true)
                    guard intent.attachBestEffortDelivery(driver), let token = intent.requestStart(explicit: true) else { throw JazzBestEffortContract.Failure.authority }
                    intent.onBestEffortRevocation = { [weak self] in self?.stop(.revoked) }
                    self.intent = intent; self.driver = driver; self.authority = auth; self.epoch = epoch
                    self.allowedApps = profile.apps
                    let envelope = try JazzSignedDeviceCredentialEnvelope(token: p.token, expiresAt: p.expiresAt,
                        routeBinding: route, enrollmentRouting: signedRouting, streamSourceId: p.streamSourceId, streamEndpoint: endpoint)
                    self.client = KeboolaClient(stackURL: p.stackURL, credentialResolver: { _ in try envelope.keboolaCredential() })
                    sequence = 0; source = Identifiers.newSourceId(); stream = Identifiers.newStreamId()
                    lastImage = nil; lastImageAt = .distantPast; lastAudioAt = .distantPast
                    ax = CaptureAXAdmission(accepting: true)
                    let started = await intent.runStart(token, recovery: { true }, prepare: { true }, enable: {
                        guard requested == self.generation, self.environment.permitsCapture else { return false }
                        self.capturing = true
                        guard ScreenCapture.physicalCapture.open(eligible: { [weak self] in self?.eligible == true }),
                            driver.startExplicitly(generation: token), self.tap.start() else { return false }
                        return true
                    }, abort: { self.stop(.stop) })
                    guard started else { throw JazzBestEffortContract.Failure.authority }
                    tap.canAdmit = { [weak self] in self?.eligible == true }
                    if Bundle.main.object(forInfoDictionaryKey: "JazzPilotCaptureAudio") as? Bool == true {
                        guard Permissions.status(.microphone) == .granted else { stop(.stop); status = "Pilot blocked — microphone permission required"; return }
                        pcm = DirectPilotPCM(); let sink = pcm
                        let audio = NarrationLivePCMAdapter(boundedPilot: true, handler: { sink.offer($0) })
                        self.audio = audio; try audio.start()
                    }
                    status = "Capturing + transmitting · volatile loss accepted · coverage unknown"
                } catch {
                    stop(.stop); status = "Pilot blocked — verified capability, permissions or physical owners unavailable"
                }
            }
        }

        func stop(_ reason: BestEffortTransport.Fence = .stop) {
            generation = UUID(); capturing = false
            driver?.suspend(reason); intent?.pause(); tap.stop(); ax.revoke()
            ScreenCapture.physicalCapture.close(); pendingPointer = nil
            if let audio {
                nativeAudioDrops += audio.droppedCallbacks
                self.audio = nil; audio.stopProducing()
                audioDrain = Task { await Task.detached { audio.drain() }.value; self.audioDrain = nil; _ = self.pcm.take() }
            }
            _ = pcm.take()
            status = "Paused/stopped — no automatic reconnect; explicit Resume required"
            // Do NOT clear/cancel mediaTask: its physical SCK/prepare owner must actually return.
        }

        private func captureEvent(_ type: String, bundle: String, at: Date) {
            guard eligible, allowedApps.contains(bundle), let epoch else { return }
            sequence += 1
            let event = ActivityEvent(sessionId: epoch.captureId, eventId: Identifiers.eventId(sessionId: epoch.captureId, sequence: sequence),
                sequence: sequence, timestamp: Timestamps.iso8601(at), eventType: type, url: "app://" + bundle,
                inputMasked: true)
            guard mediaTask == nil, Date().timeIntervalSince(lastImageAt) >= 3,
                bundle == frontBundle(), let focus = Accessibility.focusedInfo(admission: ax),
                focus.ownerPID == NSWorkspace.shared.frontmostApplication?.processIdentifier,
                !Sensitivity.isSensitiveField(role: focus.role, subrole: focus.subrole, label: focus.label),
                Permissions.status(.screenRecording) == .granted else { submit(event); return }
            lastImageAt = Date(); let token = generation
            mediaTask = Task {
                defer { mediaTask = nil }
                let result = await ScreenCapture.focusedWindowShot(admission: ScreenCapture.physicalCapture.admission,
                    bundleID: bundle, privacyDenylist: [], pilotMaximumDimension: 960, pilotMaximumJPEGBytes: 512 * 1024)
                guard token == generation, eligible else { mediaGaps += 1; return }
                guard case .captured(let shot) = result,
                    case .window(let owner, _) = shot.scope, owner == bundle else { mediaGaps += 1; submit(event); return }
                guard lastImage != shot.hash else { submit(event); return }; lastImage = shot.hash
                await sendMedia(shot.data, type: "image/jpeg", event: event, token: token)
            }
        }

        private func submit(_ event: ActivityEvent, media: BestEffortTransportDriver.Media? = nil,
            content: JazzArchiveArtifactContent? = nil) {
            guard eligible, let driver, let epoch, let intent else { return }
            guard let timestamp = Timestamps.parse(event.timestamp), Date().timeIntervalSince(timestamp) <= 30 else { dropped += 1; return }
            do {
                let observationID = Identifiers.newObservationId()
                let artifactID = content.map { _ in Identifiers.newArtifactId() }
                let role = content?.mediaType == "audio/wav" ? "narration_audio" : "screenshot"
                let record = ArchiveRecord(event: event, observationId: observationID,
                    originId: epoch.originId, captureId: epoch.captureId,
                    streamId: stream, streamSequence: event.sequence ?? sequence, sourceRefs: [.init(sourceId: source, role: "native_capture")],
                    actorRefs: [], artifactRefs: artifactID.map { [.init(artifactId: $0, role: role)] } ?? [],
                    provenance: .init(factClass: .observed, sources: [source]),
                    quality: .init(status: .partial, reasons: ["sampledActivity"]),
                    privacy: .init(status: .captured, policyVersion: "direct-pilot-v1"))
                let item = try JazzLiveProjectionItem.observation(JazzArchiveRecord(erasing: record))
                let envelope = try JazzBestEffortContract.envelope(item: item, epoch: epoch)
                var logs = try JazzBestEffortContract.otlpRequest(envelope, epoch: epoch)
                if let content, let artifactID {
                    let artifact = JazzArchiveArtifact(artifactId: artifactID, captureId: epoch.captureId,
                        kind: role, content: content, sourceRefs: [.init(sourceId: source, role: role)],
                        observationRefs: [observationID],
                        captureInterval: .init(startedAt: content.mediaType == "audio/wav" ? epoch.startedAt : event.timestamp,
                            endedAt: Timestamps.iso8601()),
                        provenance: .init(factClass: .observed, sources: [source]),
                        quality: .init(status: .partial, reasons: ["sampledActivity"]),
                        privacy: .init(status: .captured, policyVersion: "direct-pilot-v1"))
                    let item = try JazzLiveProjectionItem.artifact(artifact, fallbackCapturedAt: event.timestamp)
                    let pending = try JazzBestEffortContract.envelope(item: item, epoch: epoch, mediaState: "pending")
                    let artifactLogs = try JazzBestEffortContract.otlpRequest(pending, epoch: epoch)
                    logs = .init(resourceLogs: logs.resourceLogs + artifactLogs.resourceLogs)
                }
                attempts += 1
                if !driver.offer(unitID: UUID(), generation: intent.generation, logs: logs, media: media) { dropped += 1 }
            } catch { dropped += 1 }
        }

        private func sendMedia(_ data: Data, type: String, event original: ActivityEvent, token: UUID) async {
            guard data.count <= 512 * 1024, let client, let epoch, eligible else { mediaGaps += 1; return }
            do {
                let digest = JazzArchiveDigest.sha256Hex(data)
                let prepared = try await client.prepareFile(name: "jazz-qual-" + UUID().uuidString.lowercased(),
                    tags: ["jazz-direct-pilot", "capture:" + epoch.captureId, "sha256:" + digest], isPermanent: false,
                    maximumResponseBytes: 65536)
                guard token == generation, eligible, let params = prepared.gcsUploadParams,
                    let expiry = params.expiresIn, expiry > 0 else {
                    mediaGaps += 1
                    if type == "image/jpeg", token == generation { submit(original) }
                    return
                }
                let request = try BestEffortFileEncoder.putRequest(params: params, contentType: type)
                let media = BestEffortTransportDriver.Media(request: request, maximumBytes: data.count,
                    expiresAt: min(deadline, ProcessInfo.processInfo.systemUptime + Double(expiry))) { limit, cancelled in
                    guard !cancelled(), data.count <= limit else { throw CancellationError() }; return data
                }
                var event = original
                if type != "image/jpeg" {
                    sequence += 1
                    event.eventId = Identifiers.eventId(sessionId: epoch.captureId, sequence: sequence); event.sequence = sequence
                }
                if type == "image/jpeg" { event.screenshotId = String(prepared.id) } else { event.audioFileId = String(prepared.id) }
                let content = JazzArchiveArtifactContent(path: "blobs/sha256/\(digest.prefix(2))/\(digest)",
                    mediaType: type, byteLength: Int64(data.count), sha256: digest)
                submit(event, media: media, content: content)
            } catch {
                mediaGaps += 1
                if type == "image/jpeg", token == generation { submit(original) }
            } // no prepare replay, no deletion of uncertain remote objects
        }

        private func poll() {
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage); peakRSS = max(peakRSS, Int(usage.ru_maxrss))
            // Sampled fail-closed tripwire, NOT a claimed hard bound on private OS/codec allocations.
            if capturing && (peakRSS > 512 * 1024 * 1024 || !eligible) { stop(.revoked) }
            if let driver {
                for report in driver.drainReports() {
                    if report.event == .hopAccepted { accepted += 1 } else { dropped += 1 }
                    if report.media == .unavailable || report.media == .unknown { mediaGaps += 1 }
                }
                if driver.adapterUsage.overflow { stop(.stop); status = "Pilot stopped — loss reports overflowed; coverage unknown" }
            }
            guard eligible, mediaTask == nil, Date().timeIntervalSince(lastAudioAt) >= 4,
                frontBundle() != nil, let chunk = pcm.take(), let epoch else { return }
            lastAudioAt = Date(); let token = generation
            let event = ActivityEvent(sessionId: epoch.captureId, eventId: UUID().uuidString,
                timestamp: chunk.recordedAt, eventType: "narration", url: "app://session", inputMasked: true)
            mediaTask = Task { defer { mediaTask = nil }; await sendMedia(DirectPilotPCM.wave(chunk.bytes), type: "audio/wav", event: event, token: token) }
        }
        var lossSummary: String { "OTLP ACK \(accepted) · dropped/unknown \(dropped) · media gaps \(mediaGaps) · PCM drops \(nativeAudioDrops + pcm.drops + (audio?.droppedCallbacks ?? 0)) · coverage unknown" }
    }
}
