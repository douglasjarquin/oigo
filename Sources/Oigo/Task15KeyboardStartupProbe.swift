import AppKit
import Foundation
import OigoCore
import OigoInsertion

struct Task15KeyboardStartupRow: Codable {
    let caseName: String
    let events: [String]
    let generation: UInt64
    let verifiedLocaleIdentifier: String?
    let startedLocaleIdentifier: String?
    let startedGeneration: UInt64?
    let recoveryCategory: String?
    let recoveryCopy: String?
    let terminalizationCount: Int
    let appDelegateResourceCount: Int
    let coordinatorResourceCount: Int
    let hudResourceCount: Int
    let timerResourceCount: Int
    let captureResourceCount: Int
    let speechResourceCount: Int
    let transcriptionStartCount: Int
    let captureStartCount: Int
    let recordingTimerStartCount: Int
}

struct Task15KeyboardStartupReceipt: Codable {
    let ownerIdentity: String
    let rows: [Task15KeyboardStartupRow]
    let defaultsCleaned: Bool
}

@available(macOS 26.0, *)
@MainActor
enum Task15KeyboardStartupProbe {
    private static let failureCases = [
        "storage-unavailable", "onboarding-incomplete", "microphone-denied",
        "input-unavailable", "speech-unavailable", "speech-failed",
        "startup-interrupted", "startup-cancelled", "stale-generation",
        "locale-mismatch", "speech-assets-not-ready"
    ]

