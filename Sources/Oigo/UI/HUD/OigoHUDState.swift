import Foundation

public enum OigoHUDTone: String, CaseIterable, Equatable, Sendable {
    case neutral
    case informational
    case success
    case warning
    case critical
    case recording
}

public enum OigoHUDIconRole: String, CaseIterable, Equatable, Sendable {
    case progress
    case information
    case confirmation
    case attention
    case failure
    case recording
    case destination
}

public enum OigoHUDActionability: String, CaseIterable, Equatable, Sendable {
    case none
    case retryTranscription = "retry-transcription"
    case copyAndPasteAgain = "copy-and-paste-again"
    case pasteAgain = "paste-again"
    case openHistory = "open-history"
    case chooseDestination = "choose-destination"
}

public enum OigoHUDDismissalKind: String, CaseIterable, Equatable, Sendable {
    case persistent
    case timed
    case hidden
}

public struct OigoHUDShellSize: Equatable, Sendable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public static let compact = Self(width: 252, height: 38)
    public static let recording = Self(width: 252, height: 54)
    public static let expanded = Self(width: 252, height: 73)
    public static let terminal = Self(width: 252, height: 58)
}

public struct OigoHUDDismissalPolicy: Equatable, Sendable {
    public let kind: OigoHUDDismissalKind
    public let seconds: TimeInterval?

    public init(kind: OigoHUDDismissalKind, seconds: TimeInterval? = nil) {
        self.kind = kind
        self.seconds = seconds
    }

    public static let persistent = Self(kind: .persistent)
    public static let hidden = Self(kind: .hidden)

    public static func timed(after seconds: TimeInterval) -> Self {
        Self(kind: .timed, seconds: seconds)
    }
}

public struct OigoHUDContent: Equatable, Sendable {
    public let size: OigoHUDShellSize
    public let title: String
    public let detail: String
    public let tone: OigoHUDTone
    public let iconRole: OigoHUDIconRole
    public let actionability: OigoHUDActionability
    public let dismissal: OigoHUDDismissalPolicy
    public let isTerminal: Bool
    public let showsRecordingElapsed: Bool
    public let allowsPreview: Bool

    public init(
        size: OigoHUDShellSize = .compact,
        title: String,
        detail: String,
        tone: OigoHUDTone,
        iconRole: OigoHUDIconRole,
        actionability: OigoHUDActionability,
        dismissal: OigoHUDDismissalPolicy,
        isTerminal: Bool,
        showsRecordingElapsed: Bool,
        allowsPreview: Bool
    ) {
        self.size = size
        self.title = title
        self.detail = detail
        self.tone = tone
        self.iconRole = iconRole
        self.actionability = actionability
        self.dismissal = dismissal
        self.isTerminal = isTerminal
        self.showsRecordingElapsed = showsRecordingElapsed
        self.allowsPreview = allowsPreview
    }
}

public enum OigoHUDState: String, CaseIterable, Equatable, Sendable {
    case preparing
    case recording
    case degradedRecording = "degraded-recording"
    case finalizing
    case cleaning
    case pasting
    case pasteAttempted = "paste-attempted"
    case copied
    case copyOnly = "copy-only"
    case savedRetry = "saved-retry"
    case preservedFailure = "preserved-failure"
    case cleanupFallback = "cleanup-fallback"
    case cancelledBeforeRaw = "cancelled-before-raw"
    case cancelledAfterRaw = "cancelled-after-raw"
    case interrupted
    case pasteAgainDestination = "paste-again-destination"
    case terminal
    case shutdown
}
