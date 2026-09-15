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
    var sourceProbeStopCount: Int { callbackState.sourceProbeStopCount }
    var testStopCount: Int { callbackState.testStopCount }
    var testCancelCount: Int { callbackState.testCancelCount }
    var completeCallbackCount: Int { callbackState.completeCallbackCount }
    var assetRequestLocales: [String] { callbackState.assetRequestLocales }
    var assetCompletionCount: Int { callbackState.assetCompletionCount }
    var microphoneSettingsCount: Int { callbackState.microphoneSettingsCount }

    private final class CallbackState {
        var closeCallbackCount = 0
        var sourceProbeGenerations: [UInt64] = []
        var testGenerations: [UInt64] = []
        var sourceProbeStopCount = 0
        var testStopCount = 0
        var testCancelCount = 0
        var completeCallbackCount = 0
        var assetRequestLocales: [String] = []
        var assetCompletionCount = 0
        var microphoneSettingsCount = 0
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
            callbacks: callbacks,
            loadSupportedLanguages: { ["en-US", "es-MX"] },
            checkSpeechAssets: { _ in .ready }
        )
    }

    func makeController(
        initialStep: OigoOnboardingStep,
        microphoneState: OigoPermissionState = .granted,
        accessibilityState: OigoPermissionState = .granted,
        storageHealth: DurableSessionHealth? = nil,
        loadSupportedLanguages: @escaping () async -> [String] = { ["en-US", "es-MX"] },
        checkSpeechAssets: @escaping (String) async -> OigoLocaleAssetStatus = { _ in .ready }
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
            callbacks: callbackState,
            loadSupportedLanguages: loadSupportedLanguages,
            checkSpeechAssets: checkSpeechAssets
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
        callbacks: CallbackState,
        loadSupportedLanguages: @escaping () async -> [String],
        checkSpeechAssets: @escaping (String) async -> OigoLocaleAssetStatus
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
            loadSupportedLanguages: loadSupportedLanguages,
            checkSpeechAssets: { identifier in
                callbacks.assetRequestLocales.append(identifier)
                let result = await checkSpeechAssets(identifier)
                callbacks.assetCompletionCount += 1
                return result
            },
            saveLanguage: { [settingsStore] identifier in
                try? settingsStore.save(settingsStore.load().with(localeIdentifier: identifier))
            },
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
            openMicrophoneSettings: {
                callbacks.microphoneSettingsCount += 1
            },
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
            stopSourceProbe: {
                callbacks.sourceProbeStopCount += 1
            },
            startTest: { generation in
                callbacks.testGenerations.append(generation)
            },
            stopTest: {
                callbacks.testStopCount += 1
            },
            cancelTest: {
                callbacks.testCancelCount += 1
            },
            openHistory: {},
            onComplete: {
                callbacks.completeCallbackCount += 1
                onboardingStore.markCompleted()
            },
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
