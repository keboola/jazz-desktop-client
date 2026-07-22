import AppKit

// Menu-bar (accessory) agent — no Dock icon, no main window. Top-level code runs on the
// main thread at launch, so we adopt the main actor to construct the AppKit objects.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
