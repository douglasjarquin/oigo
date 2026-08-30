import Foundation
import OigoCore
import OigoHotKey

final class ShortcutTransactionScenario: NativeUIContractScenario {
    private struct Fixture: Decodable {
        let oldShortcut: ToggleShortcut
        let candidateShortcut: ToggleShortcut
        let actions: [String]
        let expectedRelaunchGeneration: UInt64
    }

    private struct StateRow: Codable {
        let action: String
        let persisted: ToggleShortcut
        let committed: ToggleShortcut
        let registrarActive: ToggleShortcut?
        let reported: ToggleShortcut?
        let generation: UInt64?
        let errorVisible: Bool
        let registrationCount: Int
    }

    private struct Receipt: Codable {
        let fixture: String
        let rows: [StateRow]
    }

    override class var scenarioName: String {
        "shortcut-transaction"
    }

    override class func run(arguments: ContractArguments) throws {
        guard arguments.defaultsSuite == "com.oigo.qa.task09" else {
            throw ContractInputError(category: "invalid-defaults-suite")
        }
        try MainActor.assumeIsolated {
            let defaults = try ShortcutSaveScenarioSupport.isolatedDefaults(arguments.defaultsSuite)
            defer { defaults.removePersistentDomain(forName: arguments.defaultsSuite) }
            let fixtures = try loadFixtures(arguments: arguments)
            var receipts: [Receipt] = []
            for (name, fixture) in fixtures {
                let rows = try exercise(name: name, fixture: fixture, defaults: defaults)
                rows.forEach(printRow)
                receipts.append(Receipt(fixture: name, rows: rows))
            }
            try write(receipts: receipts, to: arguments.evidenceRoot)
            print("PASS shortcut-transaction fixtures=\(receipts.count) state-table=converged relaunch=once rollback=fail-closed")
        }
    }

    @MainActor
    private static func exercise(
        name: String,
        fixture: Fixture,
        defaults: UserDefaults
    ) throws -> [StateRow] {
        switch name {
        case "shortcut-success":
            guard fixture.actions == ["successful-replacement", "cancel", "close", "relaunch"] else {
                throw ContractInputError(category: "invalid-transaction-action")
            }
            return try successRows(fixture: fixture, defaults: defaults)
        case "shortcut-failure":
            guard fixture.actions == [
                "conflict", "registration-failure", "persistence-failure",
                "compound-rollback-failure"
            ] else {
                throw ContractInputError(category: "invalid-transaction-action")
            }
            return try failureRows(fixture: fixture, defaults: defaults)
        default:
            throw ContractInputError(category: "unsupported-transaction-action")
        }
    }

    @MainActor
    private static func successRows(
        fixture: Fixture,
        defaults: UserDefaults
    ) throws -> [StateRow] {
        let oldSettings = OigoSettings.default.with(globalShortcut: fixture.oldShortcut)
        let store = OigoSettingsStore(defaults: defaults)
        try store.save(oldSettings)
        let registrar = TransactionScenarioRegistrar(active: fixture.oldShortcut)
        let transaction = ShortcutConfigurationTransaction(
            committedShortcut: fixture.oldShortcut,
            registrar: registrar,
            onEvent: { _ in }
        )
        let result = transaction.save(
            fixture.candidateShortcut,
            persist: { try store.save(oldSettings.with(globalShortcut: $0)) },
            restore: { try store.save(oldSettings) }
        )
        let persisted = store.load().globalShortcut
        let success = row(
            action: "successful-replacement",
            persisted: persisted,
            transaction: transaction,
            registrar: registrar
        )

        transaction.setCandidate(fixture.oldShortcut)
        transaction.cancel()
        let cancel = row(
            action: "cancel",
            persisted: persisted,
            transaction: transaction,
            registrar: registrar
        )
        transaction.setCandidate(fixture.oldShortcut)
        transaction.cancel()
        let close = row(
            action: "close",
            persisted: persisted,
            transaction: transaction,
            registrar: registrar
        )

        let relaunchedPersisted = OigoSettingsStore(defaults: defaults).load().globalShortcut
        let relaunchedRegistrar = TransactionScenarioRegistrar()
        let relaunched = ShortcutConfigurationTransaction(
            committedShortcut: relaunchedPersisted,
            registrar: relaunchedRegistrar,
            onEvent: { _ in }
        )
        try relaunched.activateCommittedShortcut()
        let relaunch = row(
            action: "relaunch",
            persisted: relaunchedPersisted,
            transaction: relaunched,
            registrar: relaunchedRegistrar
        )

        guard result.isAvailable,
              converged(success, expected: fixture.candidateShortcut),
              converged(cancel, expected: fixture.candidateShortcut),
              converged(close, expected: fixture.candidateShortcut),
              converged(relaunch, expected: fixture.candidateShortcut),
              success.generation == 2,
              relaunch.registrationCount == 1,
              relaunch.generation == fixture.expectedRelaunchGeneration else {
            throw ContractInputError(category: "transaction-success-state-diverged")
        }
        return [success, cancel, close, relaunch]
    }

