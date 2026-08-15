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

public enum InsertionOutcome: String, Codable, CaseIterable, Equatable, Sendable {
    case pasted
    case copied
    case secureRejected
    case failed
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
    public var insertionOutcome: InsertionOutcome?
    public var insertionFailureReason: String?
    public var insertionAttemptedAt: Date?
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
        insertionOutcome: InsertionOutcome? = nil,
        insertionFailureReason: String? = nil,
        insertionAttemptedAt: Date? = nil,
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
        self.insertionOutcome = insertionOutcome
        self.insertionFailureReason = insertionFailureReason
        self.insertionAttemptedAt = insertionAttemptedAt
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

public struct RawTextStaging: Equatable, Sendable {
    fileprivate let sessionID: UUID
    fileprivate let fileName: String

    fileprivate init(sessionID: UUID, fileName: String) {
        self.sessionID = sessionID
        self.fileName = fileName
    }
}

public enum SessionStoreError: Error, Equatable, CustomStringConvertible, Sendable {
    case missingSession(UUID)
    case invalidMetadata(URL)
    case invalidSessionDirectory(URL)
    case insertionAlreadyAttempted(UUID)

    public var description: String {
        switch self {
        case .missingSession(let id):
            "dictation session does not exist: " + id.uuidString
        case .invalidMetadata(let url):
            "dictation session metadata is invalid: " + url.path
        case .invalidSessionDirectory(let url):
            "dictation session directory is invalid: " + url.path
        case .insertionAlreadyAttempted(let id):
            "dictation session insertion was already attempted: " + id.uuidString
        }
    }
}

public final class SessionStore: @unchecked Sendable {
    public let rootDirectory: URL

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()
    private var failNextMetadataWrite = false

    private struct PendingRawPersistence: Codable {
        let metadata: SessionMetadata
        let sourceName: String?
        let previousRawTextByteCount: Int64
        let targetRawTextByteCount: Int64
    }

    private static let pendingRawPersistenceName = ".raw-persistence.json"

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

    @_spi(Testing)
    public func failNextMetadataWriteForTesting() {
        lock.lock()
        failNextMetadataWrite = true
        lock.unlock()
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
        rawTextByteCount: Int64? = nil,
        insertionOutcome: InsertionOutcome? = nil,
        insertionFailureReason: String? = nil
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
            if let insertionOutcome {
                metadata.insertionOutcome = insertionOutcome
                metadata.insertionFailureReason = insertionFailureReason
            }

            try writeMetadata(metadata, at: current.metadataURL, directoryFD: directoryFD)
            return DictationSession(metadata: metadata, directoryURL: current.directoryURL)
        }
    }

    @discardableResult
    public func claimInsertion(
        for session: DictationSession,
        at date: Date = Date()
    ) throws -> DictationSession {
        lock.lock()
        defer { lock.unlock() }

        return try withSessionDirectory(at: session.directoryURL) { directoryFD in
            let current = try readSession(at: session.directoryURL, directoryFD: directoryFD)
            guard current.metadata.insertionAttemptedAt == nil,
                  current.metadata.insertionOutcome == nil else {
                throw SessionStoreError.insertionAlreadyAttempted(current.id)
            }
            var metadata = current.metadata
            metadata.updatedAt = date
            metadata.insertionAttemptedAt = date
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
            let previousRawTextByteCount = try rawTextByteCount(
                named: "raw.txt",
                in: directoryFD,
                at: current.rawTextURL
            )
            var metadata = current.metadata
            metadata.updatedAt = date
            metadata.rawTextByteCount = Int64(data.count)

            let temporaryName = try prepareAtomicWrite(
                data,
                named: "raw.txt",
                in: directoryFD,
                at: current.rawTextURL
            )
            var pendingWritten = false
            defer {
                if !pendingWritten {
                    try? removeEntry(named: temporaryName, in: directoryFD, at: current.rawTextURL)
                }
            }
            try writePendingPersistence(
                PendingRawPersistence(
                    metadata: metadata,
                    sourceName: temporaryName,
                    previousRawTextByteCount: previousRawTextByteCount,
                    targetRawTextByteCount: Int64(data.count)
                ),
                in: directoryFD,
                at: current.directoryURL.appendingPathComponent(Self.pendingRawPersistenceName)
            )
            pendingWritten = true
            try commitTemporary(
                named: temporaryName,
                as: "raw.txt",
                in: directoryFD,
                at: current.rawTextURL
            )
            try writeMetadata(metadata, at: current.metadataURL, directoryFD: directoryFD)
            try removePendingPersistence(in: directoryFD, at: current.directoryURL)
            return DictationSession(metadata: metadata, directoryURL: current.directoryURL)
        }
    }

