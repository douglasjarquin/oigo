import Foundation

public struct OigoHistoryRowProjection: Equatable, Sendable {
    public let date: Date
    public let summary: String
    public let duration: TimeInterval?
    public let statusLabel: String
    public let accessibilityLabel: String
    public let hasRecoveryAction: Bool

    public init(entry: SessionHistoryEntry) {
        date = entry.session.metadata.createdAt
        summary = Self.boundedSummary(entry.firstTranscriptLine)
        duration = entry.session.metadata.duration
        let status = Self.status(for: entry.session.metadata)
        statusLabel = status.label
        hasRecoveryAction = status.hasRecoveryAction
        accessibilityLabel = [
            Self.dateText(date),
            Self.durationText(duration),
            status.label,
            status.detail
        ]
        .filter { !$0.isEmpty }
        .joined(separator: ", ")
    }

    private enum RowStatus {
        case completed
        case pasteAttempted
        case copiedOnly
        case cleanupFallback
        case insertionFailure
        case retryRequired
        case cancelledBeforeRaw
        case cancelledAfterRaw
        case interrupted
        case active
        case retrying

        var label: String {
            switch self {
            case .completed:
                "Inserted"
            case .pasteAttempted:
                "Paste attempted"
            case .copiedOnly:
                "Copied to Clipboard"
            case .cleanupFallback:
                "Cleanup fallback"
            case .insertionFailure:
                "Insertion failed"
            case .retryRequired:
                "Retry transcription"
            case .cancelledBeforeRaw:
                "Cancelled before transcript"
            case .cancelledAfterRaw:
                "Cancelled; transcript preserved"
            case .interrupted:
                "Interrupted; recording preserved"
            case .active:
                "Active"
            case .retrying:
                "Retrying"
            }
        }

        var detail: String {
            switch self {
            case .completed:
                "session completed"
            case .pasteAttempted:
                "insertion was dispatched"
            case .copiedOnly:
                "paste was not verified"
            case .cleanupFallback:
                "raw transcript retained"
            case .insertionFailure:
                "transcript preserved"
            case .retryRequired:
                "saved recording available"
            case .cancelledBeforeRaw:
                "no durable transcript"
            case .cancelledAfterRaw:
                "durable transcript available"
            case .interrupted:
                "recoverable session"
            case .active:
                "dictation in progress"
            case .retrying:
                "transcription in progress"
            }
        }

        var hasRecoveryAction: Bool {
            switch self {
            case .completed, .pasteAttempted, .cancelledBeforeRaw, .active, .retrying:
                false
            case .copiedOnly, .cleanupFallback, .insertionFailure, .retryRequired,
                 .cancelledAfterRaw, .interrupted:
                true
            }
        }
    }

    private static func status(for metadata: SessionMetadata) -> RowStatus {
        switch metadata.state {
        case .preparing, .recording, .stopping:
            return .active
        case .retrying:
            return .retrying
        case .cancelled:
            return metadata.rawTextByteCount ?? 0 > 0 ? .cancelledAfterRaw : .cancelledBeforeRaw
        case .interrupted:
            return .interrupted
        case .failed:
            return metadata.audioByteCount ?? 0 > 0 ? .retryRequired : .insertionFailure
        case .completed:
            if metadata.cleanupFallbackReason != nil {
                return .cleanupFallback
            }
            switch metadata.insertionOutcome {
            case .copied, .secureRejected:
                return .copiedOnly
            case .failed:
                return .insertionFailure
            case .pasted, nil:
                return .completed
            case .dispatched:
                return .pasteAttempted
            }
        }
    }

    private static func boundedSummary(_ value: String?) -> String {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalized.isEmpty else {
            return "No transcript summary"
        }
        let limit = 140
        guard normalized.count > limit else {
            return normalized
        }
        return String(normalized.prefix(limit - 1)) + "…"
    }

    private static func durationText(_ duration: TimeInterval?) -> String {
        guard let duration else {
            return ""
        }
        let seconds = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private static func dateText(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

public enum OigoHistoryWorkspacePolicy {
    public static let defaultWidth: Double = 1_000
    public static let defaultHeight: Double = 640
    public static let minimumWidth: Double = 880
    public static let minimumHeight: Double = 520
    public static let initialPageSize = 50
    public static let toolbarItems = ["copy", "paste-again", "playback", "more"]
}

public enum OigoApplicationCommand: String, CaseIterable, Sendable {
    case settings
    case history
    case quit
    case copy
    case selectAll
}

public enum OigoEscapeAction: Int, CaseIterable, Sendable {
    case cancelEditor
    case dismissConfirmation
    case dismissPopover
    case closeUtilityWindow
    case stopOnboardingProbe
    case cancelBoundedHandoff
}

public enum OigoUIIntegrationPolicy {
    public static let commandKeyEquivalents: [OigoApplicationCommand: String] = [
        .settings: ",",
        .quit: "q"
    ]
    public static let escapePriority: [OigoEscapeAction] = [
        .cancelEditor,
        .dismissConfirmation,
        .dismissPopover,
        .stopOnboardingProbe,
        .cancelBoundedHandoff,
        .closeUtilityWindow
    ]
    public static let restorationIdentifiers = [
        "com.oigo.settings.window",
        "com.oigo.history.window",
        "com.oigo.history.split"
    ]
    public static let forbiddenIdleBehaviors = [
        "recurring-timer",
        "global-monitor",
        "permission-polling",
        "history-polling",
        "transcript-preload",
        "model-prewarm"
    ]
}

public struct OigoVisibleFrame: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = max(0, width)
        self.height = max(0, height)
    }
}

public struct OigoRestoredWindowGeometry: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = max(0, width)
        self.height = max(0, height)
    }

    public func clamped(
        to visibleFrame: OigoVisibleFrame,
        minimumWidth: Double,
        minimumHeight: Double
    ) -> OigoRestoredWindowGeometry {
        let clampedWidth = max(minimumWidth, width)
        let clampedHeight = max(minimumHeight, height)
        let maxX = max(visibleFrame.x, visibleFrame.x + visibleFrame.width - clampedWidth)
        let maxY = max(visibleFrame.y, visibleFrame.y + visibleFrame.height - clampedHeight)
        return OigoRestoredWindowGeometry(
            x: min(max(x, visibleFrame.x), maxX),
            y: min(max(y, visibleFrame.y), maxY),
            width: clampedWidth,
            height: clampedHeight
        )
    }
}
