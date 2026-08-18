import Darwin
import Foundation
@_spi(Testing) import OigoCore
@_spi(Testing) import OigoTranscription

private struct ContractFailure: Error, CustomStringConvertible {
    let message: String

    var description: String {
        message
    }
}

@main
@available(macOS 26.0, *)
private struct OigoIssue78ContractTests {
    @MainActor
    static func main() async {
        let filter = CommandLine.arguments.dropFirst().drop(while: { $0 != "--filter" }).dropFirst().first
        let tests: [(String, () async throws -> Void)] = [
            ("cancellation returns from noncooperative finalization", testCancellationReturnsFromNoncooperativeFinalization),
            ("finalization timeout preserves recovery", testFinalizationTimeoutPreservesRecovery),
            ("startup timeout preserves ownership", testStartupTimeoutPreservesOwnership),
            ("retry timeout preserves canonical raw text", testRetryTimeoutPreservesCanonicalRawText),
            ("interruption timeout preserves terminal outcome", testInterruptionTimeoutPreservesTerminalOutcome),
            ("shutdown timeout replies with stable outcome", testShutdownTimeoutRepliesWithStableOutcome),
            ("one hundred lifecycle cycles release resources", testOneHundredLifecycleCyclesReleaseResources)
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
            print("FAIL: no issue #78 contract scenarios matched filter")
            exit(1)
        }
        if failures == 0 {
            print("GREEN: all issue #78 contract scenarios")
            exit(0)
        }
        print("FAILURES=" + String(failures))
        exit(1)
    }

