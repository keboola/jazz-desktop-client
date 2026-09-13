import AppKit

// Menu-bar (accessory) agent — no Dock icon, no main window. Top-level code runs on the
// main thread at launch, so we adopt the main actor to construct the AppKit objects.
MainActor.assumeIsolated {
    // Packaging/smoke preflight in the exact signed executable. Never constructs archive owners,
    // reads credentials, prompts for permissions, or starts capture.
    if CommandLine.arguments.contains("--pilot-preflight") {
        guard DirectPilotProfile.enabled else { print("{\"error\":\"NOT_ISOLATED_PILOT\"}"); exit(2) }
        let result: [String: Any] = [
            "bundleId": DirectPilotProfile.bundleID,
            "accessibilityGranted": Permissions.status(.accessibility) == .granted,
            "screenRecordingGranted": Permissions.status(.screenRecording) == .granted,
            "microphoneGranted": Permissions.status(.microphone) == .granted,
            "legacyOwnersConstructed": false,
            "captureStarted": false,
        ]
        print(String(data: try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
        exit(0)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
