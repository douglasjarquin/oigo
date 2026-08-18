import OigoCore

public enum GlobalShortcutEdge: Equatable, Sendable {
    case pressed
    case released
}

public struct GlobalShortcutEvent: Equatable, Sendable {
    public let edge: GlobalShortcutEdge
    public let generation: UInt64

    public init(edge: GlobalShortcutEdge, generation: UInt64) {
        self.edge = edge
        self.generation = generation
    }
}

public enum GlobalShortcutRegistrationStatus: Equatable, Sendable {
    case active(ToggleShortcut, generation: UInt64)
    case inactive(String)

    public var isActive: Bool {
        if case .active = self {
            return true
        }
        return false
    }

    public var message: String {
        switch self {
        case .active:
            return "Global shortcut is active"
        case .inactive(let reason):
            return reason
        }
    }
}

public protocol GlobalShortcutRegistrationHandle: AnyObject {}

@MainActor
public protocol GlobalShortcutRegistrationBackend: AnyObject {
    func register(
        shortcut: ToggleShortcut,
        generation: UInt64,
        receive: @escaping @MainActor (GlobalShortcutEvent) -> Void
    ) throws -> any GlobalShortcutRegistrationHandle

    func unregister(_ handle: any GlobalShortcutRegistrationHandle)
}
