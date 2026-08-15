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

        let current = try readSession(at: session.directoryURL)
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

        try writeMetadata(metadata, at: current.metadataURL)
        return DictationSession(metadata: metadata, directoryURL: current.directoryURL)
    }

    @discardableResult
    public func persistRawText(
        _ rawText: String,
        for session: DictationSession,
        at date: Date = Date()
    ) throws -> DictationSession {
        lock.lock()
        defer { lock.unlock() }

        let current = try readSession(at: session.directoryURL)
        try rejectSymlink(at: current.rawTextURL)
        let data = Data(rawText.utf8)
        try data.write(to: current.rawTextURL, options: [.atomic])

        var metadata = current.metadata
        metadata.updatedAt = date
        metadata.rawTextByteCount = Int64(data.count)
        try writeMetadata(metadata, at: current.metadataURL)
        return DictationSession(metadata: metadata, directoryURL: current.directoryURL)
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
        let rootPath = rootDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        let directoryPath = directoryURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard directoryPath.hasPrefix(rootPath + "/") else {
            throw SessionStoreError.invalidSessionDirectory(directoryURL)
        }
        try rejectSymlink(at: directoryURL)
        let metadataURL = directoryURL.appendingPathComponent("session.json")
        try rejectSymlink(at: metadataURL)
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            throw SessionStoreError.invalidSessionDirectory(directoryURL)
        }
        do {
            let data = try Data(contentsOf: metadataURL)
            let metadata = try decoder.decode(SessionMetadata.self, from: data)
            guard metadata.directoryName == directoryURL.lastPathComponent,
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
        let data = try encoder.encode(metadata)
        try data.write(to: url, options: [.atomic])
    }

    private func rejectSymlink(at url: URL) throws {
        var fileInfo = stat()
        guard lstat(url.path, &fileInfo) == 0 else {
            guard errno == ENOENT else {
                throw SessionStoreError.invalidSessionDirectory(url)
            }
            return
        }
        guard (fileInfo.st_mode & S_IFMT) != S_IFLNK else {
            throw SessionStoreError.invalidSessionDirectory(url)
        }
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
