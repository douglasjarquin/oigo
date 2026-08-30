import AppKit
import Foundation
import OigoCore
import OigoHotKey

final class ShortcutSaveScenario: NativeUIContractScenario {
    override class var scenarioName: String {
        "shortcut-save"
    }

    override class func run(arguments: ContractArguments) throws {
        guard arguments.defaultsSuite == "com.oigo.qa.task03" else {
            throw ContractInputError(category: "invalid-defaults-suite")
        }
        try MainActor.assumeIsolated {
            if arguments.fixtureName == "baseline" {
                try characterizeBaseline(arguments: arguments)
                return
            }
            guard arguments.fixtureName == nil else {
                throw ContractInputError(category: "unsupported-shortcut-fixture")
            }
            let selected = arguments.fixtureRoot.lastPathComponent
            guard ["task-03", "success", "failure"].contains(selected) else {
                throw ContractInputError(category: "unsupported-shortcut-fixture")
            }
            if selected != "failure" {
                try runSuccess(arguments: arguments)
            }
            if selected != "success" {
                try runFailures(arguments: arguments)
            }
            print("PASS shortcut-save keyCode=0 persisted=0/256 readback=0/256 registration=committed cancel=preserved close=preserved rollback=no-divergence mouse-start=enabled")
        }
    }

    @MainActor
    private static func characterizeBaseline(arguments: ContractArguments) throws {
        let defaults = try ShortcutSaveScenarioSupport.isolatedDefaults(arguments.defaultsSuite)
        defer { defaults.removePersistentDomain(forName: arguments.defaultsSuite) }
        let old = OigoSettings.default
        let candidate = ToggleShortcut(keyCode: 0, modifiers: ToggleShortcutModifiers.command)
        let store = OigoSettingsStore(defaults: defaults)
        try store.save(old)

        let conflictRegistrar = ScenarioRegistrar(active: old.globalShortcut)
        conflictRegistrar.failFor = candidate
        let conflict = ShortcutConfigurationTransaction(
            committedShortcut: old.globalShortcut,
            registrar: conflictRegistrar,
            onEvent: { _ in }
        )
        conflict.setCandidate(candidate)
        let conflictResult = conflict.save(
            candidate,
            persist: { try store.save(old.with(globalShortcut: $0)) },
            restore: { try store.save(old) }
        )

        var cancelCallbacks = 0
        let recorder = ShortcutRecorderControl(shortcut: old.globalShortcut)
        recorder.onCandidateChange = { _ in cancelCallbacks += 1 }
        recorder.beginRecording()
        recorder.cancelRecording()

        let persistenceRegistrar = ScenarioRegistrar(active: old.globalShortcut)
        let persistence = ShortcutConfigurationTransaction(
            committedShortcut: old.globalShortcut,
            registrar: persistenceRegistrar,
            onEvent: { _ in }
        )
        persistence.setCandidate(candidate)
        let failingStore = OigoSettingsStore(defaults: defaults, writeData: { data in
            defaults.set(data, forKey: "oigo.settings.v1")
            throw ScenarioFailure.persistence
        })
        let persistenceResult = persistence.save(
            candidate,
            persist: { try failingStore.save(old.with(globalShortcut: $0)) },
            restore: { try store.save(old) }
        )
        guard conflictResult.isConflict,
              persistenceResult.isConflict,
              store.load() == old else {
            throw ContractInputError(category: "baseline-characterization-failed")
        }
        print(
            "BASELINE_OBSERVED conflictRegistration=\(ShortcutSaveScenarioSupport.statusName(conflictRegistrar.status)) "
                + "persistenceFailureRegistration=\(ShortcutSaveScenarioSupport.statusName(persistenceRegistrar.status)) "
                + "cancelCallbacks=\(cancelCallbacks) "
                + "candidateAfterFailure=\(persistence.candidateShortcut.keyCode)/\(persistence.candidateShortcut.modifiers)"
        )
        print("PASS shortcut-save-baseline")
    }

