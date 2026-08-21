import Foundation

public enum OigoPresentationOperationKind: String, Equatable, Sendable {
    case dictation
    case retry
    case cleanAgain
    case reapplyDictionary
    case pasteAgain
    case onboardingTest
    case interruption
    case shutdown
    case maintenance
}

public struct OigoActiveOperationPresentationInput: Equatable, Sendable {
    public let generation: UInt64
    public let kind: OigoPresentationOperationKind

    public init(generation: UInt64, kind: OigoPresentationOperationKind) {
        self.generation = generation
        self.kind = kind
    }
}

public enum OigoOperationBusyPresentationReason: Equatable, Sendable {
    case shutdown
    case occupied(OigoPresentationOperationKind)
}

public struct OigoOperationGatePresentationInput: Equatable, Sendable {
    public let activeOperation: OigoActiveOperationPresentationInput?
    public let busyReason: OigoOperationBusyPresentationReason?

    public init(
        activeOperation: OigoActiveOperationPresentationInput?,
        busyReason: OigoOperationBusyPresentationReason?
    ) {
        self.activeOperation = activeOperation
        self.busyReason = busyReason
    }
}

public enum OigoCoordinatorPresentationState: String, Equatable, Sendable {
    case idle
    case preparing
    case recording
    case finalizing
    case cleaning
    case inserting
    case complete
    case failed
    case cancelled
    case interrupted
}

public struct OigoCoordinatorPresentationInput: Equatable, Sendable {
    public let state: OigoCoordinatorPresentationState
    public let generation: UInt64

    public init(state: OigoCoordinatorPresentationState, generation: UInt64) {
        self.state = state
        self.generation = generation
    }
}

public enum OigoStoragePresentationStatus: String, Equatable, Sendable {
    case ready
    case degraded
    case unavailable
}

public struct OigoStoragePresentationInput: Equatable, Sendable {
    public let status: OigoStoragePresentationStatus

    public init(status: OigoStoragePresentationStatus) {
        self.status = status
    }
}

public enum OigoShortcutRegistrationPresentationStatus: String, Equatable, Sendable {
    case registered
    case conflict
    case failed
    case unavailable
}

public struct OigoShortcutPresentationInput: Equatable, Sendable {
    public let registration: OigoShortcutRegistrationPresentationStatus
    public let isConfigured: Bool

    public init(registration: OigoShortcutRegistrationPresentationStatus, isConfigured: Bool) {
        self.registration = registration
        self.isConfigured = isConfigured
    }
}

public enum OigoPermissionPresentationStatus: String, Equatable, Sendable {
    case notDetermined
    case granted
    case denied
    case restricted
}

public struct OigoPermissionsPresentationInput: Equatable, Sendable {
    public let microphone: OigoPermissionPresentationStatus
    public let accessibility: OigoPermissionPresentationStatus

    public init(
        microphone: OigoPermissionPresentationStatus,
        accessibility: OigoPermissionPresentationStatus
    ) {
        self.microphone = microphone
        self.accessibility = accessibility
    }
}

public enum OigoInputSelectionPresentationStatus: String, Equatable, Sendable {
    case systemDefault
    case pinnedAvailable
    case pinnedUnavailable
    case noAvailableInput
}

public struct OigoInputPresentationInput: Equatable, Sendable {
    public let selection: OigoInputSelectionPresentationStatus
    public let channelIndex: Int

    public init(selection: OigoInputSelectionPresentationStatus, channelIndex: Int) {
        self.selection = selection
        self.channelIndex = max(0, channelIndex)
    }
}

public struct OigoLocaleIdentifier: Equatable, Sendable {
    public let value: String

    public init?(_ value: String) {
        guard value.count <= 64,
              value.range(
                of: #"^[A-Za-z]{2,3}([_-][A-Za-z0-9]{2,8})*$"#,
                options: .regularExpression
              ) != nil else {
            return nil
        }
        self.value = value
    }
}

public enum OigoLocaleAssetPresentationStatus: String, Equatable, Sendable {
    case idle
    case checking
    case installing
    case ready
    case failed
    case unavailable
    case unsupported
}

public struct OigoLocaleAssetsPresentationInput: Equatable, Sendable {
    public let localeIdentifier: OigoLocaleIdentifier
    public let status: OigoLocaleAssetPresentationStatus
    public let generation: UInt64

