import AppKit
import Foundation
import OigoCore
import OigoInsertion

@available(macOS 26.0, *)
@MainActor
enum Task16KeyboardReleaseProbe {
    private static let cases = [
        "release-before-ready", "release-during-recording",
        "interrupt-during-audio", "app-close-during-terminalization"
    ]

    static func run(mode: String, defaultsSuite: String, outputURL: URL) async throws {
        guard (mode == "all" || cases.contains(mode)),
              defaultsSuite == "com.oigo.qa.task16",
              let defaults = UserDefaults(suiteName: defaultsSuite) else {
            throw Task16ProbeError.invalidInput
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        var rows: [Task16KeyboardReleaseRow] = []
        for caseName in mode == "all" ? cases : [mode] {
            defaults.removePersistentDomain(forName: defaultsSuite)
            rows.append(try await runCase(caseName, defaults: defaults))
        }
        defaults.removePersistentDomain(forName: defaultsSuite)
        let receipt = Task16KeyboardReleaseReceipt(
            ownerIdentity: "oigo-app-delegate-keyboard-release-lifecycle",
            rows: rows,
            defaultsCleaned: defaults.persistentDomain(forName: defaultsSuite) == nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(receipt).write(to: outputURL, options: .atomic)
        print("PASS task-16-keyboard-release-probe mode=\(mode) rows=\(rows.count)")
    }

    private static func runCase(
        _ caseName: String,
        defaults: UserDefaults
    ) async throws -> Task16KeyboardReleaseRow {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-task16-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settingsStore = OigoSettingsStore(defaults: defaults)
        try settingsStore.save(OigoSettings.default.with(localeIdentifier: "en-US", defaultMode: .instant))
        let onboardingStore = OigoOnboardingStore(defaults: defaults)
        onboardingStore.markCompleted()
        let capture = Task16ProbeCapture()
        let transcription = Task16ProbeTranscription(
            blocksStartup: caseName == "release-before-ready",
            startupBlockDuration: caseName == "release-before-ready" ? .milliseconds(500) : nil,
            blocksFinish: caseName == "app-close-during-terminalization",
            cancellationText: caseName == "release-before-ready" ? "" : "preserved partial"
        )
        var events: [OigoKeyboardStartupEvent] = []
        let boundaries = OigoKeyboardStartupBoundaryProviders(
            inputDevices: { [Task16ProbeInput.device] },
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
                    configuredLocaleIdentifier: "en-US",
                    installAssets: { "en-US" },
                    applyRecognitionContext: {}
                )
            },
            currentGeneration: { handle, _ in handle.generation },
            observeBinding: { _ in },
            observe: { events.append($0) }
        )
        let pasteboard = Task16ProbePasteboard()
        let app = OigoAppDelegate(
            storageBootstrapper: DurableSessionBootstrapper(rootDirectory: root),
            settingsStore: settingsStore,
            onboardingStore: onboardingStore,
            shortcutStorageReady: { true },
            settingsPermissionStates: { (.granted, .granted) },
            insertion: InsertionService(
                targetEnvironment: Task16ProbeTargetEnvironment(),
                pasteboard: pasteboard,
                eventSender: Task16ProbeEventSender()
            ),
            keyboardStartupBoundaries: boundaries
        )
        await app.prepareKeyboardStartupOwnerForTesting()
        app.sendKeyboardStartupEventForTesting(.pressed, generation: 61)
        var checkpoints = ["preparation"]
        try await waitUntil(caseName + ":started") { transcription.startCount == 1 }

        switch caseName {
        case "release-before-ready":
            app.sendKeyboardStartupEventForTesting(.released, generation: 61)
            app.sendKeyboardStartupEventForTesting(.released, generation: 61)
        case "release-during-recording":
            try await waitUntil(caseName + ":recording") { app.keyboardStartupStateForTesting == .recording }
            checkpoints.append("recording")
            app.sendKeyboardStartupEventForTesting(.released, generation: 61)
            app.sendKeyboardStartupEventForTesting(.released, generation: 61)
        case "interrupt-during-audio":
            try await waitUntil(caseName + ":recording") { app.keyboardStartupStateForTesting == .recording }
            checkpoints.append("recording")
            app.interruptKeyboardAudioForTesting("task-16 audio interruption")
        case "app-close-during-terminalization":
            try await waitUntil(caseName + ":recording") { app.keyboardStartupStateForTesting == .recording }
            checkpoints.append("recording")
            app.sendKeyboardStartupEventForTesting(.released, generation: 61)
            try await waitUntil(caseName + ":terminalizing") { transcription.finishCount == 1 }
            await app.shutdownKeyboardLifecycleForTesting()
        default:
            throw Task16ProbeError.invalidInput
        }

        try await waitUntil(caseName + ":terminal") {
            [.complete, .cancelled, .interrupted, .failed].contains(app.keyboardStartupStateForTesting)
        }
        checkpoints.append("terminal")
        try await waitUntil(caseName + ":cleanup", attempts: 2_500) {
            let resources = app.keyboardStartupResourcesForTesting
            return resources.coordinatorResourceCount == 0
                && resources.hudResourceCount == 0
                && resources.timerResourceCount == 0
                && !capture.active && !transcription.active
        }
        checkpoints.append("cleanup")
        let resources = app.keyboardStartupResourcesForTesting
        let session = app.keyboardStartupSessionForTesting
        return Task16KeyboardReleaseRow(
            caseName: caseName,
            checkpoints: checkpoints,
            terminalState: app.keyboardStartupStateForTesting.rawValue,
            durableState: session?.metadata.state.rawValue,
            durableRawBytes: session?.metadata.rawTextByteCount ?? 0,
            terminalizationCount: events.filter { $0 == .terminalized }.count,
            captureStopCount: capture.stopCount,
            captureCancelCount: capture.cancelCount,
            transcriptionFinishCount: transcription.finishCount,
            transcriptionCancelCount: transcription.cancelCount,
            insertionCount: pasteboard.writeCount,
            appResourceCount: resources.appDelegateResourceCount,
            coordinatorResourceCount: resources.coordinatorResourceCount,
            hudResourceCount: resources.hudResourceCount,
            timerResourceCount: resources.timerResourceCount
        )
    }

