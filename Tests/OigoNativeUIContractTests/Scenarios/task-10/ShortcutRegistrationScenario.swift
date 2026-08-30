import Foundation
import OigoCore
import OigoHotKey

final class ShortcutRegistrationScenario: NativeUIContractScenario {
    private struct StateRow: Codable {
        let action: String
        let shortcutLabel: String?
        let keyboardActive: Bool
        let mouseStartEnabled: Bool
        let errorVisible: Bool
        let generation: UInt64?
        let registrationCount: Int
        let unregistrationCount: Int
        let appAlive: Bool
    }

    override class var scenarioName: String { "shortcut-registration" }

    override class func run(arguments: ContractArguments) throws {
        guard arguments.defaultsSuite == "com.oigo.qa.task10" else {
            throw ContractInputError(category: "invalid-defaults-suite")
        }
        try MainActor.assumeIsolated {
            let defaults = try ShortcutSaveScenarioSupport.isolatedDefaults(arguments.defaultsSuite)
            defer { defaults.removePersistentDomain(forName: arguments.defaultsSuite) }
            let selected = arguments.fixtureRoot.lastPathComponent
            guard ["task-10", "success", "failure"].contains(selected) else {
                throw ContractInputError(category: "unsupported-registration-fixture")
            }
            let rows = try exercise()
            let selectedRows = switch selected {
            case "success": rows.filter { !["invalid-stored", "conflict", "late-failure"].contains($0.action) }
            case "failure": ["invalid-stored", "conflict"].compactMap { action in
                rows.first { $0.action == action }
            }
            default: rows
            }
            try write(rows: selectedRows, to: arguments.evidenceRoot)
            selectedRows.forEach(printRow)
            print("PASS shortcut-registration rows=\(selectedRows.count) owner=transaction keyboard=registered-only mouse-start=available")
        }
    }

    @MainActor
    private static func exercise() throws -> [StateRow] {
        let defaultShortcut = ToggleShortcut.default
        let customShortcut = ToggleShortcut(keyCode: 0, modifiers: ToggleShortcutModifiers.command)
        let registrar = RegistrationScenarioRegistrar()
        let transaction = ShortcutConfigurationTransaction(
            committedShortcut: defaultShortcut,
            registrar: registrar,
            registrationReady: false,
            onEvent: { _ in }
        )
        var persisted = defaultShortcut
        var rows = [row("no-shortcut", transaction, registrar, mouseStartEnabled: false)]

        let defaultRegistrar = RegistrationScenarioRegistrar()
        let defaultTransaction = ShortcutConfigurationTransaction(
            committedShortcut: defaultShortcut,
            registrar: defaultRegistrar,
            registrationReady: false,
            onEvent: { _ in }
        )
        try defaultTransaction.setRegistrationReady(true)
        rows.append(row("default-shortcut", defaultTransaction, defaultRegistrar, mouseStartEnabled: true))
        try defaultTransaction.setRegistrationReady(false)

        guard transaction.save(
            customShortcut,
            persist: { persisted = $0 },
            restore: { persisted = defaultShortcut }
        ).isAvailable else {
            throw ContractInputError(category: "registration-pre-gate-save-failed")
        }
        rows.append(row("storage-ready", transaction, registrar, mouseStartEnabled: false))
        guard persisted == customShortcut, registrar.registrationCount == 0,
              !transaction.isOperationReady else {
            throw ContractInputError(category: "registration-before-readiness-gate")
        }

        try transaction.setRegistrationReady(true)
        try transaction.setRegistrationReady(true)
        rows.append(row("onboarding-ready", transaction, registrar, mouseStartEnabled: true))
        guard transaction.isOperationReady, registrar.registrationCount == 1 else {
            throw ContractInputError(category: "registration-after-readiness-not-once")
        }

        let replacement = transaction.save(
            defaultShortcut,
            persist: { persisted = $0 },
            restore: { persisted = customShortcut }
        )
        rows.append(row("replacement", transaction, registrar, mouseStartEnabled: true))
        guard replacement.isAvailable, persisted == defaultShortcut,
              transaction.committedShortcut == defaultShortcut,
              transaction.isOperationReady else {
            throw ContractInputError(category: "registration-replacement-diverged")
        }

        registrar.failRegisterFor = customShortcut
        let lateFailure = transaction.save(
            customShortcut,
            persist: { persisted = $0 },
            restore: { persisted = defaultShortcut }
        )
        rows.append(row("late-failure", transaction, registrar, mouseStartEnabled: true))
        guard lateFailure.isConflict, persisted == defaultShortcut,
              transaction.committedShortcut == defaultShortcut,
              transaction.isOperationReady else {
            throw ContractInputError(category: "registration-late-failure-published-stale-success")
        }

        try transaction.setRegistrationReady(false)
        rows.append(row("disable", transaction, registrar, mouseStartEnabled: true))
        try transaction.setRegistrationReady(false)
        rows.append(row("teardown", transaction, registrar, mouseStartEnabled: false))
        guard !transaction.isOperationReady else {
            throw ContractInputError(category: "registration-disable-left-operation-enabled")
        }

        let conflictRegistrar = RegistrationScenarioRegistrar()
        conflictRegistrar.failRegisterFor = defaultShortcut
        let conflict = ShortcutConfigurationTransaction(
            committedShortcut: defaultShortcut,
            registrar: conflictRegistrar,
            registrationReady: false,
            onEvent: { _ in }
        )
        do {
            try conflict.setRegistrationReady(true)
            throw ContractInputError(category: "registration-conflict-unexpected-success")
        } catch is RegistrationScenarioError {
            rows.append(row("conflict", conflict, conflictRegistrar, mouseStartEnabled: true))
        }
        guard !conflict.isOperationReady, conflict.lastError != nil else {
            throw ContractInputError(category: "registration-conflict-published-stale-state")
        }

        registrar.failRegisterFor = nil
        let relaunchRegistrar = RegistrationScenarioRegistrar()
        let relaunch = ShortcutConfigurationTransaction(
            committedShortcut: persisted,
            registrar: relaunchRegistrar,
            registrationReady: false,
            onEvent: { _ in }
        )
        try relaunch.setRegistrationReady(true)
        rows.append(row("relaunch", relaunch, relaunchRegistrar, mouseStartEnabled: true))
        guard relaunch.isOperationReady, relaunchRegistrar.registrationCount == 1 else {
            throw ContractInputError(category: "registration-relaunch-not-once")
        }

        let invalidRegistrar = RegistrationScenarioRegistrar()
        let invalid = ShortcutConfigurationTransaction(
            committedShortcut: ToggleShortcut(keyCode: 0, modifiers: 0),
            registrar: invalidRegistrar,
            registrationReady: false,
            onEvent: { _ in }
        )
        do {
            try invalid.setRegistrationReady(true)
            throw ContractInputError(category: "invalid-stored-shortcut-registered")
        } catch is ShortcutConfigurationError {
            rows.append(row("invalid-stored", invalid, invalidRegistrar, mouseStartEnabled: true))
        }
        guard !invalid.isOperationReady, invalid.lastError != nil,
              invalidRegistrar.registrationCount == 0 else {
            throw ContractInputError(category: "invalid-stored-shortcut-published-success")
        }
        return rows
    }

