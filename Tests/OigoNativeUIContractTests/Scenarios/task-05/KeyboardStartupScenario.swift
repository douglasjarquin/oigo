import Foundation
@_spi(Testing) import OigoCore
import OigoHotKey
import OigoInsertion

final class KeyboardStartupScenario: NativeUIContractScenario {
    private enum StartupCase: String, CaseIterable {
        case success = "startup-success"
        case microphone
        case input
        case speech
        case speechAssets = "speech-assets"
        case audioStart = "audio-start"
        case releaseDuringPreparation = "release-during-preparation"
        case cancellationBeforeRaw = "cancellation-before-raw"

    }

    private struct Receipt: Codable, Equatable, Sendable {
        let fixture: String
        let terminalCategory: String
        let durableSessionCount: Int
        let activeOperationCount: Int
        let captureCancelCount: Int
        let captureStopCount: Int
        let speechCancelCount: Int
        let duplicateStopCount: Int
        let recordingTimerStartCount: Int
        let recordingTimerActiveAfterTerminal: Bool
        let timerResourceCountAfterTerminal: Int
        let historySessionIDsBefore: [String]
        let historySessionIDsAfter: [String]
        let historySessionCountBefore: Int
        let historySessionCountAfter: Int
        let historyPreserved: Bool
        let rawTranscriptBytesBefore: Int
        let rawTranscriptBytesAfter: Int
        let audioBytesAfter: Int
        let clipboardWriteCountBefore: Int
        let clipboardWriteCountAfter: Int
        let copyOnlyAcceptedBefore: Bool
        let copyOnlyAcceptedAfter: Bool
    }

    private struct LifecycleResult: Sendable {
        let terminalCategory: String
        let reachedRecording: Bool
        let captureCancelCount: Int
        let captureStopCount: Int
        let speechCancelCount: Int
        let duplicateStopCount: Int
        let activeOperationCount: Int
    }

    override class var scenarioName: String {
        "keyboard-startup"
    }

    override class func run(arguments: ContractArguments) throws {
        guard arguments.defaultsSuite == "com.oigo.qa.task05" else {
            throw ContractInputError(category: "invalid-defaults-suite")
        }
        let cases = try selectedCases(arguments)
        let hudProbe = try HUDTimerProbe()
        defer { hudProbe.cleanup() }
        let receipts = try runOnMainActor {
            var receipts: [Receipt] = []
            for startupCase in cases {
                receipts.append(try await run(
                    startupCase,
                    fixtureRoot: arguments.fixtureRoot,
                    hudProbe: hudProbe
                ))
            }
            return receipts
        }
        guard receipts.allSatisfy({
            $0.activeOperationCount == 0
                && $0.duplicateStopCount == 0
                && !$0.recordingTimerActiveAfterTerminal
                && $0.timerResourceCountAfterTerminal == 0
                && $0.rawTranscriptBytesBefore == $0.rawTranscriptBytesAfter
                && $0.audioBytesAfter == 0
                && $0.clipboardWriteCountBefore == $0.clipboardWriteCountAfter
                && $0.historyPreserved
                && $0.copyOnlyAcceptedBefore == $0.copyOnlyAcceptedAfter
        }) else {
            throw ContractInputError(category: "startup-cleanup-contract-failed")
        }
        try write(receipts: receipts, to: arguments.evidenceRoot)
        for receipt in receipts {
            print(
                "GREEN startup \(receipt.fixture) terminal=\(receipt.terminalCategory) "
                    + "durableSession=\(receipt.durableSessionCount) active=\(receipt.activeOperationCount) "
                    + "captureCancel=\(receipt.captureCancelCount) captureStop=\(receipt.captureStopCount) "
                    + "speechCancel=\(receipt.speechCancelCount) duplicateStop=\(receipt.duplicateStopCount) "
                    + "timerStarts=\(receipt.recordingTimerStartCount) timerActive=\(receipt.recordingTimerActiveAfterTerminal) "
                    + "history=\(receipt.historySessionCountBefore)->\(receipt.historySessionCountAfter) "
                    + "raw=\(receipt.rawTranscriptBytesBefore)->\(receipt.rawTranscriptBytesAfter) "
                    + "clipboard=\(receipt.clipboardWriteCountBefore)->\(receipt.clipboardWriteCountAfter) "
                    + "copyOnly=\(receipt.copyOnlyAcceptedBefore)->\(receipt.copyOnlyAcceptedAfter)"
            )
        }
        print("PASS keyboard-startup cases=\(receipts.count) runtime-observations=terminal/session/timer/history/raw/audio/clipboard/copy-only")
    }

