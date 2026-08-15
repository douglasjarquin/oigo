import AVFAudio
import Darwin
import Foundation

public enum CaptureJournalError: Error, Equatable, CustomStringConvertible {
    case closed
    case descriptor(String)
    case invalid(URL, String)
    case missing(URL)

    public var description: String {
        switch self {
        case .closed:
            return "capture journal is closed"
        case .descriptor(let reason):
            return "capture descriptor failed: " + reason
        case .invalid(let url, let reason):
            return "capture artifact is invalid at " + url.path + ": " + reason
        case .missing(let url):
            return "capture artifact is missing at \(url.path)"
        }
    }
}

public final class CaptureFileDescriptor: @unchecked Sendable {
    public let rawValue: Int32

    private let lock = NSLock()
    private var closed = false

    fileprivate init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    @_spi(Testing)
    public func duplicate() throws -> CaptureFileDescriptor {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else {
            throw CaptureJournalError.closed
        }
        let duplicateFD = Darwin.dup(rawValue)
        guard duplicateFD >= 0 else {
            throw CaptureJournalError.descriptor("could not duplicate the capture descriptor")
        }
        guard Darwin.fcntl(duplicateFD, F_SETFD, FD_CLOEXEC) == 0 else {
            _ = Darwin.close(duplicateFD)
            throw CaptureJournalError.descriptor("could not mark the capture descriptor close-on-exec")
        }
        return CaptureFileDescriptor(rawValue: duplicateFD)
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

private enum SecureCaptureFile {
    static func create(at url: URL) throws -> CaptureFileDescriptor {
        let directoryFD = try openParentDirectory(for: url)
        defer { _ = Darwin.close(directoryFD) }
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else {
            throw CaptureJournalError.invalid(url, "the capture filename is empty")
        }
        let flags = O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW
        let descriptor = name.withCString { namePointer in
            Darwin.openat(directoryFD, namePointer, flags, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw CaptureJournalError.invalid(url, "the capture file could not be created without following a link")
        }
        do {
            try validateRegularFile(descriptor, at: url)
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
        return CaptureFileDescriptor(rawValue: descriptor)
    }

    static func open(at url: URL) throws -> CaptureFileDescriptor {
        let directoryFD = try openParentDirectory(for: url)
        defer { _ = Darwin.close(directoryFD) }
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else {
            throw CaptureJournalError.missing(url)
        }
        let descriptor = name.withCString { namePointer in
            Darwin.openat(directoryFD, namePointer, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw CaptureJournalError.missing(url)
        }
        do {
            try validateRegularFile(descriptor, at: url)
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
        return CaptureFileDescriptor(rawValue: descriptor)
    }

    private static func openParentDirectory(for url: URL) throws -> Int32 {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        let descriptor = parent.path.withCString { path in
            Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw CaptureJournalError.invalid(url, "the capture directory is not a real directory")
        }
        return descriptor
    }

    private static func validateRegularFile(_ descriptor: Int32, at url: URL) throws {
        var fileInfo = stat()
        guard Darwin.fstat(descriptor, &fileInfo) == 0,
              (fileInfo.st_mode & S_IFMT) == S_IFREG else {
            throw CaptureJournalError.invalid(url, "the capture artifact is not a regular file")
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
    private let fileDescriptor: CaptureFileDescriptor

    public convenience init(url: URL, format: AVAudioFormat) throws {
        try self.init(url: url, format: format, beforeOpeningAudioFile: nil)
    }

    @_spi(Testing)
    public init(
        url: URL,
        format: AVAudioFormat,
        beforeOpeningAudioFile: ((CaptureFileDescriptor) throws -> Void)?
    ) throws {
        self.url = url
        let descriptor = try SecureCaptureFile.create(at: url)
        do {
            try beforeOpeningAudioFile?(descriptor)
            audioFile = try AVAudioFile(
                forWriting: URL(fileURLWithPath: "/dev/fd/\(descriptor.rawValue)"),
                settings: format.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
        } catch {
            descriptor.close()
            throw error
        }
        fileDescriptor = descriptor
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
        fileDescriptor.close()
    }

    public static func playableFrameLength(at url: URL) throws -> Int64 {
        let descriptor = try SecureCaptureFile.open(at: url)
        defer { descriptor.close() }
        return try playableFrameLength(descriptor: descriptor)
    }

    public static func playableFrameLength(descriptor: CaptureFileDescriptor) throws -> Int64 {
        guard Darwin.lseek(descriptor.rawValue, 0, SEEK_SET) >= 0 else {
            throw CaptureJournalError.descriptor("could not rewind the capture descriptor")
        }
        let audioFile = try AVAudioFile(
            forReading: URL(fileURLWithPath: "/dev/fd/\(descriptor.rawValue)")
        )
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
        transcribe: (CaptureFileDescriptor) throws -> T
    ) throws -> T {
        let descriptor = try SecureCaptureFile.open(at: url)
        defer { descriptor.close() }
        return try transcribe(descriptor)
    }

    public static func retryAfterFailure<T>(
        url: URL,
        liveFailure: Error,
        transcribe: (CaptureFileDescriptor) throws -> T
    ) throws -> T {
        _ = liveFailure
        return try retry(url: url, transcribe: transcribe)
    }
}
