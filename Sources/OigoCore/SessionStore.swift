import Foundation
import Darwin

public enum DictationSessionState: String, Codable, CaseIterable, Sendable {
    case preparing
    case recording
    case stopping
    case retrying
    case completed
    case failed
    case cancelled
    case interrupted

    public var isUnfinished: Bool {
        switch self {
        case .preparing, .recording, .stopping, .retrying:
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

public enum SessionTextSource: String, Codable, CaseIterable, Equatable, Sendable {
    case raw
    case processed
}

public enum TranscriptInsertionSource: String, Codable, CaseIterable, Equatable, Sendable {
    case raw
    case clean
}

public struct SessionRetentionPolicy: Equatable, Sendable {
    public static let `default` = SessionRetentionPolicy()

    public let maxTranscriptSessions: Int
    public let successfulAudioLifetime: TimeInterval
    public let maxDirectoriesToInspect: Int

    public init(
        maxTranscriptSessions: Int = 100,
        successfulAudioLifetime: TimeInterval = 24 * 60 * 60,
        maxDirectoriesToInspect: Int = 4_096
    ) {
        self.maxTranscriptSessions = max(0, maxTranscriptSessions)
        self.successfulAudioLifetime = max(0, successfulAudioLifetime)
        self.maxDirectoriesToInspect = max(1, maxDirectoriesToInspect)
    }
}

public struct SessionMetadata: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id
        case directoryName
        case createdAt
        case updatedAt
        case state
        case startedAt
        case endedAt
        case duration
        case failureReason
        case audioByteCount
        case rawTextByteCount
        case insertionOutcome
        case insertionFailureReason
        case insertionTextSource
        case cleanupFallbackReason
        case insertionAttemptedAt
        case firstTranscriptLine
        case transcriptionAttemptCount
        case audioFileName
        case rawTextFileName
        case cleanTextFileName
    }

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
    public var insertionTextSource: TranscriptInsertionSource?
    public var cleanupFallbackReason: String?
    public var insertionAttemptedAt: Date?
    public var firstTranscriptLine: String?
    public var transcriptionAttemptCount: Int
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
        insertionTextSource: TranscriptInsertionSource? = nil,
        cleanupFallbackReason: String? = nil,
        insertionAttemptedAt: Date? = nil,
        firstTranscriptLine: String? = nil,
        transcriptionAttemptCount: Int = 0,
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
        self.insertionTextSource = insertionTextSource
        self.cleanupFallbackReason = cleanupFallbackReason
        self.insertionAttemptedAt = insertionAttemptedAt
        self.firstTranscriptLine = firstTranscriptLine
        self.transcriptionAttemptCount = max(0, transcriptionAttemptCount)
        self.audioFileName = audioFileName
        self.rawTextFileName = rawTextFileName
        self.cleanTextFileName = cleanTextFileName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            directoryName: container.decode(String.self, forKey: .directoryName),
            createdAt: container.decode(Date.self, forKey: .createdAt),
            updatedAt: container.decode(Date.self, forKey: .updatedAt),
            state: container.decode(DictationSessionState.self, forKey: .state),
            startedAt: container.decodeIfPresent(Date.self, forKey: .startedAt),
            endedAt: container.decodeIfPresent(Date.self, forKey: .endedAt),
            duration: container.decodeIfPresent(TimeInterval.self, forKey: .duration),
            failureReason: container.decodeIfPresent(String.self, forKey: .failureReason),
            audioByteCount: container.decodeIfPresent(Int64.self, forKey: .audioByteCount),
            rawTextByteCount: container.decodeIfPresent(Int64.self, forKey: .rawTextByteCount),
            insertionOutcome: container.decodeIfPresent(InsertionOutcome.self, forKey: .insertionOutcome),
            insertionFailureReason: container.decodeIfPresent(String.self, forKey: .insertionFailureReason),
            insertionTextSource: container.decodeIfPresent(TranscriptInsertionSource.self, forKey: .insertionTextSource),
            cleanupFallbackReason: container.decodeIfPresent(String.self, forKey: .cleanupFallbackReason),
            insertionAttemptedAt: container.decodeIfPresent(Date.self, forKey: .insertionAttemptedAt),
            firstTranscriptLine: container.decodeIfPresent(String.self, forKey: .firstTranscriptLine),
            transcriptionAttemptCount: container.decodeIfPresent(Int.self, forKey: .transcriptionAttemptCount) ?? 0,
            audioFileName: container.decode(String.self, forKey: .audioFileName),
            rawTextFileName: container.decode(String.self, forKey: .rawTextFileName),
            cleanTextFileName: container.decode(String.self, forKey: .cleanTextFileName)
        )
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

public struct SessionHistoryEntry: Equatable, Identifiable, Sendable {
    public let session: DictationSession
    public let firstTranscriptLine: String?
    public let textSource: SessionTextSource