    private static func selectedCases(_ arguments: ContractArguments) throws -> [StartupCase] {
        if let fixture = arguments.fixtureName {
            guard let selected = StartupCase(rawValue: fixture) else {
                throw ContractInputError(category: "unknown-startup-provider")
            }
            return [selected]
        }
        let fixtureURL = arguments.fixtureRoot.appendingPathComponent("fixture.json")
        if FileManager.default.fileExists(atPath: fixtureURL.path) {
            guard let data = try? Data(contentsOf: fixtureURL),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == ["case"],
                  let name = object["case"] as? String,
                  let selected = StartupCase(rawValue: name) else {
                throw ContractInputError(category: "malformed-startup-fixture")
            }
            return [selected]
        }
        switch arguments.fixtureRoot.lastPathComponent {
        case "task-05":
            return StartupCase.allCases
        case "startup-denied":
            return StartupCase.allCases.filter { $0 != .success }
        default:
            guard let selected = StartupCase(rawValue: arguments.fixtureRoot.lastPathComponent) else {
                throw ContractInputError(category: "unknown-startup-provider")
            }
            return [selected]
        }
    }

    @MainActor
    private static func run(
        _ startupCase: StartupCase,
        fixtureRoot: URL,
        hudProbe: HUDTimerProbe
    ) async throws -> Receipt {
        let environment = try ScenarioStartupEnvironment(
            fixtureRoot: fixtureRoot,
            fixtureName: startupCase.rawValue
        )
        defer { environment.cleanup() }
        let before = try environment.snapshot()
        let result: LifecycleResult
        switch startupCase {
        case .microphone, .input:
            let operationGate = AppOperationGate()
            guard case .success(let handle) = operationGate.begin(.dictation) else {
                throw ContractInputError(category: "startup-operation-gate-rejected")
            }
            let availableInput = OigoInputDevice(
                uid: "synthetic-input",
                displayName: "Synthetic Input",
                deviceID: 1,
                inputChannelCount: 1,
                nominalSampleRate: 48_000,
                isAlive: true,
                isDefault: true
            )
            let provider = KeyboardStartupReadinessSnapshot(
                microphonePermission: startupCase == .microphone ? .denied : .granted,
                inputSelection: .systemDefault,
                inputDevices: startupCase == .input ? [] : [availableInput]
            )
            let failure = KeyboardStartupReadinessPolicy.failure(using: provider)
            let expected: KeyboardStartupReadinessFailure = startupCase == .microphone
                ? .microphoneDenied : .inputUnavailable
            let coordinator = DictationCoordinator()
            let capture = ScenarioStartupCapture(failure: false)
            let transcription = ScenarioStartupTranscription(mode: .succeed)
            guard operationGate.isCurrent(handle),
                  failure == expected,
                  coordinator.state == .idle,
                  !coordinator.hasActiveWork else {
                throw ContractInputError(category: "readiness-gate-side-effect-mismatch")
            }
            operationGate.complete(handle)
            guard let failure else {
                throw ContractInputError(category: "readiness-provider-did-not-fail")
            }
            result = LifecycleResult(
                terminalCategory: failure.rawValue,
                reachedRecording: coordinator.state == .recording,
                captureCancelCount: capture.cancelCount,
                captureStopCount: capture.stopCount,
                speechCancelCount: transcription.cancelCount,
                duplicateStopCount: max(0, capture.stopCount - 1),
                activeOperationCount: coordinator.activeOwnedOperationCount
            )
        case .success:
            result = try await runCoordinatorCase(startupCase, environment: environment)
        case .speech, .speechAssets, .audioStart, .cancellationBeforeRaw:
            result = try await runCoordinatorCase(startupCase, environment: environment)
        case .releaseDuringPreparation:
            result = try await runReleaseDuringPreparation(environment: environment)
        }
        let timer = try hudProbe.observe(recordingReached: result.reachedRecording)
        let after = try environment.snapshot()
        return Receipt(
            fixture: startupCase.rawValue,
            terminalCategory: result.terminalCategory,
            durableSessionCount: after.historySessionCount - before.historySessionCount,
            activeOperationCount: result.activeOperationCount,
            captureCancelCount: result.captureCancelCount,
            captureStopCount: result.captureStopCount,
            speechCancelCount: result.speechCancelCount,
            duplicateStopCount: result.duplicateStopCount,
            recordingTimerStartCount: timer.recordingTimerStartCount,
            recordingTimerActiveAfterTerminal: timer.recordingTimerActiveAfterTerminal,
            timerResourceCountAfterTerminal: timer.resourceCountAfterTerminal,
            historySessionIDsBefore: before.historySessionIDs.map(\.uuidString).sorted(),
            historySessionIDsAfter: after.historySessionIDs.map(\.uuidString).sorted(),
            historySessionCountBefore: before.historySessionCount,
            historySessionCountAfter: after.historySessionCount,
            historyPreserved: before.historySessionIDs.isSubset(of: after.historySessionIDs),
            rawTranscriptBytesBefore: before.rawTranscriptBytes,
            rawTranscriptBytesAfter: after.rawTranscriptBytes,
            audioBytesAfter: after.audioBytes,
            clipboardWriteCountBefore: before.clipboardWriteCount,
            clipboardWriteCountAfter: after.clipboardWriteCount,
            copyOnlyAcceptedBefore: before.copyOnlyAccepted,
            copyOnlyAcceptedAfter: after.copyOnlyAccepted
        )
    }

