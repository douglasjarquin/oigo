extension OigoPresentationState {
    static func menuMark(for row: OigoPresentationStateRow) -> OigoMenuMark {
        switch row {
        case .recording:
            return .recording
        case .preparing, .finalizingCleaningInserting, .busyTypedReason:
            return .activity
        case .storageUnavailable, .shortcutInactiveConflict, .microphonePermissionUnavailable,
             .selectedInputUnavailable, .languageAssetsUnavailable, .retryRequired, .interrupted:
            return .attention
        case .pasteOwnedFieldVerified:
            return .hidden
        default:
            return .outline
        }
    }

    static func status(
        for row: OigoPresentationStateRow,
        coordinator: OigoCoordinatorPresentationState
    ) -> OigoPresentationStatus {
        switch row {
        case .storageChecking, .languageAssetsCheckingInstalling: return .checking
        case .storageUnavailable, .shortcutInactiveConflict, .microphonePermissionUnavailable,
             .selectedInputUnavailable, .languageAssetsUnavailable, .retryRequired, .interrupted:
            return .attentionNeeded
        case .accessibilityUnavailable: return .readyCopyOnly
        case .preparing: return .preparing
        case .recording: return .recording
        case .finalizingCleaningInserting:
            switch coordinator {
            case .cleaning: return .cleaning
            case .inserting: return .inserting
            default: return .finalizing
            }
        case .busyTypedReason: return .busy
        case .shuttingDown: return .quitting
        default: return .ready
        }
    }

    static func primaryAction(
        for row: OigoPresentationStateRow,
        inputs: OigoPresentationInputs
    ) -> OigoPrimaryPresentationAction {
        switch row {
        case .storageReadyIdle, .shortcutInactiveConflict, .accessibilityUnavailable,
             .pasteEventAttempted, .copiedOnly, .cleanupFallback,
             .insertionFailure, .cancelledBeforeDurableRaw, .cancelledAfterDurableRaw, .interrupted:
            return .enabled(.startDictation)
        case .recording:
            return .enabled(.stopDictation)
        case .storageUnavailable:
            return .enabled(.retryStorage)
        case .retryRequired:
            return .enabled(.retryTranscription)
        case .storageChecking, .languageAssetsCheckingInstalling, .finalizingCleaningInserting,
             .pasteOwnedFieldVerified:
            return .disabled(nil, .checking)
        case .preparing:
            return .enabled(.stopDictation)
        case .microphonePermissionUnavailable:
            return .disabled(.startDictation, .microphoneUnavailable)
        case .selectedInputUnavailable:
            return .disabled(.startDictation, .selectedInputUnavailable)
        case .languageAssetsUnavailable:
            return .disabled(.startDictation, .languageAssetsUnavailable)
        case .busyTypedReason:
            return .disabled(nil, .busy(inputs.operationGate.busyReason ?? .occupied(.maintenance)))
        case .shuttingDown:
            return .disabled(nil, .shuttingDown)
        }
    }

    static func context(
        for row: OigoPresentationStateRow,
        inputs: OigoPresentationInputs,
        terminal: OigoTerminalPresentationClass?
    ) -> OigoPresentationContext {
        if let terminal { return .terminal(terminal) }
        switch row {
        case .preparing, .recording, .finalizingCleaningInserting:
            return .active(inputs.coordinator.state)
        case .busyTypedReason:
            return .busy(inputs.operationGate.busyReason ?? .occupied(.maintenance))
        case .shuttingDown:
            return .shutdown
        default:
            return .readiness
        }
    }

    static func prioritizedNotice(
        for row: OigoPresentationStateRow,
        inputs: OigoPresentationInputs
    ) -> OigoNotice? {
        if inputs.storage.status == .unavailable { return .storageCritical }
        if inputs.permissions.microphone != .granted { return .microphonePermission }
        if inputs.input.selection == .pinnedUnavailable || inputs.input.selection == .noAvailableInput {
            return .selectedInput
        }
        if [.failed, .unavailable, .unsupported].contains(inputs.localeAssets.status) {
            return .languageAssets
        }
        if row == .retryRequired { return .retryRequired }
        if row == .interrupted { return .interruption }
        if inputs.shortcut.registration != .registered || !inputs.shortcut.isConfigured {
            return .shortcutConflict
        }
        if inputs.permissions.accessibility != .granted { return .accessibilityCopyOnly }
        return nil
    }

    static func latestActions(
        for row: OigoPresentationStateRow
    ) -> OigoBoundedLatestSessionActions {
        switch row {
        case .copiedOnly: return .init(primary: .pasteAgain, secondary: .openHistory)
        case .cleanupFallback: return .init(primary: .openHistory)
        case .insertionFailure: return .init(primary: .copy, secondary: .pasteAgain)
        case .retryRequired: return .init(primary: .retryTranscription, secondary: .openHistory)
        case .cancelledAfterDurableRaw, .interrupted: return .init(primary: .openHistory)
        default: return .init()
        }
    }

    static func hud(for row: OigoPresentationStateRow) -> OigoHUDPolicy {
        switch row {
        case .preparing: return .preparing
        case .recording: return .recording
        case .finalizingCleaningInserting, .busyTypedReason: return .processing
        case .pasteEventAttempted: return .pasteAttempted
        case .pasteOwnedFieldVerified: return .ownedFieldVerified
        case .copiedOnly: return .copied
        case .cleanupFallback: return .cleanupFallback
        case .insertionFailure: return .insertionFailure
        case .retryRequired: return .retryRequired
        case .cancelledBeforeDurableRaw, .cancelledAfterDurableRaw: return .cancelled
        case .interrupted: return .interrupted
        case .shuttingDown: return .released
        default: return .hidden
        }
    }

    static func availability(
        for row: OigoPresentationStateRow
    ) -> OigoPresentationAvailability {
        switch row {
        case .busyTypedReason:
            return .init(initiatorsEnabled: false, commandsEnabled: false, windowsEnabled: true)
        case .shuttingDown:
            return .init(initiatorsEnabled: false, commandsEnabled: false, windowsEnabled: false)
        case .storageChecking, .microphonePermissionUnavailable, .selectedInputUnavailable,
             .languageAssetsCheckingInstalling, .languageAssetsUnavailable, .preparing,
             .finalizingCleaningInserting:
            return .init(initiatorsEnabled: false, commandsEnabled: true, windowsEnabled: true)
        default:
            return .init(initiatorsEnabled: true, commandsEnabled: true, windowsEnabled: true)
        }
    }

    static func nextDictationNotice(
        _ inputs: OigoPresentationInputs
    ) -> OigoNextDictationNotice {
        if inputs.nextConfiguration.input == .pinnedUnavailable {
            return .pinnedInputUnavailable
        }
        guard let active = inputs.activeConfiguration else {
            return .configurationPending
        }
        return active.localeIdentifier == inputs.nextConfiguration.localeIdentifier
            && active.input == inputs.nextConfiguration.input
            && active.channelIndex == inputs.nextConfiguration.channelIndex
            ? .none : .configurationPending
    }

    static func copyOnlyPosture(
        for row: OigoPresentationStateRow
    ) -> OigoCopyOnlyPosture {
        switch row {
        case .accessibilityUnavailable: return .ready
        case .copiedOnly: return .copied
        default: return .inactive
        }
    }

    static func terminal(
        for row: OigoPresentationStateRow,
        inputs: OigoPresentationInputs
    ) -> OigoTerminalPresentationClass? {
        switch row {
        case .pasteEventAttempted: return .pasteAttempted
        case .pasteOwnedFieldVerified: return .ownedFieldVerified
        case .copiedOnly: return .copied
        case .cleanupFallback: return .cleanupFallback
        case .insertionFailure: return .insertionFailure
        case .retryRequired: return .retryRequired
        case .cancelledBeforeDurableRaw: return .cancellation(.beforeDurableRaw)
        case .cancelledAfterDurableRaw: return .cancellation(.afterDurableRaw)
        case .interrupted: return .interruption
        case .busyTypedReason:
            return .busy(inputs.operationGate.busyReason ?? .occupied(.maintenance))
        case .shuttingDown: return .shutdown
        default: return nil
        }
    }
}