    @discardableResult
    public func appendRawText(
        _ rawText: String,
        for session: DictationSession,
        at date: Date = Date()
    ) throws -> DictationSession {
        lock.lock()
        defer { lock.unlock() }

        return try withSessionDirectory(at: session.directoryURL) { directoryFD in
            let current = try readSession(at: session.directoryURL, directoryFD: directoryFD)
            guard !rawText.isEmpty else {
                return current
            }
            let existingData = try readDataIfPresent(
                named: "raw.txt",
                in: directoryFD,
                at: current.rawTextURL
            ) ?? Data()
            let rawData = Data(rawText.utf8)
            try rejectSymlink(named: "raw.txt", in: directoryFD, at: current.rawTextURL, allowMissing: true)
            let separator = existingData.isEmpty ? Data() : Data([0x20])
            let previousRawTextByteCount = Int64(existingData.count)
            let targetRawTextByteCount = previousRawTextByteCount
                + Int64(separator.count)
                + Int64(rawData.count)
            var metadata = current.metadata
            metadata.updatedAt = date
            metadata.rawTextByteCount = targetRawTextByteCount
            try writePendingPersistence(
                PendingRawPersistence(
                    metadata: metadata,
                    sourceName: nil,
                    previousRawTextByteCount: previousRawTextByteCount,
                    targetRawTextByteCount: targetRawTextByteCount
                ),
                in: directoryFD,
                at: current.directoryURL.appendingPathComponent(Self.pendingRawPersistenceName)
            )
            let flags = O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW
            let rawFD = "raw.txt".withCString { name in
                Darwin.openat(directoryFD, name, flags, mode_t(0o600))
            }
            guard rawFD >= 0 else {
                try? removePendingPersistence(in: directoryFD, at: current.directoryURL)
                throw SessionStoreError.invalidSessionDirectory(current.rawTextURL)
            }
            defer { _ = Darwin.close(rawFD) }

            var before = stat()
            guard Darwin.fstat(rawFD, &before) == 0,
                  (before.st_mode & S_IFMT) == S_IFREG else {
                try? removePendingPersistence(in: directoryFD, at: current.directoryURL)
                throw SessionStoreError.invalidSessionDirectory(current.rawTextURL)
            }
            if before.st_size > 0 {
                try writeData(separator, to: rawFD, at: current.rawTextURL)
            }
            try writeData(rawData, to: rawFD, at: current.rawTextURL)
            guard Darwin.fsync(rawFD) == 0 else {
                throw SessionStoreError.invalidSessionDirectory(current.rawTextURL)
            }
            var after = stat()
            guard Darwin.fstat(rawFD, &after) == 0 else {
                throw SessionStoreError.invalidSessionDirectory(current.rawTextURL)
            }
            guard Int64(after.st_size) == targetRawTextByteCount else {
                throw SessionStoreError.invalidSessionDirectory(current.rawTextURL)
            }
            try writeMetadata(metadata, at: current.metadataURL, directoryFD: directoryFD)
            try removePendingPersistence(in: directoryFD, at: current.directoryURL)
            return DictationSession(metadata: metadata, directoryURL: current.directoryURL)
        }
    }

