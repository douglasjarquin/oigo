import Foundation
import Darwin

public enum DictationSessionState: String, Codable, CaseIterable, Sendable {
    case preparing
    case recording
    case stopping
    case completed
    case failed
    case cancelled
    case interrupted

    public var isUnfinished: Bool {
        switch self {
        case .preparing, .recording, .stopping:
            true
        case .completed, .failed, .cancelled, .interrupted:
            false
        }
    }
}

public struct SessionMetadata: Codable, Equatable, Sendable {
    public let id: UUID
    public let directoryName: String
    public let createdAt: Date
    public var updatedAt: Date
    public var state: DictationSessionState
    public var startedAt: Date?
    public var endedAt: Date?
    public var duration: TimeInterval?
    public var failureReason: String?
    public var audioByteCount: Int64?
    public var rawTextByteCount: Int64?
    public let audioFileName: String
    public let rawTextFileName: String
    public let cleanTextFileName: String

    public init(
        id: UUID,
        directoryName: String,
        createdAt: Date,
        updatedAt: Date,
        state: DictationSessionState,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        duration: TimeInterval? = nil,
        failureReason: String? = nil,
        audioByteCount: Int64? = nil,
        rawTextByteCount: Int64? = nil,
        audioFileName: String = "audio.caf",
        rawTextFileName: String = "raw.txt",
        cleanTextFileName: String = "clean.txt"
    ) {
        self.id = id
        self.directoryName = directoryName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.state = state
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.duration = duration
        self.failureReason = failureReason
        self.audioByteCount = audioByteCount
        self.rawTextByteCount = rawTextByteCount
        self.audioFileName = audioFileName
        self.rawTextFileName = rawTextFileName
        self.cleanTextFileName = cleanTextFileName
    }
}

public struct DictationSession: Equatable, Identifiable, Sendable {
    public let metadata: SessionMetadata
    public let directoryURL: URL

    public var id: UUID {
        metadata.id
    }

    public var metadataURL: URL {
        directoryURL.appendingPathComponent("session.json")
    }

    public var audioURL: URL {
        directoryURL.appendingPathComponent("audio.caf")
    }

    public var rawTextURL: URL {
        directoryURL.appendingPathComponent("raw.txt")
    }

    public var cleanTextURL: URL {
        directoryURL.appendingPathComponent("clean.txt")
    }

    public init(metadata: SessionMetadata, directoryURL: URL) {
        self.metadata = metadata
        self.directoryURL = directoryURL
    }
}

public enum SessionStoreError: Error, Equatable, CustomStringConvertible, Sendable {
    case missingSession(UUID)
    case invalidMetadata(URL)
    case invalidSessionDirectory(URL)

    public var description: String {
        switch self {
        case .missingSession(let id):
            "dictation session does not exist: " + id.uuidString
        case .invalidMetadata(let url):
            "dictation session metadata is invalid: " + url.path
        case .invalidSessionDirectory(let url):
            "dictation session directory is invalid: " + url.path
        }
    }
}

public final class SessionStore: @unchecked Sendable {
    public let rootDirectory: URL

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()

    public init(rootDirectory: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        self.rootDirectory = rootDirectory ?? Self.defaultRootDirectory(fileManager: fileManager)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        try fileManager.createDirectory(
            at: self.rootDirectory,
            withIntermediateDirectories: true
        )
    }

    public static func defaultRootDirectory(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("Oigo", isDirectory: true)
            .appendingPathComponent("Sessions", isDirectory: true)
    }

    public func createSession(now: Date = Date()) throws -> DictationSession {
        lock.lock()
        defer { lock.unlock() }

        let id = UUID()
        let directoryName = Self.directoryName(for: now, id: id)
        let directoryURL = rootDirectory.appendingPathComponent(directoryName, isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: false)

        let metadata = SessionMetadata(
            id: id,
            directoryName: directoryName,
            createdAt: now,
            updatedAt: now,
            state: .preparing
        )
        let session = DictationSession(metadata: metadata, directoryURL: directoryURL)
        do {
            try writeMetadata(metadata, at: session.metadataURL)
            return session
        } catch {
            try? fileManager.removeItem(at: directoryURL)
            throw error
        }
    }

    public func load(id: UUID) throws -> DictationSession {
        lock.lock()
        defer { lock.unlock() }

        guard let directoryURL = try sessionDirectory(for: id) else {
            throw SessionStoreError.missingSession(id)
        }
        return try readSession(at: directoryURL)
    }

    public func listSessions() throws -> [DictationSession] {
        lock.lock()
        defer { lock.unlock() }

        let urls = try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return try urls
            .filter { url in
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return values.isDirectory == true || values.isSymbolicLink == true
            }
            .map { try readSession(at: $0) }
            .sorted { lhs, rhs in
                lhs.metadata.createdAt > rhs.metadata.createdAt
            }
    }

