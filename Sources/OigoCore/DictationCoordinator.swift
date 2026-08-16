import Foundation
import Darwin
import os

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

    public init() {}

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
    private var activeCaptureFailureForTesting: (() -> Void)?
    private var staleCaptureFailureForTesting: (() -> Void)?
    private var terminalOperationInFlight = false
    private var terminalOperationWaiters: [CheckedContinuation<Void, Never>] = []

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

    public var hasActiveTranscription: Bool {
        activeTranscription != nil
    }

    public var hasActiveWork: Bool {
        activeCapture != nil
            || activeTranscription != nil
            || activeTask != nil
            || [.preparing, .recording, .finalizing, .cleaning, .inserting].contains(state)
    }

    public init(
        initialState: DictationState = .idle,
        diagnostics: DictationDiagnostics = DictationDiagnostics()
    ) {
        machine = DictationStateMachine(initialState: initialState)
        self.diagnostics = diagnostics
        self.faultInjector = nil
    }

    @_spi(Testing)
    public init(
        faultInjector: DictationFaultInjector,
        initialState: DictationState = .idle,
        diagnostics: DictationDiagnostics = DictationDiagnostics()
    ) {
        machine = DictationStateMachine(initialState: initialState)
        self.diagnostics = diagnostics
        self.faultInjector = faultInjector
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
        guard activeCapture == nil else {
            throw DictationCoordinatorError.workAlreadyActive
        }
        guard [.idle, .complete, .failed, .cancelled, .interrupted].contains(state) else {
            throw DictationTransitionError.illegal(from: state, event: .start)
        }

        let session = try store.createSession(now: now)
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
            let reason = String(describing: error)
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
        guard activeCapture == nil else {
            throw DictationCoordinatorError.workAlreadyActive
        }
        guard [.idle, .complete, .failed, .cancelled, .interrupted].contains(state) else {
            throw DictationTransitionError.illegal(from: state, event: .start)
        }

        let session = try store.createSession(now: now)
        var preparedSession = session
        let operationID = UUID()
        do {
            pendingTranscriptionTerminalState = nil
            _ = try apply(.start)
            activeCapture = capture
            activeTranscription = transcription
            activeOperationID = operationID
            sessionStore = store
            currentSession = session

            try await withTaskCancellationHandler(operation: {
                try await transcription.start(
                    session: session,
                    format: format,
                    store: store,
                    onUpdate: { [weak self] update in
                        Task { @MainActor [weak self] in
                            guard self?.activeOperationID == operationID else {
                                return
                            }
                            onUpdate(update)
                        }
                    }
                )
            }, onCancel: {
                Task { @MainActor in
                    _ = try? await transcription.cancel()
                }
            })
            try Task.checkCancellation()
            preparedSession = try store.update(
                session,
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
            _ = try? await transcription.cancel()
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
            let reason = String(describing: error)
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
        await waitForTerminalOperationIfNeeded()
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
        activeTranscription = transcription
        sessionStore = store
        defer {
            if activeOperationID == operationID {
                releaseCapture()
            }
        }

        do {
            let result = try await transcription.retrySavedAudio(for: retryingSession, store: store)
            guard activeOperationID == operationID else {
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
            let reason = String(describing: error)
            let persistedSession = try? store.load(id: retryingSession.id)
            if terminalOperationInFlight
                || pendingTranscriptionTerminalState == .interrupted
                || persistedSession?.metadata.state == .interrupted {
                let interruptedSession = try? store.update(
                    retryingSession,
                    state: .interrupted,
                    at: Date(),
                    failureReason: "application shutdown"
                )
                _ = try? apply(.interrupt)
                currentSession = interruptedSession ?? persistedSession ?? retryingSession
            } else {
                lastFailureReason = reason
                currentSession = persistTerminalState(
                    retryingSession,
                    in: store,
                    state: .failed,
                    reason: reason,
                    failureCode: .transcriptionFailed
                )
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
            let reason = String(describing: error)
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
        await waitForTerminalOperationIfNeeded()
        guard beginTerminalOperation() else {
            throw DictationCoordinatorError.workAlreadyActive
        }
        defer { finishTerminalOperation() }
        guard let capture = activeCapture,
              let transcription = activeTranscription,
              let store = sessionStore,
              let session = currentSession else {
            throw DictationCoordinatorError.recordingNotActive
        }

        _ = try apply(.stop)
        var stoppingSession = session
        do {
            stoppingSession = try store.update(session, state: .stopping, at: date)
            try capture.stop()
            let result = try await withTaskCancellationHandler(operation: {
                try await transcription.finish()
            }, onCancel: {
                Task { @MainActor in
                    _ = try? await transcription.cancel()
                }
            })
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
            _ = try? await transcription.cancel()
            if Task.isCancelled || pendingTranscriptionTerminalState == .cancelled {
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
            let reason = String(describing: error)
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
        if terminalOperationInFlight, let activeTranscription {
            pendingTranscriptionTerminalState = .cancelled
            _ = try? await activeTranscription.cancel()
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
        await waitForTerminalOperationIfNeeded()
        guard beginTerminalOperation() else {
            throw DictationCoordinatorError.workAlreadyActive
        }
        defer { finishTerminalOperation() }
        guard let capture = activeCapture,
              let transcription = activeTranscription,
              let store = sessionStore,
              let session = currentSession else {
            throw DictationCoordinatorError.recordingNotActive
        }

        pendingTranscriptionTerminalState = state
        capture.cancel()
        let result: TranscriptionResult?
        do {
            result = try await transcription.cancel()
        } catch {
            let failureReason = String(describing: error)
            lastFailureReason = failureReason
            let failedSession = persistTerminalState(
                session,
                in: store,
                state: .failed,
                reason: failureReason,
                failureCode: .transcriptionFailed,
                rawTextByteCount: nil
            )
            if [.preparing, .recording, .finalizing, .cleaning, .inserting].contains(self.state) {
                _ = try? apply(.fail)
            }
            currentSession = failedSession
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
            lastFailureReason = String(describing: error)
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
            lastFailureReason = String(describing: error)
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
        guard activeOperationID == operationID else {
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
        await waitForTerminalOperationIfNeeded()
        guard activeOperationID == operationID else {
            return
        }
        guard let capture = activeCapture,
              let transcription = activeTranscription,
              let store = sessionStore,
              let session = currentSession else {
            return
        }

        capture.cancel()
        let result = try? await transcription.cancel()
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

    private func failureCode(
        for state: DictationSessionState,
        reason: String?
    ) -> DictationFailureCode? {
        switch state {
        case .cancelled:
            .cancelled
        case .interrupted:
            .infer(from: reason ?? "recording was interrupted", interruption: true)
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
        at date: Date = Date()
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
                insertionFailureReason: insertionFailureReason
            )
        } catch {
            diagnostics.record("terminal metadata write failed: " + String(describing: error))
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
                    insertionFailureReason: insertionFailureReason
                )
            } catch {
                diagnostics.record("terminal metadata retry failed: " + String(describing: error))
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
        guard activeOperationID == operationID else {
            return
        }
        _ = try? await interruptRecordingWithTranscription(reason: reason)
    }

    private func releaseCapture() {
        if faultInjector?.consume(.cancellationRace) == true {
            staleCaptureFailureForTesting = activeCaptureFailureForTesting
        }
        activeCaptureFailureForTesting = nil
        activeCapture = nil
        activeAudioDescriptor = nil
        activeTranscription = nil
        sessionStore = nil
        pendingTranscriptionTerminalState = nil
        activeOperationID = nil
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

    private func waitForTerminalOperationIfNeeded() async {
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
            _ = await task.value
        }
        if activeCapture == nil,
           [.preparing, .recording, .finalizing, .cleaning, .inserting].contains(state) {
            _ = try? apply(.cancel)
        }
        diagnostics.record("coordinator shutdown")
    }

    public func shutdownWithTranscription() async {
        await waitForTerminalOperationIfNeeded()
        guard beginTerminalOperation() else {
            return
        }
        defer { finishTerminalOperation() }
        if let activeTranscription,
           let store = sessionStore,
           let session = currentSession {
            pendingTranscriptionTerminalState = .interrupted
            activeCapture?.cancel()
            let result: TranscriptionResult?
            let terminalState: DictationSessionState
            let terminalEvent: DictationEvent
            let terminalReason: String
            do {
                result = try await activeTranscription.cancel()
                terminalState = .interrupted
                terminalEvent = .interrupt
                terminalReason = "application shutdown"
            } catch {
                result = nil
                terminalState = .failed
                terminalEvent = .fail
                terminalReason = String(describing: error)
                lastFailureReason = terminalReason
            }
            let interruptedSession = persistTerminalState(
                session,
                in: store,
                state: terminalState,
                reason: terminalReason,
                failureCode: terminalState == .interrupted ? .applicationQuit : .transcriptionFailed,
                rawTextByteCount: result?.rawTextByteCount
            )
            _ = try? apply(terminalEvent)
            currentSession = interruptedSession
            releaseCapture()
        }
        let task = activeTask
        activeTask = nil
        task?.cancel()
        if let task {
            _ = await task.value
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
        modifiers: 0x900
    )
}

public struct ShortcutInput: Equatable, Sendable {
    public let keyCode: UInt32
    public let modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public enum ToggleShortcutError: Error, Equatable, CustomStringConvertible, Sendable {
    case notMatching

    public var description: String {
        switch self {
        case .notMatching:
            return "shortcut input does not match configured toggle"
        }
    }
}

@MainActor
public final class ToggleShortcutController {
    public private(set) var shortcut: ToggleShortcut
    private let coordinator: DictationCoordinator

    public init(
        shortcut: ToggleShortcut = .default,
        coordinator: DictationCoordinator
    ) {
        self.shortcut = shortcut
        self.coordinator = coordinator
    }

    public func update(shortcut: ToggleShortcut) {
        self.shortcut = shortcut
    }

    @discardableResult
    public func handle(_ input: ShortcutInput) throws -> DictationState {
        guard input == ShortcutInput(
            keyCode: shortcut.keyCode,
            modifiers: shortcut.modifiers
        ) else {
            throw ToggleShortcutError.notMatching
        }
        try coordinator.toggle()
        return coordinator.state
    }
}

public enum IdlePolicy {
    public static let maxIdleCPUPercent = 0.5
    public static let maxIdlePhysicalFootprintBytes: UInt64 = 90 * 1024 * 1024
    public static let usesRecurringPolling = false
    public static let createsProcessingServicesAtLaunch = false
    public static let createsProcessingServicesOnDemand = true
    public static let networkRequestsWhileIdle = 0
    public static let thirdPartyRuntimeDependencies = 0
}
