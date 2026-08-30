import Foundation
import OigoCore
import OigoHotKey

struct ContractFailure: Error, CustomStringConvertible {
    let message: String

    var description: String {
        message
    }
}
enum SettingsWriteFailure: Error, CustomStringConvertible {
    case diskFull

    var description: String {
        "disk full"
    }
}


@MainActor
final class RecordingConfigurationRegistrationClient: GlobalShortcutRegistrationClient {
    private(set) var status: GlobalShortcutRegistrationStatus
    private(set) var lastError: String?
    private(set) var calls: [String] = []
    private var generation: UInt64
    var failFor: ToggleShortcut?

    init(active shortcut: ToggleShortcut? = nil) {
        if let shortcut {
            generation = 1
            status = .active(shortcut, generation: generation)
        } else {
            generation = 0
            status = .inactive("Global shortcut is not registered")
        }
    }

    func register(
        shortcut: ToggleShortcut,
        onEvent: @escaping @MainActor (GlobalShortcutEvent) -> Void
    ) throws {
        _ = onEvent
        calls.append("register:\(shortcut.keyCode)/\(shortcut.modifiers)")
        if failFor == shortcut {
            lastError = TestRegistrationError(shortcut: shortcut).description
            throw TestRegistrationError(shortcut: shortcut)
        }
        generation += 1
        if case .active(let previous, _) = status {
            calls.append("unregister:\(previous.keyCode)/\(previous.modifiers)")
        }
        status = .active(shortcut, generation: generation)
        lastError = nil
    }

    func probe(shortcut: ToggleShortcut) throws {
        calls.append("probe:\(shortcut.keyCode)/\(shortcut.modifiers)")
        if failFor == shortcut {
            lastError = TestRegistrationError(shortcut: shortcut).description
            throw TestRegistrationError(shortcut: shortcut)
        }
        lastError = nil
    }

    func unregister() throws {
        if case .active(let shortcut, _) = status {
            calls.append("unregister:\(shortcut.keyCode)/\(shortcut.modifiers)")
        }
        generation += 1
        status = .inactive("Global shortcut is not registered")
        lastError = nil
    }
}
