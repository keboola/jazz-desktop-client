// swift-tools-version: 6.0
import PackageDescription

// Jazz macOS capture agent. The core (pure Foundation) is testable in CI without any
// TCC permissions; the executable adds the system-capture layers (ScreenCaptureKit,
// Accessibility, CGEventTap, AVFoundation) and the menu-bar UI.
let package = Package(
    name: "JazzCapture",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "JazzCaptureCore"),
        .target(
            name: "JazzEnrollmentSecurity",
            dependencies: ["JazzCaptureCore"]
        ),
        .executableTarget(
            name: "JazzCapture",
            dependencies: ["JazzCaptureCore", "JazzEnrollmentSecurity"]
        ),
        .testTarget(
            name: "JazzCaptureCoreTests",
            dependencies: ["JazzCaptureCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "JazzCaptureTests",
            dependencies: ["JazzCapture", "JazzCaptureCore"]
        ),
        .testTarget(
            name: "JazzEnrollmentSecurityTests",
            dependencies: ["JazzCaptureCore", "JazzEnrollmentSecurity"],
            resources: [.copy("Fixtures")]
        ),
    ],
    // Language mode 5: this is system-level code with C callbacks (CGEventTap) and shared
    // capture state; Swift 6 strict-concurrency would add churn without real safety wins here.
    swiftLanguageModes: [.v5]
)