    @discardableResult
    public func replaceRawTextTail(
        _ existingText: String,
        with replacementText: String,
        for session: DictationSession,
        at date: Date = Date()
    ) throws -> DictationSession {
        let rawText = try readRawText(for: session)
        let replaced = try replaceSuffix(
            in: rawText,
            existing: existingText,
            replacement: replacementText,
            at: session.rawTextURL
        )
        return try persistRawText(replaced, for: session, at: date)
    }

    public func replaceRawTextStagingTail(
        _ existingText: String,
        with replacementText: String,
        to staging: RawTextStaging,
        for session: DictationSession
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        try withSessionDirectory(at: session.directoryURL) { directoryFD in
            let current = try readSession(at: session.directoryURL, directoryFD: directoryFD)
            try validate(staging, for: current)
            let stagingURL = current.directoryURL.appendingPathComponent(staging.fileName)
            guard let data = try readDataIfPresent(
                named: staging.fileName,
                in: directoryFD,
                at: stagingURL
            ) else {
                throw SessionStoreError.invalidSessionDirectory(stagingURL)
            }
            guard let rawText = String(data: data, encoding: .utf8) else {
                throw SessionStoreError.invalidMetadata(stagingURL)
            }
            let replaced = try replaceSuffix(
                in: rawText,
                existing: existingText,
                replacement: replacementText,
                at: stagingURL
            )
            let flags = O_WRONLY | O_TRUNC | O_CLOEXEC | O_NOFOLLOW
            let stagingFD = staging.fileName.withCString { name in
                Darwin.openat(directoryFD, name, flags)
            }
            guard stagingFD >= 0 else {
                throw SessionStoreError.invalidSessionDirectory(stagingURL)
            }
            defer { _ = Darwin.close(stagingFD) }
            var fileInfo = stat()
            guard Darwin.fstat(stagingFD, &fileInfo) == 0,
                  (fileInfo.st_mode & S_IFMT) == S_IFREG else {
                throw SessionStoreError.invalidSessionDirectory(stagingURL)
            }
            try writeData(Data(replaced.utf8), to: stagingFD, at: stagingURL)
            guard Darwin.fsync(stagingFD) == 0 else {
                throw SessionStoreError.invalidSessionDirectory(stagingURL)
            }
        }
    }

    public func beginRawTextStaging(for session: DictationSession) throws -> RawTextStaging {
        lock.lock()
        defer { lock.unlock() }

        return try withSessionDirectory(at: session.directoryURL) { directoryFD in
            let current = try readSession(at: session.directoryURL, directoryFD: directoryFD)
            let staging = RawTextStaging(
                sessionID: current.id,
                fileName: ".raw.txt." + UUID().uuidString + ".retry"
            )
            let flags = O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW
            let stagingFD = staging.fileName.withCString { name in
                Darwin.openat(directoryFD, name, flags, mode_t(0o600))
            }
            guard stagingFD >= 0 else {
                throw SessionStoreError.invalidSessionDirectory(current.rawTextURL)
            }
            defer { _ = Darwin.close(stagingFD) }
            var fileInfo = stat()
            guard Darwin.fstat(stagingFD, &fileInfo) == 0,
                  (fileInfo.st_mode & S_IFMT) == S_IFREG else {
                throw SessionStoreError.invalidSessionDirectory(current.rawTextURL)
            }
            return staging
        }
    }

