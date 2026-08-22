import AppKit

public enum MacUIStatusTone: String, CaseIterable, Sendable {
    case neutral
    case informational
    case success
    case warning
    case critical
    case recording

    @MainActor
    var color: NSColor {
        switch self {
        case .neutral:
            .secondaryLabelColor
        case .informational:
            .controlAccentColor
        case .success:
            .systemGreen
        case .warning:
            .systemOrange
        case .critical, .recording:
            .systemRed
        }
    }
}

public enum MacUIStatusIconRole: String, CaseIterable, Sendable {
    case information
    case confirmation
    case attention
    case failure
    case recording
    case permission
    case storage

    var symbolName: String {
        switch self {
        case .information:
            "info.circle.fill"
        case .confirmation:
            "checkmark.circle.fill"
        case .attention:
            "exclamationmark.triangle.fill"
        case .failure:
            "xmark.octagon.fill"
        case .recording:
            "record.circle.fill"
        case .permission:
            "hand.raised.fill"
        case .storage:
            "internaldrive.fill"
        }
    }
}

public struct MacUIStatusContent: Sendable {
    public let tone: MacUIStatusTone
    public let iconRole: MacUIStatusIconRole
    public let label: String

    public init(tone: MacUIStatusTone, iconRole: MacUIStatusIconRole, label: String) {
        self.tone = tone
        self.iconRole = iconRole
        self.label = label
    }
}
