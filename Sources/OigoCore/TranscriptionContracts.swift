import Foundation

public struct TranscriptionUpdate: Equatable, Sendable {
    public let finalizedSegment: String?
    public let volatilePreview: String
    public let isFinal: Bool

    public init(
        finalizedSegment: String?,
        volatilePreview: String,
        isFinal: Bool
    ) {
        self.finalizedSegment = finalizedSegment
        self.volatilePreview = volatilePreview
        self.isFinal = isFinal
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
