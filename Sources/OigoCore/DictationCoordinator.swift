import Foundation
import Darwin
import os

public enum PerformanceEvent: String, CaseIterable, Codable, Hashable, Sendable {
    case shortcutReceived = "shortcut-received"
    case sessionPersisted = "session-persisted"
    case audioEngineStartBegin = "audio-engine-start-begin"
    case audioEngineStartEnd = "audio-engine-start-end"
    case firstAudioBuffer = "first-audio-buffer"
    case firstVolatileResult = "first-volatile-result"
    case recordingStopped = "recording-stopped"
    case transcriptionFinalized = "transcription-finalized"
    case cleanupStart = "cleanup-start"
    case cleanupEnd = "cleanup-end"
    case insertionStart = "insertion-start"
    case insertionEnd = "insertion-end"
    case resourcesReleased = "resources-released"
}

public protocol PerformanceInstrumentation: Sendable {
    func mark(_ event: PerformanceEvent)
}

public final class OSLogPerformanceInstrumentation: PerformanceInstrumentation, @unchecked Sendable {
    private let log = OSLog(subsystem: "com.oigo.app", category: "performance")

    public init() {}

    public func mark(_ event: PerformanceEvent) {
        switch event {
        case .shortcutReceived:
            os_signpost(.event, log: log, name: "shortcut-received")
        case .sessionPersisted:
            os_signpost(.event, log: log, name: "session-persisted")
        case .audioEngineStartBegin:
            os_signpost(.event, log: log, name: "audio-engine-start-begin")
        case .audioEngineStartEnd:
            os_signpost(.event, log: log, name: "audio-engine-start-end")
        case .firstAudioBuffer:
            os_signpost(.event, log: log, name: "first-audio-buffer")
        case .firstVolatileResult:
            os_signpost(.event, log: log, name: "first-volatile-result")
        case .recordingStopped:
            os_signpost(.event, log: log, name: "recording-stopped")
        case .transcriptionFinalized:
            os_signpost(.event, log: log, name: "transcription-finalized")
        case .cleanupStart:
            os_signpost(.event, log: log, name: "cleanup-start")
        case .cleanupEnd:
            os_signpost(.event, log: log, name: "cleanup-end")
        case .insertionStart:
            os_signpost(.event, log: log, name: "insertion-start")
        case .insertionEnd:
            os_signpost(.event, log: log, name: "insertion-end")
        case .resourcesReleased:
            os_signpost(.event, log: log, name: "resources-released")
        }
    }
}

@_spi(Testing)
public final class RecordingPerformanceInstrumentation: PerformanceInstrumentation, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [PerformanceEvent] = []

    public init() {}

    public var events: [PerformanceEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }

    public func mark(_ event: PerformanceEvent) {
        lock.lock()
        recordedEvents.append(event)
        lock.unlock()
    }
}

public enum DictationState: String, CaseIterable, Codable, Sendable {
    case idle
    case preparing
    case recording
    case finalizing
    case cleaning
    case inserting
    case complete
    case failed
    case cancelled
    case interrupted
}

public enum DictationEvent: String, CaseIterable, Codable, Sendable {
    case start
    case prepared
    case stop
    case finalized
    case captureCompleted
    case cleaned
    case inserted
    case reset
    case cancel
    case fail
    case interrupt
    case retryCompleted
}

public enum DictationTransitionError: Error, Equatable, CustomStringConvertible, Sendable {
    case illegal(from: DictationState, event: DictationEvent)

    public var description: String {
        switch self {
        case .illegal(let from, let event):
            return "illegal dictation transition: " + from.rawValue + " + " + event.rawValue
        }
    }
}

public struct DictationStateMachine: Sendable {
    public struct Transition: Equatable, Sendable {
        public let from: DictationState
        public let event: DictationEvent
        public let to: DictationState

        public init(from: DictationState, event: DictationEvent, to: DictationState) {
            self.from = from
            self.event = event
            self.to = to
        }
    }

    public struct TransitionKey: Hashable, Sendable {
        public let from: DictationState
        public let event: DictationEvent

        public init(from: DictationState, event: DictationEvent) {
            self.from = from
            self.event = event
        }
    }

    public private(set) var state: DictationState

    public init(initialState: DictationState = .idle) {
        state = initialState
    }

    public static let legalTransitions: [Transition] = [
        Transition(from: .idle, event: .start, to: .preparing),
        Transition(from: .preparing, event: .prepared, to: .recording),
        Transition(from: .recording, event: .stop, to: .finalizing),
        Transition(from: .finalizing, event: .captureCompleted, to: .complete),
        Transition(from: .finalizing, event: .finalized, to: .cleaning),
        Transition(from: .cleaning, event: .cleaned, to: .inserting),
        Transition(from: .inserting, event: .inserted, to: .complete),
        Transition(from: .complete, event: .finalized, to: .cleaning),
        Transition(from: .complete, event: .reset, to: .idle),
        Transition(from: .failed, event: .reset, to: .idle),
        Transition(from: .cancelled, event: .reset, to: .idle),
        Transition(from: .interrupted, event: .reset, to: .idle),
        Transition(from: .complete, event: .start, to: .preparing),
        Transition(from: .failed, event: .start, to: .preparing),
        Transition(from: .cancelled, event: .start, to: .preparing),
        Transition(from: .interrupted, event: .start, to: .preparing),
        Transition(from: .preparing, event: .cancel, to: .cancelled),
        Transition(from: .recording, event: .cancel, to: .cancelled),
        Transition(from: .finalizing, event: .cancel, to: .cancelled),
        Transition(from: .cleaning, event: .cancel, to: .cancelled),
        Transition(from: .inserting, event: .cancel, to: .cancelled),
        Transition(from: .preparing, event: .fail, to: .failed),
        Transition(from: .recording, event: .fail, to: .failed),
        Transition(from: .finalizing, event: .fail, to: .failed),
        Transition(from: .cleaning, event: .fail, to: .failed),
        Transition(from: .inserting, event: .fail, to: .failed),
        Transition(from: .preparing, event: .interrupt, to: .interrupted),
        Transition(from: .recording, event: .interrupt, to: .interrupted),
        Transition(from: .finalizing, event: .interrupt, to: .interrupted),
        Transition(from: .cleaning, event: .interrupt, to: .interrupted),
        Transition(from: .inserting, event: .interrupt, to: .interrupted),
        Transition(from: .idle, event: .interrupt, to: .interrupted),
        Transition(from: .failed, event: .interrupt, to: .interrupted),
        Transition(from: .idle, event: .retryCompleted, to: .complete),
        Transition(from: .failed, event: .retryCompleted, to: .complete),
        Transition(from: .interrupted, event: .retryCompleted, to: .complete),
        Transition(from: .complete, event: .retryCompleted, to: .complete),
        Transition(from: .cancelled, event: .retryCompleted, to: .complete)
    ]

