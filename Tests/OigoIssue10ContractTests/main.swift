import Darwin
import Foundation
@_spi(Testing) import OigoCore
@_spi(Testing) import OigoTranscription
@_spi(Testing) import OigoInsertion

private struct ContractFailure: Error, CustomStringConvertible {
    let message: String

    var description: String {
        message
    }
}

@main
@available(macOS 26.0, *)
@MainActor
private struct OigoIssue10ContractTests {
    static func main() async {
        let filter = CommandLine.arguments.dropFirst().drop(while: { $0 != "--filter" }).dropFirst().first
        let tests: [(String, () async throws -> Void)] = [
            ("capture failure persists durable code after metadata fault", testCaptureFailurePersistsDurableCodeAfterMetadataFault),
            ("device interruption records stable code", testDeviceInterruptionRecordsStableCode),
            ("stale callback cannot fail a new session", testStaleCallbackCannotFailNewSession),
            ("rapid cancellation cycles release capture", testRapidCancellationCyclesReleaseCapture),
            ("cancellation terminalizes processing without paste", testCancellationTerminalizesProcessingWithoutPaste),
            ("cancellation metadata failure retains terminal state", testCancellationMetadataFailureRetainsTerminalState),
            ("cancellation covers every active processing state", testCancellationCoversEveryActiveProcessingState),
            ("fault injection matrix is isolated", testFaultInjectionMatrix),
            ("shutdown waits for registered task", testShutdownWaitsForRegisteredTask),
            ("transcription shutdown waits for registered task", testTranscriptionShutdownWaitsForRegisteredTask),
            ("transcription shutdown cancels active transcription", testTranscriptionShutdownCancelsActiveTranscription)
        ]

        var failures = 0
        var matched = 0
        for (name, test) in tests where filter == nil || name.contains(filter ?? "") {
            matched += 1
            do {
                try await test()
                print("GREEN: " + name)
            } catch {
                failures += 1
                print("FAIL: " + name + ": " + String(describing: error))
            }
        }

        if matched == 0 {
            print("FAIL: no issue #10 contract scenarios matched filter")
            exit(1)
        }
        if failures == 0 {
            print("GREEN: all issue #10 contract scenarios")
            exit(0)
        }
        print("FAILURES=" + String(failures))
        exit(1)
    }

    private static func testCaptureFailurePersistsDurableCodeAfterMetadataFault() async throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let store = try SessionStore(rootDirectory: root)
        let capture = ScriptedAudioCapture()
        let coordinator = DictationCoordinator()
        let session = try coordinator.startRecording(using: capture, store: store)
        capture.writePartialCapture()
        store.failNextMetadataWriteForTesting()
        capture.emitFailure("audio file write failed: disk full")
        await Task.yield()

