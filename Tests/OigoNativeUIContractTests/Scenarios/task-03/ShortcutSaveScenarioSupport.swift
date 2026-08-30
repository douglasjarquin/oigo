import AppKit
import Foundation
import OigoCore
import OigoHotKey

enum ShortcutSaveScenarioSupport {
    static func isolatedDefaults(_ suite: String) throws -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw ContractInputError(category: "defaults-suite-unavailable")
        }
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    static func keyEvent(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        characters: String
    ) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            throw ContractInputError(category: "key-event-construction-failed")
        }
        return event
    }

    static func statusName(_ status: GlobalShortcutRegistrationStatus) -> String {
        status.isActive ? "active" : "inactive"
    }
}

enum ScenarioFailure: Error, CustomStringConvertible {
    case persistence
    case registrationConflict

    var description: String {
        switch self {
        case .persistence:
            "persistence failure"
        case .registrationConflict:
            "already registered by another application"
        }
    }
}

@MainActor
final class ScenarioRegistrar: GlobalShortcutRegistrationClient {
    private(set) var status: GlobalShortcutRegistrationStatus
    private(set) var lastError: String?
    var failFor: ToggleShortcut?
    private var generation: UInt64 = 1

    init(active shortcut: ToggleShortcut) {
        status = .active(shortcut, generation: generation)
    }

    func register(
        shortcut: ToggleShortcut,
        onEvent: @escaping @MainActor (GlobalShortcutEvent) -> Void
    ) throws {
        _ = onEvent
        if failFor == shortcut {
            lastError = ScenarioFailure.registrationConflict.description
            throw ScenarioFailure.registrationConflict
        }
        generation += 1
        status = .active(shortcut, generation: generation)
        lastError = nil
    }

    func probe(shortcut: ToggleShortcut) throws {
        if failFor == shortcut {
            lastError = ScenarioFailure.registrationConflict.description
            throw ScenarioFailure.registrationConflict
        }
        lastError = nil
    }

    func unregister() {
        generation += 1
        status = .inactive("Global shortcut is not registered")
        lastError = nil
    }
}
