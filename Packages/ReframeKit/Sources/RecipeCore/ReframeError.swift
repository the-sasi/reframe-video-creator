import Foundation

/// One error type for the whole app.
///
/// Every case carries a `presentation` with a title, a plain explanation, and — critically — a
/// **recovery action that actually does something**. §44 asks for actionable errors; a message
/// that says "try again" is not actionable, a button that re-exports at 720p is.
///
/// Technical detail goes to `os.Logger`, never to the screen. There is no code path here that
/// surfaces an `NSError` domain string.
public enum ReframeError: Error, Sendable, Hashable {
    // Import
    case unsupportedFormat(detail: String)
    case corruptMedia(detail: String)
    case noVideoTrack
    case referenceTooLong(seconds: Double, limit: Double)
    case sharedURLNotAFile(host: String?)

    // Permissions
    case photosAccessDenied
    case photosAddOnlyDenied
    case fileAccessDenied(name: String)

    // Resources
    case insufficientStorage(neededBytes: Int64, availableBytes: Int64)
    case lowMemory
    case thermalThrottling

    // Analysis
    case analysisCancelled
    case analysisFailed(stage: String, detail: String)
    case noScenesDetected

    // Content
    case notEnoughAssets(needed: Int, provided: Int)

    // Render / export
    case renderSetupFailed(detail: String)
    case metalUnavailable
    case exportFailed(detail: String)
    case exportCancelled

    // Documents
    case documentTooNew(found: Int, supported: Int)
    case documentCorrupt(detail: String)
    case assetMissing(name: String)

    public struct Presentation: Sendable, Hashable {
        public var title: String
        public var message: String
        public var recovery: RecoveryAction
        /// Cancellations are not failures. The UI dismisses silently rather than alerting.
        public var isSilent: Bool

        public init(title: String, message: String, recovery: RecoveryAction, isSilent: Bool = false) {
            self.title = title
            self.message = message
            self.recovery = recovery
            self.isSilent = isSilent
        }
    }

    public enum RecoveryAction: Sendable, Hashable {
        case dismiss
        case openSettings
        case retry
        case retryAtLowerQuality
        case chooseDifferentFile
        case addMoreAssets(needed: Int)
        case manageStorage
        case showScreenRecordingHelp
        case waitForCooldown

        public var buttonTitle: String {
            switch self {
            case .dismiss: return "OK"
            case .openSettings: return "Open Settings"
            case .retry: return "Try Again"
            case .retryAtLowerQuality: return "Export at 720p"
            case .chooseDifferentFile: return "Choose Another"
            case .addMoreAssets: return "Add Photos"
            case .manageStorage: return "Manage Storage"
            case .showScreenRecordingHelp: return "How to do this"
            case .waitForCooldown: return "OK"
            }
        }
    }