        let saved = try store.load(id: session.id)
        let metadata = try metadataObject(at: saved.metadataURL)
        guard coordinator.state == .failed,
              saved.metadata.state == .failed,
              saved.metadata.failureReason?.contains("disk full") == true,
              metadata["failureCode"] as? String == "audio_write_failed",
              saved.metadata.audioByteCount ?? 0 > 0,
              FileManager.default.fileExists(atPath: saved.audioURL.path),
              !capture.isActive else {
            throw ContractFailure(message: "capture failure did not durably preserve partial audio, stable failure code, and terminal cleanup")
        }
    }

    private static func testDeviceInterruptionRecordsStableCode() async throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let store = try SessionStore(rootDirectory: root)
        let capture = ScriptedAudioCapture()
        let coordinator = DictationCoordinator()
        let session = try coordinator.startRecording(using: capture, store: store)
        capture.writePartialCapture()
        capture.emitInterruption("default input device changed: AirPods connected")
        await Task.yield()

        let saved = try store.load(id: session.id)
        let metadata = try metadataObject(at: saved.metadataURL)
        guard coordinator.state == .interrupted,
              saved.metadata.state == .interrupted,
              saved.metadata.failureReason?.contains("AirPods") == true,
              metadata["failureCode"] as? String == "audio_input_device_changed",
              saved.metadata.audioByteCount ?? 0 > 0,
              !capture.isActive else {
            throw ContractFailure(message: "input-device interruption did not leave an actionable, durable terminal session")
        }
    }

    private static func testStaleCallbackCannotFailNewSession() async throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let store = try SessionStore(rootDirectory: root)
        let capture = ScriptedAudioCapture()
        let raceFaults = DictationFaultInjector()
        let coordinator = DictationCoordinator(faultInjector: raceFaults)
        let first = try coordinator.startRecording(using: capture, store: store)
        raceFaults.arm(.cancellationRace)
        _ = try coordinator.cancelRecording()
        let second = try coordinator.startRecording(using: capture, store: store)
        coordinator.deliverCancellationRaceForTesting()
        await Task.yield()

        let savedFirst = try store.load(id: first.id)
        let savedSecond = try store.load(id: second.id)
        guard savedFirst.metadata.state == .cancelled,
              savedSecond.metadata.state == .recording,
              coordinator.state == .recording,
              capture.isActive else {
            throw ContractFailure(message: "a callback from a completed session changed the newer session")
        }
        _ = try coordinator.cancelRecording()
    }

    private static func testRapidCancellationCyclesReleaseCapture() throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let store = try SessionStore(rootDirectory: root)
        let capture = ScriptedAudioCapture()
        let coordinator = DictationCoordinator()

        for index in 0..<100 {
            let session = try coordinator.startRecording(
                using: capture,
                store: store,
                now: Date(timeIntervalSince1970: 20_000 + Double(index))
            )
            let cancelled = try coordinator.cancelRecording(
                at: Date(timeIntervalSince1970: 20_000 + Double(index) + 0.5)
            )
            guard session.id == cancelled.id,
                  cancelled.metadata.state == .cancelled,
                  coordinator.activeTaskCount == 0,
                  !capture.isActive else {
                throw ContractFailure(message: "cancellation cycle (index) left capture or coordinator work active")
            }
        }
    }

    private static func testCancellationTerminalizesProcessingWithoutPaste() async throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let faults = DictationFaultInjector()
        let store = try SessionStore(rootDirectory: root, faultInjector: faults)
        let capture = ScriptedAudioCapture()
        let coordinator = DictationCoordinator()
        let transcription = ProcessingTranscriptionController()
        let session = try await coordinator.startRecordingWithTranscription(
            using: capture,
            store: store,
            transcription: transcription,
            format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1)
        )
        let completed = try await coordinator.stopRecordingWithTranscription()
        guard completed.metadata.rawTextByteCount == 9 else {
            throw ContractFailure(message: "processing fixture did not persist a canonical transcript")
        }
        _ = try coordinator.beginInsertion(using: store, requiresCleanup: true)
        let processingTask = try coordinator.startTask {
            while !Task.isCancelled {
                await Task.yield()
            }
        }
        faults.arm(.diskWriteFailure)
        processingTask.cancel()
        await coordinator.cancelActiveWork()
        await processingTask.value
        let terminal = coordinator.currentSession
        let saved = try store.load(id: session.id)
        guard terminal?.metadata.insertionOutcome == .failed,
              saved.metadata.insertionOutcome == .failed,
              coordinator.state == .failed,
              !coordinator.hasActiveWork else {
            throw ContractFailure(message: "processing cancellation left work active or insertable")
        }
    }

    private static func testCancellationMetadataFailureRetainsTerminalState() async throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let faults = DictationFaultInjector()
        let store = try SessionStore(rootDirectory: root, faultInjector: faults)
        let capture = ScriptedAudioCapture()
        let coordinator = DictationCoordinator()
        let transcription = ProcessingTranscriptionController()
        let session = try await coordinator.startRecordingWithTranscription(
            using: capture,
            store: store,
            transcription: transcription,
            format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1)
        )
        _ = try await coordinator.stopRecordingWithTranscription()
        _ = try coordinator.beginInsertion(using: store, requiresCleanup: true)
        let processingTask = try coordinator.startTask {
            while !Task.isCancelled {
                await Task.yield()
            }
        }
        faults.arm(.diskWriteFailure, times: 2)
        processingTask.cancel()
        await coordinator.cancelActiveWork()
        await processingTask.value
        let terminal = coordinator.currentSession
        let saved = try store.load(id: session.id)
        guard terminal?.metadata.insertionOutcome == .failed,
              terminal?.metadata.insertionFailureReason == "dictation operation cancelled",
              saved.metadata.insertionOutcome == nil,
              coordinator.state == .failed,
              !coordinator.hasActiveWork else {
            throw ContractFailure(message: "cancellation metadata failure did not retain an in-memory terminal insertion result")
        }
    }

    private static func testCancellationCoversEveryActiveProcessingState() async throws {
        let preparingRoot = try temporaryDirectory()
        defer { cleanup(preparingRoot) }
        let preparingStore = try SessionStore(rootDirectory: preparingRoot)
        let preparingCapture = ScriptedAudioCapture()
        let preparingTranscription = BlockingTranscriptionController(blockStart: true)
        let preparingCoordinator = DictationCoordinator()
        let preparingTask = Task { @MainActor in
            _ = try? await preparingCoordinator.startRecordingWithTranscription(
                using: preparingCapture,
                store: preparingStore,
                transcription: preparingTranscription,
                format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1)
            )
        }
        while !preparingTranscription.isStartingForTesting {
            await Task.yield()
        }
        guard preparingCoordinator.state == .preparing else {
            throw ContractFailure(message: "preparing cancellation fixture did not reach preparing")
        }
        preparingTask.cancel()
        await preparingTask.value
        guard preparingCoordinator.state == .cancelled,
              !preparingCoordinator.hasActiveWork,
              !preparingTranscription.isRunningForTesting else {
            throw ContractFailure(message: "preparing cancellation did not terminalize and release work")
        }

        let finalizingRoot = try temporaryDirectory()
        defer { cleanup(finalizingRoot) }
        let finalizingStore = try SessionStore(rootDirectory: finalizingRoot)
        let finalizingCapture = ScriptedAudioCapture()
        let finalizingTranscription = BlockingTranscriptionController(blockFinish: true)
        let finalizingCoordinator = DictationCoordinator()
        _ = try await finalizingCoordinator.startRecordingWithTranscription(
            using: finalizingCapture,
            store: finalizingStore,
            transcription: finalizingTranscription,
            format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1)
        )
        let stopTask = Task { @MainActor in
            _ = try? await finalizingCoordinator.stopRecordingWithTranscription()
        }
        while finalizingCoordinator.state != .finalizing {
            await Task.yield()
        }
        await finalizingCoordinator.cancelActiveWork()
        await stopTask.value
        guard finalizingCoordinator.state == .cancelled,
              !finalizingCoordinator.hasActiveWork,
              !finalizingTranscription.isRunningForTesting else {
            throw ContractFailure(message: "finalizing cancellation did not terminalize and release work")
        }

        let insertingRoot = try temporaryDirectory()
        defer { cleanup(insertingRoot) }
        let insertingStore = try SessionStore(rootDirectory: insertingRoot)
        let insertingCapture = ScriptedAudioCapture()
        let insertingTranscription = ProcessingTranscriptionController()
        let insertingCoordinator = DictationCoordinator()
        let insertingSession = try await insertingCoordinator.startRecordingWithTranscription(
            using: insertingCapture,
            store: insertingStore,
            transcription: insertingTranscription,
            format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1)
        )
        _ = try await insertingCoordinator.stopRecordingWithTranscription()
        _ = try insertingCoordinator.beginInsertion(using: insertingStore, requiresCleanup: false)
        await insertingCoordinator.cancelActiveWork()
        guard insertingCoordinator.state == .failed,
              insertingCoordinator.currentSession?.id == insertingSession.id,
              insertingCoordinator.currentSession?.metadata.insertionOutcome == .failed,
              !insertingCoordinator.hasActiveWork else {
            throw ContractFailure(message: "inserting cancellation did not leave a terminal failed insertion")
        }
    }

    private static func testFaultInjectionMatrix() async throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }

        let diskFaults = DictationFaultInjector()
        let diskStore = try SessionStore(rootDirectory: root.appendingPathComponent("disk"), faultInjector: diskFaults)
        let diskSession = try diskStore.createSession()
        diskFaults.arm(.diskWriteFailure)
        do {
            _ = try diskStore.update(diskSession, state: .recording)
            throw ContractFailure(message: "disk-write fault did not reach SessionStore")
        } catch let error as SessionStoreError {
            guard case .invalidMetadata = error else {
                throw ContractFailure(message: "disk-write fault returned the wrong error: " + String(describing: error))
            }
        }

        let speechFaults = DictationFaultInjector()
        let speechStore = try SessionStore(rootDirectory: root.appendingPathComponent("speech"))
        let transcription = TranscriptionService(faultInjector: speechFaults)
        speechFaults.arm(.speechFailure)
        do {
            _ = try await transcription.deliverFinalAtStartupBoundaryForTesting(
                range: TranscriptionRange(startMilliseconds: 0, endMilliseconds: 100),
                text: "speech fault"
            )
            throw ContractFailure(message: "speech fault did not stop transcription startup")
        } catch let error as TranscriptionError {
            guard case .analysisFailed(let reason) = error,
                  reason.contains("fault injection") else {
                throw ContractFailure(message: "speech fault returned the wrong error: " + String(describing: error))
            }
        }

        let cleanupFaults = DictationFaultInjector()
        cleanupFaults.arm(.cleanupTimeout)
        let cleaner = TranscriptCleanupCoordinator(
            cleanerFactory: { SuccessfulCleaner() },
            faultInjector: cleanupFaults
        )
        let cleanupDecision = await cleaner.resolve(
            mode: .clean,
            rawText: "keep this transcript",
            deadlineNanoseconds: 1_000_000
        )
        guard cleanupDecision.cleanText == nil,
              cleanupDecision.fallbackReason == .timeout else {
            throw ContractFailure(message: "cleanup timeout fault did not select raw fallback")
        }

        let targetFaults = DictationFaultInjector()
        let targetSession = try speechStore.createSession()
        _ = try speechStore.persistRawText("copy me", for: targetSession)
        let environment = TestTargetEnvironment()
        let pasteboard = TestPasteboard()
        let eventSender = TestEventSender()
        let insertion = InsertionService(
            targetEnvironment: environment,
            pasteboard: pasteboard,
            eventSender: eventSender,
            faultInjector: targetFaults
        )
        targetFaults.arm(.targetLoss)
        let insertionResult = insertion.insertRawText(
            for: targetSession,
            store: speechStore,
            target: environment.snapshot
        )
        guard insertionResult.outcome == .copied,
              eventSender.sendCount == 0,
              pasteboard.lastText == "copy me" else {
            throw ContractFailure(message: "target-loss fault did not produce copy-only recovery")
        }

        guard DictationFailureCode.infer(from: "automatic cleanup exceeded its deadline") == .cleanupTimedOut else {
            throw ContractFailure(message: "cleanup deadline did not map to a stable failure code")
        }
    }

    private static func testShutdownWaitsForRegisteredTask() async throws {
        let coordinator = DictationCoordinator()
        let receipt = ShutdownReceipt()
        _ = try coordinator.startTask {
            while !Task.isCancelled {
                await Task.yield()
            }
            receipt.finished = true
        }
        await coordinator.shutdownAndWait()
        guard receipt.finished, coordinator.activeTaskCount == 0 else {
            throw ContractFailure(message: "shutdown returned before registered child task cleanup completed")
        }
    }

    private static func testTranscriptionShutdownWaitsForRegisteredTask() async throws {
        let coordinator = DictationCoordinator()
        let receipt = ShutdownReceipt()
        _ = try coordinator.startTask {
            while !Task.isCancelled {
                await Task.yield()
            }
            receipt.finished = true
        }
        await coordinator.shutdownWithTranscription()
        guard receipt.finished, coordinator.activeTaskCount == 0 else {
            throw ContractFailure(message: "transcription shutdown returned before registered child task cleanup completed")
        }
    }

    private static func testTranscriptionShutdownCancelsActiveTranscription() async throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let store = try SessionStore(rootDirectory: root)
        let capture = ScriptedAudioCapture()
        let transcription = ProcessingTranscriptionController()
        let coordinator = DictationCoordinator()
        _ = try await coordinator.startRecordingWithTranscription(
            using: capture,
            store: store,
            transcription: transcription,
            format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1)
        )
        await coordinator.shutdownWithTranscription()
        guard !transcription.isRunningForTesting,
              coordinator.state == .interrupted,
              !coordinator.hasActiveWork else {
            throw ContractFailure(message: "transcription shutdown did not cancel active transcription and release coordinator work")
        }
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue10-contract-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func cleanup(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
        print("CLEANUP: removed " + root.path)
    }

    private static func metadataObject(at url: URL) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw ContractFailure(message: "session metadata was not a JSON object")
        }
        return object
    }
}

