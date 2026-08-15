import Foundation

public struct AudioCaptureBuffer: Equatable, Sendable {
    public let frameCount: Int
    public let sampleRate: Double
    public let channelCount: Int
    public let pcmData: Data

    public init(
        frameCount: Int,
        sampleRate: Double,
        channelCount: Int,
        pcmData: Data
    ) {
        self.frameCount = frameCount
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.pcmData = pcmData
    }
}

public protocol AudioCapturing: AnyObject {
    func start(
        to url: URL,
        onBuffer: @escaping @Sendable (AudioCaptureBuffer) -> Void,
        onFinish: @escaping @Sendable () -> Void,
        onInterruption: @escaping @Sendable (String) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) throws

    func stop() throws

    func cancel()
}