    @discardableResult
    public mutating func apply(_ event: DictationEvent) throws -> DictationState {
        guard let transition = Self.legalTransitions.first(where: {
            $0.from == state && $0.event == event
        }) else {
            throw DictationTransitionError.illegal(from: state, event: event)
        }
        state = transition.to
        return state
    }
}

public struct DictationTransitionRecord: Equatable, Sendable {
    public let from: DictationState
    public let event: DictationEvent
    public let to: DictationState

    public init(from: DictationState, event: DictationEvent, to: DictationState) {
        self.from = from
        self.event = event
        self.to = to
    }
}

public final class DictationDiagnostics: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.oigo.app", category: "dictation")
    private let signpostLog = OSLog(subsystem: "com.oigo.app", category: "dictation")
    private let instrumentation: PerformanceInstrumentation

    public init(
        instrumentation: PerformanceInstrumentation = OSLogPerformanceInstrumentation()
    ) {
        self.instrumentation = instrumentation
    }

    public func mark(_ event: PerformanceEvent) {
        instrumentation.mark(event)
    }

    public func record(_ transition: DictationTransitionRecord) {
        logger.info(
            "state transition \(transition.from.rawValue, privacy: .public) + \(transition.event.rawValue, privacy: .public) -> \(transition.to.rawValue, privacy: .public)"
        )
        os_signpost(.event, log: signpostLog, name: "state-transition")
    }

    public func record(_ message: String) {
        logger.info("\(message, privacy: .public)")
        os_signpost(.event, log: signpostLog, name: "coordinator-event")
    }
}

public enum DictationCoordinatorError: Error, Equatable, CustomStringConvertible, Sendable {
    case workAlreadyActive
    case recordingNotActive
    case retryDidNotPersist
    case rawTranscriptNotPersisted

    public var description: String {
        switch self {
        case .workAlreadyActive:
            return "dictation work is already active"
        case .recordingNotActive:
            return "dictation recording is not active"
        case .retryDidNotPersist:
            return "saved transcription retry did not persist a completed canonical transcript"
        case .rawTranscriptNotPersisted:
            return "canonical raw transcript was not persisted before insertion"
        }
    }
}

@MainActor
public final class DictationCoordinator {
    private var machine: DictationStateMachine
    private var activeTask: Task<Void, Never>?
    private let diagnostics: DictationDiagnostics
    private var activeCapture: AudioCapturing?
    private var activeAudioDescriptor: AudioFileDescriptor?
    private var activeTranscription: TranscriptionController?
    private var sessionStore: SessionStore?
    private let faultInjector: DictationFaultInjector?
    private var pendingTranscriptionTerminalState: DictationSessionState?
    private var activeOperationID: UUID?
    private var acceptsCallbacks = false
    private var activeCaptureFailureForTesting: (() -> Void)?
    private var staleCaptureFailureForTesting: (() -> Void)?
    private var terminalOperationInFlight = false
    private var terminalOperationWaiters: [CheckedContinuation<Void, Never>] = []
    private let timeoutPolicy: TranscriptionTimeoutPolicy
    private let operationRegistry = OperationTaskRegistry()
    private var transcriptionReaperTask: Task<Void, Never>?

    public private(set) var transitionHistory: [DictationTransitionRecord] = []
    public private(set) var currentSession: DictationSession?
    public private(set) var lastFailureReason: String?
    public private(set) var lastFailureCode: DictationFailureCode?

    public var state: DictationState {
        machine.state
    }

    public var activeTaskCount: Int {
        activeTask == nil ? 0 : 1
    }

    @_spi(Testing)
    public var activeResourceCount: Int {
        [
            activeCapture != nil,
            activeAudioDescriptor != nil,
            activeTranscription != nil,
            sessionStore != nil,
            activeOperationID != nil
        ].filter { $0 }.count
    }

    @_spi(Testing)
    public var activeOwnedOperationCount: Int {
        operationRegistry.activeCount
    }

    public var hasActiveTranscription: Bool {
        activeTranscription != nil
    }

    public var hasActiveWork: Bool {
        activeCapture != nil
            || activeTranscription != nil
            || activeTask != nil
            || transcriptionReaperTask != nil
            || operationRegistry.activeCount > 0
            || [.preparing, .recording, .finalizing, .cleaning, .inserting].contains(state)
    }

    public init(
        initialState: DictationState = .idle,
        diagnostics: DictationDiagnostics = DictationDiagnostics(),
        timeoutPolicy: TranscriptionTimeoutPolicy = .production
    ) {
        machine = DictationStateMachine(initialState: initialState)
        self.diagnostics = diagnostics
        self.faultInjector = nil
        self.timeoutPolicy = timeoutPolicy
    }

    @_spi(Testing)
    public init(
        faultInjector: DictationFaultInjector,
        initialState: DictationState = .idle,
        diagnostics: DictationDiagnostics = DictationDiagnostics(),
        timeoutPolicy: TranscriptionTimeoutPolicy = .production
    ) {
        machine = DictationStateMachine(initialState: initialState)
        self.diagnostics = diagnostics
        self.faultInjector = faultInjector
        self.timeoutPolicy = timeoutPolicy
    }

    @discardableResult
    public func apply(_ event: DictationEvent) throws -> DictationState {
        let from = machine.state
        let next = try machine.apply(event)
        let transition = DictationTransitionRecord(from: from, event: event, to: next)
        transitionHistory.append(transition)
        diagnostics.record(transition)
        return next
    }

    @discardableResult
    public func startRecording(
        using capture: AudioCapturing,
        store: SessionStore,
        now: Date = Date(),
        onBuffer: @escaping @Sendable (AudioCaptureBuffer) -> Void = { _ in }
    ) throws -> DictationSession {
        reapReleasedTranscription()
        guard activeCapture == nil else {
            throw DictationCoordinatorError.workAlreadyActive
        }
        guard [.idle, .complete, .failed, .cancelled, .interrupted].contains(state) else {
            throw DictationTransitionError.illegal(from: state, event: .start)
        }

        let session = try store.createSession(now: now)
        diagnostics.mark(.sessionPersisted)
        var preparedSession = session
        let operationID = UUID()
        do {
            _ = try apply(.start)
            preparedSession = try store.update(
                session,
                state: .recording,
                at: now
            )
            _ = try apply(.prepared)
            activeCapture = capture
            activeOperationID = operationID
            acceptsCallbacks = true
            sessionStore = store
            currentSession = preparedSession
            activeCaptureFailureForTesting = { [weak self] in
                self?.handleCaptureFailure(
                    "cancellation race fault",
                    operationID: operationID
                )
            }
            let audioDescriptor = try store.createAudioFileDescriptor(for: preparedSession)
            activeAudioDescriptor = try store.duplicateAudioFileDescriptor(
                audioDescriptor,
                for: preparedSession
            )
            try capture.start(
                to: audioDescriptor,
                onBuffer: onBuffer,
                onFinish: {},
                onInterruption: { [weak self] (reason: String) in
                    Task { @MainActor [weak self] in
                        _ = try? self?.interruptRecording(
                            reason: reason,
                            operationID: operationID
                        )
                    }
                },
                onFailure: { [weak self] (reason: String) in
                    Task { @MainActor [weak self] in
                        self?.handleCaptureFailure(reason, operationID: operationID)
                    }
                }
            )
            lastFailureReason = nil
            lastFailureCode = nil
            diagnostics.record("audio capture started")
            return preparedSession
        } catch {
            capture.cancel()
            let reason = Self.failureReason(for: error)
            lastFailureReason = reason
            lastFailureCode = DictationFailureCode.infer(from: reason)
            let failedSession = persistTerminalState(
                preparedSession,
                in: store,
                state: .failed,
                reason: reason,
                failureCode: lastFailureCode
            )
            if [.preparing, .recording].contains(state) {
                _ = try? apply(.fail)
            }
            currentSession = failedSession
            releaseCapture()
            throw error
        }
    }