private final class ScriptedAudioCapture: AudioCapturing, @unchecked Sendable {
    private struct Callbacks {
        let onFinish: @Sendable () -> Void
        let onInterruption: @Sendable (String) -> Void
        let onFailure: @Sendable (String) -> Void
    }

    private var callbacks: [Callbacks] = []
    private var descriptor: AudioFileDescriptor?
    private(set) var isActive = false
    private var activeCallbackIndex: Int?

    func start(
        to descriptor: AudioFileDescriptor,
        onBuffer: @escaping @Sendable (AudioCaptureBuffer) -> Void,
        onFinish: @escaping @Sendable () -> Void,
        onInterruption: @escaping @Sendable (String) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) throws {
        _ = onBuffer
        self.descriptor = descriptor
        callbacks.append(
            Callbacks(
                onFinish: onFinish,
                onInterruption: onInterruption,
                onFailure: onFailure
            )
        )
        activeCallbackIndex = callbacks.count - 1
        isActive = true
    }

    func stop() throws {
        cancel()
    }

    func cancel() {
        guard isActive else {
            return
        }
        isActive = false
        if let activeCallbackIndex {
            callbacks[activeCallbackIndex].onFinish()
        }
        self.activeCallbackIndex = nil
        descriptor?.close()
        descriptor = nil
    }

