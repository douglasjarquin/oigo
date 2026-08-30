import Foundation
@_spi(Testing) import OigoCore

@MainActor
extension OigoIssue82ContractTests {
    static func testKeyboardStartupReadinessProviderLifecycle() throws {
        let operationGate = AppOperationGate()
        guard case .success(let handle) = operationGate.begin(.dictation) else {
            throw ContractFailure(message: "keyboard readiness did not acquire the operation gate")
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
        let microphoneDenied = KeyboardStartupReadinessSnapshot(
            microphonePermission: .denied,
            inputSelection: .systemDefault,
            inputDevices: [availableInput]
        )
        let inputUnavailable = KeyboardStartupReadinessSnapshot(
            microphonePermission: .granted,
            inputSelection: .systemDefault,
            inputDevices: []
        )
        let coordinator = DictationCoordinator()
        guard operationGate.isCurrent(handle),
              KeyboardStartupReadinessPolicy.failure(using: microphoneDenied) == .microphoneDenied,
              KeyboardStartupReadinessPolicy.failure(using: inputUnavailable) == .inputUnavailable,
              coordinator.state == .idle,
              !coordinator.hasActiveWork,
              coordinator.currentSession == nil else {
            throw ContractFailure(message: "readiness provider started coordinator or session before terminal rejection")
        }
        operationGate.complete(handle)
        guard operationGate.currentHandle == nil else {
            throw ContractFailure(message: "readiness provider leaked the operation gate")
        }
    }

    static func testKeyboardStartupCancellationCleanup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-task05-startup-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let operationGate = AppOperationGate()
        guard case .success(let handle) = operationGate.begin(.dictation) else {
            throw ContractFailure(message: "keyboard startup did not acquire the operation gate")
        }
        let store = try SessionStore(rootDirectory: root)
        let session = try store.createSession()
        let capture = StartupAudioCapture()
        let transcription = StartupCancellationTranscription()
        let coordinator = DictationCoordinator(timeoutPolicy: .testing)
        guard operationGate.isCurrent(handle), coordinator.state == .idle else {
            throw ContractFailure(message: "coordinator start preceded operation-gate ownership")
        }

        let startTask = Task { @MainActor in
            try await coordinator.startPersistedRecordingWithTranscription(
                session,
                using: capture,
                store: store,
                transcription: transcription,
                format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1)
            )
        }
        await transcription.waitUntilStarted()
        guard coordinator.state == .preparing,
              try store.load(id: session.id).metadata.state == .preparing else {
            startTask.cancel()
            _ = try? await startTask.value
            throw ContractFailure(message: "durable session was not established before Speech startup")
        }

        startTask.cancel()
        _ = try? await startTask.value
        operationGate.complete(handle)
        let terminal = try store.load(id: session.id)
        guard terminal.metadata.state == .cancelled,
              terminal.metadata.failureCode == .cancelled,
              coordinator.state == .cancelled,
              !coordinator.hasActiveWork,
              capture.cancelCount == 1,
              capture.stopCount == 0,
              transcription.cancelCount == 1,
              operationGate.currentHandle == nil else {
            throw ContractFailure(
                message: "startup cancellation leaked or duplicated cleanup "
                    + "session=\(terminal.metadata.state.rawValue) "
                    + "captureCancel=\(capture.cancelCount) captureStop=\(capture.stopCount) "
                    + "speechCancel=\(transcription.cancelCount) active=\(coordinator.hasActiveWork)"
            )
        }
    }
}

private final class StartupAudioCapture: AudioCapturing, @unchecked Sendable {
    private(set) var cancelCount = 0
    private(set) var stopCount = 0

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
    }

    func stop() throws {
        stopCount += 1
    }

    func cancel() {
        cancelCount += 1
    }
}

private final class StartupCancellationTranscription: TranscriptionController, @unchecked Sendable {
    private let lock = NSLock()
    private let started: AsyncStream<Void>
    private let startedContinuation: AsyncStream<Void>.Continuation
    private var cancellations = 0

    init() {
        let pair = AsyncStream<Void>.makeStream()
        started = pair.stream
        startedContinuation = pair.continuation
    }

    var cancelCount: Int {
        lock.withLock { cancellations }
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
        _ = session
        _ = format
        _ = store
        _ = onUpdate
        startedContinuation.yield()
        try await Task.sleep(for: .seconds(30))
    }

    func append(_ buffer: AudioCaptureBuffer) {
        _ = buffer
    }

    func finish() async throws -> TranscriptionResult {
        TranscriptionResult(finalizedText: "", rawTextByteCount: 0)
    }

    func cancel() async throws -> TranscriptionResult? {
        lock.withLock { cancellations += 1 }
        try await Task.sleep(for: .milliseconds(30))
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