    @MainActor
    private static func failureRows(
        fixture: Fixture,
        defaults: UserDefaults
    ) throws -> [StateRow] {
        var rows: [StateRow] = []
        let oldSettings = OigoSettings.default.with(globalShortcut: fixture.oldShortcut)
        let store = OigoSettingsStore(defaults: defaults)
        try store.save(oldSettings)

        let conflictRegistrar = TransactionScenarioRegistrar(active: fixture.oldShortcut)
        conflictRegistrar.failProbeFor = fixture.candidateShortcut
        let conflict = ShortcutConfigurationTransaction(
            committedShortcut: fixture.oldShortcut,
            registrar: conflictRegistrar,
            onEvent: { _ in }
        )
        let conflictResult = conflict.validate(fixture.candidateShortcut)
        rows.append(row(
            action: "conflict",
            persisted: store.load().globalShortcut,
            transaction: conflict,
            registrar: conflictRegistrar
        ))

        let registrationRegistrar = TransactionScenarioRegistrar(active: fixture.oldShortcut)
        registrationRegistrar.failRegisterFor = fixture.candidateShortcut
        let registration = ShortcutConfigurationTransaction(
            committedShortcut: fixture.oldShortcut,
            registrar: registrationRegistrar,
            onEvent: { _ in }
        )
        let registrationResult = registration.save(
            fixture.candidateShortcut,
            persist: { try store.save(oldSettings.with(globalShortcut: $0)) },
            restore: { try store.save(oldSettings) }
        )
        rows.append(row(
            action: "registration-failure",
            persisted: store.load().globalShortcut,
            transaction: registration,
            registrar: registrationRegistrar
        ))

        let persistenceRegistrar = TransactionScenarioRegistrar(active: fixture.oldShortcut)
        let persistence = ShortcutConfigurationTransaction(
            committedShortcut: fixture.oldShortcut,
            registrar: persistenceRegistrar,
            onEvent: { _ in }
        )
        let persistenceStore = OigoSettingsStore(defaults: defaults, writeData: { data in
            defaults.set(data, forKey: "oigo.settings.v1")
            throw TransactionScenarioFailure.persistence
        })
        let persistenceResult = persistence.save(
            fixture.candidateShortcut,
            persist: { try persistenceStore.save(oldSettings.with(globalShortcut: $0)) },
            restore: { try store.save(oldSettings) }
        )
        rows.append(row(
            action: "persistence-failure",
            persisted: store.load().globalShortcut,
            transaction: persistence,
            registrar: persistenceRegistrar
        ))

        try store.save(oldSettings)
        let compoundRegistrar = TransactionScenarioRegistrar(active: fixture.oldShortcut)
        let compound = ShortcutConfigurationTransaction(
            committedShortcut: fixture.oldShortcut,
            registrar: compoundRegistrar,
            onEvent: { _ in }
        )
        let compoundStore = OigoSettingsStore(defaults: defaults, writeData: { data in
            defaults.set(data, forKey: "oigo.settings.v1")
            throw TransactionScenarioFailure.persistence
        })
        let compoundResult = compound.save(
            fixture.candidateShortcut,
            persist: { try compoundStore.save(oldSettings.with(globalShortcut: $0)) },
            restore: { throw TransactionScenarioFailure.rollback }
        )
        let compoundPersisted = store.load().globalShortcut
        let compoundRow = row(
            action: "compound-rollback-failure",
            persisted: compoundPersisted,
            transaction: compound,
            registrar: compoundRegistrar
        )
        rows.append(compoundRow)

        let rejectedRows = rows.filter { $0.action != "compound-rollback-failure" }
        guard conflictResult.isConflict,
              registrationResult.isConflict,
              persistenceResult.isConflict,
              compoundResult.isConflict,
              rejectedRows.allSatisfy({ converged($0, expected: fixture.oldShortcut) }),
              compoundRow.persisted == fixture.oldShortcut,
              compoundRow.committed == fixture.oldShortcut,
              compoundRow.registrarActive == nil,
              compoundRow.reported == nil,
              compoundRow.errorVisible else {
            rows.forEach(printRow)
            throw ContractInputError(category: "transaction-rejected-state-diverged")
        }
        return rows
    }

