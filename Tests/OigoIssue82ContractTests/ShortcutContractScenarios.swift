import Foundation
import AppKit
import OigoCore
import OigoHotKey

@MainActor
extension OigoIssue82ContractTests {
    static func testShortcutContractDefaultAndMigration() throws {
        let legacy = ToggleShortcut(keyCode: 49, modifiers: 0x900)
        let canonical = ToggleShortcut(keyCode: 49, modifiers: 0x300)
        guard ToggleShortcut.default == canonical,
              canonical.displayName == "Shift-Command-Space" else {
            throw ContractFailure(message: "shortcut default did not use Shift-Command-Space")
        }

        let suiteName = "oigo-issue82-shortcut-migration-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let stored = OigoSettings(
            globalShortcut: legacy,
            localeIdentifier: "en-US",
            defaultMode: .clean,
            showVolatilePreview: false,
            audioRetention: .oneWeek,
            keepSuccessfulAudioIndefinitely: true,
            launchAtLogin: true
        )
        defaults.set(try JSONEncoder().encode(stored), forKey: "oigo.settings.v1")
        let loaded = OigoSettingsStore(defaults: defaults).load()
        guard loaded.globalShortcut == canonical,
              loaded.localeIdentifier == stored.localeIdentifier,
              loaded.defaultMode == stored.defaultMode,
              loaded.showVolatilePreview == stored.showVolatilePreview,
              loaded.audioRetention == stored.audioRetention,
              loaded.keepSuccessfulAudioIndefinitely == stored.keepSuccessfulAudioIndefinitely,
              loaded.launchAtLogin == stored.launchAtLogin else {
            throw ContractFailure(message: "legacy v1 shortcut did not migrate without changing other settings")
        }

        let persisted = try JSONDecoder().decode(
            OigoSettings.self,
            from: defaults.data(forKey: "oigo.settings.v1")!
        )
        guard persisted.globalShortcut == canonical,
              OigoSettingsStore(defaults: defaults).load() == loaded else {
            throw ContractFailure(message: "shortcut migration was not persisted idempotently")
        }

        defaults.removeObject(forKey: "oigo.settings.v1")
        defaults.set(try JSONEncoder().encode(legacy), forKey: "globalToggleShortcut")
        guard OigoSettingsStore(defaults: defaults).load().globalShortcut == canonical else {
            throw ContractFailure(message: "legacy globalToggleShortcut key did not migrate")
        }

