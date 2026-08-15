import AVFAudio
import Foundation

public enum CaptureJournalError: Error, Equatable, CustomStringConvertible {
    case closed
    case missing(URL)

    public var description: String {
        switch self {
        case .closed:
            return "capture journal is closed"
        case .missing(let url):
            return "capture artifact is missing at \(url.path)"
        }
    }
}

public final class DurableCaptureJournal: @unchecked Sendable {
    public let url: URL

    private let lock = NSLock()
    private var handle: FileHandle?
    private(set) public var bytesWritten = 0

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    public func append(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else {
            throw CaptureJournalError.closed
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
        bytesWritten += data.count
    }

    public func finish() throws {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else {
            return
        }
        try handle.synchronize()
        try handle.close()
        self.handle = nil
    }

    public static func recover(_ url: URL) throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CaptureJournalError.missing(url)
        }
        return try Data(contentsOf: url)
    }

    deinit {
        try? finish()
    }
}

@available(macOS 26.0, *)
public final class CAFRecorder: @unchecked Sendable {
    public let url: URL

    private let lock = NSLock()
    private var audioFile: AVAudioFile?

    public init(url: URL, format: AVAudioFormat) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        audioFile = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
    }

    public func append(_ buffer: AVAudioPCMBuffer) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let audioFile else {
            throw CaptureJournalError.closed
        }
        try audioFile.write(from: buffer)
    }

    public func finish() throws {
        lock.lock()
        defer { lock.unlock() }
        audioFile = nil
    }

    public static func playableFrameLength(at url: URL) throws -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CaptureJournalError.missing(url)
        }
        let audioFile = try AVAudioFile(forReading: url)
        return Int64(audioFile.length)
    }

    deinit {
        try? finish()
    }
}

public struct ForcedRecognitionFailure: Error, Sendable, CustomStringConvertible {
    public init() {}

    public var description: String {
        "forced live recognition failure"
    }
}

public enum SavedAudioRetry {
    public static func retry<T>(
        url: URL,
        transcribe: (URL) throws -> T
    ) throws -> T {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CaptureJournalError.missing(url)
        }
        return try transcribe(url)
    }

    public static func retryAfterFailure<T>(
        url: URL,
        liveFailure: Error,
        transcribe: (URL) throws -> T
    ) throws -> T {
        _ = liveFailure
        _ = try CAFRecorder.playableFrameLength(at: url)
        return try retry(url: url, transcribe: transcribe)
    }
}
