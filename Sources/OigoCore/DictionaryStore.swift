import Darwin
import Foundation

public final class DictionaryStore: @unchecked Sendable {
    public static let fileName = "custom-dictionary.json"
    public static let maxBytes = 512 * 1_024

    public let directoryURL: URL
    public var fileURL: URL {
        directoryURL.appendingPathComponent(Self.fileName)
    }

    private let fileManager: FileManager
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var directoryFD: Int32

    public init(directoryURL: URL, fileManager: FileManager = .default) throws {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        self.encoder = encoder
        self.decoder = JSONDecoder()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        directoryFD = try Self.openDirectory(at: directoryURL)
    }

    deinit {
        if directoryFD >= 0 {
            _ = Darwin.close(directoryFD)
        }
    }

    public static func defaultDirectory(fileManager: FileManager = .default) throws -> URL {
        try SessionStore.defaultRootDirectory(fileManager: fileManager)
            .deletingLastPathComponent()
    }

    public func load() -> DictionaryLoadResult {
        lock.lock()
        defer { lock.unlock() }
        do {
            guard let data = try readFileIfPresent() else {
                return DictionaryLoadResult(
                    document: .empty,
                    snapshot: .empty
                )
            }
            let document: DictionaryDocument
            do {
                document = try decoder.decode(DictionaryDocument.self, from: data)
            } catch {
                return DictionaryLoadResult(
                    document: .empty,
                    snapshot: .empty,
                    error: .malformed
                )
            }
            guard document.schemaVersion == DictionaryDocument.currentSchemaVersion else {
                return DictionaryLoadResult(
                    document: .empty,
                    snapshot: .empty,
                    error: .unsupportedVersion
                )
            }
            do {
                try DictionaryCompiler.validate(document.entries)
                let snapshot = try DictionaryCompiler.compile(document.entries, localeIdentifier: nil)
                return DictionaryLoadResult(document: document, snapshot: snapshot)
            } catch let error as DictionaryStoreError {
                return DictionaryLoadResult(
                    document: document,
                    snapshot: .empty,
                    error: error
                )
            }
        } catch let error as DictionaryStoreError {
            return DictionaryLoadResult(document: .empty, snapshot: .empty, error: error)
        } catch {
            return DictionaryLoadResult(document: .empty, snapshot: .empty, error: .malformed)
        }
    }

    public func save(_ document: DictionaryDocument) throws {
        lock.lock()
        defer { lock.unlock() }
        var normalized = document
        normalized.schemaVersion = DictionaryDocument.currentSchemaVersion
        normalized.entries = try normalized.entries.map(Self.trimmed)
        try DictionaryCompiler.validate(normalized.entries)
        let data = try encoder.encode(normalized)
        guard data.count <= Self.maxBytes else {
            throw DictionaryStoreError.tooLarge
        }
        try atomicWrite(data)
    }

    public func addStarterTerms() throws -> DictionaryDocument {
        let loaded = load()
        if let error = loaded.error,
           error == .malformed
            || error == .unsupportedVersion
            || error == .tooLarge
            || error == .notRegularFile
            || error == .symlinkRejected {
            throw error
        }
        var document = loaded.document
        let existing = Set(document.entries.map { fold($0.canonical) })
        for starter in DictionaryStarterTerms.technology {
            if existing.contains(fold(starter.canonical)) {
                continue
            }
            document.entries.append(
                DictionaryEntry(
                    canonical: starter.canonical,
                    aliases: starter.aliases
                )
            )
        }
        try save(document)
        return document
    }

    private static func trimmed(_ entry: DictionaryEntry) throws -> DictionaryEntry {
        DictionaryEntry(
            id: entry.id,
            canonical: entry.canonical.trimmingCharacters(in: .whitespacesAndNewlines),
            aliases: entry.aliases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
            localeIdentifier: entry.localeIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            isEnabled: entry.isEnabled
        )
    }

    private func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
    }

    private func readFileIfPresent() throws -> Data? {
        try rejectSymlink(allowMissing: true)
        let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        let fileFD = Self.fileName.withCString { name in
            Darwin.openat(directoryFD, name, flags)
        }
        guard fileFD >= 0 else {
            if errno == ENOENT {
                return nil
            }
            if errno == ELOOP {
                throw DictionaryStoreError.symlinkRejected
            }
            throw DictionaryStoreError.malformed
        }
        defer { _ = Darwin.close(fileFD) }
        var info = stat()
        guard Darwin.fstat(fileFD, &info) == 0 else {
            throw DictionaryStoreError.malformed
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw DictionaryStoreError.notRegularFile
        }
        guard info.st_size <= Int64(Self.maxBytes) else {
            throw DictionaryStoreError.tooLarge
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
                throw DictionaryStoreError.malformed
            }
            if data.count + count > Self.maxBytes {
                throw DictionaryStoreError.tooLarge
            }
            data.append(buffer, count: count)
        }
        return data
    }

    private func atomicWrite(_ data: Data) throws {
        try rejectSymlink(allowMissing: true)
        let temporaryName = "." + Self.fileName + "." + UUID().uuidString + ".tmp"
        let flags = O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW
        let temporaryFD = temporaryName.withCString { name in
            Darwin.openat(directoryFD, name, flags, mode_t(0o600))
        }
        guard temporaryFD >= 0 else {
            throw DictionaryStoreError.writeFailed
        }
        var prepared = false
        defer {
            _ = Darwin.close(temporaryFD)
            if !prepared {
                _ = temporaryName.withCString { name in
                    Darwin.unlinkat(directoryFD, name, 0)
                }
            }
        }
        try write(data, to: temporaryFD)
        guard Darwin.fsync(temporaryFD) == 0 else {
            throw DictionaryStoreError.writeFailed
        }
        prepared = true
        let renamed = temporaryName.withCString { source in
            Self.fileName.withCString { destination in
                Darwin.renameat(directoryFD, source, directoryFD, destination)
            }
        }
        guard renamed == 0 else {
            _ = temporaryName.withCString { name in
                Darwin.unlinkat(directoryFD, name, 0)
            }
            throw DictionaryStoreError.writeFailed
        }
        _ = Darwin.fsync(directoryFD)
    }

    private func write(_ data: Data, to fileFD: Int32) throws {
        var offset = 0
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else {
                return
            }
            while offset < data.count {
                let written = Darwin.write(fileFD, base + offset, data.count - offset)
                guard written > 0 else {
                    if errno == EINTR {
                        continue
                    }
                    throw DictionaryStoreError.writeFailed
                }
                offset += written
            }
        }
    }

    private func rejectSymlink(allowMissing: Bool) throws {
        var info = stat()
        let result = Self.fileName.withCString { name in
            Darwin.fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else {
            guard allowMissing, errno == ENOENT else {
                throw DictionaryStoreError.malformed
            }
            return
        }
        guard (info.st_mode & S_IFMT) != S_IFLNK else {
            throw DictionaryStoreError.symlinkRejected
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw DictionaryStoreError.notRegularFile
        }
    }

    private static func openDirectory(at url: URL) throws -> Int32 {
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        let directoryFD = url.path.withCString { path in
            Darwin.open(path, flags)
        }
        guard directoryFD >= 0 else {
            throw DictionaryStoreError.writeFailed
        }
        return directoryFD
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
