import Foundation
import AVFAudio
import Speech
import OigoCore
@_spi(Testing) import OigoTranscription

private struct ContractFailure: Error, CustomStringConvertible {
    let message: String

    var description: String { message }
}

@main
@available(macOS 26.0, *)
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
            ("locale", testLocaleSelection),
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
        try settings.save(before.with(showVolatilePreview: false))
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
        onboarding.save(OigoOnboardingState(step: .shortcut))
        guard onboarding.load().step == .shortcut else {
            throw ContractFailure(message: "onboarding progress did not persist before completion")
        }
        onboarding.markCompleted()
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

        guard !OigoOnboardingTestOutcome.pending.allowsContinue,
              OigoOnboardingTestOutcome.passed.allowsContinue,
              OigoOnboardingTestOutcome.skipped.allowsContinue else {
            throw ContractFailure(message: "onboarding test could not pass or be skipped")
        }

        let module = DictationTranscriber(
            locale: Locale(identifier: "en-US"),
            preset: .progressiveLongDictation
        )
        guard let analyzerFormat = await TranscriptionService.analyzerAudioFormat(
            for: AudioCaptureFormat(sampleRate: 48_000, channelCount: 1),
            compatibleWith: module
        ), analyzerFormat.sampleRate == 16_000,
           analyzerFormat.channelCount == 1,
           analyzerFormat.commonFormat == .pcmFormatInt16,
           analyzerFormat.isInterleaved else {
            throw ContractFailure(message: "live SpeechAnalyzer input did not use the module's best compatible format")
        }

        let captureBuffer = AudioCaptureBuffer(
            frameCount: 4_800,
            sampleRate: 48_000,
            channelCount: 1,
            pcmData: Data(repeating: 0, count: 4_800 * MemoryLayout<Float>.size)
        )
        let converted = try TranscriptionService.convertCaptureBufferForTesting(
            captureBuffer,
            to: analyzerFormat
        )
        guard converted.frameLength > 0,
              converted.format.commonFormat == .pcmFormatInt16,
              converted.format.channelCount == 1,
              converted.format.isInterleaved,
              converted.int16ChannelData != nil else {
            throw ContractFailure(message: "live capture conversion did not produce analyzer-compatible Int16 PCM")
        }

        guard InsertionOutcome.pasted.clipboardOutputAvailable,
              InsertionOutcome.copied.clipboardOutputAvailable,
              InsertionOutcome.secureRejected.clipboardOutputAvailable,
              !InsertionOutcome.failed.clipboardOutputAvailable else {
            throw ContractFailure(message: "clipboard output policy did not preserve copy-only outcomes")
        }
    }

    private static func testLocaleSelection() throws {
        try testLocaleDisplayNames()
        try testOnboardingSwitchDuringCheck()
        try testOnboardingSwitchDuringInstall()
        try testLateSuccessAndFailureCannotApply()
        try testContinueRequiresMatchingReadyGeneration()
        try testBackForwardRevalidate()
        try testCloseReopenAndRerunPreserveCommittedLanguage()
        try testOnboardingDoesNotPersistOnLoad()
        try testUnsupportedStoredLocaleIsKeptAndShownUnavailable()
        try testEmptySupportedListLeavesPreviousLocale()
        try testSettingsUnrelatedSaveDoesNotChangeLanguage()
        try testInstallFailureLeavesPreviousLocale()
    }

    private static func testLocaleDisplayNames() throws {
        let displayLocale = Locale(identifier: "en_US")
        let english = OigoLocalePresentation.displayName(for: "en-US", displayLocale: displayLocale)
        let french = OigoLocalePresentation.displayName(for: "fr-FR", displayLocale: displayLocale)
        guard english.contains("English"),
              english.contains("United States"),
              french.contains("French"),
              french.contains("France"),
              english != "en-US",
              french != "fr-FR" else {
            throw ContractFailure(message: "locale labels were not human-readable")
        }

        let items = OigoLocaleMenu.items(
            supportedIdentifiers: ["fr-FR", "en-US"],
            committedIdentifier: "en-US",
            role: .onboarding,
            displayLocale: displayLocale
        )
        guard items.map(\.identifier) == ["fr-FR", "en-US"],
              items.allSatisfy({ !$0.title.contains("en-US") && !$0.title.contains("fr-FR") }),
              items.allSatisfy({ !$0.isUnavailable }) else {
            throw ContractFailure(message: "locale menu did not keep exact identifiers behind human-readable titles")
        }
    }

    private static func testOnboardingSwitchDuringCheck() throws {
        var state = onboardingState(committed: "en-US")
        state.loadSupported(["en-US", "fr-FR"])
        guard state.confirm() == nil else {
            throw ContractFailure(message: "Continue was enabled before a matching ready result")
        }
        guard let request = state.beginAssetRequest(status: .checking) else {
            throw ContractFailure(message: "checking the selected locale did not start")
        }
        state.select("fr-FR")
        guard !state.canConfirm,
              state.selectedIdentifier == "fr-FR",
              state.committedIdentifier == "en-US",
              state.readiness.status == .idle,
              state.readiness.generation == state.generation else {
            throw ContractFailure(message: "switching language during a check did not invalidate readiness")
        }
        let applied = state.applyAssetResult(
            localeIdentifier: request.localeIdentifier,
            generation: request.generation,
            status: .ready
        )
        guard !applied,
              !state.canConfirm,
              state.confirm() == nil,
              state.committedIdentifier == "en-US" else {
            throw ContractFailure(message: "a late check result approved a different language")
        }
    }

    private static func testOnboardingSwitchDuringInstall() throws {
        var state = onboardingState(committed: "en-US")
        state.loadSupported(["en-US", "fr-FR"])
        state.select("fr-FR")
        guard let request = state.beginAssetRequest(status: .installing) else {
            throw ContractFailure(message: "installing the selected locale did not start")
        }
        guard state.readiness.status == .installing,
              !state.canConfirm else {
            throw ContractFailure(message: "Continue stayed enabled while assets were installing")
        }
        state.select("en-US")
        let applied = state.applyAssetResult(
            localeIdentifier: request.localeIdentifier,
            generation: request.generation,
            status: .ready
        )
        guard !applied,
              !state.canConfirm,
              state.selectedIdentifier == "en-US",
              state.committedIdentifier == "en-US",
              state.confirm() == nil else {
            throw ContractFailure(message: "a late install result committed a language the user had left")
        }
    }

    private static func testLateSuccessAndFailureCannotApply() throws {
        var state = onboardingState(committed: "en-GB")
        state.loadSupported(["en-GB", "de-DE", "fr-FR"])
        let first = state.beginAssetRequest(status: .checking)
        state.select("de-DE")
        let second = state.beginAssetRequest(status: .installing)
        guard let first, let second else {
            throw ContractFailure(message: "locale asset requests were not fenced by generation")
        }
        guard first.generation != second.generation else {
            throw ContractFailure(message: "a new locale request reused the previous generation")
        }
        guard !state.applyAssetResult(
            localeIdentifier: first.localeIdentifier,
            generation: first.generation,
            status: .ready
        ), !state.applyAssetResult(
            localeIdentifier: first.localeIdentifier,
            generation: first.generation,
            status: .failed("download failed")
        ), !state.canConfirm,
              state.committedIdentifier == "en-GB" else {
            throw ContractFailure(message: "late success or failure from an old locale updated current state")
        }
        guard state.applyAssetResult(
            localeIdentifier: second.localeIdentifier,
            generation: second.generation,
            status: .ready
        ), state.canConfirm,
              state.confirm() == "de-DE",
              state.committedIdentifier == "de-DE" else {
            throw ContractFailure(message: "only the matching ready generation should commit")
        }
    }

    private static func testContinueRequiresMatchingReadyGeneration() throws {
        var state = onboardingState(committed: "en-US")
        state.loadSupported(["en-US", "fr-FR"])
        let stale = state.beginAssetRequest(status: .checking)
        state.select("fr-FR")
        let current = state.beginAssetRequest(status: .checking)
        guard let stale, let current else {
            throw ContractFailure(message: "asset generations were not issued")
        }
        guard !state.applyAssetResult(
            localeIdentifier: "fr-FR",
            generation: stale.generation,
            status: .ready
        ), !state.canConfirm else {
            throw ContractFailure(message: "Continue accepted a ready result from the wrong generation")
        }
        guard state.applyAssetResult(
            localeIdentifier: current.localeIdentifier,
            generation: current.generation,
            status: .ready
        ), state.canConfirm,
              state.confirm() == "fr-FR" else {
            throw ContractFailure(message: "Continue was not enabled for the matching ready generation")
        }
    }

    private static func testBackForwardRevalidate() throws {
        var state = onboardingState(committed: "en-US")
        state.loadSupported(["en-US", "fr-FR"])
        state.select("fr-FR")
        guard let request = state.beginAssetRequest(status: .installing) else {
            throw ContractFailure(message: "language verification did not start")
        }
        _ = state.applyAssetResult(
            localeIdentifier: request.localeIdentifier,
            generation: request.generation,
            status: .ready
        )
        guard state.canConfirm else {
            throw ContractFailure(message: "verified locale could not continue")
        }
        state.revalidate()
        guard !state.canConfirm,
              state.confirm() == nil,
              state.committedIdentifier == "en-US",
              state.selectedIdentifier == "fr-FR",
              state.readiness.status == .idle else {
            throw ContractFailure(message: "returning to the language step kept a stale ready result")
        }
        guard let retry = state.beginAssetRequest(status: .installing),
              state.applyAssetResult(
                localeIdentifier: retry.localeIdentifier,
                generation: retry.generation,
                status: .ready
              ),
              state.confirm() == "fr-FR" else {
            throw ContractFailure(message: "rechecking after back/forward did not require a new matching ready result")
        }
    }

    private static func testCloseReopenAndRerunPreserveCommittedLanguage() throws {
        var session = onboardingState(committed: "en-US")
        session.loadSupported(["en-US", "fr-FR"])
        session.select("fr-FR")
        guard let request = session.beginAssetRequest(status: .installing) else {
            throw ContractFailure(message: "language verification did not start")
        }
        _ = session.applyAssetResult(
            localeIdentifier: request.localeIdentifier,
            generation: request.generation,
            status: .ready
        )
        session.abandonUncommitted()
        guard session.committedIdentifier == "en-US",
              session.selectedIdentifier == "en-US",
              session.confirm() == nil else {
            throw ContractFailure(message: "closing onboarding replaced the committed language")
        }

        var rerun = onboardingState(committed: "en-US")
        rerun.loadSupported(["en-US", "fr-FR"])
        rerun.select("fr-FR")
        rerun.abandonUncommitted()
        guard rerun.committedIdentifier == "en-US",
              rerun.selectedIdentifier == "en-US" else {
            throw ContractFailure(message: "rerunning onboarding replaced the committed language")
        }
    }

    private static func testOnboardingDoesNotPersistOnLoad() throws {
        var state = onboardingState(committed: "en-AU")
        state.loadSupported(["fr-FR", "en-GB", "de-DE"])
        guard state.committedIdentifier == "en-AU",
              state.selectedIdentifier == "en-GB",
              state.confirm() == nil else {
            throw ContractFailure(message: "loading languages persisted or confirmed an unverified preselection")
        }
    }

    private static func testUnsupportedStoredLocaleIsKeptAndShownUnavailable() throws {
        var state = OigoLocaleSelectionState(
            committedIdentifier: "zh-CN",
            role: .settings,
            displayLocale: Locale(identifier: "en_US")
        )
        state.loadSupported(["en-US", "fr-FR"])
        guard state.committedIdentifier == "zh-CN",
              state.selectedIdentifier == "zh-CN",
              state.selectedItemIsUnavailable,
              !state.requiresVerificationToCommit,
              state.menuItems.contains(where: { $0.identifier == "zh-CN" && $0.isUnavailable }),
              state.menuItems.contains(where: { $0.identifier == "en-US" && !$0.isUnavailable }),
              !state.menuItems.contains(where: { $0.identifier == "zh-CN" && $0.title == "en-US" }) else {
            throw ContractFailure(message: "an unavailable stored locale was replaced by the first supported locale")
        }
        guard state.beginAssetRequest(status: .installing) == nil,
              state.confirm() == nil else {
            throw ContractFailure(message: "an unavailable stored locale was treated as ready to commit")
        }
    }

    private static func testEmptySupportedListLeavesPreviousLocale() throws {
        var onboarding = onboardingState(committed: "en-US")
        onboarding.loadSupported([])
        guard onboarding.committedIdentifier == "en-US",
              onboarding.selectedIdentifier == nil,
              onboarding.menuItems.isEmpty,
              !onboarding.canConfirm,
              onboarding.statusMessage.contains("No supported speech locales") else {
            throw ContractFailure(message: "an empty onboarding language list changed the committed locale")
        }

        var settings = OigoLocaleSelectionState(
            committedIdentifier: "en-US",
            role: .settings,
            displayLocale: Locale(identifier: "en_US")
        )
        settings.loadSupported([])
        guard settings.committedIdentifier == "en-US",
              settings.selectedIdentifier == "en-US",
              settings.selectedItemIsUnavailable,
              !settings.requiresVerificationToCommit,
              settings.confirm() == nil else {
            throw ContractFailure(message: "an empty Settings language list dropped the saved locale")
        }
    }

    private static func testSettingsUnrelatedSaveDoesNotChangeLanguage() throws {
        var state = OigoLocaleSelectionState(
            committedIdentifier: "zh-CN",
            role: .settings,
            displayLocale: Locale(identifier: "en_US")
        )
        state.loadSupported(["de-DE", "en-US", "fr-FR"])
        let persisted = settingsPersistLocale(from: state)
        guard persisted == "zh-CN",
              state.committedIdentifier == "zh-CN" else {
            throw ContractFailure(message: "saving unrelated settings changed the dictation language")
        }

        state.select("fr-FR")
        let persistedAfterSelection = settingsPersistLocale(from: state)
        guard persistedAfterSelection == "zh-CN",
              state.committedIdentifier == "zh-CN",
              state.requiresVerificationToCommit else {
            throw ContractFailure(message: "selecting a language in Settings persisted it before verification")
        }
    }

    private static func testInstallFailureLeavesPreviousLocale() throws {
        var onboarding = onboardingState(committed: "en-US")
        onboarding.loadSupported(["en-US", "fr-FR"])
        onboarding.select("fr-FR")
        guard let request = onboarding.beginAssetRequest(status: .installing) else {
            throw ContractFailure(message: "install did not start")
        }
        guard onboarding.applyAssetResult(
            localeIdentifier: request.localeIdentifier,
            generation: request.generation,
            status: .failed("download failed")
        ), !onboarding.canConfirm,
              onboarding.confirm() == nil,
              onboarding.committedIdentifier == "en-US" else {
            throw ContractFailure(message: "an onboarding install failure replaced the previous locale")
        }

        var settings = OigoLocaleSelectionState(
            committedIdentifier: "en-US",
            role: .settings,
            displayLocale: Locale(identifier: "en_US")
        )
        settings.loadSupported(["en-US", "fr-FR"])
        settings.select("fr-FR")
        guard let settingsRequest = settings.beginAssetRequest(status: .installing) else {
            throw ContractFailure(message: "Settings install did not start")
        }
        _ = settings.applyAssetResult(
            localeIdentifier: settingsRequest.localeIdentifier,
            generation: settingsRequest.generation,
            status: .failed("download failed")
        )
        settings.abandonUncommitted()
        guard settings.committedIdentifier == "en-US",
              settings.selectedIdentifier == "en-US",
              settingsPersistLocale(from: settings) == "en-US" else {
            throw ContractFailure(message: "a Settings install failure replaced the previous locale")
        }
    }

    private static func onboardingState(committed: String) -> OigoLocaleSelectionState {
        OigoLocaleSelectionState(
            committedIdentifier: committed,
            role: .onboarding,
            preferredIdentifier: committed,
            displayLocale: Locale(identifier: "en_US")
        )
    }

    private static func settingsPersistLocale(from state: OigoLocaleSelectionState) -> String {
        if state.requiresVerificationToCommit {
            return state.canConfirm ? (state.selectedIdentifier ?? state.committedIdentifier) : state.committedIdentifier
        }
        return state.committedIdentifier
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
        try store.save(updated)
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
                  "Finalizing", "Cleaning", "Pasting", "Paste attempted", "Pasted", "Copied", "Failed"
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
