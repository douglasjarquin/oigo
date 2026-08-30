import OigoCore

public struct AppShortcutRegistrationState: Equatable, Sendable {
    public let registrationStatus: GlobalShortcutRegistrationStatus
    public let registrationError: String?
    public let keyboardOperationEnabled: Bool
    public let mouseStartEnabled: Bool
    public let applicationActive: Bool
}

@MainActor
public final class AppShortcutRegistrationController {
    private let initialShortcut: ToggleShortcut
    private let registrar: any GlobalShortcutRegistrationClient
    private let onRegisteredEvent: @MainActor (GlobalShortcutEvent) -> Void
    private var applicationActive = true
    private lazy var transaction = ShortcutConfigurationTransaction(
        committedShortcut: initialShortcut,
        registrar: registrar,
        registrationReady: false,
        onEvent: { [weak self] event in
            self?.receive(event)
        }
    )

    public var committedShortcut: ToggleShortcut {
        transaction.committedShortcut
    }

    public var registrationStatus: GlobalShortcutRegistrationStatus {
        transaction.registrationStatus
    }

    public var lastError: String? {
        transaction.lastError
    }

    public var isOperationReady: Bool {
        applicationActive && transaction.isOperationReady
    }

    public init(
        committedShortcut: ToggleShortcut,
        registrar: any GlobalShortcutRegistrationClient,
        onRegisteredEvent: @escaping @MainActor (GlobalShortcutEvent) -> Void
    ) {
        initialShortcut = committedShortcut
        self.registrar = registrar
        self.onRegisteredEvent = onRegisteredEvent
    }

    public func synchronize(storageReady: Bool, onboardingComplete: Bool) throws {
        try transaction.setRegistrationReady(storageReady && onboardingComplete)
    }

    public func setCandidate(_ candidate: ToggleShortcut) {
        transaction.setCandidate(candidate)
    }

    public func validate(_ candidate: ToggleShortcut) -> OigoShortcutValidation {
        transaction.validate(candidate)
    }

    public func save(
        _ candidate: ToggleShortcut,
        persist: (ToggleShortcut) throws -> Void,
        restore: () throws -> Void
    ) -> OigoShortcutValidation {
        transaction.save(candidate, persist: persist, restore: restore)
    }

    public func deactivate() {
        transaction.deactivateShortcut()
    }

    public func shutdown() {
        transaction.deactivateShortcut()
        applicationActive = false
    }

    public func state(commandAvailability: AppCommandAvailability) -> AppShortcutRegistrationState {
        AppShortcutRegistrationState(
            registrationStatus: transaction.registrationStatus,
            registrationError: transaction.lastError,
            keyboardOperationEnabled: isOperationReady,
            mouseStartEnabled: applicationActive && commandAvailability.canStartDictation,
            applicationActive: applicationActive
        )
    }

    private func receive(_ event: GlobalShortcutEvent) {
        guard isOperationReady else {
            return
        }
        onRegisteredEvent(event)
    }
}