    @MainActor
    private static func runCoordinatorCase(
        _ startupCase: StartupCase,
        environment: ScenarioStartupEnvironment
    ) async throws -> LifecycleResult {
        let store = environment.store
        let target = environment.insertion.captureTarget()
        defer { environment.insertion.discardTarget(target) }
        let operationGate = AppOperationGate()
        guard case .success(let handle) = operationGate.begin(.dictation) else {
            throw ContractInputError(category: "startup-operation-gate-rejected")
        }
        let session = try store.createSession()
        let capture = ScenarioStartupCapture(failure: startupCase == .audioStart)
        let transcriptionMode: ScenarioStartupTranscription.Mode = switch startupCase {
        case .speech: .fail("speech recognition is unavailable")
        case .speechAssets: .fail("speech assets are unavailable")
        case .cancellationBeforeRaw: .block
        default: .succeed
        }
        let transcription = ScenarioStartupTranscription(mode: transcriptionMode)
        let coordinator = DictationCoordinator(timeoutPolicy: .testing)
        var reachedRecording = false
        guard operationGate.isCurrent(handle), coordinator.state == .idle else {
            throw ContractInputError(category: "coordinator-started-before-operation-gate")
        }

        if startupCase == .cancellationBeforeRaw {
            let task = Task { @MainActor in
                try await coordinator.startPersistedRecordingWithTranscription(
                    session,
                    using: capture,
                    store: store,
                    transcription: transcription,
                    format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1)
                )
            }
            await transcription.waitUntilStarted()
            task.cancel()
            _ = try? await task.value
        } else {
            _ = try? await coordinator.startPersistedRecordingWithTranscription(
                session,
                using: capture,
                store: store,
                transcription: transcription,
                format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1)
            )
            if startupCase == .success {
                reachedRecording = coordinator.state == .recording
                guard coordinator.state == .recording,
                      try store.load(id: session.id).metadata.state == .recording,
                      transcription.sawDurableSession else {
                    throw ContractInputError(category: "success-missed-durable-recording")
                }
                await coordinator.cancelActiveWork(reason: "contract terminal cleanup")
            }
        }
        operationGate.complete(handle)
        let terminal = try store.load(id: session.id)
        let expectedState: DictationSessionState = startupCase == .cancellationBeforeRaw ? .cancelled
            : startupCase == .success ? .cancelled : .failed
        let expectedCode: DictationFailureCode = switch startupCase {
        case .speech, .speechAssets: .transcriptionFailed
        case .audioStart: .audioEngineStartFailed
        case .success, .cancellationBeforeRaw: .cancelled
        default: .unknownFailure
        }
        guard terminal.metadata.state == expectedState,
              terminal.metadata.failureCode == expectedCode,
              !coordinator.hasActiveWork,
              coordinator.activeOwnedOperationCount == 0,
              transcription.cancelCount == 1,
              capture.cancelCount == 1 else {
            throw ContractInputError(category: "startup-terminal-cleanup-mismatch")
        }
        let terminalCategory: String
        if startupCase == .success {
            terminalCategory = "recording"
        } else if terminal.metadata.state == .cancelled {
            terminalCategory = "cancelled-before-raw"
        } else if terminal.metadata.failureCode == .audioEngineStartFailed {
            terminalCategory = "audio-engine-start-failed"
        } else if terminal.metadata.failureReason?.contains("assets") == true {
            terminalCategory = "speech-assets-unavailable"
        } else if terminal.metadata.failureReason?.contains("speech") == true {
            terminalCategory = "speech-unavailable"
        } else {
            throw ContractInputError(category: "unclassified-startup-terminal")
        }
        return LifecycleResult(
            terminalCategory: terminalCategory,
            reachedRecording: reachedRecording,
            captureCancelCount: capture.cancelCount,
            captureStopCount: capture.stopCount,
            speechCancelCount: transcription.cancelCount,
            duplicateStopCount: max(0, capture.stopCount - 1),
            activeOperationCount: coordinator.activeOwnedOperationCount
        )
    }

    @MainActor
    private static func runReleaseDuringPreparation(
        environment: ScenarioStartupEnvironment
    ) async throws -> LifecycleResult {
        let store = environment.store
        let target = environment.insertion.captureTarget()
        defer { environment.insertion.discardTarget(target) }
        let session = try store.createSession()
        let capture = ScenarioStartupCapture(failure: false)
        let transcription = ScenarioStartupTranscription(mode: .succeed)
        let coordinator = DictationCoordinator(timeoutPolicy: .testing)
        let operationGate = AppOperationGate()
        guard case .success(let handle) = operationGate.begin(.dictation) else {
            throw ContractInputError(category: "startup-operation-gate-rejected")
        }
        var state = DictationState.idle
        var starts = 0
        var stops = 0
        let bridge = GlobalShortcutOperationBridge(
            state: { state },
            start: { starts += 1 },
            stop: { stops += 1 },
            feedback: { _ in }
        )
        guard bridge.receive(.pressed) == .start else {
            throw ContractInputError(category: "keyboard-start-not-delivered")
        }
        state = .preparing
        guard bridge.receive(.released) == .releaseLatched else {
            throw ContractInputError(category: "preparation-release-not-latched")
        }
        _ = try await coordinator.startPersistedRecordingWithTranscription(
            session,
            using: capture,
            store: store,
            transcription: transcription,
            format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1)
        )
        let reachedRecording = coordinator.state == .recording
        state = .recording
        guard bridge.observeState() == .stop, starts == 1, stops == 1 else {
            throw ContractInputError(category: "latched-release-stop-mismatch")
        }
        _ = try await coordinator.stopRecordingWithTranscription()
        operationGate.complete(handle)
        let terminal = try store.load(id: session.id)
        guard terminal.metadata.state == .completed,
              capture.stopCount == 1,
              capture.cancelCount == 0,
              transcription.finishCount == 1,
              transcription.cancelCount == 0,
              !coordinator.hasActiveWork else {
            throw ContractInputError(category: "release-terminal-cleanup-mismatch")
        }
        return LifecycleResult(
            terminalCategory: "released-during-preparation",
            reachedRecording: reachedRecording,
            captureCancelCount: capture.cancelCount,
            captureStopCount: capture.stopCount,
            speechCancelCount: transcription.cancelCount,
            duplicateStopCount: max(0, stops - 1),
            activeOperationCount: coordinator.activeOwnedOperationCount
        )
    }

    private static func runOnMainActor<Value: Sendable>(
        _ operation: @escaping @MainActor () async throws -> Value
    ) throws -> Value {
        let result = StartupResultBox<Value>()
        Task { @MainActor in
            do {
                result.value = .success(try await operation())
            } catch {
                result.value = .failure(error)
            }
        }
        let deadline = Date().addingTimeInterval(5)
        while result.value == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        guard let value = result.value else {
            throw ContractInputError(category: "keyboard-startup-runtime-timeout")
        }
        return try value.get()
    }

    private static func write(receipts: [Receipt], to root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(receipts)
        try data.write(to: root.appendingPathComponent("keyboard-startup.json"), options: .atomic)
    }
}