    @MainActor
    private static func testCancellationReturnsFromNoncooperativeFinalization() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue78-cancellation-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootDirectory: root)
        let capture = ContractAudioCapture()
        let transcription = NonCooperativeFinalizationController()
        let coordinator = DictationCoordinator()
        _ = try await coordinator.startRecordingWithTranscription(
            using: capture,
            store: store,
            transcription: transcription,
            format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1)
        )

        let completed = CompletionFlag()
        let stopTask = Task { @MainActor in
            defer { completed.mark() }
            _ = try? await coordinator.stopRecordingWithTranscription()
        }
        await transcription.waitUntilFinishStarted()
        stopTask.cancel()
        try await Task.sleep(for: .milliseconds(400))

        guard completed.value else {
            transcription.releaseFinish()
            _ = await stopTask.value
            throw ContractFailure(message: "cancellation remained inside noncooperative finalization after 400ms")
        }

        transcription.releaseFinish()
        _ = await stopTask.value
    }

    @MainActor
    private static func testFinalizationTimeoutPreservesRecovery() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue78-finalization-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootDirectory: root)
        let capture = ContractAudioCapture()
        let transcription = NonCooperativeFinalizationController()
        let updates = UpdateCollector()
        let coordinator = DictationCoordinator(timeoutPolicy: .testing)
        let session = try await coordinator.startRecordingWithTranscription(
            using: capture,
            store: store,
            transcription: transcription,
            format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1),
            onUpdate: { update in updates.append(update) }
        )
        _ = try store.persistRawText("committed segment", for: session)
        transcription.emit(TranscriptionUpdate(
            finalizedSegment: nil,
            volatilePreview: "volatile preview",
            isFinal: false
        ))

        let completed = CompletionFlag()
        let stopTask = Task { @MainActor in
            defer { completed.mark() }
            _ = try? await coordinator.stopRecordingWithTranscription()
        }
        await transcription.waitUntilFinishStarted()
        try await Task.sleep(for: .milliseconds(400))

        guard completed.value,
              let timedOut = coordinator.currentSession,
              timedOut.metadata.state == .failed,
              timedOut.metadata.failureCode == .transcriptionTimedOut,
              try store.readRawText(for: timedOut) == "committed segment",
              FileManager.default.fileExists(atPath: timedOut.audioURL.path),
              coordinator.activeOwnedOperationCount > 0 else {
            transcription.releaseFinish()
            _ = await stopTask.value
            throw ContractFailure(message: "finalization timeout did not preserve canonical recovery or owned Speech work")
        }

        let lateUpdateCount = updates.values.count
        transcription.emit(TranscriptionUpdate(
            finalizedSegment: "late final",
            volatilePreview: "late preview",
            isFinal: true
        ))
        try await Task.sleep(for: .milliseconds(50))
        guard updates.values.count == lateUpdateCount,
              try store.readRawText(for: timedOut) == "committed segment" else {
            transcription.releaseFinish()
            _ = await stopTask.value
            throw ContractFailure(message: "late result mutated the timed-out operation")
        }

        let replacementTranscription = NonCooperativeFinalizationController()
        do {
            _ = try await coordinator.startRecordingWithTranscription(
                using: ContractAudioCapture(),
                store: store,
                transcription: replacementTranscription,
                format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1)
            )
            throw ContractFailure(message: "new transcription overlapped unreleased timed-out Speech work")
        } catch let error as DictationCoordinatorError {
            guard error == .workAlreadyActive else {
                throw error
            }
        }

        transcription.releaseFinish()
        _ = await stopTask.value
        try await Task.sleep(for: .milliseconds(150))
        guard coordinator.activeOwnedOperationCount == 0 else {
            throw ContractFailure(message: "timed-out Speech work was not released after the fixture permitted it")
        }

        _ = try await coordinator.startRecordingWithTranscription(
            using: ContractAudioCapture(),
            store: store,
            transcription: replacementTranscription,
            format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1)
        )
        await coordinator.cancelActiveWork()
    }

    @MainActor
    private static func testStartupTimeoutPreservesOwnership() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue78-startup-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootDirectory: root)
        let transcription = NonCooperativeStartupController()
        let coordinator = DictationCoordinator(timeoutPolicy: .testing)
        let completed = CompletionFlag()
        let startTask = Task { @MainActor in
            defer { completed.mark() }
            _ = try? await coordinator.startRecordingWithTranscription(
                using: ContractAudioCapture(),
                store: store,
                transcription: transcription,
                format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1)
            )
        }

        await transcription.waitUntilStartStarted()
        try await Task.sleep(for: .milliseconds(250))
        guard completed.value,
              coordinator.currentSession?.metadata.state == .failed,
              coordinator.currentSession?.metadata.failureCode == .transcriptionTimedOut,
              coordinator.activeOwnedOperationCount > 0,
              coordinator.hasActiveTranscription else {
            transcription.releaseStart()
            _ = await startTask.value
            throw ContractFailure(message: "startup timeout did not return with a stable failure and owned Speech work")
        }

        do {
            _ = try await coordinator.startRecordingWithTranscription(
                using: ContractAudioCapture(),
                store: store,
                transcription: ImmediateTranscriptionController(),
                format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1)
            )
            throw ContractFailure(message: "replacement startup overlapped unreleased startup work")
        } catch let error as DictationCoordinatorError {
            guard error == .workAlreadyActive else {
                throw error
            }
        }

        transcription.releaseStart()
        _ = await startTask.value
        try await waitForOwnedOperationsToRelease(coordinator)
        try await Task.sleep(for: .milliseconds(50))
        guard coordinator.activeOwnedOperationCount == 0,
              !coordinator.hasActiveTranscription else {
            throw ContractFailure(message: "startup loser remained owned after release")
        }
    }

    @MainActor
    private static func testRetryTimeoutPreservesCanonicalRawText() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue78-retry-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootDirectory: root)
        let created = try store.createSession()
        let failed = try store.update(
            created,
            state: .failed,
            at: Date(),
            failureReason: "live transcription failed",
            failureCode: .transcriptionFailed
        )
        let canonical = try store.persistRawText("prior canonical", for: failed)
        let transcription = NonCooperativeRetryController()
        let coordinator = DictationCoordinator(timeoutPolicy: .testing)
        let completed = CompletionFlag()
        let retryTask = Task { @MainActor in
            defer { completed.mark() }
            _ = try? await coordinator.retryRecordingWithTranscription(
                for: canonical,
                using: transcription,
                store: store
            )
        }

        await transcription.waitUntilRetryStarted()
        try await Task.sleep(for: .milliseconds(250))
        let timedOutSession = try store.load(id: canonical.id)
        guard completed.value,
              timedOutSession.metadata.state == .failed,
              timedOutSession.metadata.failureCode == .transcriptionTimedOut,
              try store.readRawText(for: timedOutSession) == "prior canonical",
              coordinator.activeOwnedOperationCount > 0 else {
            transcription.releaseRetry()
            _ = await retryTask.value
            throw ContractFailure(message: "retry timeout changed canonical state or lost owned Speech work")
        }

        guard try retryStagingFiles(in: timedOutSession).isEmpty == false else {
            transcription.releaseRetry()
            _ = await retryTask.value
            throw ContractFailure(message: "retry timeout did not create isolated staging for the attempted result")
        }

        do {
            _ = try await coordinator.startRecordingWithTranscription(
                using: ContractAudioCapture(),
                store: store,
                transcription: ImmediateTranscriptionController(),
                format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1)
            )
            throw ContractFailure(message: "new recording overlapped unreleased retry work")
        } catch let error as DictationCoordinatorError {
            guard error == .workAlreadyActive else {
                throw error
            }
        }

        transcription.releaseRetry()
        _ = await retryTask.value
        try await waitForOwnedOperationsToRelease(coordinator)
        try await Task.sleep(for: .milliseconds(50))
        let releasedSession = try store.load(id: canonical.id)
        guard coordinator.activeOwnedOperationCount == 0,
              !coordinator.hasActiveTranscription,
              try store.readRawText(for: releasedSession) == "prior canonical",
              try retryStagingFiles(in: releasedSession).isEmpty else {
            throw ContractFailure(message: "released retry loser did not discard staging or preserve canonical raw text")
        }
    }

    @MainActor
    private static func testInterruptionTimeoutPreservesTerminalOutcome() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue78-interruption-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootDirectory: root)
        let transcription = NonCooperativeCancellationController()
        let coordinator = DictationCoordinator(timeoutPolicy: .testing)
        _ = try await coordinator.startRecordingWithTranscription(
            using: ContractAudioCapture(),
            store: store,
            transcription: transcription,
            format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1)
        )
        let completed = CompletionFlag()
        let interruptionTask = Task { @MainActor in
            defer { completed.mark() }
            _ = try? await coordinator.interruptRecordingWithTranscription(reason: "sleep")
        }

        await transcription.waitUntilCancelStarted()
        try await Task.sleep(for: .milliseconds(250))
        guard completed.value,
              coordinator.currentSession?.metadata.state == .interrupted,
              coordinator.currentSession?.metadata.failureCode == .transcriptionTimedOut,
              coordinator.activeOwnedOperationCount > 0 else {
            transcription.releaseCancel()
            _ = await interruptionTask.value
            throw ContractFailure(message: "interruption timeout did not preserve the terminal outcome and owned work")
        }

        transcription.releaseCancel()
        _ = await interruptionTask.value
        try await waitForOwnedOperationsToRelease(coordinator)
        try await Task.sleep(for: .milliseconds(50))
        guard coordinator.activeOwnedOperationCount == 0,
              !coordinator.hasActiveTranscription else {
            throw ContractFailure(message: "interruption loser remained owned after release")
        }
    }

    @MainActor
    private static func testShutdownTimeoutRepliesWithStableOutcome() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue78-shutdown-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootDirectory: root)
        let transcription = NonCooperativeCancellationController()
        let coordinator = DictationCoordinator(timeoutPolicy: .testing)
        _ = try await coordinator.startRecordingWithTranscription(
            using: ContractAudioCapture(),
            store: store,
            transcription: transcription,
            format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1)
        )
        let completed = CompletionFlag()
        let shutdownTask = Task { @MainActor in
            defer { completed.mark() }
            await coordinator.shutdownWithTranscription()
        }

        await transcription.waitUntilCancelStarted()
        try await Task.sleep(for: .milliseconds(250))
        guard completed.value,
              coordinator.currentSession?.metadata.state == .failed,
              coordinator.currentSession?.metadata.failureCode == .transcriptionTimedOut,
              coordinator.currentSession?.metadata.failureReason == "application shutdown speech timeout",
              coordinator.activeOwnedOperationCount > 0 else {
            transcription.releaseCancel()
            _ = await shutdownTask.value
            throw ContractFailure(message: "shutdown timeout did not return with a stable sanitized outcome")
        }

        transcription.releaseCancel()
        _ = await shutdownTask.value
        try await waitForOwnedOperationsToRelease(coordinator)
        try await Task.sleep(for: .milliseconds(50))
        guard coordinator.activeOwnedOperationCount == 0,
              !coordinator.hasActiveTranscription else {
            throw ContractFailure(message: "shutdown loser remained owned after release")
        }
    }

    @MainActor
    private static func testOneHundredLifecycleCyclesReleaseResources() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue78-cycles-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootDirectory: root)
        let coordinator = DictationCoordinator(timeoutPolicy: .testing)
        for _ in 0..<100 {
            _ = try await coordinator.startRecordingWithTranscription(
                using: ContractAudioCapture(),
                store: store,
                transcription: ImmediateTranscriptionController(),
                format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1)
            )
            await coordinator.cancelActiveWork()
            guard coordinator.activeResourceCount == 0,
                  coordinator.activeOwnedOperationCount == 0,
                  !coordinator.hasActiveWork else {
                throw ContractFailure(message: "lifecycle resources survived a cancellation cycle")
            }
        }
    }

    private static func retryStagingFiles(in session: DictationSession) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: session.directoryURL.path)
            .filter { $0.hasSuffix(".retry") }
    }

    @MainActor
    private static func waitForOwnedOperationsToRelease(
        _ coordinator: DictationCoordinator
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while coordinator.activeOwnedOperationCount > 0,
              DispatchTime.now().uptimeNanoseconds < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@available(macOS 26.0, *)
private final class CompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var didComplete = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didComplete
    }

    func mark() {
        lock.lock()
        didComplete = true
        lock.unlock()
    }
}