    @discardableResult
    public func update(
        _ session: DictationSession,
        state: DictationSessionState,
        at date: Date = Date(),
        failureReason: String? = nil,
        audioByteCount: Int64? = nil,
        rawTextByteCount: Int64? = nil
    ) throws -> DictationSession {
        lock.lock()
        defer { lock.unlock() }

        return try withSessionDirectory(at: session.directoryURL) { directoryFD in
            let current = try readSession(at: session.directoryURL, directoryFD: directoryFD)
            var metadata = current.metadata
            metadata.state = state
            metadata.updatedAt = date
            if state == .recording, metadata.startedAt == nil {
                metadata.startedAt = date
            }
            if state == .completed || state == .failed || state == .cancelled || state == .interrupted {
                metadata.endedAt = date
                if let startedAt = metadata.startedAt {
                    metadata.duration = max(0, date.timeIntervalSince(startedAt))
                }
            }
            if state == .failed {
                metadata.failureReason = failureReason ?? metadata.failureReason ?? "capture failed"
            } else if let failureReason {
                metadata.failureReason = failureReason
            }
            if let audioByteCount {
                metadata.audioByteCount = audioByteCount
            }
            if let rawTextByteCount {
                metadata.rawTextByteCount = rawTextByteCount
            }

            try writeMetadata(metadata, at: current.metadataURL, directoryFD: directoryFD)
            return DictationSession(metadata: metadata, directoryURL: current.directoryURL)
        }
    }

    @discardableResult
    public func persistRawText(
        _ rawText: String,
        for session: DictationSession,
        at date: Date = Date()
    ) throws -> DictationSession {
        lock.lock()
        defer { lock.unlock() }

        return try withSessionDirectory(at: session.directoryURL) { directoryFD in
            let current = try readSession(at: session.directoryURL, directoryFD: directoryFD)
            let data = Data(rawText.utf8)
            try rejectSymlink(named: "raw.txt", in: directoryFD, at: current.rawTextURL, allowMissing: true)
            try atomicWrite(data, named: "raw.txt", in: directoryFD, at: current.rawTextURL)

            var metadata = current.metadata
            metadata.updatedAt = date
            metadata.rawTextByteCount = Int64(data.count)
            try writeMetadata(metadata, at: current.metadataURL, directoryFD: directoryFD)
            return DictationSession(metadata: metadata, directoryURL: current.directoryURL)
        }
    }

    public func recoverUnfinishedSessions(at date: Date = Date()) throws -> [DictationSession] {
        lock.lock()
        defer { lock.unlock() }

        let sessions = try listSessionsUnlocked()
        return try sessions.compactMap { session in
            guard session.metadata.state.isUnfinished else {
                return nil
            }
            var metadata = session.metadata
            metadata.state = .interrupted
            metadata.updatedAt = date
            metadata.endedAt = date
            if let startedAt = metadata.startedAt {
                metadata.duration = max(0, date.timeIntervalSince(startedAt))
            }
            metadata.failureReason = "recording was interrupted before shutdown"
            try writeMetadata(metadata, at: session.metadataURL)
            return DictationSession(metadata: metadata, directoryURL: session.directoryURL)
        }
    }

    public func remove(id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }

