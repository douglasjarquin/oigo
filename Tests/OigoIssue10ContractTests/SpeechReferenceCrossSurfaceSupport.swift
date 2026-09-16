import Darwin
import Foundation
@_spi(Testing) import OigoCore
@_spi(Testing) import OigoInsertion
@_spi(Testing) import OigoTranscription

struct SpeechReferenceContractFailure: Error, CustomStringConvertible {
    let description: String
}

final class SpeechReferenceCapture: AudioCapturing, @unchecked Sendable {
    private var descriptor: AudioFileDescriptor?
    private(set) var isActive = false

    func start(
        to descriptor: AudioFileDescriptor,
        onBuffer: @escaping @Sendable (AudioCaptureBuffer) -> Void,
        onFinish: @escaping @Sendable () -> Void,
        onInterruption: @escaping @Sendable (String) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) throws {
        _ = onBuffer
        _ = onFinish
        _ = onInterruption
        _ = onFailure
        self.descriptor = descriptor
        isActive = true
        var byte: UInt8 = 1
        _ = Darwin.write(descriptor.rawValue, &byte, 1)
    }

    func stop() throws { cancel() }

    func cancel() {
        isActive = false
        descriptor?.close()
        descriptor = nil
    }
}

final class SpeechReferenceTranscription: TranscriptionController, @unchecked Sendable {
    private var session: DictationSession?
    private var store: SessionStore?
    private var onUpdate: (@Sendable (TranscriptionUpdate) -> Void)?
    private var degraded = false

    func start(
        session: DictationSession,
        format: AudioCaptureFormat,
        store: SessionStore,
        onUpdate: @escaping @Sendable (TranscriptionUpdate) -> Void
    ) async throws {
        _ = format
        self.session = session
        self.store = store
        self.onUpdate = onUpdate
    }

    func append(_ buffer: AudioCaptureBuffer) { _ = buffer }

    func finish() async throws -> TranscriptionResult {
        if degraded { throw TranscriptionError.liveQueueSaturated }
        return try persistSyntheticRaw()
    }

    func cancel() async throws -> TranscriptionResult? { nil }

    func retrySavedAudio(
        for session: DictationSession,
        store: SessionStore
    ) async throws -> TranscriptionResult {
        self.session = session
        self.store = store
        degraded = false
        let result = try persistSyntheticRaw()
        _ = try store.update(session, state: .completed, rawTextByteCount: result.rawTextByteCount)
        return result
    }

    func degrade() {
        degraded = true
        onUpdate?(.liveHealth(.queueSaturated))
    }

    private func persistSyntheticRaw() throws -> TranscriptionResult {
        guard let session, let store else { throw TranscriptionError.notRunning }
        let marker = String(UnicodeScalar(120))
        _ = try store.persistRawText(marker, for: session)
        return TranscriptionResult(finalizedText: marker, rawTextByteCount: 1)
    }
}

@MainActor
final class SpeechReferenceTargetEnvironment: InsertionTargetEnvironment {
    private(set) var captureCount = 0
    private(set) var discardCount = 0
    private(set) var validationCount = 0
    var validations: [TargetValidation] = [.safe]

    func capture() -> InsertionTargetSnapshot {
        captureCount += 1
        return InsertionTargetSnapshot(
            frontmostProcessIdentifier: 10,
            bundleIdentifier: "example.invalid",
            focusedElementIdentifier: "fixture-field",
            role: "AXTextArea",
            isSecureTextField: false
        )
    }

    func validate(_ snapshot: InsertionTargetSnapshot) -> TargetValidation {
        _ = snapshot
        let index = min(validationCount, validations.count - 1)
        validationCount += 1
        return validations[index]
    }

    func discard(_ snapshot: InsertionTargetSnapshot) {
        _ = snapshot
        discardCount += 1
    }
}

@MainActor
final class SpeechReferencePasteboard: InsertionPasteboard {
    private(set) var writeCount = 0

    func write(_ rawText: String) -> Bool {
        _ = rawText
        writeCount += 1
        return true
    }
}

@MainActor
final class SpeechReferenceEventSender: InsertionEventSender {
    private(set) var sendCount = 0

    func sendPaste(
        to processIdentifier: Int32,
        revalidate: () -> TargetValidation
    ) -> InsertionEventResult {
        _ = processIdentifier
        sendCount += 1
        let validation = revalidate()
        return validation == .safe ? .dispatched : .targetUnsafe(validation)
    }
}

@MainActor
final class SpeechReferenceScheduler {
    final class Action {
        let deadline: Duration
        let callback: @MainActor () -> Void
        var isCancelled = false

        init(deadline: Duration, callback: @escaping @MainActor () -> Void) {
            self.deadline = deadline
            self.callback = callback
        }
    }

    private(set) var now: Duration = .zero
    private var actions: [Action] = []

    func schedule(
        after delay: Duration,
        callback: @escaping @MainActor () -> Void
    ) -> @MainActor () -> Void {
        let action = Action(deadline: now + delay, callback: callback)
        actions.append(action)
        return { action.isCancelled = true }
    }

    func set(milliseconds: Int64) { now = .milliseconds(milliseconds) }

    func fireRetiredAction() {
        actions.first?.callback()
    }
}