    public var id: UUID {
        session.id
    }

    public init(
        session: DictationSession,
        firstTranscriptLine: String?,
        textSource: SessionTextSource
    ) {
        self.session = session
        self.firstTranscriptLine = firstTranscriptLine
        self.textSource = textSource
    }
}

public struct SessionMaintenanceResult: Equatable, Sendable {
    public let removedSessionIDs: [UUID]
    public let removedAudioSessionIDs: [UUID]

    public init(
        removedSessionIDs: [UUID] = [],
        removedAudioSessionIDs: [UUID] = []
    ) {
        self.removedSessionIDs = removedSessionIDs
        self.removedAudioSessionIDs = removedAudioSessionIDs
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
    case transcriptTooLarge(URL)
    case insertionAlreadyAttempted(UUID)
    case activeSession(UUID)

    public var description: String {
        switch self {
        case .missingSession(let id):
            "dictation session does not exist: " + id.uuidString
        case .invalidMetadata(let url):
            "dictation session metadata is invalid: " + url.path
        case .invalidSessionDirectory(let url):
            "dictation session directory is invalid: " + url.path
        case .transcriptTooLarge(let url):
            "raw transcript is too large to load safely: " + url.path
        case .insertionAlreadyAttempted(let id):
            "dictation session insertion was already attempted: " + id.uuidString
        case .activeSession(let id):
            "dictation session is active and cannot be deleted: " + id.uuidString
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

    private struct PendingTranscriptPrune: Codable {
        let metadata: SessionMetadata
        let rawTombstoneName: String?
        let cleanTombstoneName: String?
    }

    private static let pendingRawPersistenceName = ".raw-persistence.json"
    private static let pendingTranscriptPruneName = ".transcript-prune.json"
    private static let maxMetadataBytes = 64 * 1024
    private static let maxTranscriptBytes = 4 * 1024 * 1024

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
        return try urls.compactMap { url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw SessionStoreError.invalidSessionDirectory(url)
            }
            guard values.isDirectory == true else {
                return nil
            }
            return try? readSession(at: url)
        }
            .sorted { lhs, rhs in
                lhs.metadata.createdAt > rhs.metadata.createdAt
            }
    }

    public func listHistory(
        limit: Int = SessionRetentionPolicy.default.maxTranscriptSessions
    ) throws -> [SessionHistoryEntry] {
        guard limit > 0 else {
            return []
        }

        lock.lock()
        defer { lock.unlock() }

        let maxDirectories = SessionRetentionPolicy.default.maxDirectoriesToInspect
        let sessions = try newestSessions(maxCount: maxDirectories)
        return sessions
            .sorted { lhs, rhs in
                isNewer(lhs, than: rhs)
            }
            .prefix(limit)
            .map { session in
                let firstLine = session.metadata.firstTranscriptLine
                    ?? (try? readFirstTranscriptLine(at: session.directoryURL))
                let source: SessionTextSource = fileManager.fileExists(atPath: session.cleanTextURL.path)
                    ? .processed
                    : .raw
                return SessionHistoryEntry(
                    session: session,
                    firstTranscriptLine: firstLine,
                    textSource: source
                )
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
        insertionFailureReason: String? = nil,
        insertionTextSource: TranscriptInsertionSource? = nil,
        cleanupFallbackReason: String? = nil
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
                if metadata.duration == nil, let startedAt = metadata.startedAt {
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
                if let insertionTextSource {
                    metadata.insertionTextSource = insertionTextSource
                }
                if let cleanupFallbackReason {
                    metadata.cleanupFallbackReason = cleanupFallbackReason
                }
            }

            try writeMetadata(metadata, at: current.metadataURL, directoryFD: directoryFD)
            return DictationSession(metadata: metadata, directoryURL: current.directoryURL)
        }
    }

    @discardableResult
    public func beginTranscriptionRetry(
        for session: DictationSession,
        at date: Date = Date()
    ) throws -> DictationSession {
        lock.lock()
        defer { lock.unlock() }

        return try withSessionDirectory(at: session.directoryURL) { directoryFD in
            let current = try readSession(at: session.directoryURL, directoryFD: directoryFD)
            guard current.metadata.state == .failed || current.metadata.state == .interrupted else {
                throw SessionStoreError.invalidMetadata(current.metadataURL)
            }
            var metadata = current.metadata
            metadata.state = .retrying
            metadata.updatedAt = date
            metadata.transcriptionAttemptCount += 1
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
            metadata.firstTranscriptLine = Self.firstTranscriptLine(from: rawText)

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
            try invalidateCleanText(for: current, in: directoryFD)
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
                at: current.rawTextURL,
                maxBytes: Self.maxTranscriptBytes
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
            if metadata.firstTranscriptLine == nil {
                let existingText = String(decoding: existingData, as: UTF8.self)
                metadata.firstTranscriptLine = Self.firstTranscriptLine(
                    from: existingText.isEmpty ? rawText : existingText
                )
            }
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
            try invalidateCleanText(for: current, in: directoryFD)
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
                at: stagingURL,
                maxBytes: Self.maxTranscriptBytes
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
            metadata.firstTranscriptLine = try readFirstTranscriptLine(
                from: stagingFD,
                at: stagingURL
            )
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
            try invalidateCleanText(for: current, in: directoryFD)
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
            let data: Data?
            do {
                data = try readDataIfPresent(
                    named: "raw.txt",
                    in: directoryFD,
                    at: current.rawTextURL,
                    maxBytes: Self.maxTranscriptBytes
                )
            } catch SessionStoreError.invalidMetadata {
                throw SessionStoreError.transcriptTooLarge(current.rawTextURL)
            }
            guard let data else {
                return ""
            }
            guard let rawText = String(data: data, encoding: .utf8) else {
                throw SessionStoreError.invalidMetadata(current.rawTextURL)
            }
            return rawText
        }
    }

    @discardableResult
    public func persistCleanText(
        _ cleanText: String,
        for session: DictationSession,
        at date: Date = Date()
    ) throws -> DictationSession {
        lock.lock()
        defer { lock.unlock() }

        return try withSessionDirectory(at: session.directoryURL) { directoryFD in
            let current = try readSession(at: session.directoryURL, directoryFD: directoryFD)
            let data = Data(cleanText.utf8)
            guard data.count <= Self.maxTranscriptBytes else {
                throw SessionStoreError.transcriptTooLarge(current.cleanTextURL)
            }
            try rejectSymlink(
                named: "clean.txt",
                in: directoryFD,
                at: current.cleanTextURL,
                allowMissing: true
            )
            try atomicWrite(
                data,
                named: "clean.txt",
                in: directoryFD,
                at: current.cleanTextURL
            )
            var metadata = current.metadata
            metadata.updatedAt = date
            try writeMetadata(metadata, at: current.metadataURL, directoryFD: directoryFD)
            return DictationSession(metadata: metadata, directoryURL: current.directoryURL)
        }
    }

    public func readCleanText(for session: DictationSession) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        return try withSessionDirectory(at: session.directoryURL) { directoryFD in
            let current = try readSession(at: session.directoryURL, directoryFD: directoryFD)
            let data: Data?
            do {
                data = try readDataIfPresent(
                    named: "clean.txt",
                    in: directoryFD,
                    at: current.cleanTextURL,
                    maxBytes: Self.maxTranscriptBytes
                )
            } catch SessionStoreError.invalidMetadata {
                throw SessionStoreError.transcriptTooLarge(current.cleanTextURL)
            }
            guard let data else {
                return ""
            }
            guard let cleanText = String(data: data, encoding: .utf8) else {
                throw SessionStoreError.invalidMetadata(current.cleanTextURL)
            }
            return cleanText
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

        var recovered: [DictationSession] = []
        try forEachTolerantSession { session in
            guard session.metadata.state.isUnfinished else {
                return
            }
            var metadata = session.metadata
            metadata.state = .interrupted
            metadata.updatedAt = date
            metadata.endedAt = date
            if let startedAt = metadata.startedAt {
                metadata.duration = max(0, date.timeIntervalSince(startedAt))
            }
            metadata.failureReason = session.metadata.state == .retrying
                ? "transcription retry was interrupted before shutdown"
                : "recording was interrupted before shutdown"
            try writeMetadata(metadata, at: session.metadataURL)
            recovered.append(DictationSession(metadata: metadata, directoryURL: session.directoryURL))
        }
        return recovered
    }

    public func remove(id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }

        guard let directoryURL = try sessionDirectory(for: id) else {
            throw SessionStoreError.missingSession(id)
        }
        let session = try readSession(at: directoryURL)
        let isEmptyPreparingPlaceholder = session.metadata.state == .preparing
            && session.metadata.startedAt == nil
            && session.metadata.audioByteCount == nil
            && session.metadata.rawTextByteCount == nil
            && !fileManager.fileExists(atPath: session.audioURL.path)
            && !fileManager.fileExists(atPath: session.rawTextURL.path)
        guard !session.metadata.state.isUnfinished || isEmptyPreparingPlaceholder else {
            throw SessionStoreError.activeSession(id)
        }
        try removeSessionDirectory(at: session.directoryURL)
    }

