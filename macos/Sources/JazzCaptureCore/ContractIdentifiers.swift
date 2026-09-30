import Foundation

/// Cross-repository identifiers the macOS client shares with the Jazz processor and its web app,
/// mirrored from `contract/identifiers.json`. They live in the core (pure Foundation, no TCC) so
/// `IdentifierParityTests` can pin every value to the manifest in CI; the executable target's
/// WebCanvas, BdmLiveBridge, RegistryFetcher and HTTP clients reference them instead of literals.
///
/// Only the canonical (post-rename) spellings are here: the client emits nothing else. The legacy
/// `jasnost*` spellings in the manifest are for readers (the processor and the SPA).
public enum JazzContractIdentifiers {
    /// Keboola Storage-File tags the client writes or queries.
    public enum StorageTag {
        /// The kind tag stamped first on narration audio and liveCompatibility artifact uploads.
        public static let capture = "jazz"
        /// Marks a liveCompatibility projection of an archive artifact (next to `kind:<kind>`).
        public static let archiveArtifact = "jazz-artifact"
        /// Narration audio uploads, next to ``capture``, `session:<id>` and `label:<id>`.
        public static let narration = "narration"
        /// The Data App's per-Area registry document (with `area:<areaId>`).
        public static let areaRegistry = "jazz-area-registry"
    }

    /// Native-control-plane request and response headers.
    public enum Header {
        public static let deviceId = "X-Jazz-Device-Id"
        public static let bootstrap = "X-Jazz-Bootstrap"
        public static let replayCapability = "X-Jazz-Replay-Capability"
        public static let actionAuthorityProtocol = "X-Jazz-Action-Authority-Protocol"
        public static let archiveId = "X-Jazz-Archive-Id"
        public static let contentDigest = "X-Jazz-Content-Digest"
        public static let rawSha256 = "X-Jazz-Raw-Sha256"
        public static let byteLength = "X-Jazz-Byte-Length"
    }

    /// Terminal resources on the native control-plane origin.
    public enum DeviceRoute {
        /// `GET` the enrolled device's recording plan (`device-recording-plan-v1`).
        public static let recordingPlan = "/api/device/recording-plan"
    }

    /// The WKWebView bridge between the embedded review SPA and the native app.
    public enum WebBridge {
        /// `window.webkit.messageHandlers.<handler>`: the web-to-native channel.
        public static let handler = "jazz"
        /// `window.<hook>(segment)`: the live BDM page's native-to-web segment hook.
        public static let bdmSegmentHook = "__jazzBdmSegment"
        /// The `?embed=` value that puts the SPA in native embed mode.
        public static let embedMode = "macos"
        /// Every `type` a web-to-native message may carry; anything else is dropped.
        public static let webToNativeMessageTypes: Set<String> = [
            "ready", "openSettings", "export", "bdmLiveReady", "bdmNextQuestion",
        ]
    }
}