    @discardableResult
    public func startRecordingWithTranscription(
        using capture: AudioCapturing,
        store: SessionStore,
        transcription: TranscriptionController,
        format: AudioCaptureFormat,
        now: Date = Date(),
        onUpdate: @escaping @Sendable (TranscriptionUpdate) -> Void = { _ in }
    ) async throws -> DictationSession {
        try await startRecordingWithTranscriptionInternal(
            using: capture,
            store: store,
            transcription: transcription,
            format: format,
            session: nil,
            now: now,
            onUpdate: onUpdate
        )
    }

    public func startPersistedRecordingWithTranscription(
        _ session: DictationSession,
        using capture: AudioCapturing,
        store: SessionStore,
        transcription: TranscriptionController,
        format: AudioCaptureFormat,
        now: Date = Date(),
        onUpdate: @escaping @Sendable (TranscriptionUpdate) -> Void = { _ in }
    ) async throws -> DictationSession {
        try await startRecordingWithTranscriptionInternal(
            using: capture,
            store: store,
            transcription: transcription,
            format: format,
            session: session,
            now: now,
            onUpdate: onUpdate
        )
    }

    private func startRecordingWithTranscriptionInternal(
        using capture: AudioCapturing,
        store: SessionStore,
        transcription: TranscriptionController,
        format: AudioCaptureFormat,
        session: DictationSession?,
        now: Date,
        onUpdate: @escaping @Sendable (TranscriptionUpdate) -> Void
    ) async throws -> DictationSession {
        reapReleasedTranscription()
        guard activeCapture == nil, activeTranscription == nil else {
            throw DictationCoordinatorError.workAlreadyActive
        }
        guard [.idle, .complete, .failed, .cancelled, .interrupted].contains(state) else {
            throw DictationTransitionError.illegal(from: state, event: .start)
        }

        let persistedSession: DictationSession
        if let session {
            persistedSession = session
        } else {
            persistedSession = try store.createSession(now: now)
        }
        diagnostics.mark(.sessionPersisted)
        var preparedSession = persistedSession
        let operationID = UUID()
        do {
            pendingTranscriptionTerminalState = nil
            _ = try apply(.start)
            activeCapture = capture
            activeTranscription = transcription
            activeOperationID = operationID
            acceptsCallbacks = true
            sessionStore = store
            currentSession = persistedSession

            try await withTaskCancellationHandler(operation: {
                try await BoundedOperation.run(
                    operationID: operationID,
                    stage: .startup,
                    timeout: timeoutPolicy.budget(for: .startup),
                    registry: operationRegistry
                ) {
                    try await transcription.start(
                        session: persistedSession,
                        format: format,
                        store: store,
                        onUpdate: { [weak self] update in
                            Task { @MainActor [weak self] in
                                guard self?.activeOperationID == operationID,
                                      self?.acceptsCallbacks == true else {
                                    return
                                }
                                onUpdate(update)
                            }
                        }
                    )
                }
            }, onCancel: {
                Task { @MainActor [weak self] in
                    await self?.requestCancellation(
                        transcription,
                        operationID: operationID,
                        stage: .cancellation
                    )
                }
            })
            try Task.checkCancellation()
            preparedSession = try store.update(
                persistedSession,
                state: .recording,
                at: now
            )
            _ = try apply(.prepared)
            currentSession = preparedSession
            let audioDescriptor = try store.createAudioFileDescriptor(for: preparedSession)
            activeAudioDescriptor = try store.duplicateAudioFileDescriptor(
                audioDescriptor,
                for: preparedSession
            )
            try capture.start(
                to: audioDescriptor,
                onBuffer: { buffer in
                    transcription.append(buffer)
                },
                onFinish: {},
                onInterruption: { [weak self] reason in
                    Task { @MainActor [weak self] in
                        await self?.handleTranscriptionCaptureInterruption(
                            reason,
                            operationID: operationID
                        )
                    }
                },
                onFailure: { [weak self] reason in
                    Task { @MainActor [weak self] in
                        await self?.handleTranscriptionCaptureFailure(
                            reason,
                            operationID: operationID
                        )
                    }
                }
            )
            lastFailureReason = nil
            lastFailureCode = nil
            diagnostics.record("audio capture and transcription started")
            return preparedSession
        } catch {
            let terminalRequested = pendingTranscriptionTerminalState != nil
                || [.cancelled, .interrupted].contains(state)
            let cancellationRequested = Task.isCancelled
            capture.cancel()
            await requestCancellation(
                transcription,
                operationID: operationID,
                stage: .cancellation
            )
            if terminalRequested {
                currentSession = (try? store.load(id: preparedSession.id)) ?? preparedSession
                releaseCapture()
                throw error
            }
            if cancellationRequested {
                let cancelledSession = persistTerminalState(
                    preparedSession,
                    in: store,
                    state: .cancelled,
                    reason: "dictation operation cancelled",
                    failureCode: .cancelled
                )
                if [.preparing, .recording].contains(state) {
                    _ = try? apply(.cancel)
                }
                currentSession = cancelledSession
                releaseCapture()
                throw error
            }
            let reason = Self.failureReason(for: error)
            lastFailureReason = reason
            lastFailureCode = DictationFailureCode.infer(from: reason)
            let failedSession = persistTerminalState(
                preparedSession,
                in: store,
                state: .failed,
                reason: reason,
                failureCode: lastFailureCode
            )
            if [.preparing, .recording].contains(state) {
                _ = try? apply(.fail)
            }
            currentSession = failedSession
            releaseCapture()
            throw error
        }
    }