    private static func waitUntil(
        _ label: String,
        attempts: Int = 1_000,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw Task16ProbeError.timeout(label)
    }
}

private enum Task16ProbeError: Error { case invalidInput, timeout(String) }

private enum Task16ProbeInput {
    static let device = OigoInputDevice(
        uid: "task16-input", displayName: "Task 16 Input", deviceID: 1,
        inputChannelCount: 1, nominalSampleRate: 48_000, isAlive: true, isDefault: true
    )
}

private final class Task16ProbeCapture: AudioCapturing, @unchecked Sendable {
    private(set) var active = false
    private(set) var stopCount = 0
    private(set) var cancelCount = 0
    func start(
        to descriptor: AudioFileDescriptor,
        onBuffer: @escaping @Sendable (AudioCaptureBuffer) -> Void,
        onFinish: @escaping @Sendable () -> Void,
        onInterruption: @escaping @Sendable (String) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) throws {
        _ = descriptor; _ = onBuffer; _ = onFinish; _ = onInterruption; _ = onFailure
        active = true
    }
    func stop() throws { stopCount += 1; active = false }
    func cancel() { cancelCount += 1; active = false }
}

private final class Task16ProbeTranscription: TranscriptionController, @unchecked Sendable {
    let blocksStartup: Bool
    let startupBlockDuration: Duration?
    let blocksFinish: Bool
    let cancellationText: String
    private var session: DictationSession?
    private var store: SessionStore?
    private(set) var active = false
    private(set) var startCount = 0
    private(set) var finishCount = 0
    private(set) var cancelCount = 0
    init(
        blocksStartup: Bool,
        startupBlockDuration: Duration? = nil,
        blocksFinish: Bool,
        cancellationText: String
    ) {
        self.blocksStartup = blocksStartup
        self.startupBlockDuration = startupBlockDuration
        self.blocksFinish = blocksFinish
        self.cancellationText = cancellationText
    }
    func start(
        session: DictationSession,
        format: AudioCaptureFormat,
        store: SessionStore,
        onUpdate: @escaping @Sendable (TranscriptionUpdate) -> Void
    ) async throws {
        _ = format; _ = onUpdate
        startCount += 1; active = true; self.session = session; self.store = store
        if blocksStartup {
            if let startupBlockDuration {
                try await Task.sleep(for: startupBlockDuration)
            } else {
                try await Task.sleep(for: .seconds(30))
            }
        }
    }
    func append(_ buffer: AudioCaptureBuffer) { _ = buffer }
    func finish() async throws -> TranscriptionResult {
        finishCount += 1
        if blocksFinish { try await Task.sleep(for: .seconds(30)) }
        return try persist("release completed")
    }
    func cancel() async throws -> TranscriptionResult? {
        cancelCount += 1
        guard !cancellationText.isEmpty else { active = false; return nil }
        return try persist(cancellationText)
    }
    func retrySavedAudio(for session: DictationSession, store: SessionStore) async throws -> TranscriptionResult {
        _ = session; _ = store; return TranscriptionResult(finalizedText: "", rawTextByteCount: 0)
    }
    private func persist(_ text: String) throws -> TranscriptionResult {
        guard let session, let store else { throw Task16ProbeError.invalidInput }
        _ = try store.persistRawText(text, for: session)
        active = false
        return TranscriptionResult(finalizedText: text, rawTextByteCount: Int64(text.utf8.count))
    }
}

@MainActor private final class Task16ProbePasteboard: InsertionPasteboard {
    private(set) var writeCount = 0
    func write(_ rawText: String) -> Bool { _ = rawText; writeCount += 1; return true }
}

@MainActor private final class Task16ProbeTargetEnvironment: InsertionTargetEnvironment {
    func capture() -> InsertionTargetSnapshot {
        InsertionTargetSnapshot(
            frontmostProcessIdentifier: 1, bundleIdentifier: "com.oigo.qa.task16",
            focusedElementIdentifier: "task16-field", role: "AXTextField", isSecureTextField: false
        )
    }
    func validate(_ snapshot: InsertionTargetSnapshot) -> TargetValidation { _ = snapshot; return .safe }
}

@MainActor private final class Task16ProbeEventSender: InsertionEventSender {
    func sendPaste(to processIdentifier: Int32, revalidate: () -> TargetValidation) -> InsertionEventResult {
        _ = processIdentifier; return revalidate() == .safe ? .dispatched : .failed
    }
}
