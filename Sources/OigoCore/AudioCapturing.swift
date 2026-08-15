import Foundation
import Darwin

public final class AudioFileDescriptor: @unchecked Sendable {
    public let rawValue: Int32

    private let lock = NSLock()
    private var closed = false

    init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    public func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        _ = Darwin.close(rawValue)
    }

    deinit {
        close()
    }
}

public struct AudioCaptureFormat: Equatable, Sendable {
    public let sampleRate: Double
    public let channelCount: Int

    public init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    public var isValid: Bool {
        sampleRate.isFinite && sampleRate > 0 && channelCount > 0
    }
}

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

    func start(
        to descriptor: AudioFileDescriptor,
        url: URL,
        onBuffer: @escaping @Sendable (AudioCaptureBuffer) -> Void,
        onFinish: @escaping @Sendable () -> Void,
        onInterruption: @escaping @Sendable (String) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) throws

    func stop() throws

    func cancel()
}

public extension AudioCapturing {
    func start(
        to descriptor: AudioFileDescriptor,
        url: URL,
        onBuffer: @escaping @Sendable (AudioCaptureBuffer) -> Void,
        onFinish: @escaping @Sendable () -> Void,
        onInterruption: @escaping @Sendable (String) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) throws {
        defer { descriptor.close() }
        try start(
            to: url,
            onBuffer: onBuffer,
            onFinish: onFinish,
            onInterruption: onInterruption,
            onFailure: onFailure
        )
    }
}
