extension OigoPresentationState {
    public static func project(_ inputs: OigoPresentationInputs) -> OigoPresentationState {
        let row = row(for: inputs)
        let terminal = terminal(for: row, inputs: inputs)
        return OigoPresentationState(
            row: row,
            menuMark: menuMark(for: row),
            status: status(for: row, coordinator: inputs.coordinator.state),
            primaryAction: primaryAction(for: row, inputs: inputs),
            context: context(for: row, inputs: inputs, terminal: terminal),
            notice: prioritizedNotice(for: row, inputs: inputs),
            latestSessionActions: latestActions(for: row),
            hud: hud(for: row),
            availability: availability(for: row),
            nextDictation: nextDictationNotice(inputs),
            copyOnly: copyOnlyPosture(for: row),
            terminal: terminal
        )
    }

    private static func row(for inputs: OigoPresentationInputs) -> OigoPresentationStateRow {
        if inputs.shutdown.status != .inactive || inputs.operationGate.busyReason == .shutdown {
            return .shuttingDown
        }
        if inputs.operationGate.busyReason != nil {
            return .busyTypedReason
        }
        switch inputs.storage.status {
        case .unavailable:
            return .storageUnavailable
        case .degraded:
            return .storageChecking
        case .ready:
            break
        }
        if inputs.permissions.microphone != .granted {
            return .microphonePermissionUnavailable
        }
        switch inputs.input.selection {
        case .pinnedUnavailable, .noAvailableInput:
            return .selectedInputUnavailable
        case .systemDefault, .pinnedAvailable:
            break
        }
        switch inputs.localeAssets.status {
        case .idle, .checking, .installing:
            return .languageAssetsCheckingInstalling
        case .failed, .unavailable, .unsupported:
            return .languageAssetsUnavailable
        case .ready:
            break
        }
        switch inputs.coordinator.state {
        case .preparing:
            return .preparing
        case .recording:
            return .recording
        case .finalizing, .cleaning, .inserting:
            return .finalizingCleaningInserting
        case .complete, .failed, .cancelled, .interrupted:
            if let terminalRow = currentTerminalRow(inputs) {
                return terminalRow
            }
        case .idle:
            break
        }
        if inputs.shortcut.registration != .registered || !inputs.shortcut.isConfigured {
            return .shortcutInactiveConflict
        }
        if inputs.permissions.accessibility != .granted {
            return .accessibilityUnavailable
        }
        return .storageReadyIdle
    }

    private static func currentTerminalRow(
        _ inputs: OigoPresentationInputs
    ) -> OigoPresentationStateRow? {
        guard let terminal = inputs.terminal,
              terminal.generation == inputs.generation else {
            return nil
        }
        switch terminal.outcome {
        case .completed, .pasteAttempted:
            return .pasteEventAttempted
        case .pasted:
            return inputs.onboarding.stage == .test && inputs.onboarding.status == .passed
                ? .pasteOwnedFieldVerified : .pasteEventAttempted
        case .copied:
            return .copiedOnly
        case .cleanupFallback:
            return .cleanupFallback
        case .insertionFailed:
            return .insertionFailure
        case .retryRequired:
            return .retryRequired
        case .cancelled:
            return inputs.latestSession?.hasTranscript == true
                ? .cancelledAfterDurableRaw : .cancelledBeforeDurableRaw
        case .interrupted:
            return .interrupted
        case .failed:
            return terminal.failure == .insertion ? .insertionFailure : .retryRequired
        }
    }

}