    func writePartialCapture() {
        let data = Data(repeating: 0x41, count: 64)
        guard let descriptor else {
            return
        }
        _ = data.withUnsafeBytes { bytes in
            Darwin.write(descriptor.rawValue, bytes.baseAddress, data.count)
        }
    }

    func emitFailure(_ reason: String, callbackIndex: Int? = nil) {
        let index = callbackIndex ?? activeCallbackIndex ?? callbacks.count - 1
        guard callbacks.indices.contains(index) else {
            return
        }
        callbacks[index].onFailure(reason)
    }

    func emitInterruption(_ reason: String) {
        guard let index = activeCallbackIndex, callbacks.indices.contains(index) else {
            return
        }
        callbacks[index].onInterruption(reason)
    }
}

@available(macOS 26.0, *)
private struct SuccessfulCleaner: TranscriptCleaner {
    func availability() -> TranscriptCleanupAvailability {
        .available
    }

    func cancel() {}

    func clean(
        chunk: String,
        deadlineNanoseconds: UInt64
    ) async -> TranscriptCleanupGeneration {
        .success(chunk)
    }
}

@MainActor
private final class TestTargetEnvironment: InsertionTargetEnvironment {
    let snapshot = InsertionTargetSnapshot(
        frontmostProcessIdentifier: 10,
        bundleIdentifier: "com.example.editor",
        focusedElementIdentifier: "field",
        role: "AXTextArea",
        isSecureTextField: false
    )

