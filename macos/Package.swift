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
        .target(
            name: "JasnostEnrollmentSecurity",
            dependencies: ["JasnostCaptureCore"]
        ),
        .executableTarget(
            name: "JasnostCapture",
            dependencies: ["JasnostCaptureCore", "JasnostEnrollmentSecurity"]
        ),
        .testTarget(
            name: "JasnostCaptureCoreTests",
            dependencies: ["JasnostCaptureCore"]
        ),
        .testTarget(
            name: "JasnostEnrollmentSecurityTests",
            dependencies: ["JasnostCaptureCore", "JasnostEnrollmentSecurity"],
            resources: [.copy("Fixtures")]
        ),
    ],
    // Language mode 5: this is system-level code with C callbacks (CGEventTap) and shared
    // capture state; Swift 6 strict-concurrency would add churn without real safety wins here.
    swiftLanguageModes: [.v5]
)