private final class StartupResultBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Value, Error>?

    var value: Result<Value, Error>? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private struct ScenarioRuntimeSnapshot: Sendable {
    let historySessionIDs: Set<UUID>
    let historySessionCount: Int
    let rawTranscriptBytes: Int
    let audioBytes: Int
    let clipboardWriteCount: Int
    let copyOnlyAccepted: Bool
}

@MainActor
private final class ScenarioStartupEnvironment {
    let store: SessionStore
    let insertion: InsertionService

    private let root: URL
    private let defaultsSuite: String
    private let defaults: UserDefaults
    private let onboardingStore: OigoOnboardingStore
    private let pasteboard: ScenarioStartupPasteboard

    init(fixtureRoot: URL, fixtureName: String) throws {
        root = fixtureRoot.appendingPathComponent(
            "runtime-" + fixtureName + "-" + UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try SessionStore(rootDirectory: root)
        let historySession = try store.createSession()
        _ = try store.update(
            historySession,
            state: .failed,
            failureReason: "synthetic history sentinel",
            failureCode: .unknownFailure
        )

        defaultsSuite = "com.oigo.qa.task05." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: defaultsSuite) else {
            throw ContractInputError(category: "startup-defaults-unavailable")
        }
        self.defaults = defaults
        defaults.removePersistentDomain(forName: defaultsSuite)
        onboardingStore = OigoOnboardingStore(defaults: defaults)
        onboardingStore.save(OigoOnboardingState(step: .complete, copyOnlyAccepted: true))

        pasteboard = ScenarioStartupPasteboard()
        _ = pasteboard.write("synthetic-baseline")
        insertion = InsertionService(
            targetEnvironment: ScenarioStartupTargetEnvironment(),
            pasteboard: pasteboard,
            eventSender: ScenarioStartupEventSender()
        )
    }

