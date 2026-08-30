import Foundation

public protocol DictationStartupFailureEvidence: Error, Sendable {
    var dictationStartupFailureReason: String { get }
}

public enum KeyboardStartupReadinessFailure: String, Equatable, Sendable {
    case microphoneDenied = "microphone-denied"
    case inputUnavailable = "input-unavailable"
}

public enum KeyboardStartupReadinessPolicy {
    public static func failure(
        microphonePermission: OigoPermissionState,
        inputSelection: OigoInputSelection,
        inputDevices: [OigoInputDevice]
    ) -> KeyboardStartupReadinessFailure? {
        if microphonePermission == .denied {
            return .microphoneDenied
        }
        guard (try? OigoInputDeviceCatalog.resolve(inputSelection, from: inputDevices)) != nil else {
            return .inputUnavailable
        }
        return nil
    }
}

public enum LiveTranscriptionDegradation: String, Equatable, Sendable {
    case queueSaturated = "speech_queue_saturated"
    case continuationTerminated = "speech_continuation_terminated"
    case conversionFailed = "speech_conversion_failed"
    case analyzerFailed = "speech_analyzer_failed"
    case resultSequenceFailed = "speech_result_sequence_failed"
}

public struct LiveTranscriptionEvent: Equatable, Sendable {
    public let degradation: LiveTranscriptionDegradation

    public init(degradation: LiveTranscriptionDegradation) {
        self.degradation = degradation
    }
}

public struct TranscriptionUpdate: Equatable, Sendable {
    public let finalizedSegment: String?
    public let volatilePreview: String
    public let isFinal: Bool
    public let liveDegradation: LiveTranscriptionDegradation?

    public init(
        finalizedSegment: String?,
        volatilePreview: String,
        isFinal: Bool,
        liveDegradation: LiveTranscriptionDegradation? = nil
    ) {
        self.finalizedSegment = finalizedSegment
        self.volatilePreview = volatilePreview
        self.isFinal = isFinal
        self.liveDegradation = liveDegradation
    }

    public static func liveHealth(
        _ degradation: LiveTranscriptionDegradation
    ) -> TranscriptionUpdate {
        TranscriptionUpdate(
            finalizedSegment: nil,
            volatilePreview: "",
            isFinal: false,
            liveDegradation: degradation
        )
    }
}

public struct TranscriptionResult: Equatable, Sendable {
    public let finalizedText: String
    public let rawTextByteCount: Int64

    public init(finalizedText: String, rawTextByteCount: Int64) {
        self.finalizedText = finalizedText
        self.rawTextByteCount = rawTextByteCount
    }
}

public protocol TranscriptionController: AnyObject, Sendable {
    func start(
        session: DictationSession,
        format: AudioCaptureFormat,
        store: SessionStore,
        onUpdate: @escaping @Sendable (TranscriptionUpdate) -> Void
    ) async throws

    func append(_ buffer: AudioCaptureBuffer)

    func finish() async throws -> TranscriptionResult

    func cancel() async throws -> TranscriptionResult?

    func retrySavedAudio(
        for session: DictationSession,
        store: SessionStore
    ) async throws -> TranscriptionResult
}