    public func performIdleMaintenance(
        at date: Date = Date(),
        policy: SessionRetentionPolicy = .default
    ) throws -> SessionMaintenanceResult {
        lock.lock()
        defer { lock.unlock() }

        var removedSessionIDs: [UUID] = []
        var removedAudioSessionIDs: [UUID] = []

        func applyMaintenance(
            to session: DictationSession,
            retainsTranscript: Bool
        ) throws {
            guard !session.metadata.state.isUnfinished else {
                return
            }
            guard session.metadata.state != .failed,
                  session.metadata.state != .interrupted else {
                return
            }

            let hasAudio = fileManager.fileExists(atPath: session.audioURL.path)
            let referenceDate = session.metadata.endedAt ?? session.metadata.updatedAt
            let audioIsRetained = session.metadata.state == .completed
                && hasAudio
                && date.timeIntervalSince(referenceDate) <= policy.successfulAudioLifetime

            if !retainsTranscript {
                if audioIsRetained {
                    if sessionHasTranscript(session) {
                        try removeTranscriptFiles(for: session)
                    }
                } else {
                    try removeSessionDirectory(at: session.directoryURL)
                    removedSessionIDs.append(session.id)
                    return
                }
            }

            guard session.metadata.state == .completed,
                  hasAudio else {
                return
            }
            guard date.timeIntervalSince(referenceDate) > policy.successfulAudioLifetime else {
                return
            }
            try removeAudioFile(for: session)
            removedAudioSessionIDs.append(session.id)
        }

        var retainedTranscriptSessions: [DictationSession] = []
        try forEachTolerantSession { session in
            if sessionHasTranscript(session) {
                retainedTranscriptSessions.append(session)
                retainedTranscriptSessions.sort { isNewer($0, than: $1) }
                if retainedTranscriptSessions.count > policy.maxTranscriptSessions {
                    let evicted = retainedTranscriptSessions.removeLast()
                    try applyMaintenance(to: evicted, retainsTranscript: false)
                    if evicted.id == session.id {
                        return
                    }
                }
            }
            let retainsTranscript = retainedTranscriptSessions.contains { $0.id == session.id }
            try applyMaintenance(to: session, retainsTranscript: retainsTranscript)
        }

        return SessionMaintenanceResult(
            removedSessionIDs: removedSessionIDs,
            removedAudioSessionIDs: removedAudioSessionIDs
        )
    }