    static func run(mode: String, defaultsSuite: String, outputURL: URL) async throws {
        guard ["all", "success", "failure"].contains(mode),
              defaultsSuite.hasPrefix("com.oigo.qa.task15") || defaultsSuite == "com.oigo.qa.task05",
              let defaults = UserDefaults(suiteName: defaultsSuite) else {
            throw Task15ProbeError.invalidInput
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let caseNames = switch mode {
        case "success": ["ready"]
        case "failure": failureCases
        default: ["ready"] + failureCases
        }
        var rows: [Task15KeyboardStartupRow] = []
        for caseName in caseNames {
            defaults.removePersistentDomain(forName: defaultsSuite)
            rows.append(try await runCase(caseName, defaults: defaults))
        }
        defaults.removePersistentDomain(forName: defaultsSuite)
        let receipt = Task15KeyboardStartupReceipt(
            ownerIdentity: "oigo-app-delegate-keyboard-startup",
            rows: rows,
            defaultsCleaned: defaults.persistentDomain(forName: defaultsSuite) == nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(receipt).write(to: outputURL, options: .atomic)
        print("PASS task-15-keyboard-startup-probe mode=\(mode) rows=\(rows.count)")
    }

    private static func runCase(
        _ caseName: String,
        defaults: UserDefaults
    ) async throws -> Task15KeyboardStartupRow {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-task15-probe-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settingsStore = OigoSettingsStore(defaults: defaults)
        try settingsStore.save(OigoSettings.default.with(localeIdentifier: "fr-FR"))
        let onboardingStore = OigoOnboardingStore(defaults: defaults)
        if caseName != "onboarding-incomplete" { onboardingStore.markCompleted() }
        let capture = Task15ProbeCapture()
        let transcription = Task15ProbeTranscription(
            mode: ["startup-interrupted", "startup-cancelled"].contains(caseName)
                ? .block : caseName == "speech-failed" ? .fail : .succeed
        )
        let verifiedLocale: String? = caseName == "speech-assets-not-ready" ? nil
            : caseName == "locale-mismatch" ? "en-US" : "fr-FR"
        let configuredLocale = caseName == "locale-mismatch" ? "en-US" : "fr-FR"
        var events: [OigoKeyboardStartupEvent] = []
        var binding: KeyboardStartupLocaleBinding?
        let boundaries = OigoKeyboardStartupBoundaryProviders(
            inputDevices: { caseName == "input-unavailable" ? [] : [Task15ProbeInput.device] },
            audio: {
                OigoKeyboardStartupAudioBoundary(
                    capture: capture,
                    setInputSelection: { _, _ in },
                    captureFormat: { AudioCaptureFormat(sampleRate: 16_000, channelCount: 1) }
                )
            },
            speech: {
                OigoKeyboardStartupSpeechBoundary(
                    controller: transcription,
                    configuredLocaleIdentifier: configuredLocale,
                    installAssets: {
                        if caseName == "speech-unavailable" {
                            throw OigoKeyboardStartupBoundaryFailure.speechUnavailable
                        }
                        return verifiedLocale
                    },
                    applyRecognitionContext: {}
                )
            },
            currentGeneration: { handle, _ in
                caseName == "stale-generation" ? handle.generation &- 1 : handle.generation
            },
            observeBinding: { binding = $0 },
            observe: { events.append($0) }
        )
        let insertion = InsertionService(
            targetEnvironment: Task15ProbeTargetEnvironment(),
            pasteboard: Task15ProbePasteboard(),
            eventSender: Task15ProbeEventSender()
        )
        let bootstrapper: any DurableSessionBootstrapping = caseName == "storage-unavailable"
            ? Task15UnavailableBootstrapper()
            : DurableSessionBootstrapper(rootDirectory: root)
        let app = OigoAppDelegate(
            storageBootstrapper: bootstrapper,
            settingsStore: settingsStore,
            onboardingStore: onboardingStore,
            shortcutStorageReady: { true },
            settingsPermissionStates: {
                (caseName == "microphone-denied" ? .denied : .granted, .granted)
            },
            insertion: insertion,
            keyboardStartupBoundaries: boundaries
        )
        await app.prepareKeyboardStartupOwnerForTesting()
        app.sendKeyboardStartupEventForTesting(.pressed, generation: 41)
        if caseName == "startup-interrupted" || caseName == "startup-cancelled" {
            try await waitUntil(caseName + ":speech-start") { transcription.startCount == 1 }
            if caseName == "startup-interrupted" {
                app.interruptKeyboardStartupForTesting()
            } else {
                app.cancelKeyboardStartupForTesting()
            }
        }
        if caseName == "ready" {
            try await waitUntil(caseName + ":recording") { app.keyboardStartupStateForTesting == .recording }
            app.terminalizeKeyboardStartupForTesting()
        }
        do {
            try await waitUntil(caseName + ":cleanup") {
                let resources = app.keyboardStartupResourcesForTesting
                return resources.appDelegateResourceCount == 0
                    && resources.coordinatorResourceCount == 0
                    && resources.hudResourceCount == 0
                    && resources.timerResourceCount == 0
                    && !capture.active && !transcription.active
            }
        } catch {
            let resources = app.keyboardStartupResourcesForTesting
            throw Task15ProbeError.timeout(
                "\(caseName):cleanup:app=\(resources.appDelegateResourceCount):"
                    + "coordinator=\(resources.coordinatorResourceCount):hud=\(resources.hudResourceCount):"
                    + "timer=\(resources.timerResourceCount):capture=\(capture.active):speech=\(transcription.active)"
            )
        }
        let resources = app.keyboardStartupResourcesForTesting
        let recovery = app.keyboardStartupRecoveryForTesting
        return Task15KeyboardStartupRow(
            caseName: caseName,
            events: events.filter { $0 != .terminalized }.map(\.rawValue),
            generation: resources.generation,
            verifiedLocaleIdentifier: verifiedLocale,
            startedLocaleIdentifier: transcription.startedLocaleIdentifier,
            startedGeneration: transcription.startCount == 0 ? nil : binding?.generation,
            recoveryCategory: recovery.category,
            recoveryCopy: recovery.copy,
            terminalizationCount: events.filter { $0 == .terminalized }.count,
            appDelegateResourceCount: resources.appDelegateResourceCount,
            coordinatorResourceCount: resources.coordinatorResourceCount,
            hudResourceCount: resources.hudResourceCount,
            timerResourceCount: resources.timerResourceCount,
            captureResourceCount: capture.active ? 1 : 0,
            speechResourceCount: transcription.active ? 1 : 0,
            transcriptionStartCount: transcription.startCount,
            captureStartCount: capture.startCount,
            recordingTimerStartCount: resources.recordingTimerStartCount
        )
    }

    private static func waitUntil(
        _ label: String,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<1_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw Task15ProbeError.timeout(label)
    }
}

private enum Task15ProbeError: Error { case invalidInput, timeout(String), unavailable }

private struct Task15UnavailableBootstrapper: DurableSessionBootstrapping {
    func bootstrap() async throws -> DurableSessionBootstrapResult {
        throw Task15ProbeError.unavailable
    }
}

private enum Task15ProbeInput {
    static let device = OigoInputDevice(
        uid: "task15-input", displayName: "Task 15 Input", deviceID: 1,
        inputChannelCount: 1, nominalSampleRate: 48_000, isAlive: true, isDefault: true
    )
}

private final class Task15ProbeCapture: AudioCapturing, @unchecked Sendable {
    private(set) var active = false
    private(set) var startCount = 0
    func start(
        to descriptor: AudioFileDescriptor,
        onBuffer: @escaping @Sendable (AudioCaptureBuffer) -> Void,
        onFinish: @escaping @Sendable () -> Void,
        onInterruption: @escaping @Sendable (String) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) throws {
        _ = descriptor; _ = onBuffer; _ = onFinish; _ = onInterruption; _ = onFailure
        startCount += 1; active = true
    }
    func stop() throws { active = false }
    func cancel() { active = false }
}

private final class Task15ProbeTranscription: TranscriptionController, @unchecked Sendable {
    enum Mode { case succeed, fail, block }
    let mode: Mode
    private(set) var active = false
    private(set) var startCount = 0
    private(set) var startedLocaleIdentifier: String?
    init(mode: Mode) { self.mode = mode }
    func start(
        session: DictationSession,
        format: AudioCaptureFormat,
        store: SessionStore,
        onUpdate: @escaping @Sendable (TranscriptionUpdate) -> Void
    ) async throws {
        _ = format; _ = store; _ = onUpdate
        startCount += 1; active = true
        startedLocaleIdentifier = session.metadata.configurationSnapshot?.resolvedLocaleIdentifier
        if mode == .fail { throw OigoKeyboardStartupBoundaryFailure.speechFailed }
        if mode == .block { try await Task.sleep(for: .seconds(30)) }
    }
    func append(_ buffer: AudioCaptureBuffer) { _ = buffer }
    func finish() async throws -> TranscriptionResult {
        active = false; return TranscriptionResult(finalizedText: "", rawTextByteCount: 0)
    }
    func cancel() async throws -> TranscriptionResult? {
        active = false; return TranscriptionResult(finalizedText: "", rawTextByteCount: 0)
    }
    func retrySavedAudio(for session: DictationSession, store: SessionStore) async throws -> TranscriptionResult {
        _ = session; _ = store; return TranscriptionResult(finalizedText: "", rawTextByteCount: 0)
    }
}

@MainActor private final class Task15ProbePasteboard: InsertionPasteboard {
    func write(_ rawText: String) -> Bool { _ = rawText; return true }
}
@MainActor private final class Task15ProbeTargetEnvironment: InsertionTargetEnvironment {
    func capture() -> InsertionTargetSnapshot {
        InsertionTargetSnapshot(
            frontmostProcessIdentifier: 1, bundleIdentifier: "com.oigo.qa.task15",
            focusedElementIdentifier: "task15-field", role: "AXTextField", isSecureTextField: false
        )
    }
    func validate(_ snapshot: InsertionTargetSnapshot) -> TargetValidation { _ = snapshot; return .safe }
}
@MainActor private final class Task15ProbeEventSender: InsertionEventSender {
    func sendPaste(to processIdentifier: Int32, revalidate: () -> TargetValidation) -> InsertionEventResult {
        _ = processIdentifier; return revalidate() == .safe ? .dispatched : .failed
    }
}