    @discardableResult
    public func retryRecordingWithTranscription(
        for savedSession: DictationSession? = nil,
        using transcription: TranscriptionController,
        store: SessionStore
    ) async throws -> DictationSession {
        guard await waitForTerminalOperationIfNeeded(
            operationID: activeOperationID ?? UUID(),
            stage: .retry
        ) else {
            throw BoundedOperationError.timedOut(.retry)
        }
        guard activeCapture == nil, activeTranscription == nil else {
            throw DictationCoordinatorError.workAlreadyActive
        }
        guard let session = savedSession ?? currentSession,
              [.failed, .interrupted].contains(session.metadata.state) else {
            throw DictationCoordinatorError.recordingNotActive
        }
        guard [.idle, .failed, .interrupted, .complete, .cancelled].contains(state),
              savedSession != nil || [.failed, .interrupted].contains(state) else {
            throw DictationCoordinatorError.recordingNotActive
        }

        let retryingSession = try store.beginTranscriptionRetry(for: session)
        currentSession = retryingSession
        let operationID = UUID()
        activeOperationID = operationID
        acceptsCallbacks = true
        activeTranscription = transcription
        sessionStore = store
        defer {
            if activeOperationID == operationID {
                releaseCapture()
            }
        }

        do {
            let result = try await BoundedOperation.run(
                operationID: operationID,
                stage: .retry,
                timeout: timeoutPolicy.budget(for: .retry),
                registry: operationRegistry
            ) {
                try await transcription.retrySavedAudio(for: retryingSession, store: store)
            }
            guard activeOperationID == operationID, acceptsCallbacks else {
                throw DictationCoordinatorError.recordingNotActive
            }
            let completedSession = try store.load(id: retryingSession.id)
            guard completedSession.metadata.state == .completed,
                  completedSession.metadata.rawTextByteCount == result.rawTextByteCount else {
                throw DictationCoordinatorError.retryDidNotPersist
            }
            _ = try apply(.retryCompleted)
            currentSession = completedSession
            lastFailureReason = nil
            diagnostics.record("saved audio transcription retried")
            return completedSession
        } catch {
            let reason = Self.failureReason(for: error)
            await requestCancellation(
                transcription,
                operationID: operationID,
                stage: .cancellation
            )
            let persistedSession = try? store.load(id: retryingSession.id)
            if let persistedSession, persistedSession.metadata.state == .completed {
                _ = try? apply(.retryCompleted)
                currentSession = persistedSession
                lastFailureReason = nil
                lastFailureCode = nil
                diagnostics.record("saved audio transcription completed before retry timeout")
                return persistedSession
            }
            if terminalOperationInFlight
                || pendingTranscriptionTerminalState == .interrupted
                || persistedSession?.metadata.state == .interrupted {
                let interruptedSession = try? store.update(
                    retryingSession,
                    state: .interrupted,
                    at: Date(),
                    failureReason: "application shutdown",
                    expectedState: .retrying
                )
                if let interruptedSession {
                    _ = try? apply(.interrupt)
                    currentSession = interruptedSession
                } else if let reconciledSession = try? store.load(id: retryingSession.id),
                          reconciledSession.metadata.state == .completed {
                    _ = try? apply(.retryCompleted)
                    currentSession = reconciledSession
                    lastFailureReason = nil
                    lastFailureCode = nil
                    diagnostics.record("saved audio transcription completed during shutdown")
                    return reconciledSession
                } else {
                    _ = try? apply(.interrupt)
                    currentSession = persistedSession ?? retryingSession
                }
            } else {
                lastFailureReason = reason
                let terminalSession = persistTerminalState(
                    retryingSession,
                    in: store,
                    state: .failed,
                    reason: reason,
                    failureCode: DictationFailureCode.infer(from: reason),
                    expectedState: .retrying
                )
                if let reconciledSession = try? store.load(id: retryingSession.id),
                   reconciledSession.metadata.state == .completed {
                    _ = try? apply(.retryCompleted)
                    currentSession = reconciledSession
                    lastFailureReason = nil
                    lastFailureCode = nil
                    diagnostics.record("saved audio transcription completed during retry timeout")
                    return reconciledSession
                }
                currentSession = terminalSession
            }
            throw error
        }
    }

    @discardableResult
    public func stopRecording(at date: Date = Date()) throws -> DictationSession {
        guard !terminalOperationInFlight else {
            throw DictationCoordinatorError.workAlreadyActive
        }
        guard let capture = activeCapture,
              let store = sessionStore,
              let session = currentSession else {
            throw DictationCoordinatorError.recordingNotActive
        }

        _ = try apply(.stop)
        var stoppingSession = session
        do {
            stoppingSession = try store.update(session, state: .stopping, at: date)
            try capture.stop()
            diagnostics.mark(.recordingStopped)
            let completedSession = try store.update(
                stoppingSession,
                state: .completed,
                at: date,
                audioByteCount: audioByteCount()
            )
            _ = try apply(.captureCompleted)
            currentSession = completedSession
            releaseCapture()
            diagnostics.record("audio capture stopped")
            return completedSession
        } catch {
            let reason = Self.failureReason(for: error)
            lastFailureReason = reason
            lastFailureCode = DictationFailureCode.infer(from: reason)
            capture.cancel()
            currentSession = persistTerminalState(
                stoppingSession,
                in: store,
                state: .failed,
                reason: reason,
                failureCode: lastFailureCode
            )
            _ = try? apply(.fail)
            releaseCapture()
            throw error
        }
    }

    @discardableResult
    public func stopRecordingWithTranscription(
        at date: Date = Date()
    ) async throws -> DictationSession {
        guard await waitForTerminalOperationIfNeeded(
            operationID: activeOperationID ?? UUID(),
            stage: .finalization
        ) else {
            throw BoundedOperationError.timedOut(.finalization)
        }
        guard beginTerminalOperation() else {
            throw DictationCoordinatorError.workAlreadyActive
        }
        defer { finishTerminalOperation() }
        guard let capture = activeCapture,
              let transcription = activeTranscription,
              let store = sessionStore,
              let session = currentSession,
              let operationID = activeOperationID else {
            throw DictationCoordinatorError.recordingNotActive
        }

        _ = try apply(.stop)
        var stoppingSession = session
        do {
            stoppingSession = try store.update(session, state: .stopping, at: date)
            try capture.stop()
            diagnostics.mark(.recordingStopped)
            let result = try await withTaskCancellationHandler(operation: {
                try await BoundedOperation.run(
                    operationID: operationID,
                    stage: .finalization,
                    timeout: timeoutPolicy.budget(for: .finalization),
                    registry: operationRegistry
                ) {
                    try await transcription.finish()
                }
            }, onCancel: {
                Task { @MainActor [weak self] in
                    await self?.requestCancellation(
                        transcription,
                        operationID: operationID,
                        stage: .cancellation
                    )
                }
            })
            if pendingTranscriptionTerminalState != nil {
                throw CancellationError()
            }
            let completedSession = try store.update(
                stoppingSession,
                state: .completed,
                at: date,
                audioByteCount: audioByteCount(),
                rawTextByteCount: result.rawTextByteCount
            )
            _ = try apply(.captureCompleted)
            currentSession = completedSession
            releaseCapture()
            diagnostics.record("audio capture and transcription stopped")
            return completedSession
        } catch {
            await requestCancellation(
                transcription,
                operationID: operationID,
                stage: .cancellation
            )
            if let requestedState = pendingTranscriptionTerminalState {
                let terminalEvent: DictationEvent = requestedState == .interrupted
                    ? .interrupt
                    : .cancel
                let cancelledSession = persistTerminalState(
                    stoppingSession,
                    in: store,
                    state: requestedState,
                    reason: requestedState == .interrupted
                        ? "recording was interrupted"
                        : "dictation operation cancelled",
                    failureCode: failureCode(
                        for: requestedState,
                        reason: requestedState == .interrupted
                            ? "recording was interrupted"
                            : "dictation operation cancelled"
                    )
                )
                _ = try? apply(terminalEvent)
                currentSession = cancelledSession
                releaseCapture()
                throw error
            }
            if Task.isCancelled {
                let cancelledSession = persistTerminalState(
                    stoppingSession,
                    in: store,
                    state: .cancelled,
                    reason: "dictation operation cancelled",
                    failureCode: .cancelled
                )
                _ = try? apply(.cancel)
                currentSession = cancelledSession
                releaseCapture()
                throw error
            }
            let reason = Self.failureReason(for: error)
            lastFailureReason = reason
            lastFailureCode = DictationFailureCode.infer(from: reason)
            capture.cancel()
            currentSession = persistTerminalState(
                stoppingSession,
                in: store,
                state: .failed,
                reason: reason,
                failureCode: lastFailureCode
            )
            _ = try? apply(.fail)
            releaseCapture()
            throw error
        }
    }

