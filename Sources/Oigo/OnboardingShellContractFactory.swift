import AppKit
import OigoCore
import OigoHotKey

@available(macOS 26.0, *)
@MainActor
final class OnboardingShellContractFactory {
    let settingsStore: OigoSettingsStore
    let onboardingStore: OigoOnboardingStore
    let controller: OnboardingWindowController
    private let callbackState: CallbackState

    var closeCallbackCount: Int { callbackState.closeCallbackCount }
    var sourceProbeGenerations: [UInt64] { callbackState.sourceProbeGenerations }
    var testGenerations: [UInt64] { callbackState.testGenerations }

    private final class CallbackState {
        var closeCallbackCount = 0
        var sourceProbeGenerations: [UInt64] = []
        var testGenerations: [UInt64] = []
    }

    init(defaultsSuite: String) throws {
        guard let defaults = UserDefaults(suiteName: defaultsSuite) else {
            throw ContractFactoryError.defaultsUnavailable
        }
        defaults.removePersistentDomain(forName: defaultsSuite)
        settingsStore = OigoSettingsStore(defaults: defaults)
        onboardingStore = OigoOnboardingStore(defaults: defaults)
        let callbacks = CallbackState()
        callbackState = callbacks
        let committedShortcut = ToggleShortcut(
            keyCode: 13,
            modifiers: ToggleShortcutModifiers.command
        )
        try settingsStore.save(OigoSettings.default.with(
            globalShortcut: committedShortcut,
            localeIdentifier: "en-US"
        ))
        controller = Self.buildController(
            support: .init(isSupported: true, reason: "This Mac is supported"),
            initialStep: .system,
            processingMode: .instant,
            globalShortcut: committedShortcut,
            inputDevices: [],
            selectedInput: .systemDefault,
            selectedInputChannel: 0,
            committedLocaleIdentifier: "en-US",
            microphoneState: .granted,
            accessibilityState: .granted,
            storageHealth: .ready(.init(
                recoveredSessionCount: 0,
                historyEntryCount: 0,
                malformedSessionCount: 0
            )),
            settingsStore: settingsStore,
            onboardingStore: onboardingStore,
            callbacks: callbacks
        )
    }

    func makeController(
        initialStep: OigoOnboardingStep,
        microphoneState: OigoPermissionState = .granted,
        accessibilityState: OigoPermissionState = .granted,
        storageHealth: DurableSessionHealth? = nil
    ) -> OnboardingWindowController {
        Self.buildController(
            support: .init(isSupported: true, reason: "This Mac is supported"),
            initialStep: initialStep,
            processingMode: .instant,
            globalShortcut: settingsStore.load().globalShortcut,
            inputDevices: [],
            selectedInput: .systemDefault,
            selectedInputChannel: 0,
            committedLocaleIdentifier: settingsStore.load().localeIdentifier,
            microphoneState: microphoneState,
            accessibilityState: accessibilityState,
            storageHealth: storageHealth ?? .ready(.init(
                recoveredSessionCount: 0,
                historyEntryCount: 0,
                malformedSessionCount: 0
            )),
            settingsStore: settingsStore,
            onboardingStore: onboardingStore,
            callbacks: callbackState
        )
    }

    private static func buildController(
        support: OigoSystemSupportResult,
        initialStep: OigoOnboardingStep,
        processingMode: OigoProcessingMode,
        globalShortcut: ToggleShortcut,
        inputDevices: [OigoInputDevice],
        selectedInput: OigoInputSelection,
        selectedInputChannel: Int,
        committedLocaleIdentifier: String,
        microphoneState: OigoPermissionState,
        accessibilityState: OigoPermissionState,
        storageHealth: DurableSessionHealth,
        settingsStore: OigoSettingsStore,
        onboardingStore: OigoOnboardingStore,
        callbacks: CallbackState
    ) -> OnboardingWindowController {
        OnboardingWindowController(
            support: support,
            initialStep: initialStep,
            processingMode: processingMode,
            globalShortcut: globalShortcut,
            inputDevices: inputDevices,
            selectedInput: selectedInput,
            selectedInputChannel: selectedInputChannel,
            committedLocaleIdentifier: committedLocaleIdentifier,
            microphoneState: microphoneState,
            accessibilityState: accessibilityState,
            storageHealth: storageHealth,
            loadSupportedLanguages: { ["en-US"] },
            checkSpeechAssets: { _ in .ready },
            saveLanguage: { _ in },
            saveStep: { [onboardingStore] step, copyOnlyAccepted in
                onboardingStore.save(OigoOnboardingState(
                    step: step,
                    copyOnlyAccepted: copyOnlyAccepted
                ))
            },
            saveInputSelection: { [settingsStore] selection, channel in
                let settings = settingsStore.load().with(
                    selectedInput: selection,
                    selectedInputChannel: channel
                )
                try? settingsStore.save(settings)
            },
            requestMicrophone: { microphoneState },
            openMicrophoneSettings: {},
            registrationStatus: {
                .inactive("Global shortcut registration is waiting for setup")
            },
            registrationError: { nil },
            validateShortcut: { _ in .available },
            saveShortcut: { [settingsStore] shortcut in
                let settings = settingsStore.load().with(globalShortcut: shortcut)
                do {
                    try settingsStore.save(settings)
                    return .available
                } catch {
                    return .invalid("Settings could not be saved")
                }
            },
            requestAccessibility: { accessibilityState },
            openAccessibilitySettings: {},
            retryStorage: {},
            openDataLocation: {},
            startSourceProbe: { _, _, generation in
                callbacks.sourceProbeGenerations.append(generation)
            },
            stopSourceProbe: {},
            startTest: { generation in
                callbacks.testGenerations.append(generation)
            },
            stopTest: {},
            cancelTest: {},
            openHistory: {},
            onComplete: {},
            onClose: {
                callbacks.closeCallbackCount += 1
            }
        )
    }

    func resetDefaults() {
        onboardingStore.rerun()
        controller.window?.close()
    }
}

enum ContractFactoryError: Error {
    case defaultsUnavailable
}
