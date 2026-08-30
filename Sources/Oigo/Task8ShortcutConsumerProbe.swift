import AppKit
import Foundation
import OigoCore
import OigoHotKey

struct Task8ControlObservation: Codable {
    let status: String
    let hint: String
    let recorderDisplay: String
    let recorderAccessibilityValue: String
}

struct Task8HUDObservation: Codable {
    let title: String
    let detail: String
    let accessibilityLabel: String
    let visible: Bool
}

struct Task8StatusObservation: Codable {
    let title: String
    let toolTip: String
    let menuTitle: String
    let accessibilityLabel: String
}

struct Task8ShortcutConsumerReceipt: Codable {
    let shortcut: ToggleShortcut
    let hud: Task8HUDObservation
    let onboardingActive: Task8ControlObservation
    let onboardingConflict: Task8ControlObservation
    let settingsActive: Task8ControlObservation
    let settingsConflict: Task8ControlObservation
    let statusActive: Task8StatusObservation
    let statusError: Task8StatusObservation
    let statusConflict: Task8StatusObservation
}

@MainActor
enum Task8ShortcutConsumerProbe {
    static func run(fixtureURL: URL, outputURL: URL) throws {
        let shortcut = try JSONDecoder().decode(
            Task8ShortcutFixture.self,
            from: Data(contentsOf: fixtureURL)
        ).shortcut
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)

        let hudController = OigoHUDController()
        guard hudController.present(
            .recording,
            generation: 8,
            shortcutReleaseHint: shortcut.copy.releaseHint
        ) else {
            throw Task8ProbeError.hudRenderFailed
        }
        let renderedHUD = hudController.task8ShortcutObservation()
        let hud = Task8HUDObservation(
            title: renderedHUD.title,
            detail: renderedHUD.detail,
            accessibilityLabel: renderedHUD.accessibilityLabel,
            visible: renderedHUD.visible
        )
        hudController.shutdown()

        let receipt = Task8ShortcutConsumerReceipt(
            shortcut: shortcut,
            hud: hud,
            onboardingActive: makeOnboarding(shortcut: shortcut, status: .active(shortcut, generation: 8)).task8ShortcutObservation(),
            onboardingConflict: makeOnboarding(shortcut: shortcut, status: .inactive("Shortcut conflicts with another app")).task8ShortcutObservation(),
            settingsActive: makeSettings(shortcut: shortcut, status: .active(shortcut, generation: 8)).task8ShortcutObservation(),
            settingsConflict: makeSettings(shortcut: shortcut, status: .inactive("Shortcut conflicts with another app")).task8ShortcutObservation(),
            statusActive: OigoAppDelegate.task8StatusObservation(
                status: .active(shortcut, generation: 8), shortcut: shortcut, error: nil
            ),
            statusError: OigoAppDelegate.task8StatusObservation(
                status: .active(shortcut, generation: 8), shortcut: shortcut, error: "Synthetic registration warning"
            ),
            statusConflict: OigoAppDelegate.task8StatusObservation(
                status: .inactive("Shortcut conflicts with another app"), shortcut: shortcut, error: nil
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(receipt).write(to: outputURL, options: .atomic)
        print("PASS task-8-consumer-probe display=" + shortcut.copy.displayName)
    }

    private static func makeSettings(
        shortcut: ToggleShortcut,
        status: GlobalShortcutRegistrationStatus
    ) -> SettingsWindowController {
        SettingsWindowController(
            settings: OigoSettings(globalShortcut: shortcut, localeIdentifier: "en-US"),
            inputDevices: [], supportedLocales: ["en-US"], loadSupportedLocales: { ["en-US"] },
            microphoneState: .granted, accessibilityState: .granted, storageHealth: .checking,
            launchAtLoginStatus: .disabled, launchAtLoginStatusProvider: { .disabled },
            openLoginItemsSettings: {}, registrationStatus: { status }, registrationError: { nil },
            save: { _ in nil }, checkSpeechAssets: { _ in .ready },
            refreshPermissions: { (.granted, .granted) }, openMicrophoneSettings: {},
            openAccessibilitySettings: {}, rerunOnboarding: {}, openHistory: {}, openDataFolder: {},
            retryStorage: {}, deleteAllHistory: {}, exportDiagnostics: { Data() },
            dictionaryDocument: .empty, saveDictionary: { _ in nil }, previewDictionary: { $0 },
            addStarterTerms: { (.empty, nil) }, isPresented: { true }, onClose: {}
        )
    }

    private static func makeOnboarding(
        shortcut: ToggleShortcut,
        status: GlobalShortcutRegistrationStatus
    ) -> OnboardingWindowController {
        OnboardingWindowController(
            support: .init(isSupported: true, reason: "This Mac is supported"),
            initialStep: .shortcut, processingMode: .instant, globalShortcut: shortcut,
            inputDevices: [], selectedInput: .systemDefault, selectedInputChannel: 0,
            committedLocaleIdentifier: "en-US", microphoneState: .granted,
            accessibilityState: .granted, storageHealth: .checking,
            loadSupportedLanguages: { ["en-US"] }, checkSpeechAssets: { _ in .ready },
            saveLanguage: { _ in }, saveStep: { _, _ in }, saveInputSelection: { _, _ in },
            requestMicrophone: { .granted }, openMicrophoneSettings: {}, registrationStatus: { status },
            registrationError: { nil }, validateShortcut: { _ in .available },
            saveShortcut: { _ in .available }, requestAccessibility: { .granted },
            openAccessibilitySettings: {}, retryStorage: {}, openDataLocation: {},
            startSourceProbe: { _, _, _ in }, stopSourceProbe: {}, startTest: { _ in },
            stopTest: {}, cancelTest: {}, openHistory: {}, onComplete: {}, onClose: {}
        )
    }
}

private struct Task8ShortcutFixture: Decodable {
    let shortcut: ToggleShortcut
}

private enum Task8ProbeError: Error {
    case hudRenderFailed
}