    @discardableResult
    public func beginInsertion(
        using store: SessionStore,
        requiresCleanup: Bool = false
    ) throws -> DictationSession {
        guard state == .complete,
              let session = currentSession,
              session.metadata.state == .completed,
              session.metadata.rawTextByteCount != nil else {
            throw DictationCoordinatorError.rawTranscriptNotPersisted
        }
        sessionStore = store
        _ = try apply(.finalized)
        if !requiresCleanup {
            _ = try apply(.cleaned)
        }
        return session
    }

    @discardableResult
    public func finishCleanup() throws -> DictationSession {
        if state == .inserting, let session = currentSession {
            return session
        }
        guard state == .cleaning,
              let session = currentSession else {
            throw DictationCoordinatorError.recordingNotActive
        }
        _ = try apply(.cleaned)
        diagnostics.record("transcript cleanup finished")
        return session
    }

    @discardableResult
    public func finishInsertion(
        outcome: InsertionOutcome,
        reason: String? = nil,
        insertionSource: TranscriptInsertionSource? = nil,
        cleanupFallbackReason: String? = nil,
        at date: Date = Date()
    ) throws -> DictationSession {
        if state == .complete,
           let session = currentSession,
           session.metadata.insertionOutcome != nil {
            return session
        }
        guard state == .inserting,
              let session = currentSession,
              let sessionStore else {
            throw DictationCoordinatorError.recordingNotActive
        }
        let completedSession = try sessionStore.update(
            session,
            state: .completed,
            at: date,
            insertionOutcome: outcome,
            insertionFailureReason: reason,
            insertionTextSource: insertionSource,
            cleanupFallbackReason: cleanupFallbackReason
        )
        _ = try apply(.inserted)
        currentSession = completedSession
        diagnostics.record("transcript insertion finished as " + outcome.rawValue)
        return completedSession
    }

    @discardableResult
    public func failInsertion(
        reason: String,
        at date: Date = Date()
    ) -> DictationSession? {
        if state == .complete {
            return currentSession
        }
        guard [.cleaning, .inserting].contains(state),
              let session = currentSession,
              let sessionStore else {
            return nil
        }
        let failedSession = persistTerminalState(
            session,
            in: sessionStore,
            state: .completed,
            reason: nil,
            failureCode: nil,
            insertionOutcome: .failed,
            insertionFailureReason: reason,
            at: date
        )
        _ = try? apply(.fail)
        currentSession = failedSession
        lastFailureReason = reason
        diagnostics.record("transcript insertion failed: " + reason)
        return failedSession
    }

    @discardableResult
    public func cancelRecording(at date: Date = Date()) throws -> DictationSession {
        if state == .cancelled, let session = currentSession {
            return session
        }
        return try finishRecording(
            state: .cancelled,
            event: .cancel,
            reason: nil,
            at: date
        )
    }

    @discardableResult
    public func cancelRecordingWithTranscription(
        at date: Date = Date()
    ) async throws -> DictationSession {
        if state == .cancelled, let session = currentSession {
            return session
        }
        return try await finishTranscribedRecording(
            state: .cancelled,
            event: .cancel,
            reason: nil,
            at: date
        )
    }

    public func cancelActiveWork(
        reason: String = "dictation operation cancelled"
    ) async {
        if terminalOperationInFlight,
           let activeTranscription,
           let operationID = activeOperationID {
            pendingTranscriptionTerminalState = reason == "dictation operation cancelled"
                ? .cancelled
                : .interrupted
            _ = try? await BoundedOperation.run(
                operationID: operationID,
                stage: .cancellation,
                timeout: timeoutPolicy.budget(for: .cancellation),
                registry: operationRegistry
            ) {
                try await activeTranscription.cancel()
            }
            return
        }
        if activeTranscription != nil {
            _ = try? await cancelRecordingWithTranscription()
            return
        }
        if activeCapture != nil {
            _ = try? cancelRecording()
            return
        }
        if [.cleaning, .inserting].contains(state) {
            _ = failInsertion(reason: reason)
        }
    }

    @discardableResult
    public func interruptRecording(
        reason: String = "recording was interrupted",
        at date: Date = Date()
    ) throws -> DictationSession {
        if state == .interrupted, let session = currentSession {
            return session
        }
        return try finishRecording(
            state: .interrupted,
            event: .interrupt,
            reason: reason,
            at: date,
            expectedOperationID: nil
        )
    }

    private func interruptRecording(
        reason: String,
        operationID: UUID,
        at date: Date = Date()
    ) throws -> DictationSession {
        try finishRecording(
            state: .interrupted,
            event: .interrupt,
            reason: reason,
            at: date,
            expectedOperationID: operationID
        )
    }

    @discardableResult
    public func interruptRecordingWithTranscription(
        reason: String = "recording was interrupted",
        at date: Date = Date()
    ) async throws -> DictationSession {
        if state == .interrupted, let session = currentSession {
            return session
        }
        return try await finishTranscribedRecording(
            state: .interrupted,
            event: .interrupt,
            reason: reason,
            at: date
        )
    }

