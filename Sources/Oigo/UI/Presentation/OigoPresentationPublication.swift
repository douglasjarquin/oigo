public enum OigoTogglePresentationCommand: Equatable, Sendable {
    case start
    case stop
    case retryStorage
}

public struct OigoPresentationAdapters: Equatable, Sendable {
    public let toggleTitle: String
    public let toggleCommand: OigoTogglePresentationCommand
    public let toggleEnabled: Bool
    public let modeEnabled: Bool
    public let settingsApplyToNextDictation: Bool
    public let retryStorageEnabled: Bool

    public init(inputs: OigoPresentationInputs, state: OigoPresentationState) {
        let storageReady = inputs.storage.status == .ready
        let setupComplete = inputs.onboarding.stage == .complete
        let acceptingCommands = inputs.shutdown.status == .inactive
            && inputs.operationGate.busyReason != .shutdown
        let terminalCoordinator = [
            OigoCoordinatorPresentationState.idle,
            .complete,
            .failed,
            .cancelled,
            .interrupted
        ].contains(inputs.coordinator.state)
        let dictationActive = inputs.operationGate.activeOperation?.kind == .dictation
            || inputs.operationGate.activeOperation?.kind == .onboardingTest
        let canStart = setupComplete
            && storageReady
            && acceptingCommands
            && inputs.operationGate.activeOperation == nil
            && terminalCoordinator
        let canStop = storageReady
            && acceptingCommands
            && dictationActive
            && [.preparing, .recording].contains(inputs.coordinator.state)

        if storageReady {
            let shouldStop = inputs.coordinator.state == .recording
                || state.primaryAction == .enabled(.stopDictation)
            toggleTitle = shouldStop ? "Stop Dictation" : "Start Dictation"
            toggleCommand = shouldStop ? .stop : .start
        } else {
            toggleTitle = "Storage unavailable"
            toggleCommand = .retryStorage
        }
        toggleEnabled = setupComplete && (storageReady ? canStart || canStop : true)
        modeEnabled = setupComplete
            && storageReady
            && acceptingCommands
        settingsApplyToNextDictation = inputs.operationGate.activeOperation != nil
        retryStorageEnabled = !storageReady && inputs.storage.status != .degraded
    }
}

public struct OigoPresentationPublication: Equatable, Sendable {
    public let generation: UInt64
    public let inputs: OigoPresentationInputs
    public let state: OigoPresentationState
    public let adapters: OigoPresentationAdapters

    public init(inputs: OigoPresentationInputs) {
        self.init(inputs: inputs, state: OigoPresentationState.project(inputs))
    }

    public init(inputs: OigoPresentationInputs, state: OigoPresentationState) {
        generation = inputs.generation
        self.inputs = inputs
        self.state = state
        adapters = OigoPresentationAdapters(inputs: inputs, state: state)
    }
}

public struct OigoPresentationGenerationFence: Sendable {
    private var latestGeneration: UInt64?
    private var acceptsPublications = true

    public init() {}

    @discardableResult
    public mutating func publish(
        _ publication: OigoPresentationPublication,
        to consumer: (OigoPresentationPublication) -> Void
    ) -> Bool {
        guard acceptsPublications,
              latestGeneration.map({ publication.generation > $0 }) ?? true else {
            return false
        }
        latestGeneration = publication.generation
        consumer(publication)
        return true
    }

    public mutating func shutdown() {
        acceptsPublications = false
        latestGeneration = nil
    }
}
