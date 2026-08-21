import Foundation

public enum OigoPresentationStateRow: String, CaseIterable, Equatable, Sendable {
    case storageChecking = "storage-checking"
    case storageReadyIdle = "storage-ready-idle"
    case storageUnavailable = "storage-unavailable"
    case shortcutInactiveConflict = "shortcut-inactive-conflict"
    case microphonePermissionUnavailable = "mic-permission-unavailable"
    case selectedInputUnavailable = "selected-input-unavailable"
    case languageAssetsCheckingInstalling = "language-assets-checking-installing"
    case languageAssetsUnavailable = "language-assets-unavailable"
    case accessibilityUnavailable = "accessibility-unavailable"
    case preparing
    case recording
    case finalizingCleaningInserting = "finalizing-cleaning-inserting"
    case pasteEventAttempted = "paste-event-attempted"
    case pasteOwnedFieldVerified = "paste-owned-field-verified"
    case copiedOnly = "copied-only"
    case cleanupFallback = "cleanup-fallback"
    case insertionFailure = "insertion-failure"
    case retryRequired = "retry-required"
    case cancelledBeforeDurableRaw = "cancelled-before-durable-raw"
    case cancelledAfterDurableRaw = "cancelled-after-durable-raw"
    case interrupted
    case busyTypedReason = "busy-typed-reason"
    case shuttingDown = "shutting-down"
}

public enum OigoMenuMark: String, Equatable, Sendable {
    case outline
    case activity
    case recording
    case attention
    case hidden
}

public enum OigoPresentationStatus: String, Equatable, Sendable {
    case checking
    case ready
    case readyCopyOnly = "ready-copy-only"
    case attentionNeeded = "attention-needed"
    case preparing
    case recording
    case finalizing
    case cleaning
    case inserting
    case busy
    case quitting
}

public enum OigoPresentationAction: Equatable, Sendable {
    case startDictation
    case stopDictation
    case retryStorage
    case retryTranscription
    case chooseInput
    case installAssets
    case openSettings
    case openSystemSettings(URL)
    case setMode(OigoProcessingModePresentationValue)
    case openDataLocation
    case copy
    case pasteAgain
    case openHistory
    case quit

    var category: String {
        switch self {
        case .startDictation: "start-dictation"
        case .stopDictation: "stop-dictation"
        case .retryStorage: "retry-storage"
        case .retryTranscription: "retry-transcription"
        case .chooseInput: "choose-input"
        case .installAssets: "install-assets"
        case .openSettings: "open-settings"
        case .openSystemSettings: "open-system-settings"
        case .setMode(let mode): "set-mode-" + mode.rawValue
        case .openDataLocation: "open-data-location"
        case .copy: "copy"
        case .pasteAgain: "paste-again"
        case .openHistory: "open-history"
        case .quit: "quit"
        }
    }
}

public enum OigoActionDisabledReason: Equatable, Sendable {
    case checking
    case storageUnavailable
    case microphoneUnavailable
    case selectedInputUnavailable
    case languageAssetsUnavailable
    case busy(OigoOperationBusyPresentationReason)
    case shuttingDown

    var category: String {
        switch self {
        case .checking: "checking"
        case .storageUnavailable: "storage-unavailable"
        case .microphoneUnavailable: "microphone-unavailable"
        case .selectedInputUnavailable: "selected-input-unavailable"
        case .languageAssetsUnavailable: "language-assets-unavailable"
        case .busy(.shutdown): "busy-shutdown"
        case .busy(.occupied(let kind)): "busy-" + kind.rawValue
        case .shuttingDown: "shutting-down"
        }
    }
}

public enum OigoPrimaryPresentationAction: Equatable, Sendable {
    case enabled(OigoPresentationAction)
    case disabled(OigoPresentationAction?, OigoActionDisabledReason)

    var category: String {
        switch self {
        case .enabled(let action): "enabled-" + action.category
        case .disabled(let action, let reason):
            "disabled-" + (action?.category ?? "none") + "-" + reason.category
        }
    }
}

public enum OigoPresentationContext: Equatable, Sendable {
    case readiness
    case active(OigoCoordinatorPresentationState)
    case terminal(OigoTerminalPresentationClass)
    case busy(OigoOperationBusyPresentationReason)
    case shutdown
}

public enum OigoNotice: Equatable, Sendable {
    case storageCritical
    case microphonePermission
    case selectedInput
    case languageAssets
    case retryRequired
    case interruption
    case shortcutConflict
    case accessibilityCopyOnly