    private func sessionHasTranscript(_ session: DictationSession) -> Bool {
        session.metadata.rawTextByteCount != nil
            || fileManager.fileExists(atPath: session.rawTextURL.path)
    }

    private func removeSessionDirectory(at directoryURL: URL) throws {
        let tombstone = rootDirectory.appendingPathComponent(
            ".deleting-" + UUID().uuidString,
            isDirectory: true
        )
        do {
            try fileManager.moveItem(at: directoryURL, to: tombstone)
            try fileManager.removeItem(at: tombstone)
        } catch {
            throw SessionStoreError.invalidSessionDirectory(tombstone)
        }
    }

    private func removeAudioFile(for session: DictationSession) throws {
        try withSessionDirectory(at: session.directoryURL) { directoryFD in
            try removeEntry(
                named: "audio.caf",
                in: directoryFD,
                at: session.audioURL,
                allowMissing: true
            )
            _ = Darwin.fsync(directoryFD)
        }
    }

    private func removeTranscriptFiles(for session: DictationSession) throws {
        try withSessionDirectory(at: session.directoryURL) { directoryFD in
            let current = try readSession(at: session.directoryURL, directoryFD: directoryFD)
            var metadata = current.metadata
            metadata.rawTextByteCount = nil
            metadata.firstTranscriptLine = nil
            let rawTombstoneName = entryExists(named: "raw.txt", in: directoryFD)
                ? ".raw.txt." + UUID().uuidString + ".pruned"
                : nil
            let cleanTombstoneName = entryExists(named: "clean.txt", in: directoryFD)
                ? ".clean.txt." + UUID().uuidString + ".pruned"
                : nil
            let pending = PendingTranscriptPrune(
                metadata: metadata,
                rawTombstoneName: rawTombstoneName,
                cleanTombstoneName: cleanTombstoneName
            )
            try writePendingTranscriptPrune(
                pending,
                in: directoryFD,
                at: current.directoryURL.appendingPathComponent(Self.pendingTranscriptPruneName)
            )
            if let rawTombstoneName {
                try renameEntry(
                    named: "raw.txt",
                    to: rawTombstoneName,
                    in: directoryFD,
                    at: current.rawTextURL
                )
            }
            if let cleanTombstoneName {
                try renameEntry(
                    named: "clean.txt",
                    to: cleanTombstoneName,
                    in: directoryFD,
                    at: current.cleanTextURL
                )
            }
            try writeMetadata(metadata, at: current.metadataURL, directoryFD: directoryFD)
            if let rawTombstoneName {
                try removeEntry(
                    named: rawTombstoneName,
                    in: directoryFD,
                    at: current.directoryURL.appendingPathComponent(rawTombstoneName),
                    allowMissing: true
                )
            }
            if let cleanTombstoneName {
                try removeEntry(
                    named: cleanTombstoneName,
                    in: directoryFD,
                    at: current.directoryURL.appendingPathComponent(cleanTombstoneName),
                    allowMissing: true
                )
            }
            try removePendingTranscriptPrune(in: directoryFD, at: current.directoryURL)
            _ = Darwin.fsync(directoryFD)
        }
    }

