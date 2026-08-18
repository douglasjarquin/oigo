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
}

@MainActor
public final class ShortcutConfigurationTransaction {
    private let registrar: any GlobalShortcutRegistrationClient
    private let onEvent: @MainActor (GlobalShortcutEvent) -> Void

    public private(set) var committedShortcut: ToggleShortcut
    public private(set) var candidateShortcut: ToggleShortcut

    public var registrationStatus: GlobalShortcutRegistrationStatus {
        registrar.status
    }

    public var lastError: String? {
        registrar.lastError
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
            return basicValidation
        }
        do {
            try registrar.probe(shortcut: candidate)
            return .available
        } catch {
            return .conflict(String(describing: error))
        }
    }

    public func save(
        _ candidate: ToggleShortcut,
        persist: (ToggleShortcut) throws -> Void
    ) -> OigoShortcutValidation {
        let basicValidation = OigoShortcutValidator.validate(candidate, occupied: [])
        guard basicValidation.isAvailable else {
            return basicValidation
        }

        let previous = committedShortcut
        do {
            try registrar.register(shortcut: candidate, onEvent: onEvent)
        } catch {
            return .conflict(String(describing: error))
        }

        do {
            try persist(candidate)
        } catch {
            do {
                try registrar.register(shortcut: previous, onEvent: onEvent)
            } catch let restoreError {
                return .conflict(
                    "Shortcut save failed: \(error). Previous registration could not be restored: \(restoreError)"
                )
            }
            return .conflict("Shortcut save failed: \(error)")
        }

        committedShortcut = candidate
        candidateShortcut = candidate
        return .available
    }

    public func cancel() {
        candidateShortcut = committedShortcut
    }
}

extension CarbonGlobalShortcutRegistrar: GlobalShortcutRegistrationClient {}
