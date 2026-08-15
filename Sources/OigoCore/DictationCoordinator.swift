import Foundation
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
        Transition(from: .idle, event: .retryCompleted, to: .complete),
        Transition(from: .failed, event: .retryCompleted, to: .complete),
        Transition(from: .interrupted, event: .retryCompleted, to: .complete)
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

    public var description: String {
        switch self {
        case .workAlreadyActive:
            return "dictation work is already active"
        case .recordingNotActive:
            return "dictation recording is not active"
        case .retryDidNotPersist:
            return "saved transcription retry did not persist a completed canonical transcript"
        }
    }
}

@MainActor
public final class DictationCoordinator {
    private var machine: DictationStateMachine
    private var activeTask: Task<Void, Never>?
    private let diagnostics: DictationDiagnostics
    private var activeCapture: AudioCapturing?
    private var activeTranscription: TranscriptionController?
    private var sessionStore: SessionStore?
    private var pendingTranscriptionTerminalState: DictationSessionState?

    public private(set) var transitionHistory: [DictationTransitionRecord] = []
    public private(set) var currentSession: DictationSession?
    public private(set) var lastFailureReason: String?

    public var state: DictationState {
        machine.state
    }

    public var activeTaskCount: Int {
        activeTask == nil ? 0 : 1
    }

    public var hasActiveTranscription: Bool {
        activeTranscription != nil
    }

    public init(
        initialState: DictationState = .idle,
        diagnostics: DictationDiagnostics = DictationDiagnostics()
    ) {
        machine = DictationStateMachine(initialState: initialState)
        self.diagnostics = diagnostics
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
        do {
            _ = try apply(.start)
            preparedSession = try store.update(
                session,
                state: .recording,
                at: now
            )
            _ = try apply(.prepared)
            activeCapture = capture
            sessionStore = store
            currentSession = preparedSession
            try capture.start(
                to: preparedSession.audioURL,
                onBuffer: onBuffer,
                onFinish: {},
                onInterruption: { [weak self] (reason: String) in
                    Task { @MainActor [weak self] in
                        _ = try? self?.interruptRecording(reason: reason)
                    }
                },
                onFailure: { [weak self] (reason: String) in
                    Task { @MainActor [weak self] in
                        self?.handleCaptureFailure(reason)
                    }
                }
            )
            lastFailureReason = nil
            diagnostics.record("audio capture started")
            return preparedSession
        } catch {
            capture.cancel()
            let reason = String(describing: error)
            lastFailureReason = reason
            let failedSession = try? store.update(
                preparedSession,
                state: .failed,
                at: Date(),
                failureReason: reason
            )
            if [.preparing, .recording].contains(state) {
                _ = try? apply(.fail)
            }
            currentSession = failedSession ?? preparedSession
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
        do {
            pendingTranscriptionTerminalState = nil
            _ = try apply(.start)
            activeCapture = capture
            activeTranscription = transcription
            sessionStore = store
            currentSession = session

            try await transcription.start(
                session: session,
                format: format,
                store: store,
                onUpdate: onUpdate
            )
            preparedSession = try store.update(
                session,
                state: .recording,
                at: now
            )
            _ = try apply(.prepared)
            currentSession = preparedSession
            try capture.start(
                to: preparedSession.audioURL,
                onBuffer: { buffer in
                    transcription.append(buffer)
                },
                onFinish: {},
                onInterruption: { [weak self] reason in
                    Task { @MainActor [weak self] in
                        await self?.handleTranscriptionCaptureInterruption(reason)
                    }
                },
                onFailure: { [weak self] reason in
                    Task { @MainActor [weak self] in
                        await self?.handleTranscriptionCaptureFailure(reason)
                    }
                }
            )
            lastFailureReason = nil
            diagnostics.record("audio capture and transcription started")
            return preparedSession
        } catch {
            let terminalRequested = pendingTranscriptionTerminalState != nil
                || [.cancelled, .interrupted].contains(state)
            capture.cancel()
            _ = try? await transcription.cancel()
            if terminalRequested {
                currentSession = (try? store.load(id: preparedSession.id)) ?? preparedSession
                releaseCapture()
                throw error
            }
            let reason = String(describing: error)
            lastFailureReason = reason
            let failedSession = try? store.update(
                preparedSession,
                state: .failed,
                at: Date(),
                failureReason: reason
            )
            if [.preparing, .recording].contains(state) {
                _ = try? apply(.fail)
            }
            currentSession = failedSession ?? preparedSession
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
        guard activeCapture == nil, activeTranscription == nil else {
            throw DictationCoordinatorError.workAlreadyActive
        }
        guard let session = savedSession ?? currentSession,
              [.failed, .interrupted].contains(session.metadata.state) else {
            throw DictationCoordinatorError.recordingNotActive
        }
        guard [.idle, .failed, .interrupted].contains(state),
              savedSession != nil || [.failed, .interrupted].contains(state) else {
            throw DictationCoordinatorError.recordingNotActive
        }

        currentSession = session
        let result = try await transcription.retrySavedAudio(for: session, store: store)
        let completedSession = try store.load(id: session.id)
        guard completedSession.metadata.state == .completed,
              completedSession.metadata.rawTextByteCount == result.rawTextByteCount else {
            throw DictationCoordinatorError.retryDidNotPersist
        }
        _ = try apply(.retryCompleted)
        currentSession = completedSession
        lastFailureReason = nil
        diagnostics.record("saved audio transcription retried")
        return completedSession
    }

    @discardableResult
    public func stopRecording(at date: Date = Date()) throws -> DictationSession {
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
                audioByteCount: audioByteCount(at: stoppingSession.audioURL)
            )
            _ = try apply(.captureCompleted)
            currentSession = completedSession
            releaseCapture()
            diagnostics.record("audio capture stopped")
            return completedSession
        } catch {
            let reason = String(describing: error)
            lastFailureReason = reason
            capture.cancel()
            _ = try? store.update(
                stoppingSession,
                state: .failed,
                at: Date(),
                failureReason: reason,
                audioByteCount: audioByteCount(at: stoppingSession.audioURL)
            )
            currentSession = (try? store.load(id: stoppingSession.id)) ?? stoppingSession
            _ = try? apply(.fail)
            releaseCapture()
            throw error
        }
    }