    public func appendRawText(
        _ rawText: String,
        to staging: RawTextStaging,
        for session: DictationSession
    ) throws {
        guard !rawText.isEmpty else {
            return
        }
        lock.lock()
        defer { lock.unlock() }

        try withSessionDirectory(at: session.directoryURL) { directoryFD in
            let current = try readSession(at: session.directoryURL, directoryFD: directoryFD)
            try validate(staging, for: current)
            let stagingURL = current.directoryURL.appendingPathComponent(staging.fileName)
            try rejectSymlink(named: staging.fileName, in: directoryFD, at: stagingURL, allowMissing: false)
            let flags = O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW
            let stagingFD = staging.fileName.withCString { name in
                Darwin.openat(directoryFD, name, flags)
            }
            guard stagingFD >= 0 else {
                throw SessionStoreError.invalidSessionDirectory(stagingURL)
            }
            defer { _ = Darwin.close(stagingFD) }
            var before = stat()
            guard Darwin.fstat(stagingFD, &before) == 0,
                  (before.st_mode & S_IFMT) == S_IFREG else {
                throw SessionStoreError.invalidSessionDirectory(stagingURL)
            }
            if before.st_size > 0 {
                try writeData(Data([0x20]), to: stagingFD, at: stagingURL)
            }
            try writeData(Data(rawText.utf8), to: stagingFD, at: stagingURL)
            guard Darwin.fsync(stagingFD) == 0 else {
                throw SessionStoreError.invalidSessionDirectory(stagingURL)
            }
        }
    }