    public init(
        localeIdentifier: OigoLocaleIdentifier,
        status: OigoLocaleAssetPresentationStatus,
        generation: UInt64
    ) {
        self.localeIdentifier = localeIdentifier
        self.status = status
        self.generation = generation
    }
}

public enum OigoConfigurationApplication: String, Equatable, Sendable {
    case active
    case next
}

public struct OigoDictationConfigurationPresentationInput: Equatable, Sendable {
    public let localeIdentifier: OigoLocaleIdentifier
    public let input: OigoInputSelectionPresentationStatus
    public let channelIndex: Int
    public let appliesTo: OigoConfigurationApplication

    public init(
        localeIdentifier: OigoLocaleIdentifier,
        input: OigoInputSelectionPresentationStatus,
        channelIndex: Int,
        appliesTo: OigoConfigurationApplication
    ) {
        self.localeIdentifier = localeIdentifier
        self.input = input
        self.channelIndex = max(0, channelIndex)
        self.appliesTo = appliesTo
    }
}

public enum OigoTerminalPresentationOutcome: String, Equatable, Sendable {
    case completed
    case pasteAttempted
    case pasted
    case copied
    case cleanupFallback
    case insertionFailed
    case retryRequired
    case cancelled
    case interrupted
    case failed
}

public enum OigoTerminalPresentationFailure: String, Equatable, Sendable {
    case capture
    case transcription
    case cleanup
    case insertion
    case permission
    case storage
    case timeout
    case targetLost
    case unknown
}

public struct OigoTerminalPresentationInput: Equatable, Sendable {
    public let generation: UInt64
    public let outcome: OigoTerminalPresentationOutcome
    public let failure: OigoTerminalPresentationFailure?

    public init(
        generation: UInt64,
        outcome: OigoTerminalPresentationOutcome,
        failure: OigoTerminalPresentationFailure?
    ) {
        self.generation = generation
        self.outcome = outcome
        self.failure = failure
    }
}

public enum OigoLatestSessionPresentationState: String, Equatable, Sendable {
    case preparing
    case recording
    case stopping
    case retrying
    case complete
    case failed
    case cancelled
    case interrupted
}

public struct OigoLatestSessionPresentationInput: Equatable, Sendable {
    public let id: UUID
    public let state: OigoLatestSessionPresentationState
    public let createdAt: Date
    public let hasAudio: Bool
    public let hasTranscript: Bool
    public let failure: OigoTerminalPresentationFailure?

    public init(
        id: UUID,
        state: OigoLatestSessionPresentationState,
        createdAt: Date,
        hasAudio: Bool,
        hasTranscript: Bool,
        failure: OigoTerminalPresentationFailure?
    ) {
        self.id = id
        self.state = state
        self.createdAt = createdAt
        self.hasAudio = hasAudio
        self.hasTranscript = hasTranscript
        self.failure = failure
    }
}

public enum OigoPlaybackPresentationStatus: String, Equatable, Sendable {
    case idle
    case playing
    case completed
    case stopped
    case replaced
    case failed
    case shutdown
}

public struct OigoPlaybackPresentationInput: Equatable, Sendable {
    public let generation: UInt64
    public let status: OigoPlaybackPresentationStatus

    public init(generation: UInt64, status: OigoPlaybackPresentationStatus) {
        self.generation = generation
        self.status = status
    }
}

public enum OigoOnboardingPresentationStage: String, Equatable, Sendable {
    case welcome
    case microphone
    case test
    case ready
    case complete
}

public enum OigoOnboardingPresentationStatus: String, Equatable, Sendable {
    case notStarted
    case running
    case passed
    case copyOnlyAccepted
    case skipped
    case failed
}

public enum OigoOnboardingPresentationFailure: String, Equatable, Sendable {
    case storage
    case selectedSource
    case canonicalBuffer
    case shortcut
    case durableAudio
    case speech
    case cleanup
    case clipboard
    case targetValidation
    case pasteDispatch
    case destinationVerification
    case destinationUnavailable
}

public struct OigoOnboardingPresentationInput: Equatable, Sendable {
    public let stage: OigoOnboardingPresentationStage
    public let status: OigoOnboardingPresentationStatus
    public let failure: OigoOnboardingPresentationFailure?