    @discardableResult
    public func stopRecordingWithTranscription(
        at date: Date = Date()
    ) async throws -> DictationSession {
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
            let result = try await transcription.finish()
            let completedSession = try store.update(
                stoppingSession,
                state: .completed,
                at: date,
                audioByteCount: audioByteCount(at: stoppingSession.audioURL),
                rawTextByteCount: result.rawTextByteCount
            )
            _ = try apply(.captureCompleted)
            currentSession = completedSession
            releaseCapture()
            diagnostics.record("audio capture and transcription stopped")
            return completedSession
        } catch {
            _ = try? await transcription.cancel()
            let reason = String(describing: error)
            lastFailureReason = reason
            capture.cancel()
            _ = try? store.update(
                stoppingSession,
                state: .failed,
                at: Date(),
                failureReason: reason,
                audioByteCount: audioByteCount(at: stoppingSession.audioURL)
            )
            currentSession = (try? store.load(id: stoppingSession.id)) ?? stoppingSession
            _ = try? apply(.fail)
            releaseCapture()
            throw error
        }
    }

    @discardableResult
    public func cancelRecording(at date: Date = Date()) throws -> DictationSession {
        try finishRecording(
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
        try await finishTranscribedRecording(
            state: .cancelled,
            event: .cancel,
            reason: nil,
            at: date
        )
    }

    @discardableResult
    public func interruptRecording(
        reason: String = "recording was interrupted",
        at date: Date = Date()
    ) throws -> DictationSession {
        try finishRecording(
            state: .interrupted,
            event: .interrupt,
            reason: reason,
            at: date
        )
    }

    @discardableResult
    public func interruptRecordingWithTranscription(
        reason: String = "recording was interrupted",
        at date: Date = Date()
    ) async throws -> DictationSession {
        try await finishTranscribedRecording(
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
            let failedSession = try? store.update(
                session,
                state: .failed,
                at: Date(),
                failureReason: failureReason,
                audioByteCount: audioByteCount(at: session.audioURL)
            )
            if [.preparing, .recording, .finalizing, .cleaning, .inserting].contains(self.state) {
                _ = try? apply(.fail)
            }
            currentSession = failedSession ?? session
            releaseCapture()
            throw error
        }
        do {
            let finishedSession = try store.update(
                session,
                state: state,
                at: date,
                failureReason: reason,
                audioByteCount: audioByteCount(at: session.audioURL),
                rawTextByteCount: result?.rawTextByteCount
            )
            _ = try apply(event)
            currentSession = finishedSession
            releaseCapture()
            diagnostics.record("audio capture and transcription finished as " + state.rawValue)
            return finishedSession
        } catch {
            lastFailureReason = String(describing: error)
            let failedSession = try? store.update(
                session,
                state: .failed,
                at: Date(),
                failureReason: lastFailureReason,
                audioByteCount: audioByteCount(at: session.audioURL),
                rawTextByteCount: result?.rawTextByteCount
            )
            currentSession = failedSession ?? session
            _ = try? apply(.fail)
            releaseCapture()
            throw error
        }
    }

    private func finishRecording(
        state: DictationSessionState,
        event: DictationEvent,
        reason: String?,
        at date: Date
    ) throws -> DictationSession {
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
                audioByteCount: audioByteCount(at: session.audioURL)
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
                audioByteCount: audioByteCount(at: session.audioURL)
            )
            currentSession = failedSession ?? session
            _ = try? apply(.fail)
            releaseCapture()
            throw error
        }
    }

    private func handleCaptureFailure(_ reason: String) {
        guard let capture = activeCapture,
              let store = sessionStore,
              let session = currentSession else {
            return
        }

        capture.cancel()
        lastFailureReason = reason
        let failedSession = try? store.update(
            session,
            state: .failed,
            at: Date(),
            failureReason: reason,
            audioByteCount: audioByteCount(at: session.audioURL)
        )
        if [.preparing, .recording, .finalizing].contains(state) {
            _ = try? apply(.fail)
        }
        currentSession = failedSession ?? session
        releaseCapture()
        diagnostics.record("audio capture failed: " + reason)
    }

    private func handleTranscriptionCaptureFailure(_ reason: String) async {
        guard let capture = activeCapture,
              let transcription = activeTranscription,
              let store = sessionStore,
              let session = currentSession else {
            return
        }

        capture.cancel()
        let result = try? await transcription.cancel()
        lastFailureReason = reason
        let failedSession = try? store.update(
            session,
            state: .failed,
            at: Date(),
            failureReason: reason,
            audioByteCount: audioByteCount(at: session.audioURL),
            rawTextByteCount: result?.rawTextByteCount
        )
        if [.preparing, .recording, .finalizing].contains(state) {
            _ = try? apply(.fail)
        }
        currentSession = failedSession ?? session
        releaseCapture()
        diagnostics.record("audio capture and transcription failed: " + reason)
    }

    private func handleTranscriptionCaptureInterruption(_ reason: String) async {
        _ = try? await interruptRecordingWithTranscription(reason: reason)
    }

    private func releaseCapture() {
        activeCapture = nil
        activeTranscription = nil
        sessionStore = nil
        pendingTranscriptionTerminalState = nil
    }

    private func audioByteCount(at url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
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

    public func shutdownWithTranscription() async {
        if let activeTranscription,
           let capture = activeCapture,
           let store = sessionStore,
           let session = currentSession {
            pendingTranscriptionTerminalState = .interrupted
            capture.cancel()
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
            let interruptedSession = try? store.update(
                session,
                state: terminalState,
                at: Date(),
                failureReason: terminalReason,
                audioByteCount: audioByteCount(at: session.audioURL),
                rawTextByteCount: result?.rawTextByteCount
            )
            _ = try? apply(terminalEvent)
            currentSession = interruptedSession ?? session
            releaseCapture()
        }
        activeTask?.cancel()
        activeTask = nil
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