    public var category: String {
        switch self {
        case .storageCritical: "storage-critical"
        case .microphonePermission: "microphone-permission"
        case .selectedInput: "selected-input"
        case .languageAssets: "language-assets"
        case .retryRequired: "retry-required"
        case .interruption: "interruption"
        case .shortcutConflict: "shortcut-conflict"
        case .accessibilityCopyOnly: "accessibility-copy-only"
        }
    }
}

public enum OigoLatestSessionAction: String, Equatable, Sendable {
    case retryTranscription
    case copy
    case pasteAgain
    case openHistory
}

public struct OigoBoundedLatestSessionActions: Equatable, Sendable {
    public let primary: OigoLatestSessionAction?
    public let secondary: OigoLatestSessionAction?

    public init(
        primary: OigoLatestSessionAction? = nil,
        secondary: OigoLatestSessionAction? = nil
    ) {
        self.primary = primary
        self.secondary = secondary == primary ? nil : secondary
    }

    var category: String {
        [primary?.rawValue, secondary?.rawValue].compactMap { $0 }.joined(separator: "+")
    }
}

public enum OigoHUDPolicy: String, Equatable, Sendable {
    case hidden
    case preparing
    case recording
    case processing
    case pasteAttempted
    case ownedFieldVerified
    case copied
    case cleanupFallback
    case insertionFailure
    case retryRequired
    case cancelled
    case interrupted
    case released
}

public struct OigoPresentationAvailability: Equatable, Sendable {
    public let initiatorsEnabled: Bool
    public let commandsEnabled: Bool
    public let windowsEnabled: Bool

    public init(initiatorsEnabled: Bool, commandsEnabled: Bool, windowsEnabled: Bool) {
        self.initiatorsEnabled = initiatorsEnabled
        self.commandsEnabled = commandsEnabled
        self.windowsEnabled = windowsEnabled
    }
}

public enum OigoNextDictationNotice: String, Equatable, Sendable {
    case none
    case configurationPending
    case pinnedInputUnavailable
}

public enum OigoCopyOnlyPosture: String, Equatable, Sendable {
    case inactive
    case ready
    case copied
}

public enum OigoCancellationPresentationClass: String, Equatable, Sendable {
    case beforeDurableRaw
    case afterDurableRaw
}

public enum OigoTerminalPresentationClass: Equatable, Sendable {
    case pasteAttempted
    case ownedFieldVerified
    case copied
    case cleanupFallback
    case insertionFailure
    case retryRequired
    case cancellation(OigoCancellationPresentationClass)
    case interruption
    case busy(OigoOperationBusyPresentationReason)
    case shutdown

    var category: String {
        switch self {
        case .pasteAttempted: "paste-attempted"
        case .ownedFieldVerified: "owned-field-verified"
        case .copied: "copied"
        case .cleanupFallback: "cleanup-fallback"
        case .insertionFailure: "insertion-failure"
        case .retryRequired: "retry-required"
        case .cancellation(.beforeDurableRaw): "cancelled-before-durable-raw"
        case .cancellation(.afterDurableRaw): "cancelled-after-durable-raw"
        case .interruption: "interruption"
        case .busy(.shutdown): "busy-shutdown"
        case .busy(.occupied(let kind)): "busy-" + kind.rawValue
        case .shutdown: "shutdown"
        }
    }
}

public struct OigoPresentationState: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    public let row: OigoPresentationStateRow
    public let menuMark: OigoMenuMark
    public let status: OigoPresentationStatus
    public let primaryAction: OigoPrimaryPresentationAction
    public let context: OigoPresentationContext
    public let notice: OigoNotice?
    public let latestSessionActions: OigoBoundedLatestSessionActions
    public let hud: OigoHUDPolicy
    public let availability: OigoPresentationAvailability
    public let nextDictation: OigoNextDictationNotice
    public let copyOnly: OigoCopyOnlyPosture
    public let terminal: OigoTerminalPresentationClass?

    public var sanitizedDescription: String {
        [
            "presentation-state-v1", "row=" + row.rawValue, "mark=" + menuMark.rawValue,
            "status=" + status.rawValue, "primary=" + primaryAction.category,
            "notice=" + (notice?.category ?? "none"),
            "actions=" + (latestSessionActions.category.isEmpty ? "none" : latestSessionActions.category),
            "hud=" + hud.rawValue,
            "initiators=" + (availability.initiatorsEnabled ? "enabled" : "disabled"),
            "commands=" + (availability.commandsEnabled ? "enabled" : "disabled"),
            "windows=" + (availability.windowsEnabled ? "enabled" : "disabled"),
            "next=" + nextDictation.rawValue, "copy-only=" + copyOnly.rawValue,
            "terminal=" + (terminal?.category ?? "none")
        ].joined(separator: "|")
    }

    public var description: String { sanitizedDescription }
    public var debugDescription: String { sanitizedDescription }
}