        guard let directoryURL = try sessionDirectory(for: id) else {
            throw SessionStoreError.missingSession(id)
        }
        try fileManager.removeItem(at: directoryURL)
    }

    private func listSessionsUnlocked() throws -> [DictationSession] {
        let urls = try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return try urls
            .filter { url in
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return values.isDirectory == true || values.isSymbolicLink == true
            }
            .map { try readSession(at: $0) }
            .sorted { lhs, rhs in
                lhs.metadata.createdAt > rhs.metadata.createdAt
            }
    }

    private func sessionDirectory(for id: UUID) throws -> URL? {
        try listSessionsUnlocked().first { $0.id == id }?.directoryURL
    }

    private func readSession(at directoryURL: URL) throws -> DictationSession {
        try withSessionDirectory(at: directoryURL) { directoryFD in
            try readSession(at: directoryURL, directoryFD: directoryFD)
        }
    }

    private func readSession(at directoryURL: URL, directoryFD: Int32) throws -> DictationSession {
        let metadataURL = directoryURL.appendingPathComponent("session.json")
        do {
            let data = try readData(named: "session.json", in: directoryFD, at: metadataURL)
            let metadata = try decoder.decode(SessionMetadata.self, from: data)
            guard metadata.directoryName == directoryURL.standardizedFileURL.lastPathComponent,
                  metadata.audioFileName == "audio.caf",
                  metadata.rawTextFileName == "raw.txt",
                  metadata.cleanTextFileName == "clean.txt" else {
                throw SessionStoreError.invalidMetadata(metadataURL)
            }
            return DictationSession(metadata: metadata, directoryURL: directoryURL)
        } catch let error as SessionStoreError {
            throw error
        } catch {
            throw SessionStoreError.invalidMetadata(metadataURL)
        }
    }

    private func writeMetadata(_ metadata: SessionMetadata, at url: URL) throws {
        try withSessionDirectory(at: url.deletingLastPathComponent()) { directoryFD in
            try writeMetadata(metadata, at: url, directoryFD: directoryFD)
        }
    }

    private func writeMetadata(_ metadata: SessionMetadata, at url: URL, directoryFD: Int32) throws {
        let data = try encoder.encode(metadata)
        try rejectSymlink(named: url.lastPathComponent, in: directoryFD, at: url, allowMissing: true)
        try atomicWrite(data, named: url.lastPathComponent, in: directoryFD, at: url)
    }

    private func withSessionDirectory<T>(
        at directoryURL: URL,
        _ body: (Int32) throws -> T
    ) throws -> T {
        let directoryFD = try openSessionDirectory(at: directoryURL)
        defer { _ = Darwin.close(directoryFD) }
        return try body(directoryFD)
    }

    private func openSessionDirectory(at directoryURL: URL) throws -> Int32 {
        let rootURL = rootDirectory.standardizedFileURL
        let directoryURL = directoryURL.standardizedFileURL
        guard directoryURL.deletingLastPathComponent().path == rootURL.path,
              !directoryURL.lastPathComponent.isEmpty,
              directoryURL.lastPathComponent != ".",
              directoryURL.lastPathComponent != "..",
              !directoryURL.lastPathComponent.contains("/") else {
            throw SessionStoreError.invalidSessionDirectory(directoryURL)
        }
        let directoryName = directoryURL.lastPathComponent

        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        let rootFD = rootURL.path.withCString { path in
            Darwin.open(path, flags)
        }
        guard rootFD >= 0 else {
            throw SessionStoreError.invalidSessionDirectory(directoryURL)
        }
        defer { _ = Darwin.close(rootFD) }

        let directoryFD = directoryName.withCString { name in
            Darwin.openat(rootFD, name, flags)
        }
        guard directoryFD >= 0 else {
            throw SessionStoreError.invalidSessionDirectory(directoryURL)
        }
        return directoryFD
    }

    private func readData(named name: String, in directoryFD: Int32, at url: URL) throws -> Data {
        let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        let fileFD = name.withCString { entryName in
            Darwin.openat(directoryFD, entryName, flags)
        }
        guard fileFD >= 0 else {
            throw SessionStoreError.invalidSessionDirectory(url)
        }
        defer { _ = Darwin.close(fileFD) }

        var fileInfo = stat()
        guard Darwin.fstat(fileFD, &fileInfo) == 0,
              (fileInfo.st_mode & S_IFMT) == S_IFREG else {
            throw SessionStoreError.invalidSessionDirectory(url)
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fileFD, bytes.baseAddress, bytes.count)
            }
            if count == 0 {
                break
            }
            guard count > 0 else {
                if errno == EINTR {
                    continue
                }
                throw SessionStoreError.invalidSessionDirectory(url)
            }
            data.append(buffer, count: count)
        }

        return data
    }

    private func rejectSymlink(
        named name: String,
        in directoryFD: Int32,
        at url: URL,
        allowMissing: Bool
    ) throws {
        var fileInfo = stat()
        let result = name.withCString { entryName in
            Darwin.fstatat(directoryFD, entryName, &fileInfo, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else {
            guard allowMissing, errno == ENOENT else {
                throw SessionStoreError.invalidSessionDirectory(url)
            }
            return
        }
        guard (fileInfo.st_mode & S_IFMT) != S_IFLNK else {
            throw SessionStoreError.invalidSessionDirectory(url)
        }
    }

    private func atomicWrite(
        _ data: Data,
        named name: String,
        in directoryFD: Int32,
        at url: URL
    ) throws {
        let temporaryName = "." + name + "." + UUID().uuidString + ".tmp"
        let flags = O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW
        let temporaryFD = temporaryName.withCString { temporaryName in
            Darwin.openat(directoryFD, temporaryName, flags, mode_t(0o600))
        }
        guard temporaryFD >= 0 else {
            throw SessionStoreError.invalidSessionDirectory(url)
        }
        var committed = false
        defer {
            _ = Darwin.close(temporaryFD)
            if !committed {
                _ = temporaryName.withCString { name in
                    Darwin.unlinkat(directoryFD, name, 0)
                }
            }
        }

        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    temporaryFD,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw SessionStoreError.invalidSessionDirectory(url)
                }
                guard count > 0 else {
                    throw SessionStoreError.invalidSessionDirectory(url)
                }
                offset += count
            }
        }
        guard Darwin.fsync(temporaryFD) == 0 else {
            throw SessionStoreError.invalidSessionDirectory(url)
        }
        let renamed = temporaryName.withCString { sourceName in
            name.withCString { destinationName in
                Darwin.renameat(directoryFD, sourceName, directoryFD, destinationName)
            }
        }
        guard renamed == 0 else {
            throw SessionStoreError.invalidSessionDirectory(url)
        }
        committed = true
        _ = Darwin.fsync(directoryFD)
    }

    private static func directoryName(for date: Date, id: UUID) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date) + "-" + id.uuidString.lowercased()
    }
}