    private func newestSessions(maxCount: Int) throws -> [DictationSession] {
        guard maxCount > 0 else {
            return []
        }

        var sessions: [DictationSession] = []
        try forEachTolerantSession { session in
            sessions.append(session)
            sessions.sort { isNewer($0, than: $1) }
            if sessions.count > maxCount {
                sessions.removeLast()
            }
        }
        return sessions
    }

    private func sessionDirectory(for id: UUID) throws -> URL? {
        let suffix = "-" + id.uuidString.lowercased()
        guard let enumerator = fileManager.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            return nil
        }

        while let value = enumerator.nextObject() {
            guard let url = value as? URL,
                  let values = try? url.resourceValues(
                      forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                  ) else {
                continue
            }
            if values.isDirectory == true {
                enumerator.skipDescendants()
            }
            guard values.isDirectory == true,
                  values.isSymbolicLink != true else {
                continue
            }
            if url.lastPathComponent.hasSuffix(suffix) {
                return url
            }
        }
        return nil
    }

    private func isNewer(_ lhs: DictationSession, than rhs: DictationSession) -> Bool {
        if lhs.metadata.createdAt == rhs.metadata.createdAt {
            return lhs.metadata.directoryName > rhs.metadata.directoryName
        }
        return lhs.metadata.createdAt > rhs.metadata.createdAt
    }

