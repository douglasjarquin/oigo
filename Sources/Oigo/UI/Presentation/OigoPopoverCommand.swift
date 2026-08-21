import OigoCore

public enum OigoPopoverFocusDirection: Equatable, Sendable {
    case next
    case previous
}

public enum OigoPopoverInvocationKey: Equatable, Sendable {
    case returnKey
    case space
}

public enum OigoPopoverCommandIntent: Equatable, Sendable {
    case presentation(OigoPresentationAction)
    case selectInput(OigoInputSelection, channel: Int)
    case dismiss
    case moveFocus(OigoPopoverFocusDirection)
    case invokeFocused(OigoPopoverInvocationKey)
}

public struct OigoPopoverCommand: Equatable, Sendable {
    public let generation: UInt64
    public let intent: OigoPopoverCommandIntent

    public init(generation: UInt64, intent: OigoPopoverCommandIntent) {
        self.generation = generation
        self.intent = intent
    }
}

public struct OigoPopoverInputOption: Equatable, Sendable {
    public let title: String
    public let selection: OigoInputSelection
    public let channel: Int
    public let isSelected: Bool
    public let isEnabled: Bool

    public init(
        title: String,
        selection: OigoInputSelection,
        channel: Int,
        isSelected: Bool,
        isEnabled: Bool
    ) {
        self.title = title
        self.selection = selection
        self.channel = channel
        self.isSelected = isSelected
        self.isEnabled = isEnabled
    }
}