    func capture() -> InsertionTargetSnapshot {
        snapshot
    }

    func validate(_ snapshot: InsertionTargetSnapshot) -> TargetValidation {
        .safe
    }
}

@MainActor
private final class TestPasteboard: InsertionPasteboard {
    private(set) var lastText: String?

    func write(_ rawText: String) -> Bool {
        lastText = rawText
        return true
    }
}

@MainActor
private final class TestEventSender: InsertionEventSender {
    private(set) var sendCount = 0

    func sendPaste(
        to processIdentifier: Int32,
        revalidate: () -> TargetValidation
    ) -> InsertionEventResult {
        sendCount += 1
        return .dispatched
    }
}

private final class ShutdownReceipt: @unchecked Sendable {
    var finished = false
}

@available(macOS 26.0, *)
private final class BlockingTranscriptionController: TranscriptionController, @unchecked Sendable {
    private let lock = NSLock()
    private let blockStart: Bool
    private let blockFinish: Bool
    private var cancellationRequested = false
    private var starting = false
    private var finishing = false
    private var running = false
    private var session: DictationSession?
    private var store: SessionStore?

    init(blockStart: Bool = false, blockFinish: Bool = false) {
        self.blockStart = blockStart
        self.blockFinish = blockFinish
    }

    var isStartingForTesting: Bool {
        withState { starting }
    }

