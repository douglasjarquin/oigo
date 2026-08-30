import Foundation
import OigoCore
import OigoHotKey

@MainActor
extension OigoIssue82ContractTests {
    static func testConfigurationAtomicSave() throws {
        let oldShortcut = ToggleShortcut.default
        let newShortcut = ToggleShortcut(keyCode: 0, modifiers: ToggleShortcutModifiers.command)
        let registrar = RecordingConfigurationRegistrationClient(active: oldShortcut)
        let transaction = ShortcutConfigurationTransaction(
            committedShortcut: oldShortcut,
            registrar: registrar,
            onEvent: { _ in }
        )
        transaction.setCandidate(newShortcut)

        guard transaction.validate(newShortcut).isAvailable,
              registrar.status == .active(oldShortcut, generation: 1) else {
            throw ContractFailure(message: "validation-only changed or dropped the working registration")
        }

        var persisted = oldShortcut
        guard transaction.save(
            newShortcut,
            persist: { persisted = $0 },
            restore: { persisted = oldShortcut }
        ).isAvailable,
              persisted == newShortcut,
              transaction.committedShortcut == newShortcut,
              transaction.candidateShortcut == newShortcut,
              registrar.status == .active(newShortcut, generation: 2),
              registrar.calls == [
                  "probe:0/256",
                  "register:0/256",
                  "unregister:49/768"
              ] else {
            throw ContractFailure(message: "shortcut save did not atomically commit registration and persistence")
        }

        transaction.setCandidate(oldShortcut)
        transaction.cancel()
        guard transaction.candidateShortcut == newShortcut,
              registrar.status == .active(newShortcut, generation: 2),
              persisted == newShortcut else {
            throw ContractFailure(message: "cancel changed the committed shortcut")
        }
    }

    static func testConfigurationFailureRestoration() throws {
        let oldShortcut = ToggleShortcut.default
        let newShortcut = ToggleShortcut(keyCode: 12, modifiers: ToggleShortcutModifiers.command)
        let registrar = RecordingConfigurationRegistrationClient(active: oldShortcut)
        registrar.failFor = newShortcut
        let transaction = ShortcutConfigurationTransaction(
            committedShortcut: oldShortcut,
            registrar: registrar,
            onEvent: { _ in }
        )
        var persisted = oldShortcut
        guard transaction.save(
            newShortcut,
            persist: { persisted = $0 },
            restore: { persisted = oldShortcut }
        ).isConflict,
              registrar.status == .active(oldShortcut, generation: 1),
              persisted == oldShortcut,
              registrar.calls == ["register:12/256"] else {
            throw ContractFailure(message: "failed replacement did not preserve the working shortcut")
        }

        registrar.failFor = nil
        let persistenceFailure = transaction.save(
            newShortcut,
            persist: { _ in
                throw ContractFailure(message: "simulated persistence failure")
            },
            restore: { persisted = oldShortcut }
        )
        guard persistenceFailure.isConflict,
              registrar.status == .active(oldShortcut, generation: 3),
              transaction.committedShortcut == oldShortcut,
              persisted == oldShortcut,
              registrar.calls.suffix(2) == [
                  "register:49/768",
                  "unregister:12/256"
              ] else {
            throw ContractFailure(message: "persistence failure did not restore settings and registration")
        }

        transaction.setCandidate(newShortcut)
        transaction.cancel()
        guard transaction.candidateShortcut == oldShortcut else {
            throw ContractFailure(message: "close or cancel did not discard only the uncommitted candidate")
        }
    }

    static func testSettingsStorePersistenceFailureRestoration() throws {
        let suiteName = "oigo-issue82-settings-failure-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let oldSettings = OigoSettings.default
        let newShortcut = ToggleShortcut(keyCode: 0, modifiers: ToggleShortcutModifiers.command)
        let workingStore = OigoSettingsStore(defaults: defaults)
        try workingStore.save(oldSettings)

        let failingStore = OigoSettingsStore(defaults: defaults, writeData: { data in
            defaults.set(data, forKey: "oigo.settings.v1")
            throw SettingsWriteFailure.diskFull
        })
        let registrar = RecordingConfigurationRegistrationClient(active: oldSettings.globalShortcut)
        let transaction = ShortcutConfigurationTransaction(
            committedShortcut: oldSettings.globalShortcut,
            registrar: registrar,
            onEvent: { _ in }
        )

        let result = transaction.save(
            newShortcut,
            persist: { shortcut in
                try failingStore.save(oldSettings.with(globalShortcut: shortcut))
            },
            restore: {
                try workingStore.save(oldSettings)
            }
        )
        let persistedAfterFailure = OigoSettingsStore(defaults: defaults).load()
        guard result.isConflict,
              transaction.lastError?.contains("disk full") == true,
              registrar.status == .active(oldSettings.globalShortcut, generation: 3),
              transaction.committedShortcut == oldSettings.globalShortcut,
              persistedAfterFailure == oldSettings else {
            throw ContractFailure(message: "production settings persistence failure did not restore live and durable shortcut state")
        }
    }

