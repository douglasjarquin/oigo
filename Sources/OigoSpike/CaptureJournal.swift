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

    static func openOrCreate(at url: URL) throws -> CaptureFileDescriptor {
        let directoryFD = try openParentDirectory(for: url)
        defer { _ = Darwin.close(directoryFD) }
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else {
            throw CaptureJournalError.invalid(url, "the capture filename is empty")
        }
        let descriptor = name.withCString { namePointer in
            Darwin.openat(
                directoryFD,
                namePointer,
                O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw CaptureJournalError.invalid(url, "the capture file could not be opened without following a link")
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
    private var descriptor: CaptureFileDescriptor?
    private(set) public var bytesWritten = 0

    public convenience init(url: URL) throws {
        try self.init(url: url, beforeOpeningDescriptor: nil)
    }

    @_spi(Testing)
    public init(
        url: URL,
        beforeOpeningDescriptor: ((CaptureFileDescriptor) throws -> Void)?
    ) throws {
        self.url = url
        let openedDescriptor = try SecureCaptureFile.openOrCreate(at: url)
        do {
            try beforeOpeningDescriptor?(openedDescriptor)
            guard Darwin.lseek(openedDescriptor.rawValue, 0, SEEK_END) >= 0 else {
                throw CaptureJournalError.descriptor("could not seek to the end of the capture journal")
            }
        } catch {
            openedDescriptor.close()
            throw error
        }
        descriptor = openedDescriptor
    }

    public func append(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let descriptor else {
            throw CaptureJournalError.closed
        }
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor.rawValue,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                guard written > 0 else {
                    throw CaptureJournalError.descriptor("could not append capture data")
                }
                offset += written
            }
        }
        guard Darwin.fsync(descriptor.rawValue) == 0 else {
            throw CaptureJournalError.descriptor("could not flush capture data")
        }
        bytesWritten += data.count
    }

    public func finish() throws {
        lock.lock()
        defer { lock.unlock() }
        guard let descriptor else {
            return
        }
        defer {
            descriptor.close()
            self.descriptor = nil
        }
        guard Darwin.fsync(descriptor.rawValue) == 0 else {
            throw CaptureJournalError.descriptor("could not flush the capture journal")
        }
    }

    public static func recover(_ url: URL) throws -> Data {
        let descriptor = try SecureCaptureFile.open(at: url)
        defer { descriptor.close() }
        guard Darwin.lseek(descriptor.rawValue, 0, SEEK_SET) >= 0 else {
            throw CaptureJournalError.descriptor("could not rewind the capture journal")
        }
        var contents = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor.rawValue, bytes.baseAddress, bytes.count)
            }
            guard count >= 0 else {
                throw CaptureJournalError.descriptor("could not read the capture journal")
            }
            if count == 0 {
                return contents
            }
            contents.append(contentsOf: buffer.prefix(count))
        }
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