@available(macOS 26.0, *)
private final class UpdateCollector: @unchecked Sendable {
    private(set) var values: [TranscriptionUpdate] = []

    func append(_ value: TranscriptionUpdate) {
        values.append(value)
    }
}

@available(macOS 26.0, *)
private final class NonCooperativeFinalizationController: TranscriptionController, @unchecked Sendable {
    private let lock = NSLock()
    private var finishContinuation: CheckedContinuation<TranscriptionResult, Error>?
    private var finishStarted = false
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var session: DictationSession?
    private var onUpdate: (@Sendable (TranscriptionUpdate) -> Void)?

    func start(
        session: DictationSession,
        format: AudioCaptureFormat,
        store: SessionStore,
        onUpdate: @escaping @Sendable (TranscriptionUpdate) -> Void
    ) async throws {
        guard format.isValid, format.channelCount == 1 else {
            throw TranscriptionError.invalidCaptureFormat
        }
        self.session = session
        _ = store
        self.onUpdate = onUpdate
    }

    func append(_ buffer: AudioCaptureBuffer) {
        _ = buffer
    }

    func finish() async throws -> TranscriptionResult {
        try await withCheckedThrowingContinuation { continuation in
            let waiters = withLock {
                finishStarted = true
                finishContinuation = continuation
                let waiters = finishWaiters
                finishWaiters.removeAll(keepingCapacity: true)
                return waiters
            }
            waiters.forEach { $0.resume() }
        }
    }