    private static func loadFixtures(arguments: ContractArguments) throws -> [(String, Fixture)] {
        let roots: [URL]
        if arguments.fixtureRoot.lastPathComponent.hasPrefix("shortcut-") {
            roots = [arguments.fixtureRoot]
        } else if let fixtureName = arguments.fixtureName {
            roots = [arguments.fixtureRoot.appendingPathComponent(fixtureName, isDirectory: true)]
        } else {
            roots = ["shortcut-success", "shortcut-failure"].map {
                arguments.fixtureRoot.appendingPathComponent($0, isDirectory: true)
            }
        }
        return try roots.map { root in
            let data: Data
            do {
                data = try Data(contentsOf: root.appendingPathComponent("fixture.json"))
            } catch {
                throw ContractInputError(category: "missing-transaction-fixture")
            }
            let fixture: Fixture
            do {
                fixture = try JSONDecoder().decode(Fixture.self, from: data)
            } catch {
                throw ContractInputError(category: "malformed-transaction-fixture")
            }
            guard fixture.oldShortcut != fixture.candidateShortcut,
                  fixture.oldShortcut.keyCode <= UInt16.max,
                  fixture.candidateShortcut.keyCode <= UInt16.max,
                  OigoShortcutValidator.validate(fixture.oldShortcut, occupied: []).isAvailable,
                  OigoShortcutValidator.validate(fixture.candidateShortcut, occupied: []).isAvailable else {
                throw ContractInputError(category: "invalid-transaction-shortcut")
            }
            let supportedActions = [
                "successful-replacement", "conflict", "persistence-failure",
                "registration-failure", "compound-rollback-failure", "cancel", "close", "relaunch"
            ]
            guard !fixture.actions.isEmpty,
                  fixture.actions.allSatisfy(supportedActions.contains) else {
                throw ContractInputError(category: "invalid-transaction-action")
            }
            guard fixture.expectedRelaunchGeneration == 1 else {
                throw ContractInputError(category: "invalid-transaction-generation")
            }
            return (root.lastPathComponent, fixture)
        }
    }

    @MainActor
    private static func row(
        action: String,
        persisted: ToggleShortcut,
        transaction: ShortcutConfigurationTransaction,
        registrar: TransactionScenarioRegistrar
    ) -> StateRow {
        let active: ToggleShortcut?
        let generation: UInt64?
        switch registrar.status {
        case .active(let shortcut, let activeGeneration):
            active = shortcut
            generation = activeGeneration
        case .inactive:
            active = nil
            generation = nil
        }
        let reported: ToggleShortcut?
        switch transaction.registrationStatus {
        case .active(let shortcut, _):
            reported = shortcut
        case .inactive:
            reported = nil
        }
        return StateRow(
            action: action,
            persisted: persisted,
            committed: transaction.committedShortcut,
            registrarActive: active,
            reported: reported,
            generation: generation,
            errorVisible: transaction.lastError != nil,
            registrationCount: registrar.registrationCount
        )
    }

    private static func converged(_ row: StateRow, expected: ToggleShortcut) -> Bool {
        row.persisted == expected
            && row.committed == expected
            && row.registrarActive == expected
            && row.reported == expected
    }

    private static func printRow(_ row: StateRow) {
        print(
            "STATE action=\(row.action) persisted=\(shortcut(row.persisted)) "
                + "committed=\(shortcut(row.committed)) registrar=\(shortcut(row.registrarActive)) "
                + "reported=\(shortcut(row.reported)) generation=\(row.generation.map(String.init) ?? "inactive") "
                + "error=\(row.errorVisible) registrations=\(row.registrationCount)"
        )
    }

    private static func shortcut(_ shortcut: ToggleShortcut?) -> String {
        guard let shortcut else { return "inactive" }
        return "\(shortcut.keyCode)/\(shortcut.modifiers)"
    }

    private static func write(receipts: [Receipt], to evidenceRoot: URL) throws {
        try FileManager.default.createDirectory(at: evidenceRoot, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(receipts)
        try data.write(to: evidenceRoot.appendingPathComponent("shortcut-transaction.json"), options: .atomic)
    }
}

private enum TransactionScenarioFailure: Error, CustomStringConvertible {
    case persistence
    case rollback
    case registration

    var description: String {
        switch self {
        case .persistence:
            "simulated persistence failure"
        case .rollback:
            "simulated rollback failure"
        case .registration:
            "simulated registration failure"
        }
    }
}

@MainActor
private final class TransactionScenarioRegistrar: GlobalShortcutRegistrationClient {
    private(set) var status: GlobalShortcutRegistrationStatus
    private(set) var lastError: String?
    private(set) var registrationCount = 0
    var failProbeFor: ToggleShortcut?
    var failRegisterFor: ToggleShortcut?
    private var generation: UInt64

    init(active shortcut: ToggleShortcut? = nil) {
        if let shortcut {
            generation = 1
            status = .active(shortcut, generation: 1)
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
        registrationCount += 1
        if failRegisterFor == shortcut {
            lastError = TransactionScenarioFailure.registration.description
            throw TransactionScenarioFailure.registration
        }
        generation += 1
        status = .active(shortcut, generation: generation)
        lastError = nil
    }

    func probe(shortcut: ToggleShortcut) throws {
        if failProbeFor == shortcut {
            lastError = TransactionScenarioFailure.registration.description
            throw TransactionScenarioFailure.registration
        }
        lastError = nil
    }

    func unregister() {
        generation += 1
        status = .inactive("Global shortcut is not registered")
        lastError = nil
    }
}
