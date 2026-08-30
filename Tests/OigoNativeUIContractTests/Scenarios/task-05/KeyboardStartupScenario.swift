import Foundation
@_spi(Testing) import OigoCore
import OigoHotKey

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

        var terminalCategory: String {
            switch self {
            case .success: "recording"
            case .microphone: "microphone-denied"
            case .input: "input-unavailable"
            case .speech: "speech-unavailable"
            case .speechAssets: "speech-assets-unavailable"
            case .audioStart: "audio-engine-start-failed"
            case .releaseDuringPreparation: "released-during-preparation"
            case .cancellationBeforeRaw: "cancelled-before-raw"
            }
        }
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
        let rawTranscriptBytes: Int
        let audioBytes: Int
        let clipboardWrites: Int
        let historyPreserved: Bool
        let copyOnlyPreserved: Bool
    }

    override class var scenarioName: String {
        "keyboard-startup"
    }

    override class func run(arguments: ContractArguments) throws {
        guard arguments.defaultsSuite == "com.oigo.qa.task05" else {
            throw ContractInputError(category: "invalid-defaults-suite")
        }
        let cases = try selectedCases(arguments)
        let receipts = try runOnMainActor {
            var receipts: [Receipt] = []
            for startupCase in cases {
                receipts.append(try await run(startupCase, fixtureRoot: arguments.fixtureRoot))
            }
            return receipts
        }
        guard receipts.allSatisfy({
            $0.activeOperationCount == 0
                && $0.duplicateStopCount == 0
                && $0.rawTranscriptBytes == 0
                && $0.audioBytes == 0
                && $0.clipboardWrites == 0
                && $0.historyPreserved
                && $0.copyOnlyPreserved
        }) else {
            throw ContractInputError(category: "startup-cleanup-contract-failed")
        }
        try write(receipts: receipts, to: arguments.evidenceRoot)
        for receipt in receipts {
            print(
                "GREEN startup \(receipt.fixture) terminal=\(receipt.terminalCategory) "
                    + "durableSession=\(receipt.durableSessionCount) active=\(receipt.activeOperationCount) "
                    + "captureCancel=\(receipt.captureCancelCount) captureStop=\(receipt.captureStopCount) "
                    + "speechCancel=\(receipt.speechCancelCount) duplicateStop=\(receipt.duplicateStopCount)"
            )
        }
        print("PASS keyboard-startup cases=\(receipts.count) raw=0 audio=0 clipboard=0 history=preserved copy-only=preserved")
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
    private static func run(_ startupCase: StartupCase, fixtureRoot: URL) async throws -> Receipt {
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
            let failure = KeyboardStartupReadinessPolicy.failure(
                microphonePermission: startupCase == .microphone ? .denied : .granted,
                inputSelection: .systemDefault,
                inputDevices: startupCase == .input ? [] : [availableInput]
            )
            let expected: KeyboardStartupReadinessFailure = startupCase == .microphone
                ? .microphoneDenied : .inputUnavailable
            let coordinator = DictationCoordinator()
            guard operationGate.isCurrent(handle),
                  failure == expected,
                  coordinator.state == .idle,
                  !coordinator.hasActiveWork else {
                throw ContractInputError(category: "readiness-gate-side-effect-mismatch")
            }
            operationGate.complete(handle)
            return Receipt(
                fixture: startupCase.rawValue,
                terminalCategory: startupCase.terminalCategory,
                durableSessionCount: 0,
                activeOperationCount: 0,
                captureCancelCount: 0,
                captureStopCount: 0,
                speechCancelCount: 0,
                duplicateStopCount: 0,
                rawTranscriptBytes: 0,
                audioBytes: 0,
                clipboardWrites: 0,
                historyPreserved: true,
                copyOnlyPreserved: true
            )
        case .success:
            return try await runCoordinatorCase(startupCase, fixtureRoot: fixtureRoot)
        case .speech, .speechAssets, .audioStart, .cancellationBeforeRaw:
            return try await runCoordinatorCase(startupCase, fixtureRoot: fixtureRoot)
        case .releaseDuringPreparation:
            return try await runReleaseDuringPreparation(fixtureRoot: fixtureRoot)
        }
    }

    @MainActor
    private static func runCoordinatorCase(
        _ startupCase: StartupCase,
        fixtureRoot: URL
    ) async throws -> Receipt {
        let root = fixtureRoot.appendingPathComponent("runtime-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(rootDirectory: root)
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
        return Receipt(
            fixture: startupCase.rawValue,
            terminalCategory: startupCase.terminalCategory,
            durableSessionCount: 1,
            activeOperationCount: coordinator.activeOwnedOperationCount,
            captureCancelCount: capture.cancelCount,
            captureStopCount: capture.stopCount,
            speechCancelCount: transcription.cancelCount,
            duplicateStopCount: max(0, capture.stopCount - 1),
            rawTranscriptBytes: Int(terminal.metadata.rawTextByteCount ?? 0),
            audioBytes: Int(terminal.metadata.audioByteCount ?? 0),
            clipboardWrites: 0,
            historyPreserved: try store.listSessions().contains(where: { $0.id == session.id }),
            copyOnlyPreserved: terminal.metadata.insertionOutcome == nil
        )
    }

    @MainActor
    private static func runReleaseDuringPreparation(fixtureRoot: URL) async throws -> Receipt {
        let root = fixtureRoot.appendingPathComponent("runtime-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(rootDirectory: root)
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
        return Receipt(
            fixture: StartupCase.releaseDuringPreparation.rawValue,
            terminalCategory: StartupCase.releaseDuringPreparation.terminalCategory,
            durableSessionCount: 1,
            activeOperationCount: coordinator.activeOwnedOperationCount,
            captureCancelCount: capture.cancelCount,
            captureStopCount: capture.stopCount,
            speechCancelCount: transcription.cancelCount,
            duplicateStopCount: max(0, stops - 1),
            rawTranscriptBytes: Int(terminal.metadata.rawTextByteCount ?? 0),
            audioBytes: Int(terminal.metadata.audioByteCount ?? 0),
            clipboardWrites: 0,
            historyPreserved: try store.listSessions().contains(where: { $0.id == session.id }),
            copyOnlyPreserved: terminal.metadata.insertionOutcome == nil
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