    private func finishTranscribedRecording(
        state: DictationSessionState,
        event: DictationEvent,
        reason: String?,
        at date: Date
    ) async throws -> DictationSession {
        let waitStage: TranscriptionStage = state == .interrupted ? .interruption : .cancellation
        guard await waitForTerminalOperationIfNeeded(
            operationID: activeOperationID ?? UUID(),
            stage: waitStage
        ) else {
            throw BoundedOperationError.timedOut(waitStage)
        }
        guard beginTerminalOperation() else {
            throw DictationCoordinatorError.workAlreadyActive
        }
        defer { finishTerminalOperation() }
        guard let capture = activeCapture,
              let transcription = activeTranscription,
              let store = sessionStore,
              let session = currentSession,
              let operationID = activeOperationID else {
            throw DictationCoordinatorError.recordingNotActive
        }

        pendingTranscriptionTerminalState = state
        capture.cancel()
        let result: TranscriptionResult?
        do {
            let stage: TranscriptionStage = state == .interrupted ? .interruption : .cancellation
            result = try await BoundedOperation.run(
                operationID: operationID,
                stage: stage,
                timeout: timeoutPolicy.budget(for: stage),
                registry: operationRegistry
            ) {
                try await transcription.cancel()
            }
        } catch {
            let failureReason = Self.failureReason(for: error)
            let timedOut = error is BoundedOperationError
                || DictationFailureCode.infer(from: failureReason) == .transcriptionTimedOut
            let terminalState = timedOut ? state : .failed
            let terminalEvent = timedOut ? event : .fail
            lastFailureReason = failureReason
            let terminalSession = persistTerminalState(
                session,
                in: store,
                state: terminalState,
                reason: failureReason,
                failureCode: failureCode(for: terminalState, reason: failureReason),
                rawTextByteCount: nil
            )
            if [.preparing, .recording, .finalizing, .cleaning, .inserting].contains(self.state) {
                _ = try? apply(terminalEvent)
            }
            currentSession = terminalSession
            releaseCapture()
            throw error
        }
        do {
            let finishedSession = try store.update(
                session,
                state: state,
                at: date,
                failureReason: reason,
                failureCode: failureCode(for: state, reason: reason),
                audioByteCount: audioByteCount(),
                rawTextByteCount: result?.rawTextByteCount
            )
            _ = try apply(event)
            currentSession = finishedSession
            releaseCapture()
            diagnostics.record("audio capture and transcription finished as " + state.rawValue)
            return finishedSession
        } catch {
            lastFailureReason = Self.failureReason(for: error)
            let failedSession = persistTerminalState(
                session,
                in: store,
                state: .failed,
                reason: lastFailureReason,
                failureCode: .transcriptionFailed,
                rawTextByteCount: result?.rawTextByteCount
            )
            currentSession = failedSession
            _ = try? apply(.fail)
            releaseCapture()
            throw error
        }
    }

    private func finishRecording(
        state: DictationSessionState,
        event: DictationEvent,
        reason: String?,
        at date: Date,
        expectedOperationID: UUID? = nil
    ) throws -> DictationSession {
        guard !terminalOperationInFlight else {
            throw DictationCoordinatorError.workAlreadyActive
        }
        if let expectedOperationID,
           activeOperationID != expectedOperationID {
            throw DictationCoordinatorError.recordingNotActive
        }
        guard let capture = activeCapture,
              let store = sessionStore,
              let session = currentSession else {
            throw DictationCoordinatorError.recordingNotActive
        }

        capture.cancel()
        diagnostics.mark(.recordingStopped)
        do {
            let finishedSession = try store.update(
                session,
                state: state,
                at: date,
                failureReason: reason,
                failureCode: failureCode(for: state, reason: reason),
                audioByteCount: audioByteCount()
            )
            _ = try apply(event)
            currentSession = finishedSession
            releaseCapture()
            diagnostics.record("audio capture finished as " + state.rawValue)
            return finishedSession
        } catch {
            lastFailureReason = Self.failureReason(for: error)
            let failedSession = try? store.update(
                session,
                state: .failed,
                at: Date(),
                failureReason: lastFailureReason,
                failureCode: DictationFailureCode.infer(
                    from: lastFailureReason ?? "capture failed"
                ),
                audioByteCount: audioByteCount()
            )
            currentSession = failedSession ?? session
            _ = try? apply(.fail)
            releaseCapture()
            throw error
        }
    }

    private func handleCaptureFailure(_ reason: String, operationID: UUID) {
        guard activeOperationID == operationID, acceptsCallbacks else {
            return
        }
        guard let capture = activeCapture,
              let store = sessionStore,
              let session = currentSession else {
            return
        }

        capture.cancel()
        lastFailureReason = reason
        lastFailureCode = DictationFailureCode.infer(from: reason)
        let failedSession = persistTerminalState(
            session,
            in: store,
            state: .failed,
            reason: reason,
            failureCode: lastFailureCode
        )
        if [.preparing, .recording, .finalizing].contains(state) {
            _ = try? apply(.fail)
        }
        currentSession = failedSession
        releaseCapture()
        diagnostics.record("audio capture failed: " + reason)
    }

    private func handleTranscriptionCaptureFailure(
        _ reason: String,
        operationID: UUID
    ) async {
        guard await waitForTerminalOperationIfNeeded(
            operationID: operationID,
            stage: .cancellation
        ) else {
            return
        }
        guard activeOperationID == operationID, acceptsCallbacks else {
            return
        }
        guard let capture = activeCapture,
              let transcription = activeTranscription,
              let store = sessionStore,
              let session = currentSession else {
            return
        }

        capture.cancel()
        let result: TranscriptionResult?
        do {
            result = try await BoundedOperation.run(
                operationID: operationID,
                stage: .cancellation,
                timeout: timeoutPolicy.budget(for: .cancellation),
                registry: operationRegistry
            ) {
                try await transcription.cancel()
            }
        } catch {
            lastFailureReason = "speech capture failure cancellation timed out"
            lastFailureCode = .transcriptionTimedOut
            let timedOutSession = persistTerminalState(
                session,
                in: store,
                state: .failed,
                reason: "speech capture failure cancellation timed out",
                failureCode: .transcriptionTimedOut
            )
            if [.preparing, .recording, .finalizing].contains(state) {
                _ = try? apply(.fail)
            }
            currentSession = timedOutSession
            releaseCapture()
            diagnostics.record("audio capture failure cancellation timed out")
            return
        }
        lastFailureReason = reason
        lastFailureCode = DictationFailureCode.infer(from: reason)
        let failedSession = persistTerminalState(
            session,
            in: store,
            state: .failed,
            reason: reason,
            failureCode: lastFailureCode,
            rawTextByteCount: result?.rawTextByteCount
        )
        if [.preparing, .recording, .finalizing].contains(state) {
            _ = try? apply(.fail)
        }
        currentSession = failedSession
        releaseCapture()
        diagnostics.record("audio capture and transcription failed: " + reason)
    }