    public var presentation: Presentation {
        switch self {
        case .unsupportedFormat(let detail):
            return .init(
                title: "Can't read this video",
                message: "This file uses a format iPhone can't decode (\(detail)). Try an MP4 or MOV, or re-save it from Photos.",
                recovery: .chooseDifferentFile
            )
        case .corruptMedia:
            return .init(
                title: "This file looks damaged",
                message: "The video couldn't be opened. It may have been interrupted while downloading or copying.",
                recovery: .chooseDifferentFile
            )
        case .noVideoTrack:
            return .init(
                title: "No video in this file",
                message: "Reframe needs a video to learn an editing style from. This file only contains audio.",
                recovery: .chooseDifferentFile
            )
        case .referenceTooLong(let seconds, let limit):
            return .init(
                title: "That's a long reference",
                message: "This video is \(Int(seconds))s. Reframe works best under \(Int(limit))s — longer references take a while to analyse and produce unwieldy templates.",
                recovery: .retry
            )
        case .sharedURLNotAFile(let host):
            // The honest path for Instagram/YouTube links. See docs/00-research.md §6.
            let source = host.map { " from \($0)" } ?? ""
            return .init(
                title: "That's a link, not a video",
                message: "Reframe can only read video files on your device\(source). Play the reel and record your screen, or save the video to Photos, then import it here.",
                recovery: .showScreenRecordingHelp
            )
        case .photosAccessDenied:
            return .init(
                title: "Photos access is off",
                message: "Reframe needs to read the photos you pick. Nothing is uploaded — everything stays on this iPhone.",
                recovery: .openSettings
            )
        case .photosAddOnlyDenied:
            return .init(
                title: "Can't save to Photos",
                message: "Reframe needs permission to add your finished video to Photos. You can also save it to Files instead.",
                recovery: .openSettings
            )
        case .fileAccessDenied(let name):
            return .init(
                title: "Can't open \(name)",
                message: "Permission to read this file has expired. Pick it again from Files.",
                recovery: .chooseDifferentFile
            )
        case .insufficientStorage(let needed, let available):
            let neededMB = needed / 1_000_000
            let availableMB = available / 1_000_000
            return .init(
                title: "Not enough space",
                message: "This export needs about \(neededMB) MB and there's \(availableMB) MB free.",
                recovery: .manageStorage
            )
        case .lowMemory:
            return .init(
                title: "Ran low on memory",
                message: "Close other apps and try again, or export at a smaller size.",
                recovery: .retryAtLowerQuality
            )
        case .thermalThrottling:
            return .init(
                title: "iPhone is warm",
                message: "Rendering is paused so your iPhone can cool down. It'll pick up on its own in a moment.",
                recovery: .waitForCooldown
            )
        case .analysisCancelled:
            return .init(title: "Cancelled", message: "", recovery: .dismiss, isSilent: true)
        case .analysisFailed(let stage, _):
            return .init(
                title: "Couldn't finish analysing",
                message: "Something went wrong while \(stage). You can still build a video from scratch with your own photos.",
                recovery: .retry
            )
        case .noScenesDetected:
            return .init(
                title: "No cuts found",
                message: "This video appears to be one continuous shot, so there's no editing structure to learn. Try a reference with several cuts.",
                recovery: .chooseDifferentFile
            )
        case .notEnoughAssets(let needed, let provided):
            return .init(
                title: "A few more photos",
                message: "This style has \(needed) slots and you've added \(provided). Reframe can repeat photos, but it'll look better with more.",
                recovery: .addMoreAssets(needed: needed - provided)
            )
        case .renderSetupFailed:
            return .init(
                title: "Couldn't start the preview",
                message: "The video engine failed to start. Restarting Reframe usually clears this.",
                recovery: .retry
            )
        case .metalUnavailable:
            return .init(
                title: "Graphics unavailable",
                message: "Reframe needs Metal, which isn't available here. It requires a real iPhone — the Simulator won't work.",
                recovery: .dismiss
            )
        case .exportFailed:
            return .init(
                title: "Export didn't finish",
                message: "The video couldn't be written. Exporting at a smaller size usually works.",
                recovery: .retryAtLowerQuality
            )
        case .exportCancelled:
            return .init(title: "Cancelled", message: "", recovery: .dismiss, isSilent: true)
        case .documentTooNew(let found, let supported):
            return .init(
                title: "Made with a newer Reframe",
                message: "This project uses format version \(found); this version understands up to \(supported). Update Reframe to open it.",
                recovery: .dismiss
            )
        case .documentCorrupt:
            return .init(
                title: "This project won't open",
                message: "The project file is damaged and can't be recovered.",
                recovery: .dismiss
            )
        case .assetMissing(let name):
            return .init(
                title: "A photo is missing",
                message: "\"\(name)\" was removed from your library. The rest of the project is fine — pick a replacement for that slot.",
                recovery: .chooseDifferentFile
            )
        }
    }

    /// Detail for the log, never for the screen.
    public var logDetail: String {
        switch self {
        case .unsupportedFormat(let d), .corruptMedia(let d), .renderSetupFailed(let d),
             .exportFailed(let d), .documentCorrupt(let d):
            return d
        case .analysisFailed(let stage, let d):
            return "\(stage): \(d)"
        default:
            return String(describing: self)
        }
    }
}
