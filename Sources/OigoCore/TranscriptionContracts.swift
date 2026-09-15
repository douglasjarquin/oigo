import Foundation

public protocol DictationStartupFailureEvidence: Error, Sendable {
    var dictationStartupFailureReason: String { get }
}

public enum KeyboardStartupLocaleBindingFailure: Error, Equatable, Sendable,
    DictationStartupFailureEvidence {
    case staleGeneration
    case localeMismatch
    case assetsNotReady

    public var dictationStartupFailureReason: String {
        switch self {
        case .staleGeneration:
            "speech assets were verified for a stale dictation generation"
        case .localeMismatch:
            "speech assets were verified for a different dictation language"
        case .assetsNotReady:
            "speech assets are not ready for the selected dictation language"
        }
    }
}

public struct KeyboardStartupLocaleBinding: Equatable, Sendable {
    public let generation: UInt64
    public let localeIdentifier: String

    public init(
        generation: UInt64,
        currentGeneration: UInt64,
        requestedLocaleIdentifier: String,
        configuredLocaleIdentifier: String,
        verifiedLocaleIdentifier: String?
    ) throws {
        guard generation > 0, generation == currentGeneration else {
            throw KeyboardStartupLocaleBindingFailure.staleGeneration
        }
        guard let verifiedLocaleIdentifier else {
            throw KeyboardStartupLocaleBindingFailure.assetsNotReady
        }
        let requested = Locale(identifier: requestedLocaleIdentifier).identifier
        let configured = Locale(identifier: configuredLocaleIdentifier).identifier
        let verified = Locale(identifier: verifiedLocaleIdentifier).identifier
        guard requested == configured, configured == verified else {
            throw KeyboardStartupLocaleBindingFailure.localeMismatch
        }
        self.generation = generation
        localeIdentifier = verified
    }
}

public enum KeyboardStartupReadinessFailure: String, Equatable, Sendable {
    case microphoneDenied = "microphone-denied"
    case inputUnavailable = "input-unavailable"
}

public protocol KeyboardStartupReadinessProviding: Sendable {
    var microphonePermission: OigoPermissionState { get }
    var inputSelection: OigoInputSelection { get }
    var inputDevices: [OigoInputDevice] { get }
}

public struct KeyboardStartupReadinessSnapshot: KeyboardStartupReadinessProviding, Equatable, Sendable {
    public let microphonePermission: OigoPermissionState
    public let inputSelection: OigoInputSelection
    public let inputDevices: [OigoInputDevice]

    public init(
        microphonePermission: OigoPermissionState,
        inputSelection: OigoInputSelection,
        inputDevices: [OigoInputDevice]
    ) {
        self.microphonePermission = microphonePermission
        self.inputSelection = inputSelection
        self.inputDevices = inputDevices
    }
}

public enum KeyboardStartupReadinessPolicy {
    public static func failure(
        using provider: some KeyboardStartupReadinessProviding
    ) -> KeyboardStartupReadinessFailure? {
        failure(
            microphonePermission: provider.microphonePermission,
            inputSelection: provider.inputSelection,
            inputDevices: provider.inputDevices
        )
    }

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
