import Foundation
import OigoCore
import OigoTranscription

private struct ContractFailure: Error, CustomStringConvertible {
    let message: String

    var description: String { message }
}

@main
@MainActor
private struct OigoIssue9ContractTests {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let suite: String? = if let index = arguments.firstIndex(of: "--suite"),
                                 arguments.indices.contains(index + 1) {
            arguments[index + 1]
        } else {
            nil
        }

        let suites: [(String, () async throws -> Void)] = [
            ("lifecycle", testLifecycle),
            ("setup", testSetup),
            ("settings", testSettings),
            ("hud", testHUD),
            ("history", testHistory)
        ]
        let selected = suites.filter { suite == nil || suite == $0.0 }
        guard !selected.isEmpty else {
            print("FAIL: unknown issue #9 suite")
            exit(1)
        }

        var failures = 0
        for (name, test) in selected {
            do {
                try await test()
                print("GREEN: issue #9 " + name)
            } catch {
                failures += 1
                print("FAIL: issue #9 " + name + ": " + String(describing: error))
            }
        }

        if failures == 0 {
            print("GREEN: all issue #9 contract suites")
            exit(0)
        }
        print("FAILURES=" + String(failures))
        exit(1)
    }

    private static func testLifecycle() throws {
        let supported = OigoSystemSupportEvaluator.evaluate(
            osVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0),
            architecture: .appleSilicon
        )
        guard supported.isSupported else {
            throw ContractFailure(message: "supported macOS 26 Apple silicon was rejected")
        }

        let unsupported = OigoSystemSupportEvaluator.evaluate(
            osVersion: OperatingSystemVersion(majorVersion: 25, minorVersion: 6, patchVersion: 0),
            architecture: .intel
        )
        guard !unsupported.isSupported,
              unsupported.reason.contains("macOS 26") else {
            throw ContractFailure(message: "unsupported system did not fail before setup")
        }

        let suiteName = "oigo-issue9-lifecycle-" + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw ContractFailure(message: "could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = OigoSettingsStore(defaults: defaults)
        let before = settings.load()
        settings.save(before.with(showVolatilePreview: false))
        let reloaded = OigoSettingsStore(defaults: defaults).load()
        guard reloaded.showVolatilePreview == false,
              reloaded.globalShortcut == before.globalShortcut else {
            throw ContractFailure(message: "settings did not persist without a restart")
        }

        let onboarding = OigoOnboardingStore(defaults: defaults)
        onboarding.markCompleted()
        guard onboarding.load().isComplete else {
            throw ContractFailure(message: "onboarding completion was not persisted")
        }
        onboarding.rerun()
        guard !onboarding.load().isComplete,
              OigoSettingsStore(defaults: defaults).load().globalShortcut == before.globalShortcut else {
            throw ContractFailure(message: "rerunning onboarding erased settings")
        }
    }

    private static func testSetup() async throws {
        let resolved = OigoSupportedLocaleResolver.closest(
            to: "en-AU",
            among: ["fr-FR", "en-GB", "de-DE"]
        )
        guard resolved == "en-GB" else {
            throw ContractFailure(message: "supported locale resolver did not choose the closest language")
        }

        guard SpeechAssetState.unavailable("missing").description.contains("unavailable"),
              SpeechAssetState.installing("en-US").description.contains("installing"),
              SpeechAssetState.failed("download failed").description.contains("failed"),
              SpeechAssetState.ready("en-US").description.contains("ready") else {
            throw ContractFailure(message: "speech asset state did not expose all onboarding states")
        }

        let microphone = OigoPermissionPresentation.microphone(.denied)
        let accessibility = OigoPermissionPresentation.accessibility(.denied)
        guard !microphone.explanation.isEmpty,
              microphone.settingsURL.absoluteString.contains("Microphone"),
              !accessibility.explanation.isEmpty,
              accessibility.settingsURL.absoluteString.contains("Accessibility"),
              accessibility.allowsCopyOnly else {
            throw ContractFailure(message: "permission denial did not retain contextual recovery and copy-only behavior")
        }

        let shortcut = ToggleShortcut.default
        guard OigoShortcutValidator.validate(shortcut, occupied: []).isAvailable,
              OigoShortcutValidator.validate(shortcut, occupied: [shortcut]).isConflict else {
            throw ContractFailure(message: "shortcut conflict was silently accepted")
        }
        guard OigoProcessingMode.instant.supportsDictationWithoutFoundationModels else {
            throw ContractFailure(message: "Instant mode incorrectly requires Foundation Models")
        }
    }

    private static func testSettings() throws {
        let suiteName = "oigo-issue9-settings-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = OigoSettingsStore(defaults: defaults)
        let original = store.load()
        let updated = original.with(
            defaultMode: .clean,
            audioRetention: .oneWeek,
            keepSuccessfulAudioIndefinitely: true,
            launchAtLogin: true
        )
        store.save(updated)
        guard OigoSettingsStore(defaults: defaults).load() == updated else {
            throw ContractFailure(message: "minimal settings did not round-trip")
        }
        guard OigoLaunchAtLoginImplementation.publicMainAppService.rawValue == "SMAppService.mainApp",
              !OigoLaunchAtLoginImplementation.publicMainAppService.usesHelperProcess else {
            throw ContractFailure(message: "launch at login did not use the public main-app service")
        }

        let client = RecordingLaunchAtLoginClient()
        let controller = OigoLaunchAtLoginController(client: client)
        try controller.setEnabled(true)
        guard client.registerCount == 1, controller.isEnabled else {
            throw ContractFailure(message: "launch-at-login enable did not call the public service")
        }
    }

    private static func testHUD() throws {
        let text = "first line\nsecond line\nthird line\n" + String(repeating: "x", count: 300)
        let bounded = OigoHUDPreviewPolicy.bounded(text)
        guard bounded.count <= OigoHUDPreviewPolicy.maxCharacters,
              bounded.split(separator: "\n").count <= OigoHUDPreviewPolicy.maxLines,
              bounded.contains("third line") else {
            throw ContractFailure(message: "HUD preview was not bounded to the latest lines")
        }

        var throttle = OigoHUDPreviewThrottle()
        guard throttle.shouldPublish(at: 0),
              !throttle.shouldPublish(at: 0.1),
              throttle.shouldPublish(at: 0.2) else {
            throw ContractFailure(message: "HUD preview throttle exceeded five updates per second")
        }

        var resources = OigoHUDResourceLedger()
        resources.beginRecording()
        guard resources.recordingTimerActive else {
            throw ContractFailure(message: "HUD recording timer did not start")
        }
        resources.endRecording()
        resources.close()
        guard resources.activeResourceCount == 0,
              OigoHUDProcessingState.allCases.map(\.rawValue) == [
                  "Finalizing", "Cleaning", "Pasting", "Pasted", "Copied", "Failed"
              ] else {
            throw ContractFailure(message: "HUD resources or processing statuses outlived the session")
        }
    }

    private static func testHistory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue9-history-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(rootDirectory: root)
        let session = try store.persistRawText("saved transcript", for: store.createSession())
        let completed = try store.update(session, state: .completed)
        try Data([0x43, 0x41, 0x46]).write(to: completed.audioURL, options: [.atomic])
        let customDictionary = root.deletingLastPathComponent().appendingPathComponent("custom-dictionary.json")
        try Data("future dictionary".utf8).write(to: customDictionary, options: [.atomic])

        do {
            try store.deleteAllHistory(confirmed: false)
            throw ContractFailure(message: "Delete All History did not require deliberate confirmation")
        } catch let error as SessionStoreError {
            guard error.description.contains("confirmation") else {
                throw ContractFailure(message: "history deletion returned a non-actionable confirmation error")
            }
        }
        _ = try store.deleteAllHistory(confirmed: true)
        guard (try? store.load(id: completed.id)) == nil,
              FileManager.default.fileExists(atPath: customDictionary.path) else {
            throw ContractFailure(message: "Delete All History crossed the session/dictionary boundary")
        }
    }

}

private final class RecordingLaunchAtLoginClient: OigoLaunchAtLoginClient {
    var registerCount = 0
    var unregisterCount = 0
    var status: OigoLaunchAtLoginStatus = .disabled

    func register() throws {
        registerCount += 1
        status = .enabled
    }

    func unregister() throws {
        unregisterCount += 1
        status = .disabled
    }
}