        defaults.removeObject(forKey: "oigo.settings.v1")
        defaults.set(
            try JSONEncoder().encode(OigoSettings(globalShortcut: ToggleShortcut(keyCode: 0, modifiers: 0x100))),
            forKey: "oigo.settings.v1"
        )
        guard OigoSettingsStore(defaults: defaults).load().globalShortcut == ToggleShortcut(keyCode: 0, modifiers: 0x100) else {
            throw ContractFailure(message: "custom key-code-zero shortcut was changed during migration")
        }
    }

    static func testShortcutKeyCodeZero() throws {
        let keyCodeZero = ToggleShortcut(keyCode: 0, modifiers: 0x100)
        guard OigoShortcutValidator.validate(keyCodeZero, occupied: []).isAvailable,
              keyCodeZero.displayName == "Command-A" else {
            throw ContractFailure(message: "key code zero with Command was rejected")
        }
        guard !OigoShortcutValidator.validate(
            ToggleShortcut(keyCode: 0, modifiers: 0),
            occupied: []
        ).isAvailable else {
            throw ContractFailure(message: "modifier-free shortcut was accepted")
        }
    }

    static func testRecorderKeyCodeZero() throws {
        let original = ToggleShortcut.default
        let recorder = ShortcutRecorderControl(shortcut: original)
        var candidates: [ToggleShortcut] = []
        recorder.onCandidateChange = { candidates.append($0) }

        recorder.keyDown(with: try keyEvent(
            keyCode: 0,
            modifiers: [.command],
            characters: "a",
            isARepeat: false
        ))
        guard candidates.isEmpty, recorder.shortcut == original else {
            throw ContractFailure(message: "recorder accepted a key while it was not active")
        }

        recorder.beginRecording()
        recorder.keyDown(with: try keyEvent(
            keyCode: 0,
            modifiers: [.command],
            characters: "a",
            isARepeat: true
        ))
        guard candidates.isEmpty, recorder.isRecording else {
            throw ContractFailure(message: "recorder accepted a repeated key event")
        }

        recorder.keyDown(with: try keyEvent(
            keyCode: 0,
            modifiers: [.command],
            characters: "a",
            isARepeat: false
        ))
        guard candidates == [ToggleShortcut(keyCode: 0, modifiers: ToggleShortcutModifiers.command)],
              recorder.shortcut == candidates[0],
              recorder.displayValue == "⌘A",
              !recorder.isRecording else {
            throw ContractFailure(message: "recorder did not accept and display key code zero")
        }
    }

    static func testRecorderRejection() throws {
        let original = ToggleShortcut.default
        let recorder = ShortcutRecorderControl(shortcut: original)
        var errors: [String] = []
        recorder.onValidationError = { errors.append($0) }

        recorder.beginRecording()
        recorder.keyDown(with: try keyEvent(
            keyCode: 0,
            modifiers: [],
            characters: "a",
            isARepeat: false
        ))
        guard recorder.shortcut == original,
              recorder.isRecording,
              errors.last?.contains("modifier") == true else {
            throw ContractFailure(message: "recorder did not reject a modifier-free shortcut")
        }

        recorder.beginRecording()
        recorder.keyDown(with: try keyEvent(
            keyCode: 12,
            modifiers: [.capsLock],
            characters: "q",
            isARepeat: false
        ))
        guard recorder.shortcut == original,
              recorder.isRecording,
              errors.last?.contains("supported") == true else {
            throw ContractFailure(message: "recorder did not reject an unsupported modifier")
        }

        guard ShortcutFormatter.displayName(
            for: ToggleShortcut(keyCode: 36, modifiers: ToggleShortcutModifiers.command)
        ) == "⌘Return" else {
            throw ContractFailure(message: "special key was not formatted readably")
        }

        let expectedNumericKeyNames: [(UInt32, String)] = [
            (22, "6"),
            (23, "5"),
            (24, "="),
            (25, "9"),
            (26, "7"),
            (27, "-"),
            (28, "8")
        ]
        for (keyCode, expectedName) in expectedNumericKeyNames {
            guard OigoShortcutPresentation.keyName(for: keyCode) == expectedName else {
                throw ContractFailure(message: "key code \(keyCode) was not formatted as \(expectedName)")
            }
        }

        recorder.keyDown(with: try keyEvent(
            keyCode: 12,
            modifiers: [.command],
            characters: "q",
            isARepeat: false
        ))
        let accepted = recorder.shortcut
        guard accepted == ToggleShortcut(keyCode: 12, modifiers: ToggleShortcutModifiers.command) else {
            throw ContractFailure(message: "recorder did not retain the accepted candidate")
        }

        let commandEscape = ToggleShortcut(keyCode: 53, modifiers: ToggleShortcutModifiers.command)
        recorder.beginRecording()
        recorder.keyDown(with: try keyEvent(
            keyCode: 53,
            modifiers: [.command],
            characters: "\u{1b}",
            isARepeat: false
        ))
        guard recorder.shortcut == commandEscape,
              !recorder.isRecording else {
            throw ContractFailure(message: "recorder treated modified Escape as cancellation instead of a valid shortcut")
        }

        recorder.beginRecording()
        recorder.keyDown(with: try keyEvent(
            keyCode: 13,
            modifiers: [.command],
            characters: "w",
            isARepeat: false
        ))
        recorder.beginRecording()
        recorder.keyDown(with: try keyEvent(
            keyCode: 53,
            modifiers: [],
            characters: "\u{1b}",
            isARepeat: false
        ))
        guard recorder.shortcut == ToggleShortcut(keyCode: 13, modifiers: ToggleShortcutModifiers.command) else {
            throw ContractFailure(message: "Escape did not restore the original recorder candidate")
        }
    }

    static func keyEvent(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        characters: String,
        isARepeat: Bool
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
            isARepeat: isARepeat,
            keyCode: keyCode
        ) else {
            throw ContractFailure(message: "could not construct deterministic key event")
        }
        return event
    }


}