    static func testCompoundRollbackFailureFailsClosed() throws {
        let oldShortcut = ToggleShortcut.default
        let newShortcut = ToggleShortcut(keyCode: 0, modifiers: ToggleShortcutModifiers.command)
        let registrar = RecordingConfigurationRegistrationClient(active: oldShortcut)
        registrar.failFor = oldShortcut
        let transaction = ShortcutConfigurationTransaction(
            committedShortcut: oldShortcut,
            registrar: registrar,
            onEvent: { _ in }
        )

        let result = transaction.save(
            newShortcut,
            persist: { _ in
                throw SettingsWriteFailure.diskFull
            },
            restore: {
                throw SettingsWriteFailure.diskFull
            }
        )
        guard result.isConflict,
              registrar.status == .inactive("Global shortcut is not registered"),
              transaction.committedShortcut == oldShortcut,
              transaction.lastError?.contains("Shortcut registration was disabled") == true,
              registrar.calls == [
                  "register:0/256",
                  "unregister:49/768",
                  "unregister:0/256"
              ] else {
            throw ContractFailure(message: "compound rollback failure did not fail closed with actionable state")
        }
    }

    static func testAppDelegateShortcutReadiness() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appDelegate = try String(
            contentsOf: repository.appendingPathComponent("Sources/Oigo/OigoAppDelegate.swift"),
            encoding: .utf8
        )
        guard appDelegate.components(separatedBy: "private let shortcutRegistrar").count == 2,
              appDelegate.components(separatedBy: "ShortcutConfigurationTransaction(").count == 2,
              appDelegate.contains("try shortcutConfiguration.setRegistrationReady(ready)"),
              appDelegate.contains("guard shortcutConfiguration.isOperationReady else"),
              !appDelegate.contains("shortcutRegistered") else {
            throw ContractFailure(message: "AppDelegate retained duplicate shortcut ownership or stale callback readiness")
        }

        let defaultShortcut = ToggleShortcut.default
        let customShortcut = ToggleShortcut(keyCode: 0, modifiers: ToggleShortcutModifiers.command)
        let registrar = RecordingConfigurationRegistrationClient()
        let transaction = ShortcutConfigurationTransaction(
            committedShortcut: defaultShortcut,
            registrar: registrar,
            registrationReady: false,
            onEvent: { _ in }
        )
        var persisted = defaultShortcut

        guard transaction.save(
            customShortcut,
            persist: { persisted = $0 },
            restore: { persisted = defaultShortcut }
        ).isAvailable,
              persisted == customShortcut,
              transaction.committedShortcut == customShortcut,
              registrar.calls.isEmpty,
              !transaction.registrationStatus.isActive,
              !transaction.isOperationReady else {
            throw ContractFailure(message: "AppDelegate shortcut registered or enabled operation before readiness")
        }

        try transaction.setRegistrationReady(true)
        try transaction.setRegistrationReady(true)
        guard registrar.calls == ["register:0/256"],
              transaction.registrationStatus.isActive,
              transaction.isOperationReady else {
            throw ContractFailure(message: "AppDelegate shortcut did not register exactly once after readiness")
        }

        try transaction.setRegistrationReady(false)
        guard registrar.calls == ["register:0/256", "unregister:0/256"],
              !transaction.registrationStatus.isActive,
              !transaction.isOperationReady else {
            throw ContractFailure(message: "AppDelegate shortcut teardown retained stale registration readiness")
        }
    }

    static func testAppDelegateShortcutFailure() throws {
        let defaultShortcut = ToggleShortcut.default
        let customShortcut = ToggleShortcut(keyCode: 0, modifiers: ToggleShortcutModifiers.command)
        let launchRegistrar = RecordingConfigurationRegistrationClient()
        launchRegistrar.failFor = defaultShortcut
        let launch = ShortcutConfigurationTransaction(
            committedShortcut: defaultShortcut,
            registrar: launchRegistrar,
            registrationReady: false,
            onEvent: { _ in }
        )

        do {
            try launch.setRegistrationReady(true)
            throw ContractFailure(message: "AppDelegate shortcut launch failure unexpectedly succeeded")
        } catch is ContractFailure {
            throw ContractFailure(message: "AppDelegate shortcut launch failure unexpectedly succeeded")
        } catch {
            guard !launch.registrationStatus.isActive,
                  !launch.isOperationReady,
                  launch.lastError != nil else {
                throw ContractFailure(message: "AppDelegate shortcut launch failure published stale success")
            }
        }

        let replacementRegistrar = RecordingConfigurationRegistrationClient(active: defaultShortcut)
        replacementRegistrar.failFor = customShortcut
        let replacement = ShortcutConfigurationTransaction(
            committedShortcut: defaultShortcut,
            registrar: replacementRegistrar,
            onEvent: { _ in }
        )
        var persisted = defaultShortcut
        guard replacement.validate(customShortcut).isConflict,
              replacement.save(
                customShortcut,
                persist: { persisted = $0 },
                restore: { persisted = defaultShortcut }
              ).isConflict,
              persisted == defaultShortcut,
              replacement.committedShortcut == defaultShortcut,
              replacement.registrationStatus.isActive,
              replacement.isOperationReady else {
            throw ContractFailure(message: "AppDelegate shortcut conflict replaced or disabled the current registration")
        }
    }


}