    func cancel() async throws -> TranscriptionResult? {
        nil
    }

    func retrySavedAudio(
        for session: DictationSession,
        store: SessionStore
    ) async throws -> TranscriptionResult {
        _ = session
        _ = store
        throw TranscriptionError.analysisFailed("noncooperative fixture cannot retry")
    }

    func waitUntilFinishStarted() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = withLock {
                if finishStarted {
                    return true
                }
                finishWaiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func releaseFinish() {
        let continuation = withLock {
            let continuation = finishContinuation
            finishContinuation = nil
            return continuation
        }
        continuation?.resume(returning: TranscriptionResult(finalizedText: "", rawTextByteCount: 0))
        _ = session
    }

    func emit(_ update: TranscriptionUpdate) {
        onUpdate?(update)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

@available(macOS 26.0, *)
private final class ImmediateTranscriptionController: TranscriptionController, @unchecked Sendable {
    func start(
        session: DictationSession,
        format: AudioCaptureFormat,
        store: SessionStore,
        onUpdate: @escaping @Sendable (TranscriptionUpdate) -> Void
    ) async throws {
        _ = session
        _ = store
        _ = onUpdate
        guard format.isValid, format.channelCount == 1 else {
            throw TranscriptionError.invalidCaptureFormat
        }
    }

    func append(_ buffer: AudioCaptureBuffer) {
        _ = buffer
    }

    func finish() async throws -> TranscriptionResult {
        TranscriptionResult(finalizedText: "", rawTextByteCount: 0)
    }

    func cancel() async throws -> TranscriptionResult? {
        nil
    }

    func retrySavedAudio(
        for session: DictationSession,
        store: SessionStore
    ) async throws -> TranscriptionResult {
        _ = session
        _ = store
        throw TranscriptionError.analysisFailed("immediate fixture does not retry")
    }
}

@available(macOS 26.0, *)
private final class NonCooperativeStartupController: TranscriptionController, @unchecked Sendable {
    private let lock = NSLock()
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var startStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func start(
        session: DictationSession,
        format: AudioCaptureFormat,
        store: SessionStore,
        onUpdate: @escaping @Sendable (TranscriptionUpdate) -> Void
    ) async throws {
        _ = session
        _ = store
        _ = onUpdate
        guard format.isValid, format.channelCount == 1 else {
            throw TranscriptionError.invalidCaptureFormat
        }
        try await withCheckedThrowingContinuation { continuation in
            let waiters = withLock {
                startStarted = true
                startContinuation = continuation
                let waiters = startWaiters
                startWaiters.removeAll(keepingCapacity: true)
                return waiters
            }
            waiters.forEach { $0.resume() }
        }
    }

    func append(_ buffer: AudioCaptureBuffer) {
        _ = buffer
    }

    func finish() async throws -> TranscriptionResult {
        TranscriptionResult(finalizedText: "", rawTextByteCount: 0)
    }

    func cancel() async throws -> TranscriptionResult? {
        nil
    }

    func retrySavedAudio(
        for session: DictationSession,
        store: SessionStore
    ) async throws -> TranscriptionResult {
        _ = session
        _ = store
        throw TranscriptionError.analysisFailed("startup fixture does not retry")
    }

    func waitUntilStartStarted() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = withLock {
                if startStarted {
                    return true
                }
                startWaiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func releaseStart() {
        let continuation = withLock {
            let continuation = startContinuation
            startContinuation = nil
            return continuation
        }
        continuation?.resume()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

@available(macOS 26.0, *)
private final class NonCooperativeRetryController: TranscriptionController, @unchecked Sendable {
    private let lock = NSLock()
    private var retryContinuation: CheckedContinuation<TranscriptionResult, Error>?
    private var retryStarted = false
    private var retryWaiters: [CheckedContinuation<Void, Never>] = []

    func start(
        session: DictationSession,
        format: AudioCaptureFormat,
        store: SessionStore,
        onUpdate: @escaping @Sendable (TranscriptionUpdate) -> Void
    ) async throws {
        _ = session
        _ = store
        _ = onUpdate
        _ = format
    }

    func append(_ buffer: AudioCaptureBuffer) {
        _ = buffer
    }

    func finish() async throws -> TranscriptionResult {
        TranscriptionResult(finalizedText: "", rawTextByteCount: 0)
    }

    func cancel() async throws -> TranscriptionResult? {
        nil
    }

    func retrySavedAudio(
        for session: DictationSession,
        store: SessionStore
    ) async throws -> TranscriptionResult {
        let staging = try store.beginRawTextStaging(for: session)
        try store.appendRawText("staged replacement", to: staging, for: session)
        let result: TranscriptionResult
        do {
            result = try await withCheckedThrowingContinuation { continuation in
                let waiters = withLock {
                    retryStarted = true
                    retryContinuation = continuation
                    let waiters = retryWaiters
                    retryWaiters.removeAll(keepingCapacity: true)
                    return waiters
                }
                waiters.forEach { $0.resume() }
            }
        } catch {
            try? store.discardRawTextStaging(staging, for: session)
            throw error
        }
        try? store.discardRawTextStaging(staging, for: session)
        return result
    }

    func waitUntilRetryStarted() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = withLock {
                if retryStarted {
                    return true
                }
                retryWaiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func releaseRetry() {
        let continuation = withLock {
            let continuation = retryContinuation
            retryContinuation = nil
            return continuation
        }
        continuation?.resume(throwing: TranscriptionError.analysisFailed("released retry fixture"))
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

@available(macOS 26.0, *)
private final class NonCooperativeCancellationController: TranscriptionController, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelContinuation: CheckedContinuation<TranscriptionResult?, Error>?
    private var cancelStarted = false
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []

    func start(
        session: DictationSession,
        format: AudioCaptureFormat,
        store: SessionStore,
        onUpdate: @escaping @Sendable (TranscriptionUpdate) -> Void
    ) async throws {
        _ = session
        _ = store
        _ = onUpdate
        _ = format
    }

    func append(_ buffer: AudioCaptureBuffer) {
        _ = buffer
    }

    func finish() async throws -> TranscriptionResult {
        TranscriptionResult(finalizedText: "", rawTextByteCount: 0)
    }

    func cancel() async throws -> TranscriptionResult? {
        try await withCheckedThrowingContinuation { continuation in
            let waiters = withLock {
                cancelStarted = true
                cancelContinuation = continuation
                let waiters = cancelWaiters
                cancelWaiters.removeAll(keepingCapacity: true)
                return waiters
            }
            waiters.forEach { $0.resume() }
        }
    }

    func retrySavedAudio(
        for session: DictationSession,
        store: SessionStore
    ) async throws -> TranscriptionResult {
        _ = session
        _ = store
        throw TranscriptionError.analysisFailed("cancellation fixture does not retry")
    }

    func waitUntilCancelStarted() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = withLock {
                if cancelStarted {
                    return true
                }
                cancelWaiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func releaseCancel() {
        let continuation = withLock {
            let continuation = cancelContinuation
            cancelContinuation = nil
            return continuation
        }
        continuation?.resume(returning: nil)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

@available(macOS 26.0, *)
private final class ContractAudioCapture: AudioCapturing, @unchecked Sendable {
    private var descriptor: AudioFileDescriptor?

    func start(
        to descriptor: AudioFileDescriptor,
        onBuffer: @escaping @Sendable (AudioCaptureBuffer) -> Void,
        onFinish: @escaping @Sendable () -> Void,
        onInterruption: @escaping @Sendable (String) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) throws {
        self.descriptor = descriptor
        _ = onBuffer
        _ = onFinish
        _ = onInterruption
        _ = onFailure
    }

    func stop() throws {
        descriptor?.close()
        descriptor = nil
    }

    func cancel() {
        descriptor?.close()
        descriptor = nil
    }
}