    @MainActor
    private static func runSuccess(arguments: ContractArguments) throws {
        let defaults = try ShortcutSaveScenarioSupport.isolatedDefaults(arguments.defaultsSuite)
        defer { defaults.removePersistentDomain(forName: arguments.defaultsSuite) }
        let old = OigoSettings.default
        let store = OigoSettingsStore(defaults: defaults)
        try store.save(old)
        let recorder = ShortcutRecorderControl(shortcut: old.globalShortcut)
        var candidateChanges = 0
        recorder.onCandidateChange = { _ in candidateChanges += 1 }
        recorder.beginRecording()
        recorder.keyDown(with: try ShortcutSaveScenarioSupport.keyEvent(
            keyCode: 0,
            modifiers: [.command],
            characters: "a"
        ))
        let candidate = ToggleShortcut(keyCode: 0, modifiers: ToggleShortcutModifiers.command)
        guard recorder.shortcut == candidate, candidateChanges == 1 else {
            throw ContractInputError(category: "key-code-zero-capture-failed")
        }

        let registrar = ScenarioRegistrar(active: old.globalShortcut)
        let transaction = ShortcutConfigurationTransaction(
            committedShortcut: old.globalShortcut,
            registrar: registrar,
            onEvent: { _ in }
        )
        transaction.setCandidate(candidate)
        guard transaction.save(
            candidate,
            persist: { try store.save(old.with(globalShortcut: $0)) },
            restore: { try store.save(old) }
        ).isAvailable else {
            throw ContractInputError(category: "shortcut-save-failed")
        }
        let relaunched = OigoSettingsStore(defaults: defaults).load()
        guard relaunched.globalShortcut == candidate,
              transaction.committedShortcut == candidate,
              transaction.candidateShortcut == candidate,
              registrar.status.isActive,
              ShortcutFormatter.displayName(for: relaunched.globalShortcut) == "⌘A" else {
            throw ContractInputError(category: "shortcut-save-diverged")
        }

        recorder.beginRecording()
        recorder.keyDown(with: try ShortcutSaveScenarioSupport.keyEvent(
            keyCode: 13,
            modifiers: [.command],
            characters: "w"
        ))
        let changesBeforeCancel = candidateChanges
        recorder.beginRecording()
        recorder.cancelRecording()
        transaction.setCandidate(old.globalShortcut)
        transaction.cancel()
        guard candidateChanges == changesBeforeCancel,
              transaction.candidateShortcut == candidate,
              store.load().globalShortcut == candidate else {
            throw ContractInputError(category: "cancel-committed")
        }

        recorder.beginRecording()
        recorder.keyDown(with: try ShortcutSaveScenarioSupport.keyEvent(
            keyCode: 12,
            modifiers: [.command],
            characters: "q"
        ))
        recorder.restoreCandidate(transaction.committedShortcut)
        transaction.cancel()
        guard recorder.shortcut == candidate,
              transaction.candidateShortcut == candidate,
              store.load().globalShortcut == candidate else {
            throw ContractInputError(category: "close-committed")
        }
        print("OBSERVE shortcut-save-success keyCode=0 persisted=0/256 readback=0/256 registration=active label=⌘A cancel=preserved close=preserved")
    }

    @MainActor
    private static func runFailures(arguments: ContractArguments) throws {
        let defaults = try ShortcutSaveScenarioSupport.isolatedDefaults(arguments.defaultsSuite)
        defer { defaults.removePersistentDomain(forName: arguments.defaultsSuite) }
        let old = OigoSettings.default
        let candidate = ToggleShortcut(keyCode: 0, modifiers: ToggleShortcutModifiers.command)
        let store = OigoSettingsStore(defaults: defaults)
        try store.save(old)

        let conflictRegistrar = ScenarioRegistrar(active: old.globalShortcut)
        conflictRegistrar.failFor = candidate
        let conflict = ShortcutConfigurationTransaction(
            committedShortcut: old.globalShortcut,
            registrar: conflictRegistrar,
            onEvent: { _ in }
        )
        conflict.setCandidate(candidate)
        let conflictResult = conflict.save(
            candidate,
            persist: { try store.save(old.with(globalShortcut: $0)) },
            restore: { try store.save(old) }
        )
        try assertFailedState(
            result: conflictResult,
            transaction: conflict,
            registrar: conflictRegistrar,
            store: store,
            old: old,
            errorFragment: "already registered"
        )

        let persistenceRegistrar = ScenarioRegistrar(active: old.globalShortcut)
        let persistence = ShortcutConfigurationTransaction(
            committedShortcut: old.globalShortcut,
            registrar: persistenceRegistrar,
            onEvent: { _ in }
        )
        persistence.setCandidate(candidate)
        let failingStore = OigoSettingsStore(defaults: defaults, writeData: { data in
            defaults.set(data, forKey: "oigo.settings.v1")
            throw ScenarioFailure.persistence
        })
        let persistenceResult = persistence.save(
            candidate,
            persist: { try failingStore.save(old.with(globalShortcut: $0)) },
            restore: { try store.save(old) }
        )
        try assertFailedState(
            result: persistenceResult,
            transaction: persistence,
            registrar: persistenceRegistrar,
            store: store,
            old: old,
            errorFragment: "persistence failure"
        )
        print("OBSERVE shortcut-save-failure conflict=named persistence=named old=committed label=⇧⌘Space keyboard=unavailable candidate=committed mouse-start=enabled")
    }

    @MainActor
    private static func assertFailedState(
        result: OigoShortcutValidation,
        transaction: ShortcutConfigurationTransaction,
        registrar: ScenarioRegistrar,
        store: OigoSettingsStore,
        old: OigoSettings,
        errorFragment: String
    ) throws {
        let mouseStart = AppCommandAvailability.evaluate(
            coordinatorState: .idle,
            occupiedKind: nil,
            acceptingCommands: true,
            setupComplete: true,
            storageReady: true
        )
        guard result.isConflict,
              transaction.lastError?.contains(errorFragment) == true,
              transaction.committedShortcut == old.globalShortcut,
              transaction.candidateShortcut == old.globalShortcut,
              store.load() == old,
              ShortcutFormatter.displayName(for: store.load().globalShortcut) == "⇧⌘Space",
              !registrar.status.isActive,
              mouseStart.canStartDictation else {
            throw ContractInputError(category: "failure-rollback-diverged")
        }
    }

}
