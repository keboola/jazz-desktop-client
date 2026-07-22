// swift-tools-version: 6.0
import PackageDescription

// Jazz macOS capture agent. The core (pure Foundation) is testable in CI without any
// TCC permissions; the executable adds the system-capture layers (ScreenCaptureKit,
// Accessibility, CGEventTap, AVFoundation) and the menu-bar UI.
let package = Package(
    name: "JasnostCapture",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "JasnostCaptureCore"),
        .executableTarget(
            name: "JasnostCapture",
            dependencies: ["JasnostCaptureCore"]
        ),
        .testTarget(
            name: "JasnostCaptureCoreTests",
            dependencies: ["JasnostCaptureCore"]
        ),
    ],
    // Language mode 5: this is system-level code with C callbacks (CGEventTap) and shared
    // capture state; Swift 6 strict-concurrency would add churn without real safety wins here.
    swiftLanguageModes: [.v5]
)
