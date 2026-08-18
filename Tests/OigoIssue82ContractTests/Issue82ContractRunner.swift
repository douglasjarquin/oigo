import Darwin
import Foundation
import OigoCore
import OigoHotKey

private struct ContractFailure: Error, CustomStringConvertible {
    let message: String

    var description: String {
        message
    }
}

@main
@available(macOS 13.0, *)
@MainActor
private struct OigoIssue82ContractTests {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let filter: String? = if let index = arguments.firstIndex(of: "--filter"),
                                  arguments.indices.contains(index + 1) {
            arguments[index + 1]
        } else {
            nil
        }
        let normalizedFilter = filter?.replacingOccurrences(of: "-", with: " ")
        let scenarios: [(String, () throws -> Void)] = [
            ("harness smoke", testHarnessSmoke),
            ("registrar atomic replacement", testRegistrarAtomicReplacement),
            ("registrar failure and generation", testRegistrarFailureAndGeneration),
            ("intent rapid tap", testIntentRapidTap),
            ("intent duplicates and processing", testIntentDuplicatesAndProcessing),
            ("shortcut contract default and migration", testShortcutContractDefaultAndMigration),
            ("shortcut keycode zero", testShortcutKeyCodeZero)
        ]
        let selected = scenarios.filter { normalizedFilter == nil || $0.0.contains(normalizedFilter ?? "") }
        guard !selected.isEmpty else {
            print("FAIL: no issue #82 contract scenarios matched filter")
            exit(1)
        }

        var failures = 0
        for (name, test) in selected {
            do {
                try test()
                print("GREEN: " + name)
            } catch {
                failures += 1
                print("FAIL: " + name + ": " + String(describing: error))
            }
        }
        guard failures == 0 else {
            print("FAILURES=" + String(failures))
            exit(1)
        }
        print("GREEN: all issue #82 contract scenarios")
    }

    private static func testHarnessSmoke() {
        _ = ToggleShortcut.default
        _ = CarbonGlobalShortcutRegistrar.self
    }

    private static func testRegistrarAtomicReplacement() throws {
        let backend = RecordingRegistrationBackend()
        let registrar = CarbonGlobalShortcutRegistrar(backend: backend)
        let first = ToggleShortcut(keyCode: 49, modifiers: 0x300)
        let second = ToggleShortcut(keyCode: 0, modifiers: 0x100)
        var events: [GlobalShortcutEvent] = []

        try registrar.register(shortcut: first, onEvent: { event in
            events.append(event)
        })
        let firstGeneration = try activeGeneration(of: registrar)
        backend.emit(.pressed, generation: firstGeneration)
        backend.emit(.released, generation: firstGeneration)
        guard events.map(\.edge) == [.pressed, .released] else {
            throw ContractFailure(message: "registrar did not deliver both press and release edges")
        }

        let callsBeforeProbe = backend.calls
        try registrar.probe(shortcut: second)
        guard backend.calls == callsBeforeProbe + ["register:0/256", "unregister:0/256"],
              try activeShortcut(of: registrar) == first else {
            throw ContractFailure(message: "successful validation probe displaced the working registration")
        }

        try registrar.register(shortcut: second, onEvent: { event in
            events.append(event)
        })
        guard backend.calls.suffix(2) == ["register:0/256", "unregister:49/768"],
              try activeShortcut(of: registrar) == second else {
            throw ContractFailure(message: "replacement did not register the candidate before removing the prior shortcut")
        }
    }

    private static func testRegistrarFailureAndGeneration() throws {
        let backend = RecordingRegistrationBackend()
        let registrar = CarbonGlobalShortcutRegistrar(backend: backend)
        let first = ToggleShortcut(keyCode: 49, modifiers: 0x300)
        let second = ToggleShortcut(keyCode: 12, modifiers: 0x100)
        var events: [GlobalShortcutEvent] = []
        try registrar.register(shortcut: first, onEvent: { event in
            events.append(event)
        })
        let firstGeneration = try activeGeneration(of: registrar)
        backend.failFor = second

        do {
            try registrar.register(shortcut: second, onEvent: { event in
                events.append(event)
            })
            throw ContractFailure(message: "failed candidate registration was accepted")
        } catch let error as TestRegistrationError {
            guard error.description.contains("12/256") else {
                throw ContractFailure(message: "candidate failure was not actionable")
            }
        }

        guard try activeShortcut(of: registrar) == first,
              backend.calls.suffix(1) == ["register:12/256"],
              registrar.lastError?.contains("12/256") == true else {
            throw ContractFailure(message: "failed replacement removed or hid the prior working registration")
        }

        backend.failFor = nil
        try registrar.register(shortcut: second, onEvent: { event in
            events.append(event)
        })
        backend.emit(.pressed, generation: firstGeneration)
        guard events.isEmpty else {
            throw ContractFailure(message: "stale callback from a replaced generation was delivered")
        }
    }

    private static func testIntentRapidTap() throws {
        var controller = GlobalShortcutIntentController()
        guard controller.receive(.pressed, state: .idle) == .start,
              controller.receive(.pressed, state: .preparing, isRepeat: true) == .ignoredRepeat,
              controller.receive(.released, state: .preparing) == .releaseLatched,
              controller.observe(.recording) == .stop,
              controller.receive(.released, state: .finalizing) == .ignoredProcessing(.finalizing) else {
            throw ContractFailure(message: "rapid press/release did not produce one latched stop without cancellation")
        }
    }

    private static func testIntentDuplicatesAndProcessing() throws {
        var controller = GlobalShortcutIntentController()
        guard controller.receive(.pressed, state: .idle) == .start,
              controller.receive(.pressed, state: .preparing) == .ignoredDuplicatePress,
              controller.receive(.released, state: .preparing) == .releaseLatched,
              controller.receive(.released, state: .preparing) == .ignoredDuplicateRelease,
              controller.observe(.recording) == .stop else {
            throw ContractFailure(message: "duplicate shortcut edges changed ownership or stop count")
        }

        var mouseOwnedRecording = GlobalShortcutIntentController()
        guard mouseOwnedRecording.receive(.pressed, state: .recording) == .ignoredRecordingNotOwned,
              mouseOwnedRecording.receive(.released, state: .recording) == .ignoredRecordingNotOwned,
              controller.receive(.pressed, state: .cleaning) == .ignoredProcessing(.cleaning),
              controller.receive(.released, state: .inserting) == .ignoredProcessing(.inserting) else {
            throw ContractFailure(message: "processing or mouse-owned recording input was not ignored explicitly")
        }
    }

    private static func testShortcutContractDefaultAndMigration() throws {
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

    private static func testShortcutKeyCodeZero() throws {
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

    private static func activeGeneration(of registrar: CarbonGlobalShortcutRegistrar) throws -> UInt64 {
        guard case .active(_, let generation) = registrar.status else {
            throw ContractFailure(message: "registrar was not active")
        }
        return generation
    }

    private static func activeShortcut(of registrar: CarbonGlobalShortcutRegistrar) throws -> ToggleShortcut {
        guard case .active(let shortcut, _) = registrar.status else {
            throw ContractFailure(message: "registrar was not active")
        }
        return shortcut
    }
}
