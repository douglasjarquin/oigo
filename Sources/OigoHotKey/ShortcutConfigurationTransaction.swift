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
        registrar.status
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

        let previous = committedShortcut
        do {
            try registrar.register(shortcut: candidate, onEvent: onEvent)
        } catch {
            let validation = OigoShortcutValidation.conflict(String(describing: error))
            configurationError = Self.message(for: validation)
            return validation
        }

        do {
            try persist(candidate)
        } catch {
            var failure = "Shortcut save failed: \(error)"
            var compensationFailed = false
            do {
                try restore()
            } catch let restorePersistenceError {
                compensationFailed = true
                failure += ". Previous settings could not be restored: \(restorePersistenceError)"
            }
            do {
                try registrar.register(shortcut: previous, onEvent: onEvent)
            } catch let restoreError {
                compensationFailed = true
                failure += ". Previous registration could not be restored: \(restoreError)"
            }
            if compensationFailed {
                registrar.unregister()
                failure += ". Shortcut registration was disabled until the prior settings can be restored"
            }
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