    public init(
        stage: OigoOnboardingPresentationStage,
        status: OigoOnboardingPresentationStatus,
        failure: OigoOnboardingPresentationFailure?
    ) {
        self.stage = stage
        self.status = status
        self.failure = failure
    }
}

public enum OigoShutdownPresentationStatus: String, Equatable, Sendable {
    case inactive
    case requested
    case waiting
    case fenced
    case complete
}

public struct OigoShutdownPresentationInput: Equatable, Sendable {
    public let status: OigoShutdownPresentationStatus
    public let fencedOperationCount: Int

    public init(status: OigoShutdownPresentationStatus, fencedOperationCount: Int) {
        self.status = status
        self.fencedOperationCount = max(0, fencedOperationCount)
    }
}

public struct OigoPresentationInputs: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    public let generation: UInt64
    public let operationGate: OigoOperationGatePresentationInput
    public let coordinator: OigoCoordinatorPresentationInput
    public let storage: OigoStoragePresentationInput
    public let shortcut: OigoShortcutPresentationInput
    public let permissions: OigoPermissionsPresentationInput
    public let input: OigoInputPresentationInput
    public let localeAssets: OigoLocaleAssetsPresentationInput
    public let activeConfiguration: OigoDictationConfigurationPresentationInput?
    public let nextConfiguration: OigoDictationConfigurationPresentationInput
    public let terminal: OigoTerminalPresentationInput?
    public let latestSession: OigoLatestSessionPresentationInput?
    public let playback: OigoPlaybackPresentationInput
    public let onboarding: OigoOnboardingPresentationInput
    public let shutdown: OigoShutdownPresentationInput

    public init(
        generation: UInt64,
        operationGate: OigoOperationGatePresentationInput,
        coordinator: OigoCoordinatorPresentationInput,
        storage: OigoStoragePresentationInput,
        shortcut: OigoShortcutPresentationInput,
        permissions: OigoPermissionsPresentationInput,
        input: OigoInputPresentationInput,
        localeAssets: OigoLocaleAssetsPresentationInput,
        activeConfiguration: OigoDictationConfigurationPresentationInput?,
        nextConfiguration: OigoDictationConfigurationPresentationInput,
        terminal: OigoTerminalPresentationInput?,
        latestSession: OigoLatestSessionPresentationInput?,
        playback: OigoPlaybackPresentationInput,
        onboarding: OigoOnboardingPresentationInput,
        shutdown: OigoShutdownPresentationInput
    ) {
        self.generation = generation
        self.operationGate = operationGate
        self.coordinator = coordinator
        self.storage = storage
        self.shortcut = shortcut
        self.permissions = permissions
        self.input = input
        self.localeAssets = localeAssets
        self.activeConfiguration = activeConfiguration
        self.nextConfiguration = nextConfiguration
        self.terminal = terminal
        self.latestSession = latestSession
        self.playback = playback
        self.onboarding = onboarding
        self.shutdown = shutdown
    }

    public var sanitizedContractOutput: String {
        [
            "presentation-inputs-v1",
            "operation=" + operationCategory,
            "busy=" + busyCategory,
            "coordinator=" + coordinator.state.rawValue,
            "storage=" + storage.status.rawValue,
            "shortcut=" + shortcut.registration.rawValue,
            "microphone=" + permissions.microphone.rawValue,
            "accessibility=" + permissions.accessibility.rawValue,
            "input=" + input.selection.rawValue,
            "assets=" + localeAssets.status.rawValue,
            "active=" + (activeConfiguration?.appliesTo.rawValue ?? "none"),
            "next=" + nextConfiguration.appliesTo.rawValue,
            "terminal=" + (terminal?.outcome.rawValue ?? "none"),
            "latest=" + (latestSession?.state.rawValue ?? "none"),
            "playback=" + playback.status.rawValue,
            "onboarding=" + onboarding.status.rawValue,
            "shutdown=" + shutdown.status.rawValue
        ].joined(separator: "|")
    }

    public var description: String {
        sanitizedContractOutput
    }

    public var debugDescription: String {
        sanitizedContractOutput
    }

    private var operationCategory: String {
        operationGate.activeOperation?.kind.rawValue ?? "none"
    }

    private var busyCategory: String {
        switch operationGate.busyReason {
        case .shutdown:
            "shutdown"
        case .occupied(let kind):
            "occupied-" + kind.rawValue
        case nil:
            "none"
        }
    }
}