    @MainActor
    private static func row(
        _ action: String,
        _ transaction: ShortcutConfigurationTransaction,
        _ registrar: RegistrationScenarioRegistrar,
        mouseStartEnabled: Bool
    ) -> StateRow {
        let label: String?
        let generation: UInt64?
        switch transaction.registrationStatus {
        case .active(let shortcut, let currentGeneration):
            label = shortcut.displayName
            generation = currentGeneration
        case .inactive:
            label = nil
            generation = nil
        }
        return StateRow(
            action: action,
            shortcutLabel: label,
            keyboardActive: transaction.isOperationReady,
            mouseStartEnabled: mouseStartEnabled,
            errorVisible: transaction.lastError != nil,
            generation: generation,
            registrationCount: registrar.registrationCount,
            unregistrationCount: registrar.unregistrationCount,
            appAlive: true
        )
    }

    private static func printRow(_ row: StateRow) {
        print("STATE action=\(row.action) shortcut=\(row.shortcutLabel ?? "inactive") keyboard=\(row.keyboardActive) mouse=\(row.mouseStartEnabled) error=\(row.errorVisible) generation=\(row.generation.map(String.init) ?? "inactive") registrations=\(row.registrationCount) unregistrations=\(row.unregistrationCount) alive=\(row.appAlive)")
    }

    private static func write(rows: [StateRow], to root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(
            to: root.appendingPathComponent("shortcut-registration.json"),
            options: .atomic
        )
    }
}

@MainActor
private final class RegistrationScenarioRegistrar: GlobalShortcutRegistrationClient {
    private(set) var status: GlobalShortcutRegistrationStatus = .inactive("Global shortcut is not registered")
    private(set) var lastError: String?
    private(set) var registrationCount = 0
    private(set) var unregistrationCount = 0
    var failProbeFor: ToggleShortcut?
    var failRegisterFor: ToggleShortcut?
    private var generation: UInt64 = 0

    func register(
        shortcut: ToggleShortcut,
        onEvent: @escaping @MainActor (GlobalShortcutEvent) -> Void
    ) throws {
        _ = onEvent
        registrationCount += 1
        if failRegisterFor == shortcut {
            lastError = "simulated registration conflict"
            throw RegistrationScenarioError.conflict
        }
        generation += 1
        status = .active(shortcut, generation: generation)
        lastError = nil
    }

    func probe(shortcut: ToggleShortcut) throws {
        if failProbeFor == shortcut {
            lastError = "simulated registration conflict"
            throw RegistrationScenarioError.conflict
        }
        lastError = nil
    }

    func unregister() {
        unregistrationCount += 1
        generation += 1
        status = .inactive("Global shortcut is not registered")
        lastError = nil
    }
}

private enum RegistrationScenarioError: Error {
    case conflict
}