    var isRunningForTesting: Bool {
        withState { starting || finishing || running }
    }

    func start(
        session: DictationSession,
        format: AudioCaptureFormat,
        store: SessionStore,
        onUpdate: @escaping @Sendable (TranscriptionUpdate) -> Void
    ) async throws {
        guard format.isValid else {
            throw TranscriptionError.invalidCaptureFormat
        }
        _ = onUpdate
        let shouldBlock = withState {
            self.session = session
            self.store = store
            starting = true
            return blockStart
        }
        if shouldBlock {
            while true {
                let cancelled = withState { cancellationRequested }
                if cancelled {
                    withState { starting = false }
                    throw TranscriptionError.cancelled
                }
                await Task.yield()
            }
        }
        let cancelled = withState {
            starting = false
            let cancelled = cancellationRequested
            running = !cancelled
            return cancelled
        }
        if cancelled {
            throw TranscriptionError.cancelled
        }
    }

    func append(_ buffer: AudioCaptureBuffer) {
        _ = buffer
    }

    func finish() async throws -> TranscriptionResult {
        let (shouldBlock, cancelledBeforeStart, session, store) = withState {
            finishing = true
            return (blockFinish, cancellationRequested, self.session, self.store)
        }
        if shouldBlock {
            while true {
                let cancelled = withState { cancellationRequested }
                if cancelled {
                    withState {
                        finishing = false
                        running = false
                    }
                    throw TranscriptionError.cancelled
                }
                await Task.yield()
            }
        }
        guard !cancelledBeforeStart,
              let session,
              let store else {
            withState {
                finishing = false
                running = false
            }
            throw TranscriptionError.cancelled
        }
        let text = "finalize me"
        _ = try store.persistRawText(text, for: session)
        withState {
            finishing = false
            running = false
        }
        return TranscriptionResult(
            finalizedText: text,
            rawTextByteCount: Int64(text.utf8.count)
        )
    }

    func cancel() async throws -> TranscriptionResult? {
        withState {
            cancellationRequested = true
            starting = false
            finishing = false
            running = false
        }
        return nil
    }

    private func withState<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func retrySavedAudio(
        for session: DictationSession,
        store: SessionStore
    ) async throws -> TranscriptionResult {
        _ = session
        _ = store
        throw TranscriptionError.notRunning
    }
}

@available(macOS 26.0, *)
private final class ProcessingTranscriptionController: TranscriptionController, @unchecked Sendable {
    private var session: DictationSession?
    private var store: SessionStore?
    private var isRunning = false

    var isRunningForTesting: Bool {
        isRunning
    }

    func start(
        session: DictationSession,
        format: AudioCaptureFormat,
        store: SessionStore,
        onUpdate: @escaping @Sendable (TranscriptionUpdate) -> Void
    ) async throws {
        guard format.isValid else {
            throw TranscriptionError.invalidCaptureFormat
        }
        self.session = session
        self.store = store
        isRunning = true
        _ = onUpdate
    }

    func append(_ buffer: AudioCaptureBuffer) {
        _ = buffer
    }

    func finish() async throws -> TranscriptionResult {
        guard isRunning, let session, let store else {
            throw TranscriptionError.notRunning
        }
        isRunning = false
        let text = "cancel me"
        _ = try store.persistRawText(text, for: session)
        self.session = nil
        self.store = nil
        return TranscriptionResult(
            finalizedText: text,
            rawTextByteCount: Int64(text.utf8.count)
        )
    }

    func cancel() async throws -> TranscriptionResult? {
        isRunning = false
        session = nil
        store = nil
        return nil
    }

    func retrySavedAudio(
        for session: DictationSession,
        store: SessionStore
    ) async throws -> TranscriptionResult {
        _ = session
        _ = store
        throw TranscriptionError.notRunning
    }
}