    private static func failureReason(for error: Error) -> String {
        if let timeout = error as? BoundedOperationError {
            switch timeout.stage {
            case .startup:
                return "transcription startup timed out"
            case .finalization:
                return "transcription finalization timed out"
            case .retry:
                return "transcription retry timed out"
            case .cancellation:
                return "transcription cancellation timed out"
            case .interruption:
                return "transcription interruption timed out"
            case .shutdown:
                return "transcription shutdown timed out"
            }
        }
        if let failure = error as? DurableSessionBootstrapFailure {
            return "storage failure: " + failure.category.statusDescription
        }
        if let error = error as? SessionStoreError {
            switch error {
            case .applicationSupportUnavailable,
                 .stateChanged,
                 .invalidMetadata,
                 .invalidSessionDirectory:
                return "durable session storage is unavailable"
            case .missingSession:
                return "saved session is unavailable"
            case .transcriptTooLarge:
                return "saved transcript is too large"
            case .insertionAlreadyAttempted:
                return "saved session insertion was already attempted"
            case .activeSession:
                return "saved session is still active"
            case .rawTextChanged:
                return "saved transcript changed before cleanup completed"
            case .deletionConfirmationRequired:
                return "history deletion requires confirmation"
            }
        }
        return "operation failed"
    }

    private static func isTranscriptionTimeout(_ error: Error) -> Bool {
        if error is BoundedOperationError {
            return true
        }
        return DictationFailureCode.infer(from: String(describing: error)) == .transcriptionTimedOut
    }

    private func failureCode(
        for state: DictationSessionState,
        reason: String?
    ) -> DictationFailureCode? {
        switch state {
        case .cancelled:
            reason?.lowercased().contains("timed out") == true
                ? .transcriptionTimedOut
                : .cancelled
        case .interrupted:
            reason?.lowercased().contains("timed out") == true
                ? .transcriptionTimedOut
                : .infer(from: reason ?? "recording was interrupted", interruption: true)
        case .failed:
            .infer(from: reason ?? "capture failed")
        default:
            nil
        }
    }

    private func persistTerminalState(
        _ session: DictationSession,
        in store: SessionStore,
        state: DictationSessionState,
        reason: String?,
        failureCode: DictationFailureCode?,
        rawTextByteCount: Int64? = nil,
        insertionOutcome: InsertionOutcome? = nil,
        insertionFailureReason: String? = nil,
        at date: Date = Date(),
        expectedState: DictationSessionState? = nil
    ) -> DictationSession {
        let audioBytes = audioByteCount()
        do {
            return try store.update(
                session,
                state: state,
                at: date,
                failureReason: reason,
                failureCode: failureCode,
                audioByteCount: audioBytes,
                rawTextByteCount: rawTextByteCount,
                insertionOutcome: insertionOutcome,
                insertionFailureReason: insertionFailureReason,
                expectedState: expectedState
            )
        } catch {
            diagnostics.record("terminal metadata write failed: " + Self.failureReason(for: error))
            do {
                return try store.update(
                    session,
                    state: state,
                    at: date,
                    failureReason: reason,
                    failureCode: failureCode,
                    audioByteCount: audioBytes,
                    rawTextByteCount: rawTextByteCount,
                    insertionOutcome: insertionOutcome,
                    insertionFailureReason: insertionFailureReason,
                    expectedState: expectedState
                )
            } catch {
                diagnostics.record("terminal metadata retry failed: " + Self.failureReason(for: error))
                return inMemoryTerminalState(
                    session,
                    state: state,
                    at: date,
                    reason: reason,
                    failureCode: failureCode,
                    audioByteCount: audioBytes,
                    rawTextByteCount: rawTextByteCount,
                    insertionOutcome: insertionOutcome,
                    insertionFailureReason: insertionFailureReason
                )
            }
        }
    }

    private func inMemoryTerminalState(
        _ session: DictationSession,
        state: DictationSessionState,
        at date: Date,
        reason: String?,
        failureCode: DictationFailureCode?,
        audioByteCount: Int64?,
        rawTextByteCount: Int64?,
        insertionOutcome: InsertionOutcome?,
        insertionFailureReason: String?
    ) -> DictationSession {
        var metadata = session.metadata
        metadata.updatedAt = date
        metadata.state = state
        metadata.failureReason = reason ?? metadata.failureReason
        metadata.failureCode = failureCode ?? metadata.failureCode
        metadata.audioByteCount = audioByteCount ?? metadata.audioByteCount
        metadata.rawTextByteCount = rawTextByteCount ?? metadata.rawTextByteCount
        if let insertionOutcome {
            metadata.insertionOutcome = insertionOutcome
            metadata.insertionFailureReason = insertionFailureReason
        }
        metadata.endedAt = date
        if metadata.duration == nil, let startedAt = metadata.startedAt {
            metadata.duration = max(0, date.timeIntervalSince(startedAt))
        }
        return DictationSession(metadata: metadata, directoryURL: session.directoryURL)
    }

    private func handleTranscriptionCaptureInterruption(
        _ reason: String,
        operationID: UUID
    ) async {
        guard activeOperationID == operationID, acceptsCallbacks else {
            return
        }
        _ = try? await interruptRecordingWithTranscription(reason: reason)
    }

    private func releaseCapture() {
        let operationID = activeOperationID
        let keepTranscription = operationID.map {
            operationRegistry.activeCount(for: $0) > 0
        } ?? false
        if faultInjector?.consume(.cancellationRace) == true {
            staleCaptureFailureForTesting = activeCaptureFailureForTesting
        }
        activeCaptureFailureForTesting = nil
        acceptsCallbacks = false
        activeCapture = nil
        activeAudioDescriptor = nil
        pendingTranscriptionTerminalState = nil
        if keepTranscription, let operationID {
            transcriptionReaperTask?.cancel()
            transcriptionReaperTask = Task { @MainActor [weak self] in
                while let self,
                      self.activeOperationID == operationID,
                      self.activeCapture == nil,
                      self.operationRegistry.activeCount(for: operationID) > 0 {
                    do {
                        try await Task.sleep(for: .milliseconds(10))
                    } catch {
                        return
                    }
                }
                guard let self,
                      self.activeOperationID == operationID else {
                    return
                }
                self.reapReleasedTranscription()
            }
        } else {
            transcriptionReaperTask?.cancel()
            transcriptionReaperTask = nil
            activeTranscription = nil
            sessionStore = nil
            activeOperationID = nil
            diagnostics.mark(.resourcesReleased)
        }
    }

    private func requestCancellation(
        _ transcription: TranscriptionController,
        operationID: UUID,
        stage: TranscriptionStage
    ) async {
        guard activeOperationID == operationID else {
            return
        }
        _ = try? await BoundedOperation.run(
            operationID: operationID,
            stage: stage,
            timeout: timeoutPolicy.budget(for: stage),
            registry: operationRegistry
        ) {
            _ = try await transcription.cancel()
        }
    }

    private func reapReleasedTranscription() {
        guard let operationID = activeOperationID,
              activeCapture == nil,
              operationRegistry.activeCount(for: operationID) == 0 else {
            return
        }
        transcriptionReaperTask?.cancel()
        transcriptionReaperTask = nil
        activeTranscription = nil
        sessionStore = nil
        activeOperationID = nil
        acceptsCallbacks = false
        diagnostics.mark(.resourcesReleased)
    }

    private func beginTerminalOperation() -> Bool {
        guard !terminalOperationInFlight else {
            return false
        }
        terminalOperationInFlight = true
        return true
    }

