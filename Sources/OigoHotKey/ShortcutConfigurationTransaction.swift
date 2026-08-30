import OigoCore

@MainActor
public protocol GlobalShortcutRegistrationClient: AnyObject {
    var status: GlobalShortcutRegistrationStatus { get }
    var lastError: String? { get }

    func register(
        shortcut: ToggleShortcut,
        onEvent: @escaping @MainActor (GlobalShortcutEvent) -> Void
    ) throws
    func probe(shortcut: ToggleShortcut) throws
    func unregister()
}

@MainActor
public final class ShortcutConfigurationTransaction {
    private let registrar: any GlobalShortcutRegistrationClient
    private let onEvent: @MainActor (GlobalShortcutEvent) -> Void
    private var configurationError: String?

    public private(set) var committedShortcut: ToggleShortcut
    public private(set) var candidateShortcut: ToggleShortcut

    public var registrationStatus: GlobalShortcutRegistrationStatus {
        switch registrar.status {
        case .active(let shortcut, let generation) where shortcut == committedShortcut:
            .active(shortcut, generation: generation)
        case .active:
            .inactive("Global shortcut state is inconsistent")
        case .inactive(let reason):
            .inactive(reason)
        }
    }

    public var isCommittedShortcutActive: Bool {
        registrationStatus.isActive
    }

    public var lastError: String? {
        configurationError ?? registrar.lastError
    }

    public init(
        committedShortcut: ToggleShortcut,
        registrar: any GlobalShortcutRegistrationClient,
        onEvent: @escaping @MainActor (GlobalShortcutEvent) -> Void
    ) {
        self.committedShortcut = committedShortcut
        candidateShortcut = committedShortcut
        self.registrar = registrar
        self.onEvent = onEvent
    }

    public func setCandidate(_ candidate: ToggleShortcut) {
        candidateShortcut = candidate
    }

    public func validate(_ candidate: ToggleShortcut) -> OigoShortcutValidation {
        let basicValidation = OigoShortcutValidator.validate(candidate, occupied: [])
        guard basicValidation.isAvailable else {
            configurationError = Self.message(for: basicValidation)
            return basicValidation
        }
        do {
            try registrar.probe(shortcut: candidate)
            configurationError = nil
            return .available
        } catch {
            let validation = OigoShortcutValidation.conflict(String(describing: error))
            configurationError = Self.message(for: validation)
            return validation
        }
    }

    public func save(
        _ candidate: ToggleShortcut,
        persist: (ToggleShortcut) throws -> Void,
        restore: () throws -> Void
    ) -> OigoShortcutValidation {
        let basicValidation = OigoShortcutValidator.validate(candidate, occupied: [])
        guard basicValidation.isAvailable else {
            configurationError = Self.message(for: basicValidation)
            return basicValidation
        }

        do {
            try registrar.register(shortcut: candidate, onEvent: onEvent)
        } catch {
            candidateShortcut = committedShortcut
            let validation = OigoShortcutValidation.conflict(String(describing: error))
            configurationError = Self.message(for: validation)
            return validation
        }

        do {
            try persist(candidate)
        } catch {
            var failure = "Shortcut save failed: \(error)"
            do {
                try restore()
            } catch let restorePersistenceError {
                failure += ". Previous settings could not be restored: \(restorePersistenceError)"
                candidateShortcut = committedShortcut
                registrar.unregister()
                failure += ". Shortcut registration was disabled until a shortcut is saved again"
                let validation = OigoShortcutValidation.conflict(failure)
                configurationError = Self.message(for: validation)
                return validation
            }
            do {
                try registrar.register(shortcut: committedShortcut, onEvent: onEvent)
            } catch let restoreRegistrationError {
                failure += ". Previous shortcut registration could not be restored: \(restoreRegistrationError)"
                candidateShortcut = committedShortcut
                registrar.unregister()
                failure += ". Shortcut registration was disabled until a shortcut is saved again"
                let validation = OigoShortcutValidation.conflict(failure)
                configurationError = Self.message(for: validation)
                return validation
            }
            candidateShortcut = committedShortcut
            failure += ". Previous shortcut was restored"
            let validation = OigoShortcutValidation.conflict(failure)
            configurationError = Self.message(for: validation)
            return validation
        }

        committedShortcut = candidate
        candidateShortcut = candidate
        configurationError = nil
        return .available
    }

    public func cancel() {
        candidateShortcut = committedShortcut
    }

    public func activateCommittedShortcut() throws {
        guard !isCommittedShortcutActive else {
            return
        }
        do {
            try registrar.register(shortcut: committedShortcut, onEvent: onEvent)
            configurationError = nil
        } catch {
            let validation = OigoShortcutValidation.conflict(String(describing: error))
            configurationError = Self.message(for: validation)
            throw error
        }
    }

    public func deactivateShortcut() {
        registrar.unregister()
    }

    public func clear(
        persist: (ToggleShortcut) throws -> Void,
        restore: () throws -> Void
    ) -> OigoShortcutValidation {
        save(.default, persist: persist, restore: restore)
    }

    public func clearError() {
        configurationError = nil
    }

    private static func message(for validation: OigoShortcutValidation) -> String? {
        switch validation {
        case .available:
            nil
        case .conflict(let reason), .invalid(let reason):
            reason
        }
    }
}

extension CarbonGlobalShortcutRegistrar: GlobalShortcutRegistrationClient {}