    private func forEachTolerantSession(
        _ body: (DictationSession) throws -> Void
    ) throws {
        guard let enumerator = fileManager.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            return
        }

        while let value = enumerator.nextObject() {
            guard let url = value as? URL,
                  let values = try? url.resourceValues(
                      forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                  ) else {
                continue
            }
            if values.isDirectory == true {
                enumerator.skipDescendants()
            }
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                continue
            }
            guard let session = try? readSession(at: url) else {
                continue
            }
            try body(session)
        }
    }

    private func readFirstTranscriptLine(at directoryURL: URL) throws -> String? {
        let directoryFD = try openSessionDirectory(at: directoryURL)
        defer { _ = Darwin.close(directoryFD) }

        let fileURL = directoryURL.appendingPathComponent("raw.txt")
        let fileFD = "raw.txt".withCString { name in
            Darwin.openat(directoryFD, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard fileFD >= 0 else {
            guard errno == ENOENT else {
                throw SessionStoreError.invalidSessionDirectory(fileURL)
            }
            return nil
        }
        defer { _ = Darwin.close(fileFD) }

        return try readFirstTranscriptLine(from: fileFD, at: fileURL)
    }

    private func readFirstTranscriptLine(
        from fileFD: Int32,
        at url: URL
    ) throws -> String? {
        var fileInfo = stat()
        guard Darwin.fstat(fileFD, &fileInfo) == 0,
              (fileInfo.st_mode & S_IFMT) == S_IFREG else {
            throw SessionStoreError.invalidSessionDirectory(url)
        }
        var buffer = [UInt8](repeating: 0, count: 4_096)
        let count = buffer.withUnsafeMutableBytes { bytes in
            Darwin.read(fileFD, bytes.baseAddress, bytes.count)
        }
        guard count >= 0 else {
            throw SessionStoreError.invalidSessionDirectory(url)
        }
        return Self.firstTranscriptLine(from: Data(buffer.prefix(Int(count))))
    }

    private static func firstTranscriptLine(from rawText: String) -> String? {
        let line = rawText
            .split(maxSplits: 1, omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !line.isEmpty else {
            return nil
        }
        return String(line.prefix(512))
    }

    private static func firstTranscriptLine(from data: Data) -> String? {
        firstTranscriptLine(from: String(decoding: data, as: UTF8.self))
    }

    private func readSession(at directoryURL: URL) throws -> DictationSession {
        try withSessionDirectory(at: directoryURL) { directoryFD in
            try readSession(at: directoryURL, directoryFD: directoryFD)
        }
    }

    private func readSession(at directoryURL: URL, directoryFD: Int32) throws -> DictationSession {
        try recoverTranscriptPrune(at: directoryURL, directoryFD: directoryFD)
        try recoverPendingPersistence(at: directoryURL, directoryFD: directoryFD)
        let metadataURL = directoryURL.appendingPathComponent("session.json")
        do {
            let data = try readData(
                named: "session.json",
                in: directoryFD,
                at: metadataURL,
                maxBytes: Self.maxMetadataBytes
            )
            let metadata = try decoder.decode(SessionMetadata.self, from: data)
            guard metadata.directoryName == directoryURL.standardizedFileURL.lastPathComponent,
                  metadata.directoryName.hasSuffix("-" + metadata.id.uuidString.lowercased()),
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

    private func invalidateCleanText(
        for session: DictationSession,
        in directoryFD: Int32
    ) throws {
        try rejectSymlink(
            named: "clean.txt",
            in: directoryFD,
            at: session.cleanTextURL,
            allowMissing: true
        )
        try removeEntry(
            named: "clean.txt",
            in: directoryFD,
            at: session.cleanTextURL,
            allowMissing: true
        )
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
        try fileByteCount(named: name, in: directoryFD, at: url)
    }

    private func writePendingTranscriptPrune(
        _ pending: PendingTranscriptPrune,
        in directoryFD: Int32,
        at url: URL
    ) throws {
        let data = try encoder.encode(pending)
        try rejectSymlink(
            named: Self.pendingTranscriptPruneName,
            in: directoryFD,
            at: url,
            allowMissing: true
        )
        try atomicWrite(
            data,
            named: Self.pendingTranscriptPruneName,
            in: directoryFD,
            at: url
        )
    }

    private func removePendingTranscriptPrune(
        in directoryFD: Int32,
        at directoryURL: URL
    ) throws {
        try removeEntry(
            named: Self.pendingTranscriptPruneName,
            in: directoryFD,
            at: directoryURL.appendingPathComponent(Self.pendingTranscriptPruneName),
            allowMissing: true
        )
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
            at: pendingURL,
            maxBytes: Self.maxMetadataBytes
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
              pending.metadata.directoryName.hasSuffix("-" + pending.metadata.id.uuidString.lowercased()),
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

    private func recoverTranscriptPrune(at directoryURL: URL, directoryFD: Int32) throws {
        let pendingURL = directoryURL.appendingPathComponent(Self.pendingTranscriptPruneName)
        guard let data = try readDataIfPresent(
            named: Self.pendingTranscriptPruneName,
            in: directoryFD,
            at: pendingURL,
            maxBytes: Self.maxMetadataBytes
        ) else {
            return
        }
        let pending: PendingTranscriptPrune
        do {
            pending = try decoder.decode(PendingTranscriptPrune.self, from: data)
        } catch {
            throw SessionStoreError.invalidMetadata(pendingURL)
        }
        guard pending.metadata.directoryName == directoryURL.standardizedFileURL.lastPathComponent,
              pending.metadata.directoryName.hasSuffix("-" + pending.metadata.id.uuidString.lowercased()),
              pending.metadata.audioFileName == "audio.caf",
              pending.metadata.rawTextFileName == "raw.txt",
              pending.metadata.cleanTextFileName == "clean.txt" else {
            throw SessionStoreError.invalidMetadata(pendingURL)
        }

        let metadataURL = directoryURL.appendingPathComponent("session.json")
        let metadata: SessionMetadata
        do {
            let metadataData = try readData(
                named: "session.json",
                in: directoryFD,
                at: metadataURL,
                maxBytes: Self.maxMetadataBytes
            )
            metadata = try decoder.decode(SessionMetadata.self, from: metadataData)
        } catch {
            throw SessionStoreError.invalidMetadata(metadataURL)
        }
        let pruneCompleted = metadata.rawTextByteCount == nil
            && metadata.firstTranscriptLine == nil
        let tombstones = [
            ("raw.txt", pending.rawTombstoneName),
            ("clean.txt", pending.cleanTombstoneName)
        ]
        for (originalName, tombstoneName) in tombstones {
            guard let tombstoneName else {
                continue
            }
            let tombstoneURL = directoryURL.appendingPathComponent(tombstoneName)
            guard entryExists(named: tombstoneName, in: directoryFD) else {
                continue
            }
            if pruneCompleted {
                try removeEntry(
                    named: tombstoneName,
                    in: directoryFD,
                    at: tombstoneURL,
                    allowMissing: true
                )
            } else if entryExists(named: originalName, in: directoryFD) {
                try removeEntry(
                    named: tombstoneName,
                    in: directoryFD,
                    at: tombstoneURL,
                    allowMissing: true
                )
            } else {
                try renameEntry(
                    named: tombstoneName,
                    to: originalName,
                    in: directoryFD,
                    at: directoryURL.appendingPathComponent(originalName)
                )
            }
        }
        try removePendingTranscriptPrune(in: directoryFD, at: directoryURL)
        _ = Darwin.fsync(directoryFD)
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

    private func fileByteCount(
        named name: String,
        in directoryFD: Int32,
        at url: URL
    ) throws -> Int64 {
        let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        let fileFD = name.withCString { entryName in
            Darwin.openat(directoryFD, entryName, flags)
        }
        guard fileFD >= 0 else {
            guard errno == ENOENT else {
                throw SessionStoreError.invalidSessionDirectory(url)
            }
            return 0
        }
        defer { _ = Darwin.close(fileFD) }

        var fileInfo = stat()
        guard Darwin.fstat(fileFD, &fileInfo) == 0,
              (fileInfo.st_mode & S_IFMT) == S_IFREG else {
            throw SessionStoreError.invalidSessionDirectory(url)
        }
        return Int64(fileInfo.st_size)
    }

    private func readData(
        named name: String,
        in directoryFD: Int32,
        at url: URL,
        maxBytes: Int? = nil
    ) throws -> Data {
        let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        let fileFD = name.withCString { entryName in
            Darwin.openat(directoryFD, entryName, flags)
        }
        guard fileFD >= 0 else {
            throw SessionStoreError.invalidSessionDirectory(url)
        }
        defer { _ = Darwin.close(fileFD) }

        return try readData(from: fileFD, at: url, maxBytes: maxBytes)
    }

    private func readDataIfPresent(
        named name: String,
        in directoryFD: Int32,
        at url: URL,
        maxBytes: Int? = nil
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

        return try readData(from: fileFD, at: url, maxBytes: maxBytes)
    }

    private func readData(
        from fileFD: Int32,
        at url: URL,
        maxBytes: Int? = nil
    ) throws -> Data {

        var fileInfo = stat()
        guard Darwin.fstat(fileFD, &fileInfo) == 0,
              (fileInfo.st_mode & S_IFMT) == S_IFREG else {
            throw SessionStoreError.invalidSessionDirectory(url)
        }
        if let maxBytes, fileInfo.st_size > Int64(maxBytes) {
            throw SessionStoreError.invalidMetadata(url)
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
            if let maxBytes, data.count + count > maxBytes {
                throw SessionStoreError.invalidMetadata(url)
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

    private func renameEntry(
        named sourceName: String,
        to destinationName: String,
        in directoryFD: Int32,
        at destinationURL: URL
    ) throws {
        guard !sourceName.isEmpty,
              !destinationName.isEmpty,
              !sourceName.contains("/"),
              !destinationName.contains("/") else {
            throw SessionStoreError.invalidSessionDirectory(destinationURL)
        }
        try rejectSymlink(
            named: sourceName,
            in: directoryFD,
            at: destinationURL,
            allowMissing: false
        )
        try rejectSymlink(
            named: destinationName,
            in: directoryFD,
            at: destinationURL,
            allowMissing: true
        )
        let result = sourceName.withCString { sourceName in
            destinationName.withCString { destinationName in
                Darwin.renameat(directoryFD, sourceName, directoryFD, destinationName)
            }
        }
        guard result == 0 else {
            throw SessionStoreError.invalidSessionDirectory(destinationURL)
        }
        _ = Darwin.fsync(directoryFD)
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
