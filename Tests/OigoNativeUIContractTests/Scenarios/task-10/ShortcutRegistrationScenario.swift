import Foundation
import OigoCore
import OigoHotKey

final class ShortcutRegistrationScenario: NativeUIContractScenario {
    fileprivate struct StateRow: Codable {
        let action: String
        let shortcutLabel: String?
        let keyboardActive: Bool
        let mouseStartEnabled: Bool
        let errorVisible: Bool
        let generation: UInt64?
        let registrationCount: Int
        let unregistrationCount: Int
        let operationCount: Int
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
            let rows = try exercise(defaults: defaults)
            let selectedRows = switch selected {
            case "success": rows.filter { !["invalid-stored", "conflict", "late-failure"].contains($0.action) }
            case "failure": ["invalid-stored", "conflict", "late-failure"].compactMap { action in
                rows.first { $0.action == action }
            }
            default: rows
            }
            try write(rows: selectedRows, to: arguments.evidenceRoot)
            selectedRows.forEach(printRow)
            print("PASS shortcut-registration rows=\(selectedRows.count) owner=app-controller keyboard=registered-only mouse-start=production-command")
        }
    }

    @MainActor
    private static func exercise(defaults: UserDefaults) throws -> [StateRow] {
        let defaultShortcut = ToggleShortcut.default
        let customShortcut = ToggleShortcut(keyCode: 0, modifiers: ToggleShortcutModifiers.command)
        var rows = [StateRow]()

        defaults.removePersistentDomain(forName: defaultsSuiteName)
        let app = ShortcutRegistrationApp(defaults: defaults)
        rows.append(app.row("no-shortcut"))

        let defaultApp = ShortcutRegistrationApp(defaults: defaults)
        defaultApp.storageReady = true
        defaultApp.onboardingStore.markCompleted()
        try defaultApp.synchronize()
        rows.append(defaultApp.row("default-shortcut"))
        guard defaultApp.backend.registrationCount == 1 else {
            throw ContractInputError(category: "default-registration-not-once")
        }
        defaultApp.shutdown()

        defaults.removePersistentDomain(forName: defaultsSuiteName)
        let primary = ShortcutRegistrationApp(defaults: defaults)
        guard primary.save(customShortcut).isAvailable else {
            throw ContractInputError(category: "registration-pre-gate-save-failed")
        }
        primary.storageReady = true
        try primary.synchronize()
        rows.append(primary.row("storage-ready"))
        guard primary.settingsStore.load().globalShortcut == customShortcut,
              primary.backend.registrationCount == 0,
              !primary.row("probe").keyboardActive else {
            throw ContractInputError(category: "registration-before-readiness-gate")
        }

        primary.onboardingStore.markCompleted()
        try primary.synchronize()
        try primary.synchronize()
        primary.backend.emitCurrent(.pressed)
        rows.append(primary.row("onboarding-ready"))
        guard primary.backend.registrationCount == 1,
              primary.operationCount == 1,
              primary.row("probe").keyboardActive else {
            throw ContractInputError(category: "registration-after-readiness-not-once")
        }

        guard primary.save(defaultShortcut).isAvailable else {
            throw ContractInputError(category: "registration-replacement-failed")
        }
        rows.append(primary.row("replacement"))
        guard primary.settingsStore.load().globalShortcut == defaultShortcut,
              primary.controller.committedShortcut == defaultShortcut,
              primary.row("probe").keyboardActive else {
            throw ContractInputError(category: "registration-replacement-diverged")
        }

        primary.backend.failFor = customShortcut
        let lateFailure = primary.save(customShortcut)
        rows.append(primary.row("late-failure"))
        guard lateFailure.isConflict,
              primary.settingsStore.load().globalShortcut == defaultShortcut,
              primary.controller.committedShortcut == defaultShortcut,
              primary.row("probe").keyboardActive,
              primary.row("probe").appAlive else {
            throw ContractInputError(category: "registration-late-failure-published-stale-success")
        }

        primary.onboardingStore.rerun()
        try primary.synchronize()
        rows.append(primary.row("disable"))
        primary.shutdown()
        rows.append(primary.row("teardown"))
        guard !primary.row("probe").keyboardActive,
              !primary.row("probe").appAlive else {
            throw ContractInputError(category: "registration-teardown-left-app-active")
        }

        defaults.removePersistentDomain(forName: defaultsSuiteName)
        let conflict = ShortcutRegistrationApp(defaults: defaults)
        conflict.storageReady = true
        conflict.onboardingStore.markCompleted()
        conflict.backend.failFor = defaultShortcut
        do {
            try conflict.synchronize()
            throw ContractInputError(category: "registration-conflict-unexpected-success")
        } catch is RegistrationScenarioError {
            rows.append(conflict.row("conflict"))
        }
        let conflictState = conflict.row("probe")
        guard !conflictState.keyboardActive,
              conflictState.mouseStartEnabled,
              conflictState.errorVisible,
              conflictState.appAlive else {
            throw ContractInputError(category: "registration-conflict-published-stale-state")
        }

        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try OigoSettingsStore(defaults: defaults).save(
            OigoSettings.default.with(globalShortcut: customShortcut)
        )
        OigoOnboardingStore(defaults: defaults).markCompleted()
        let relaunch = ShortcutRegistrationApp(defaults: defaults)
        relaunch.storageReady = true
        try relaunch.synchronize()
        rows.append(relaunch.row("relaunch"))
        guard relaunch.backend.registrationCount == 1,
              relaunch.controller.committedShortcut == customShortcut,
              relaunch.row("probe").keyboardActive else {
            throw ContractInputError(category: "registration-relaunch-not-once")
        }
        relaunch.shutdown()

        defaults.removePersistentDomain(forName: defaultsSuiteName)
        let invalidShortcut = ToggleShortcut(keyCode: 0, modifiers: 0)
        try OigoSettingsStore(defaults: defaults).save(
            OigoSettings.default.with(globalShortcut: invalidShortcut)
        )
        OigoOnboardingStore(defaults: defaults).markCompleted()
        let invalid = ShortcutRegistrationApp(defaults: defaults)
        invalid.storageReady = true
        do {
            try invalid.synchronize()
            throw ContractInputError(category: "invalid-stored-shortcut-registered")
        } catch is ShortcutConfigurationError {
            rows.append(invalid.row("invalid-stored"))
        }
        let invalidState = invalid.row("probe")
        guard !invalidState.keyboardActive,
              invalidState.mouseStartEnabled,
              invalidState.errorVisible,
              invalidState.appAlive,
              invalid.backend.registrationCount == 0 else {
            throw ContractInputError(category: "invalid-stored-shortcut-published-success")
        }
        return rows
    }

    private static let defaultsSuiteName = "com.oigo.qa.task10"

    private static func printRow(_ row: StateRow) {
        print("STATE action=\(row.action) shortcut=\(row.shortcutLabel ?? "inactive") keyboard=\(row.keyboardActive) mouse=\(row.mouseStartEnabled) error=\(row.errorVisible) generation=\(row.generation.map(String.init) ?? "inactive") registrations=\(row.registrationCount) unregistrations=\(row.unregistrationCount) operations=\(row.operationCount) alive=\(row.appAlive)")
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
private final class ShortcutRegistrationApp {
    let settingsStore: OigoSettingsStore
    let onboardingStore: OigoOnboardingStore
    let backend = RegistrationScenarioBackend()
    let operationGate = AppOperationGate()
    var storageReady = false
    private(set) var operationCount = 0
    lazy var controller = AppShortcutRegistrationController(
        committedShortcut: settingsStore.load().globalShortcut,
        registrar: CarbonGlobalShortcutRegistrar(backend: backend),
        onRegisteredEvent: { [weak self] _ in self?.operationCount += 1 }
    )

    init(defaults: UserDefaults) {
        settingsStore = OigoSettingsStore(defaults: defaults)
        onboardingStore = OigoOnboardingStore(defaults: defaults)
    }

    func synchronize() throws {
        try controller.synchronize(
            storageReady: storageReady,
            onboardingComplete: onboardingStore.load().isComplete
        )
    }

    func save(_ shortcut: ToggleShortcut) -> OigoShortcutValidation {
        let previous = settingsStore.load()
        return controller.save(
            shortcut,
            persist: { [settingsStore] in
                try settingsStore.save(previous.with(globalShortcut: $0))
            },
            restore: { [settingsStore] in
                try settingsStore.save(previous)
            }
        )
    }

    func shutdown() {
        controller.shutdown()
        _ = operationGate.enterShutdown()
    }

    func row(_ action: String) -> ShortcutRegistrationScenario.StateRow {
        let availability = operationGate.availability(
            coordinatorState: .idle,
            setupComplete: onboardingStore.load().isComplete,
            storageReady: storageReady
        )
        let state = controller.state(commandAvailability: availability)
        let label: String?
        let generation: UInt64?
        switch state.registrationStatus {
        case .active(let shortcut, let currentGeneration):
            label = shortcut.displayName
            generation = currentGeneration
        case .inactive:
            label = nil
            generation = nil
        }
        return ShortcutRegistrationScenario.StateRow(
            action: action,
            shortcutLabel: label,
            keyboardActive: state.keyboardOperationEnabled,
            mouseStartEnabled: state.mouseStartEnabled,
            errorVisible: state.registrationError != nil,
            generation: generation,
            registrationCount: backend.registrationCount,
            unregistrationCount: backend.unregistrationCount,
            operationCount: operationCount,
            appAlive: state.applicationActive
        )
    }
}

@MainActor
private final class RegistrationScenarioBackend: GlobalShortcutRegistrationBackend {
    private final class Handle: GlobalShortcutRegistrationHandle {}
    private struct Registration {
        let handle: Handle
        let generation: UInt64
        let receive: @MainActor (GlobalShortcutEvent) -> Void
    }

    private var registrations: [ObjectIdentifier: Registration] = [:]
    private(set) var registrationCount = 0
    private(set) var unregistrationCount = 0
    var failFor: ToggleShortcut?

    func register(
        shortcut: ToggleShortcut,
        generation: UInt64,
        receive: @escaping @MainActor (GlobalShortcutEvent) -> Void
    ) throws -> any GlobalShortcutRegistrationHandle {
        registrationCount += 1
        if failFor == shortcut {
            throw RegistrationScenarioError.conflict
        }
        let handle = Handle()
        registrations[ObjectIdentifier(handle)] = Registration(
            handle: handle,
            generation: generation,
            receive: receive
        )
        return handle
    }

    func unregister(_ handle: any GlobalShortcutRegistrationHandle) {
        guard let handle = handle as? Handle,
              registrations.removeValue(forKey: ObjectIdentifier(handle)) != nil else { return }
        unregistrationCount += 1
    }

    func emitCurrent(_ edge: GlobalShortcutEdge) {
        guard let registration = registrations.values.max(by: { $0.generation < $1.generation }) else {
            return
        }
        registration.receive(GlobalShortcutEvent(edge: edge, generation: registration.generation))
    }
}

private enum RegistrationScenarioError: Error {
    case conflict
}