    func snapshot() throws -> ScenarioRuntimeSnapshot {
        let sessions = try store.listSessions()
        let rawBytes = sessions.reduce(into: 0) { total, session in
            total += (try? Data(contentsOf: session.rawTextURL).count) ?? 0
        }
        let audioBytes = sessions.reduce(into: 0) { total, session in
            total += (try? Data(contentsOf: session.audioURL).count) ?? 0
        }
        return ScenarioRuntimeSnapshot(
            historySessionIDs: Set(sessions.map(\.id)),
            historySessionCount: sessions.count,
            rawTranscriptBytes: rawBytes,
            audioBytes: audioBytes,
            clipboardWriteCount: pasteboard.writeCount,
            copyOnlyAccepted: onboardingStore.load().copyOnlyAccepted
        )
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: defaultsSuite)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class ScenarioStartupPasteboard: InsertionPasteboard {
    private(set) var writeCount = 0

    func write(_ rawText: String) -> Bool {
        guard !rawText.isEmpty else {
            return false
        }
        writeCount += 1
        return true
    }
}

@MainActor
private final class ScenarioStartupTargetEnvironment: InsertionTargetEnvironment {
    func capture() -> InsertionTargetSnapshot {
        InsertionTargetSnapshot(
            frontmostProcessIdentifier: 1,
            bundleIdentifier: "com.oigo.qa.synthetic",
            focusedElementIdentifier: "synthetic-field",
            role: "AXTextField",
            isSecureTextField: false
        )
    }