    @discardableResult
    public func commitRawTextStaging(
        _ staging: RawTextStaging,
        for session: DictationSession,
        at date: Date = Date()
    ) throws -> DictationSession {
        lock.lock()
        defer { lock.unlock() }

        return try withSessionDirectory(at: session.directoryURL) { directoryFD in
            let current = try readSession(at: session.directoryURL, directoryFD: directoryFD)
            try validate(staging, for: current)
            let stagingURL = current.directoryURL.appendingPathComponent(staging.fileName)
            let stagingFD = staging.fileName.withCString { name in
                Darwin.openat(directoryFD, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard stagingFD >= 0 else {
                throw SessionStoreError.invalidSessionDirectory(stagingURL)
            }
            defer { _ = Darwin.close(stagingFD) }
            var fileInfo = stat()
            guard Darwin.fstat(stagingFD, &fileInfo) == 0,
                  (fileInfo.st_mode & S_IFMT) == S_IFREG else {
                throw SessionStoreError.invalidSessionDirectory(stagingURL)
            }
            try rejectSymlink(named: "raw.txt", in: directoryFD, at: current.rawTextURL, allowMissing: true)

            var metadata = current.metadata
            metadata.updatedAt = date
            metadata.rawTextByteCount = Int64(fileInfo.st_size)
            try writePendingPersistence(
                PendingRawPersistence(
                    metadata: metadata,
                    sourceName: staging.fileName,
                    previousRawTextByteCount: try rawTextByteCount(
                        named: "raw.txt",
                        in: directoryFD,
                        at: current.rawTextURL
                    ),
                    targetRawTextByteCount: Int64(fileInfo.st_size)
                ),
                in: directoryFD,
                at: current.directoryURL.appendingPathComponent(Self.pendingRawPersistenceName)
            )
            try commitTemporary(
                named: staging.fileName,
                as: "raw.txt",
                in: directoryFD,
                at: current.rawTextURL
            )
            try writeMetadata(metadata, at: current.metadataURL, directoryFD: directoryFD)
            try removePendingPersistence(in: directoryFD, at: current.directoryURL)
            return DictationSession(metadata: metadata, directoryURL: current.directoryURL)
        }
    }

    public func discardRawTextStaging(
        _ staging: RawTextStaging,
        for session: DictationSession
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        try withSessionDirectory(at: session.directoryURL) { directoryFD in
            let current = try readSession(at: session.directoryURL, directoryFD: directoryFD)
            try validate(staging, for: current)
            try removeEntry(
                named: staging.fileName,
                in: directoryFD,
                at: current.directoryURL.appendingPathComponent(staging.fileName),
                allowMissing: true
            )
        }
    }

    public func readRawText(for session: DictationSession) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        return try withSessionDirectory(at: session.directoryURL) { directoryFD in
            let current = try readSession(at: session.directoryURL, directoryFD: directoryFD)
            guard let data = try readDataIfPresent(
                named: "raw.txt",
                in: directoryFD,
                at: current.rawTextURL
            ) else {
                return ""
            }
            guard let rawText = String(data: data, encoding: .utf8) else {
                throw SessionStoreError.invalidMetadata(current.rawTextURL)
            }
            return rawText
        }
    }

    public func createAudioFileDescriptor(for session: DictationSession) throws -> AudioFileDescriptor {
        lock.lock()
        defer { lock.unlock() }

        return try withSessionDirectory(at: session.directoryURL) { directoryFD in
            let current = try readSession(at: session.directoryURL, directoryFD: directoryFD)
            try rejectSymlink(named: "audio.caf", in: directoryFD, at: current.audioURL, allowMissing: true)
            let flags = O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW
            let audioFD = "audio.caf".withCString { name in
                Darwin.openat(directoryFD, name, flags, mode_t(0o600))
            }
            guard audioFD >= 0 else {
                throw SessionStoreError.invalidSessionDirectory(current.audioURL)
            }
            var fileInfo = stat()
            guard Darwin.fstat(audioFD, &fileInfo) == 0,
                  (fileInfo.st_mode & S_IFMT) == S_IFREG else {
                _ = Darwin.close(audioFD)
                throw SessionStoreError.invalidSessionDirectory(current.audioURL)
            }
            return AudioFileDescriptor(rawValue: audioFD)
        }
    }

    public func duplicateAudioFileDescriptor(
        _ descriptor: AudioFileDescriptor,
        for session: DictationSession
    ) throws -> AudioFileDescriptor {
        var fileInfo = stat()
        guard Darwin.fstat(descriptor.rawValue, &fileInfo) == 0,
              (fileInfo.st_mode & S_IFMT) == S_IFREG else {
            throw SessionStoreError.invalidSessionDirectory(session.audioURL)
        }
        let duplicateFD = Darwin.dup(descriptor.rawValue)
        guard duplicateFD >= 0 else {
            throw SessionStoreError.invalidSessionDirectory(session.audioURL)
        }
        guard Darwin.fcntl(duplicateFD, F_SETFD, FD_CLOEXEC) == 0 else {
            _ = Darwin.close(duplicateFD)
            throw SessionStoreError.invalidSessionDirectory(session.audioURL)
        }
        return AudioFileDescriptor(rawValue: duplicateFD)
    }

    public func openAudioFileDescriptor(for session: DictationSession) throws -> AudioFileDescriptor {
        lock.lock()
        defer { lock.unlock() }

        return try withSessionDirectory(at: session.directoryURL) { directoryFD in
            let current = try readSession(at: session.directoryURL, directoryFD: directoryFD)
            let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            let audioFD = "audio.caf".withCString { name in
                Darwin.openat(directoryFD, name, flags)
            }
            guard audioFD >= 0 else {
                throw SessionStoreError.invalidSessionDirectory(current.audioURL)
            }
            var fileInfo = stat()
            guard Darwin.fstat(audioFD, &fileInfo) == 0,
                  (fileInfo.st_mode & S_IFMT) == S_IFREG else {
                _ = Darwin.close(audioFD)
                throw SessionStoreError.invalidSessionDirectory(current.audioURL)
            }
            return AudioFileDescriptor(rawValue: audioFD)
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
        try recoverPendingPersistence(at: directoryURL, directoryFD: directoryFD)
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
        if consumeMetadataWriteFailure() {
            throw SessionStoreError.invalidMetadata(url)
        }
        let data = try encoder.encode(metadata)
        try rejectSymlink(named: url.lastPathComponent, in: directoryFD, at: url, allowMissing: true)
        try atomicWrite(data, named: url.lastPathComponent, in: directoryFD, at: url)
    }

    private func consumeMetadataWriteFailure() -> Bool {
        guard failNextMetadataWrite else {
            return false
        }
        failNextMetadataWrite = false
        return true
    }

    private func validate(_ staging: RawTextStaging, for session: DictationSession) throws {
        guard staging.sessionID == session.id,
              staging.fileName.hasPrefix(".raw.txt."),
              staging.fileName.hasSuffix(".retry"),
              !staging.fileName.contains("/") else {
            throw SessionStoreError.invalidSessionDirectory(session.rawTextURL)
        }
    }

    private func rawTextByteCount(
        named name: String,
        in directoryFD: Int32,
        at url: URL
    ) throws -> Int64 {
        Int64((try readDataIfPresent(named: name, in: directoryFD, at: url) ?? Data()).count)
    }

    private func writePendingPersistence(
        _ pending: PendingRawPersistence,
        in directoryFD: Int32,
        at url: URL
    ) throws {
        let data = try encoder.encode(pending)
        try rejectSymlink(
            named: Self.pendingRawPersistenceName,
            in: directoryFD,
            at: url,
            allowMissing: true
        )
        try atomicWrite(data, named: Self.pendingRawPersistenceName, in: directoryFD, at: url)
    }

    private func removePendingPersistence(in directoryFD: Int32, at directoryURL: URL) throws {
        try removeEntry(
            named: Self.pendingRawPersistenceName,
            in: directoryFD,
            at: directoryURL.appendingPathComponent(Self.pendingRawPersistenceName),
            allowMissing: true
        )
        _ = Darwin.fsync(directoryFD)
    }

    private func recoverPendingPersistence(at directoryURL: URL, directoryFD: Int32) throws {
        let pendingURL = directoryURL.appendingPathComponent(Self.pendingRawPersistenceName)
        guard let data = try readDataIfPresent(
            named: Self.pendingRawPersistenceName,
            in: directoryFD,
            at: pendingURL
        ) else {
            return
        }
        let pending: PendingRawPersistence
        do {
            pending = try decoder.decode(PendingRawPersistence.self, from: data)
        } catch {
            throw SessionStoreError.invalidMetadata(pendingURL)
        }
        guard pending.metadata.directoryName == directoryURL.standardizedFileURL.lastPathComponent,
              pending.metadata.audioFileName == "audio.caf",
              pending.metadata.rawTextFileName == "raw.txt",
              pending.metadata.cleanTextFileName == "clean.txt" else {
            throw SessionStoreError.invalidMetadata(pendingURL)
        }

        if let sourceName = pending.sourceName {
            guard sourceName.hasPrefix(".raw.txt."),
                  sourceName.hasSuffix(".tmp") || sourceName.hasSuffix(".retry"),
                  !sourceName.contains("/") else {
                throw SessionStoreError.invalidMetadata(pendingURL)
            }
            if entryExists(named: sourceName, in: directoryFD) {
                try removeEntry(
                    named: sourceName,
                    in: directoryFD,
                    at: directoryURL.appendingPathComponent(sourceName)
                )
            } else {
                try writeMetadata(
                    pending.metadata,
                    at: directoryURL.appendingPathComponent("session.json"),
                    directoryFD: directoryFD
                )
            }
        } else {
            let currentByteCount = try rawTextByteCount(
                named: "raw.txt",
                in: directoryFD,
                at: directoryURL.appendingPathComponent("raw.txt")
            )
            guard currentByteCount == pending.previousRawTextByteCount
                    || currentByteCount == pending.targetRawTextByteCount else {
                throw SessionStoreError.invalidMetadata(pendingURL)
            }
            if currentByteCount == pending.targetRawTextByteCount {
                try writeMetadata(
                    pending.metadata,
                    at: directoryURL.appendingPathComponent("session.json"),
                    directoryFD: directoryFD
                )
            }
        }
        try removePendingPersistence(in: directoryFD, at: directoryURL)
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

        return try readData(from: fileFD, at: url)
    }

    private func readDataIfPresent(
        named name: String,
        in directoryFD: Int32,
        at url: URL
    ) throws -> Data? {
        let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        let fileFD = name.withCString { entryName in
            Darwin.openat(directoryFD, entryName, flags)
        }
        guard fileFD >= 0 else {
            guard errno == ENOENT else {
                throw SessionStoreError.invalidSessionDirectory(url)
            }
            return nil
        }
        defer { _ = Darwin.close(fileFD) }

        return try readData(from: fileFD, at: url)
    }

    private func readData(from fileFD: Int32, at url: URL) throws -> Data {

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

    private func entryExists(named name: String, in directoryFD: Int32) -> Bool {
        var fileInfo = stat()
        return name.withCString { entryName in
            Darwin.fstatat(directoryFD, entryName, &fileInfo, AT_SYMLINK_NOFOLLOW) == 0
        }
    }

    private func removeEntry(
        named name: String,
        in directoryFD: Int32,
        at url: URL,
        allowMissing: Bool = false
    ) throws {
        let result = name.withCString { entryName in
            Darwin.unlinkat(directoryFD, entryName, 0)
        }
        guard result == 0 else {
            guard allowMissing, errno == ENOENT else {
                throw SessionStoreError.invalidSessionDirectory(url)
            }
            return
        }
    }

    private func prepareAtomicWrite(
        _ data: Data,
        named name: String,
        in directoryFD: Int32,
        at url: URL
    ) throws -> String {
        let temporaryName = "." + name + "." + UUID().uuidString + ".tmp"
        let flags = O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW
        let temporaryFD = temporaryName.withCString { temporaryName in
            Darwin.openat(directoryFD, temporaryName, flags, mode_t(0o600))
        }
        guard temporaryFD >= 0 else {
            throw SessionStoreError.invalidSessionDirectory(url)
        }
        var prepared = false
        defer {
            _ = Darwin.close(temporaryFD)
            if !prepared {
                try? removeEntry(named: temporaryName, in: directoryFD, at: url)
            }
        }
        try writeData(data, to: temporaryFD, at: url)
        guard Darwin.fsync(temporaryFD) == 0 else {
            throw SessionStoreError.invalidSessionDirectory(url)
        }
        prepared = true
        return temporaryName
    }

    private func commitTemporary(
        named sourceName: String,
        as destinationName: String,
        in directoryFD: Int32,
        at url: URL
    ) throws {
        let renamed = sourceName.withCString { sourceName in
            destinationName.withCString { destinationName in
                Darwin.renameat(directoryFD, sourceName, directoryFD, destinationName)
            }
        }
        guard renamed == 0 else {
            throw SessionStoreError.invalidSessionDirectory(url)
        }
        _ = Darwin.fsync(directoryFD)
    }

    private func atomicWrite(
        _ data: Data,
        named name: String,
        in directoryFD: Int32,
        at url: URL
    ) throws {
        let temporaryName = try prepareAtomicWrite(data, named: name, in: directoryFD, at: url)
        do {
            try commitTemporary(named: temporaryName, as: name, in: directoryFD, at: url)
        } catch {
            try? removeEntry(named: temporaryName, in: directoryFD, at: url)
            throw error
        }
    }

    private func replaceSuffix(
        in rawText: String,
        existing: String,
        replacement: String,
        at url: URL
    ) throws -> String {
        let existing = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !existing.isEmpty, rawText.hasSuffix(existing) else {
            throw SessionStoreError.invalidMetadata(url)
        }
        let prefix = String(rawText.dropLast(existing.count))
        guard !replacement.isEmpty else {
            return prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !prefix.isEmpty else {
            return replacement
        }
        return prefix.hasSuffix(" ") ? prefix + replacement : prefix + " " + replacement
    }

    private func writeData(_ data: Data, to fileFD: Int32, at url: URL) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    fileFD,
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