    private func finishTerminalOperation() {
        terminalOperationInFlight = false
        let waiters = terminalOperationWaiters
        terminalOperationWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForTerminalOperationIfNeeded(
        operationID: UUID,
        stage: TranscriptionStage
    ) async -> Bool {
        guard terminalOperationInFlight else {
            return true
        }
        do {
            _ = try await BoundedOperation.run(
                operationID: operationID,
                stage: stage,
                timeout: timeoutPolicy.budget(for: stage),
                registry: operationRegistry
            ) {
                await self.waitForTerminalOperation()
            }
            return true
        } catch {
            return false
        }
    }

    private func waitForTerminalOperation() async {
        await withCheckedContinuation { continuation in
            guard terminalOperationInFlight else {
                continuation.resume()
                return
            }
            terminalOperationWaiters.append(continuation)
        }
    }

    private func audioByteCount() -> Int64? {
        guard let descriptor = activeAudioDescriptor else {
            return nil
        }
        var fileInfo = stat()
        guard Darwin.fstat(descriptor.rawValue, &fileInfo) == 0,
              (fileInfo.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        return Int64(fileInfo.st_size)
    }

    public func toggle() throws {
        switch state {
        case .idle, .complete, .failed, .cancelled, .interrupted:
            _ = try apply(.start)
            _ = try apply(.prepared)
        case .recording:
            _ = try apply(.stop)
        case .preparing, .finalizing, .cleaning, .inserting:
            throw DictationTransitionError.illegal(from: state, event: .start)
        }
    }

    public func register(task: Task<Void, Never>) throws {
        guard activeTask == nil else {
            throw DictationCoordinatorError.workAlreadyActive
        }
        activeTask = task
        diagnostics.record("registered one active processing task")
    }

    public func finishTask() {
        activeTask = nil
        diagnostics.record("released active processing task")
    }

    public func startTask(
        operation: @escaping @MainActor () async -> Void
    ) throws -> Task<Void, Never> {
        guard activeTask == nil else {
            throw DictationCoordinatorError.workAlreadyActive
        }
        let task = Task { @MainActor [weak self] in
            await operation()
            self?.finishTask()
        }
        activeTask = task
        diagnostics.record("started one coordinator-owned processing task")
        return task
    }

    @_spi(Testing)
    public func deliverCancellationRaceForTesting() {
        let callback = staleCaptureFailureForTesting
        staleCaptureFailureForTesting = nil
        callback?()
    }

    public func shutdown() {
        if activeTranscription == nil, activeCapture != nil, currentSession != nil {
            _ = try? interruptRecording(reason: "application shutdown")
        }
        activeTask?.cancel()
        activeTask = nil
        if activeCapture == nil,
           [.preparing, .recording, .finalizing, .cleaning, .inserting].contains(state) {
            _ = try? apply(.cancel)
        }
        diagnostics.record("coordinator shutdown")
    }

    public func shutdownAndWait() async {
        if activeTranscription == nil, activeCapture != nil, currentSession != nil {
            _ = try? interruptRecording(reason: "application shutdown")
        }
        let task = activeTask
        activeTask = nil
        task?.cancel()
        if let task {
            let operationID = activeOperationID ?? UUID()
            _ = try? await BoundedOperation.run(
                operationID: operationID,
                stage: .shutdown,
                timeout: timeoutPolicy.budget(for: .shutdown),
                registry: operationRegistry
            ) {
                await task.value
            }
        }
        if activeCapture == nil,
           [.preparing, .recording, .finalizing, .cleaning, .inserting].contains(state) {
            _ = try? apply(.cancel)
        }
        diagnostics.record("coordinator shutdown")
    }

    public func shutdownWithTranscription() async {
        guard await waitForTerminalOperationIfNeeded(
            operationID: activeOperationID ?? UUID(),
            stage: .shutdown
        ) else {
            return
        }
        guard beginTerminalOperation() else {
            return
        }
        defer { finishTerminalOperation() }
        if let activeTranscription,
           let store = sessionStore,
           let session = currentSession,
           let operationID = activeOperationID {
            pendingTranscriptionTerminalState = .interrupted
            activeCapture?.cancel()
            let result: TranscriptionResult?
            let terminalState: DictationSessionState
            let terminalEvent: DictationEvent
            let terminalReason: String
            let terminalFailureCode: DictationFailureCode
            do {
                result = try await BoundedOperation.run(
                    operationID: operationID,
                    stage: .shutdown,
                    timeout: timeoutPolicy.budget(for: .shutdown),
                    registry: operationRegistry
                ) {
                    try await activeTranscription.cancel()
                }
                terminalState = .interrupted
                terminalEvent = .interrupt
                terminalReason = "application shutdown"
                terminalFailureCode = .applicationQuit
            } catch {
                result = nil
                terminalState = .failed
                terminalEvent = .fail
                if Self.isTranscriptionTimeout(error) {
                    terminalReason = "application shutdown speech timeout"
                    terminalFailureCode = .transcriptionTimedOut
                } else {
                    terminalReason = Self.failureReason(for: error)
                    terminalFailureCode = .applicationQuit
                }
                lastFailureReason = terminalReason
            }
            let terminalSession = persistTerminalState(
                session,
                in: store,
                state: terminalState,
                reason: terminalReason,
                failureCode: terminalFailureCode,
                rawTextByteCount: result?.rawTextByteCount,
                expectedState: session.metadata.state
            )
            if session.metadata.state == .retrying,
               let reconciledSession = try? store.load(id: session.id),
               reconciledSession.metadata.state == .completed {
                _ = try? apply(.retryCompleted)
                currentSession = reconciledSession
                lastFailureReason = nil
                lastFailureCode = nil
                diagnostics.record("saved audio transcription completed during shutdown")
            } else {
                _ = try? apply(terminalEvent)
                currentSession = terminalSession
            }
            releaseCapture()
        }
        let task = activeTask
        activeTask = nil
        task?.cancel()
        if let task {
            let operationID = activeOperationID ?? UUID()
            _ = try? await BoundedOperation.run(
                operationID: operationID,
                stage: .shutdown,
                timeout: timeoutPolicy.budget(for: .shutdown),
                registry: operationRegistry
            ) {
                await task.value
            }
        }
        diagnostics.record("coordinator shutdown")
    }
}

public struct ToggleShortcut: Codable, Equatable, Hashable, Sendable {
    public let keyCode: UInt32
    public let modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let `default` = ToggleShortcut(
        keyCode: 49,
        modifiers: 0x300
    )
}

public enum IdlePolicy {
    public static let maxIdleCPUPercent = PerformanceBudgetCatalog.idleCPUHardLimit
    public static let maxIdlePhysicalFootprintBytes = PerformanceBudgetCatalog.idlePhysicalFootprintHardLimitBytes
    public static let usesRecurringPolling = false
    public static let createsProcessingServicesAtLaunch = false
    public static let createsProcessingServicesOnDemand = true
    public static let networkRequestsWhileIdle = 0
    public static let thirdPartyRuntimeDependencies = 0
}
