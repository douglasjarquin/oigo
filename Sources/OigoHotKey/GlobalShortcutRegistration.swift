import OigoCore

public enum GlobalShortcutEdge: Equatable, Sendable {
    case pressed
    case released
}

public struct FunctionKeyShortcutState: Sendable {
    private var isDown: Bool
    private var deliveredPress = false

    public init(isDown: Bool) {
        self.isDown = isDown
    }

    public mutating func update(isDown: Bool) -> GlobalShortcutEdge? {
        guard self.isDown != isDown else { return nil }
        self.isDown = isDown
        if isDown {
            deliveredPress = true
            return .pressed
        }
        guard deliveredPress else { return nil }
        deliveredPress = false
        return .released
    }

    public mutating func reset(isDown: Bool) -> GlobalShortcutEdge? {
        let edge: GlobalShortcutEdge? = deliveredPress ? .released : nil
        self.isDown = isDown
        deliveredPress = false
        return edge
    }
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

    func unregister(_ handle: any GlobalShortcutRegistrationHandle) throws
}

@MainActor
public final class GlobalShortcutProductionBridge {
    private let operations: GlobalShortcutOperationBridge

    public init(operations: GlobalShortcutOperationBridge) {
        self.operations = operations
    }

    @discardableResult
    public func receive(_ event: GlobalShortcutEvent) -> GlobalShortcutIntentResult {
        let edge: GlobalShortcutIntentEdge = switch event.edge {
        case .pressed:
            .pressed
        case .released:
            .released
        }
        return operations.receive(edge)
    }

    @discardableResult
    public func observeState() -> GlobalShortcutIntentResult? {
        operations.observeState()
    }

    @discardableResult
    public func reset() -> GlobalShortcutIntentResult {
        operations.reset()
    }
}
