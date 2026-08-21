import Foundation
import OigoPresentation

enum Task12PopoverFixture {
    static func presentation(rowNamed name: String) -> OigoPopoverPresentation {
        guard let row = OigoPresentationStateRow(rawValue: name) else {
            preconditionFailure("unknown Task 12 presentation row")
        }
        let value = inputs(for: row)
        return OigoPopoverPresentation.project(
            state: OigoPresentationState.project(value),
            inputs: value
        )
    }

    private static func inputs(for row: OigoPresentationStateRow) -> OigoPresentationInputs {
        var selectedInput: OigoInputSelectionPresentationStatus = .systemDefault
        var shortcut: OigoShortcutRegistrationPresentationStatus = .registered
        var permissions = OigoPermissionsPresentationInput(
            microphone: .granted,
            accessibility: .granted
        )
        var storage = OigoStoragePresentationInput(status: .ready)
        var assets = OigoLocaleAssetPresentationStatus.ready
        var coordinator = OigoCoordinatorPresentationState.idle
        var terminal: OigoTerminalPresentationInput?
        var latestHasTranscript = true
        var onboarding = OigoOnboardingPresentationInput(
            stage: .ready,
            status: .passed,
            failure: nil
        )
        var busyReason: OigoOperationBusyPresentationReason?
        var shutdown = OigoShutdownPresentationStatus.inactive

        switch row {
        case .storageChecking:
            storage = .init(status: .degraded)
        case .storageUnavailable:
            storage = .init(status: .unavailable)
        case .shortcutInactiveConflict:
            shortcut = .conflict
        case .microphonePermissionUnavailable:
            permissions = .init(microphone: .denied, accessibility: .granted)
        case .selectedInputUnavailable:
            selectedInput = .pinnedUnavailable
        case .languageAssetsCheckingInstalling:
            assets = .checking
        case .languageAssetsUnavailable:
            assets = .unavailable
        case .accessibilityUnavailable:
            permissions = .init(microphone: .granted, accessibility: .denied)
        case .preparing:
            coordinator = .preparing
        case .recording:
            coordinator = .recording
        case .finalizingCleaningInserting:
            coordinator = .finalizing
        case .pasteEventAttempted:
            coordinator = .complete
            terminal = .init(generation: 42, outcome: .pasteAttempted, failure: nil)
        case .pasteOwnedFieldVerified:
            coordinator = .complete
            terminal = .init(generation: 42, outcome: .pasted, failure: nil)
            onboarding = .init(stage: .test, status: .passed, failure: nil)
        case .copiedOnly:
            coordinator = .complete
            terminal = .init(generation: 42, outcome: .copied, failure: nil)
        case .cleanupFallback:
            coordinator = .complete
            terminal = .init(generation: 42, outcome: .cleanupFallback, failure: nil)
        case .insertionFailure:
            coordinator = .complete
            terminal = .init(generation: 42, outcome: .insertionFailed, failure: .insertion)
        case .retryRequired:
            coordinator = .complete
            terminal = .init(generation: 42, outcome: .retryRequired, failure: .transcription)
        case .cancelledBeforeDurableRaw:
            coordinator = .cancelled
            terminal = .init(generation: 42, outcome: .cancelled, failure: nil)
            latestHasTranscript = false
        case .cancelledAfterDurableRaw:
            coordinator = .cancelled
            terminal = .init(generation: 42, outcome: .cancelled, failure: nil)
        case .interrupted:
            coordinator = .interrupted
            terminal = .init(generation: 42, outcome: .interrupted, failure: nil)
        case .busyTypedReason:
            busyReason = .occupied(.retry)
        case .shuttingDown:
            shutdown = .requested
        case .storageReadyIdle:
            break
        }

        let locale = OigoLocaleIdentifier("en-US")!
        return OigoPresentationInputs(
            generation: 42,
            operationGate: .init(activeOperation: nil, busyReason: busyReason),
            coordinator: .init(state: coordinator, generation: 42),
            storage: storage,
            shortcut: .init(
                registration: shortcut,
                isConfigured: true,
                displayName: "⌥ Space"
            ),
            permissions: permissions,
            input: .init(selection: selectedInput, channelIndex: 0),
            localeAssets: .init(localeIdentifier: locale, status: assets, generation: 42),
            activeConfiguration: nil,
            nextConfiguration: .init(
                localeIdentifier: locale,
                input: selectedInput,
                channelIndex: 0,
                appliesTo: .next,
                mode: .clean
            ),
            terminal: terminal,
            latestSession: .init(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
                state: .complete,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                hasAudio: true,
                hasTranscript: latestHasTranscript,
                failure: nil,
                durationSeconds: 18,
                source: .clean
            ),
            playback: .init(generation: 42, status: .idle),
            onboarding: onboarding,
            shutdown: .init(status: shutdown, fencedOperationCount: 0),
            presentationDate: Date(timeIntervalSince1970: 1_700_000_120)
        )
    }
}