    func validate(_ snapshot: InsertionTargetSnapshot) -> TargetValidation {
        _ = snapshot
        return .safe
    }
}

@MainActor
private final class ScenarioStartupEventSender: InsertionEventSender {
    func sendPaste(
        to processIdentifier: Int32,
        revalidate: () -> TargetValidation
    ) -> InsertionEventResult {
        _ = processIdentifier
        guard revalidate() == .safe else {
            return .failed
        }
        return .dispatched
    }
}

private struct HUDTimerObservation: Decodable, Sendable {
    let recordingTimerStartCount: Int
    let recordingTimerActiveAfterTerminal: Bool
    let resourceCountAfterTerminal: Int
}

private final class HUDTimerProbe: @unchecked Sendable {
    private let root: URL
    private let executable: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-task05-hud-timer-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        executable = root.appendingPathComponent("hud-timer-probe")
        let driver = root.appendingPathComponent("main.swift")
        try Self.driver.write(to: driver, atomically: true, encoding: .utf8)
        let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sources = [
            "Sources/Oigo/UI/HUD/OigoHUDState.swift",
            "Sources/Oigo/UI/HUD/OigoHUDPolicy.swift",
            "Sources/Oigo/UI/HUD/OigoHUDLifecycle.swift",
            "Sources/Oigo/UI/HUD/HUDTargetGeometry.swift",
            "Sources/Oigo/UI/HUD/OigoHUDController.swift"
        ].map { repository.appendingPathComponent($0).path }
        _ = try Self.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["swiftc"] + sources + [driver.path, "-framework", "AppKit", "-o", executable.path]
        )
    }

    func observe(recordingReached: Bool) throws -> HUDTimerObservation {
        let data = try Self.run(
            executable: executable,
            arguments: [recordingReached ? "recording" : "preflight"]
        )
        do {
            return try JSONDecoder().decode(HUDTimerObservation.self, from: data)
        } catch {
            throw ContractInputError(category: "hud-timer-observation-malformed")
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func run(executable: URL, arguments: [String]) throws -> Data {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let error = stderr.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: error + output, encoding: .utf8) ?? ""
            throw ContractInputError(
                category: "hud-timer-probe-failed:exit=\(process.terminationStatus):"
                    + detail.prefix(500)
            )
        }
        return output
    }

    private static let driver = #"""
    import AppKit
    import Foundation

    @MainActor
    final class ProbeDelegate: NSObject, NSApplicationDelegate {
        func applicationDidFinishLaunching(_ notification: Notification) {
            _ = notification
            let recordingReached = CommandLine.arguments[1] == "recording"
            let controller = OigoHUDController()
            guard controller.present(.preparing, generation: 1) else { exit(2) }
            var timerStarts = 0
            var generation: UInt64 = 1
            if recordingReached {
                generation = 2
                guard controller.present(.recording, generation: generation, startedAt: Date()) else {
                    exit(3)
                }
                if controller.resourceSnapshot.recordingTimerActive {
                    timerStarts += 1
                }
                generation = 3
                guard controller.present(.cancelledBeforeRaw, generation: generation) else {
                    exit(4)
                }
            }
            guard controller.hide(generation: generation) else { exit(5) }
            let terminal = controller.resourceSnapshot
            let payload: [String: Any] = [
                "recordingTimerStartCount": timerStarts,
                "recordingTimerActiveAfterTerminal": terminal.recordingTimerActive,
                "resourceCountAfterTerminal":
                    (terminal.recordingTimerActive ? 1 : 0)
                    + (terminal.dismissalTaskActive ? 1 : 0)
                    + (terminal.sessionReferenceHeld ? 1 : 0)
            ]
            let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            FileHandle.standardOutput.write(data)
            NSApp.terminate(nil)
        }
    }

    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let delegate = MainActor.assumeIsolated { ProbeDelegate() }
    application.delegate = delegate
    application.run()
    """#
}

private struct ScenarioStartupError: DictationStartupFailureEvidence {
    let dictationStartupFailureReason: String
}

private final class ScenarioStartupCapture: AudioCapturing, @unchecked Sendable {
    private let failure: Bool
    private(set) var cancelCount = 0
    private(set) var stopCount = 0

    init(failure: Bool) {
        self.failure = failure
    }

    func start(
        to descriptor: AudioFileDescriptor,
        onBuffer: @escaping @Sendable (AudioCaptureBuffer) -> Void,
        onFinish: @escaping @Sendable () -> Void,
        onInterruption: @escaping @Sendable (String) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) throws {
        _ = descriptor
        _ = onBuffer
        _ = onFinish
        _ = onInterruption
        _ = onFailure
        if failure {
            throw ScenarioStartupError(dictationStartupFailureReason: "audio engine could not start")
        }
    }

    func stop() throws {
        stopCount += 1
    }

    func cancel() {
        cancelCount += 1
    }
}

private final class ScenarioStartupTranscription: TranscriptionController, @unchecked Sendable {
    enum Mode {
        case succeed
        case fail(String)
        case block
    }

    private let mode: Mode
    private let started: AsyncStream<Void>
    private let startedContinuation: AsyncStream<Void>.Continuation
    private(set) var cancelCount = 0
    private(set) var finishCount = 0
    private(set) var sawDurableSession = false

    init(mode: Mode) {
        self.mode = mode
        let pair = AsyncStream<Void>.makeStream()
        started = pair.stream
        startedContinuation = pair.continuation
    }

    func waitUntilStarted() async {
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
    }

    func start(
        session: DictationSession,
        format: AudioCaptureFormat,
        store: SessionStore,
        onUpdate: @escaping @Sendable (TranscriptionUpdate) -> Void
    ) async throws {
        _ = format
        _ = onUpdate
        sawDurableSession = (try? store.load(id: session.id)) != nil
        startedContinuation.yield()
        switch mode {
        case .succeed:
            return
        case .fail(let reason):
            throw ScenarioStartupError(dictationStartupFailureReason: reason)
        case .block:
            try await Task.sleep(for: .seconds(30))
        }
    }

    func append(_ buffer: AudioCaptureBuffer) {
        _ = buffer
    }

    func finish() async throws -> TranscriptionResult {
        finishCount += 1
        return TranscriptionResult(finalizedText: "", rawTextByteCount: 0)
    }

    func cancel() async throws -> TranscriptionResult? {
        cancelCount += 1
        return TranscriptionResult(finalizedText: "", rawTextByteCount: 0)
    }

    func retrySavedAudio(
        for session: DictationSession,
        store: SessionStore
    ) async throws -> TranscriptionResult {
        _ = session
        _ = store
        return TranscriptionResult(finalizedText: "", rawTextByteCount: 0)
    }
}
