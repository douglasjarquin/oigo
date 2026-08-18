import Darwin
import Foundation

public enum DurableSessionFailureCategory: String, CaseIterable, Equatable, Sendable {
    case unavailableParent = "unavailable-parent"
    case permissionDenied = "permission-denied"
    case rootIdentityViolation = "root-identity-violation"
    case metadataRecoveryFailure = "metadata-recovery-failure"
    case insufficientSpaceOrWriteFailure = "insufficient-space-write-failure"
    case unknownIOFailure = "unknown-io-failure"

    public var statusDescription: String {
        switch self {
        case .unavailableParent:
            "unavailable parent"
        case .permissionDenied:
            "permission denied"
        case .rootIdentityViolation:
            "root identity violation"
        case .metadataRecoveryFailure:
            "metadata or recovery failure"
        case .insufficientSpaceOrWriteFailure:
            "insufficient space or write failure"
        case .unknownIOFailure:
            "unknown I/O failure"
        }
    }
}

public struct DurableSessionBootstrapReport: Equatable, Sendable {
    public let recoveredSessionCount: Int
    public let historyEntryCount: Int
    public let malformedSessionCount: Int

    public init(
        recoveredSessionCount: Int,
        historyEntryCount: Int,
        malformedSessionCount: Int
    ) {
        self.recoveredSessionCount = recoveredSessionCount
        self.historyEntryCount = historyEntryCount
        self.malformedSessionCount = malformedSessionCount
    }
}

public struct DurableSessionBootstrapResult: @unchecked Sendable {
    public let store: SessionStore
    public let history: [SessionHistoryEntry]
    public let report: DurableSessionBootstrapReport

    public init(
        store: SessionStore,
        history: [SessionHistoryEntry],
        report: DurableSessionBootstrapReport
    ) {
        self.store = store
        self.history = history
        self.report = report
    }
}

public struct DurableSessionBootstrapFailure: Error, Equatable, CustomStringConvertible, Sendable {
    public let category: DurableSessionFailureCategory
    public let isFatal: Bool
    private let underlyingDescription: String?

    public init(
        category: DurableSessionFailureCategory,
        isFatal: Bool,
        underlyingDescription: String? = nil
    ) {
        self.category = category
        self.isFatal = isFatal
        self.underlyingDescription = underlyingDescription
    }

    public func diagnosticsExport() -> String? {
        underlyingDescription
    }

    public var description: String {
        category.rawValue
    }
}

public enum DurableSessionHealth: Equatable, Sendable, CustomStringConvertible {
    case checking
    case ready(DurableSessionBootstrapReport)
    case recoverablyUnavailable(DurableSessionFailureCategory)
    case fatallyInvalid(DurableSessionFailureCategory)

    public var isReady: Bool {
        if case .ready = self {
            return true
        }
        return false
    }

    public var failureCategory: DurableSessionFailureCategory? {
        switch self {
        case .checking, .ready:
            nil
        case .recoverablyUnavailable(let category), .fatallyInvalid(let category):
            category
        }
    }

    public var statusTitle: String {
        switch self {
        case .checking:
            "Storage checking"
        case .ready:
            "Storage ready"
        case .recoverablyUnavailable, .fatallyInvalid:
            "Storage unavailable"
        }
    }

    public var statusMessage: String {
        switch self {
        case .checking:
            "Checking durable storage"
        case .ready(let report) where report.malformedSessionCount == 1:
            "Storage ready: 1 malformed history item isolated"
        case .ready(let report) where report.malformedSessionCount > 1:
            "Storage ready: " + String(report.malformedSessionCount) + " malformed history items isolated"
        case .ready:
            "Storage ready"
        case .recoverablyUnavailable(let category), .fatallyInvalid(let category):
            "Storage unavailable: " + category.statusDescription
        }
    }

    public var description: String {
        statusMessage
    }
}

public enum DurableSessionAccessError: Error, Equatable, CustomStringConvertible, Sendable {
    case storageUnavailable(DurableSessionFailureCategory?)

    public var description: String {
        switch self {
        case .storageUnavailable(let category):
            if let category {
                return "durable storage unavailable: " + category.rawValue
            }
            return "durable storage unavailable"
        }
    }
}

public protocol DurableSessionBootstrapping: Sendable {
    func bootstrap() async throws -> DurableSessionBootstrapResult
}

private final class DurableSessionAttemptWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resume(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        lock.unlock()
        continuation.resume()
    }
}

public struct DurableSessionBootstrapper: DurableSessionBootstrapping, @unchecked Sendable {
    public typealias RootPreparation = () throws -> URL
    public typealias StoreFactory = (URL) throws -> SessionStore
    public typealias Recovery = (SessionStore) throws -> Int
    public typealias HistoryEnumeration = (SessionStore) throws -> SessionHistoryEnumeration

    private let rootPreparation: RootPreparation
    private let storeFactory: StoreFactory
    private let recovery: Recovery
    private let historyEnumeration: HistoryEnumeration

    public init(
        rootDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        rootPreparation = {
            let root = try rootDirectory ?? SessionStore.defaultRootDirectory(fileManager: fileManager)
            return try Self.validatedRootDirectory(at: root)
        }
        storeFactory = { root in
            try SessionStore(rootDirectory: root, fileManager: fileManager)
        }
        recovery = { store in
            try Task.checkCancellation()
            let recovered = try store.recoverUnfinishedSessions(
                shouldContinue: { !Task.isCancelled }
            )
            try Task.checkCancellation()
            return recovered.count
        }
        historyEnumeration = { store in
            try store.listHistoryReport()
        }
    }

    @_spi(Testing)
    public init(
        rootPreparation: @escaping RootPreparation,
        storeFactory: @escaping StoreFactory,
        recovery: @escaping Recovery,
        historyEnumeration: @escaping HistoryEnumeration
    ) {
        self.rootPreparation = rootPreparation
        self.storeFactory = storeFactory
        self.recovery = recovery
        self.historyEnumeration = historyEnumeration
    }

    public func bootstrap() async throws -> DurableSessionBootstrapResult {
        let task = Task.detached(priority: .userInitiated) {
            try self.bootstrapSynchronously()
        }
        return try await withTaskCancellationHandler(operation: {
            try await task.value
        }, onCancel: {
            task.cancel()
        })
    }

    private func bootstrapSynchronously() throws -> DurableSessionBootstrapResult {
        try Task.checkCancellation()
        let root: URL
        do {
            root = try rootPreparation()
        } catch let failure as DurableSessionBootstrapFailure {
            throw failure
        } catch {
            throw Self.map(error, phase: .root)
        }

        try Task.checkCancellation()
        let store: SessionStore
        do {
            store = try storeFactory(root)
        } catch let failure as DurableSessionBootstrapFailure {
            throw failure
        } catch {
            throw Self.map(error, phase: .store)
        }

        try Task.checkCancellation()
        let recoveredSessionCount: Int
        do {
            recoveredSessionCount = try recovery(store)
        } catch let failure as DurableSessionBootstrapFailure {
            throw failure
        } catch {
            throw Self.map(error, phase: .recovery)
        }

        try Task.checkCancellation()
        let historyReport: SessionHistoryEnumeration
        do {
            historyReport = try historyEnumeration(store)
        } catch let failure as DurableSessionBootstrapFailure {
            throw failure
        } catch {
            throw Self.map(error, phase: .history)
        }
        try Task.checkCancellation()

        return DurableSessionBootstrapResult(
            store: store,
            history: historyReport.entries,
            report: DurableSessionBootstrapReport(
                recoveredSessionCount: recoveredSessionCount,
                historyEntryCount: historyReport.entries.count,
                malformedSessionCount: historyReport.malformedSessionCount
            )
        )
    }

    private enum Phase {
        case root
        case store
        case recovery
        case history
    }

    private enum RootPreparationFailure: Error {
        case unavailableParent(String)
        case permissionDenied(String)
        case identityViolation(String)
        case writeFailure(String)
        case unknown(String)
    }

    static func validatedRootDirectory(at root: URL) throws -> URL {
        do {
            return try prepareRoot(at: root)
        } catch {
            throw map(error, phase: .root)
        }
    }

    private static func prepareRoot(at root: URL) throws -> URL {
        let standardizedPath = root.standardizedFileURL.path
        let canonicalPath = standardizedPath == "/var" || standardizedPath.hasPrefix("/var/")
            ? "/private" + standardizedPath
            : standardizedPath
        let components = canonicalPath.split(separator: "/").map(String.init)
        guard standardizedPath.hasPrefix("/"), !components.isEmpty else {
            throw RootPreparationFailure.identityViolation(canonicalPath)
        }

        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        let rootFD = "/".withCString { path in
            Darwin.open(path, flags)
        }
        guard rootFD >= 0 else {
            throw rootFailure(for: errno, path: "/")
        }
        var currentFD = rootFD
        defer { _ = Darwin.close(currentFD) }

        for component in components {
            guard !component.isEmpty, component != ".", component != ".." else {
                throw RootPreparationFailure.identityViolation(canonicalPath)
            }

            var nextFD = component.withCString { name in
                Darwin.openat(currentFD, name, flags)
            }
            if nextFD < 0, errno == ENOENT {
                let created = component.withCString { name in
                    Darwin.mkdirat(currentFD, name, mode_t(0o700))
                }
                if created != 0, errno != EEXIST {
                    throw rootFailure(for: errno, path: canonicalPath)
                }
                nextFD = component.withCString { name in
                    Darwin.openat(currentFD, name, flags)
                }
            }

            guard nextFD >= 0 else {
                throw rootFailure(for: errno, path: canonicalPath)
            }
            var info = stat()
            guard Darwin.fstat(nextFD, &info) == 0 else {
                let errorCode = errno
                _ = Darwin.close(nextFD)
                throw rootFailure(for: errorCode, path: canonicalPath)
            }
            guard (info.st_mode & S_IFMT) == S_IFDIR else {
                _ = Darwin.close(nextFD)
                throw RootPreparationFailure.identityViolation(canonicalPath)
            }
            _ = Darwin.close(currentFD)
            currentFD = nextFD
        }
        return URL(fileURLWithPath: canonicalPath, isDirectory: true)
    }

    private static func rootFailure(for errorCode: Int32, path: String) -> RootPreparationFailure {
        switch errorCode {
        case EACCES, EPERM:
            .permissionDenied(path)
        case ENOENT:
            .unavailableParent(path)
        case ELOOP, ENOTDIR:
            .identityViolation(path)
        case ENOSPC, EDQUOT:
            .writeFailure(path)
        default:
            .unknown(path)
        }
    }

    private static func rootFailure(for error: Error, path: String) -> RootPreparationFailure {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return rootFailure(for: Int32(nsError.code), path: path)
        }
        switch nsError.code {
        case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
            return .permissionDenied(path)
        case NSFileWriteOutOfSpaceError:
            return .writeFailure(path)
        case NSFileNoSuchFileError:
            return .unavailableParent(path)
        default:
            return .unknown(path)
        }
    }

    private static func map(_ error: Error, phase: Phase) -> DurableSessionBootstrapFailure {
        if let failure = error as? DurableSessionBootstrapFailure {
            return failure
        }
        if let rootFailure = error as? RootPreparationFailure {
            switch rootFailure {
            case .unavailableParent(let path):
                return DurableSessionBootstrapFailure(
                    category: .unavailableParent,
                    isFatal: false,
                    underlyingDescription: path
                )
            case .permissionDenied(let path):
                return DurableSessionBootstrapFailure(
                    category: .permissionDenied,
                    isFatal: false,
                    underlyingDescription: path
                )
            case .identityViolation(let path):
                return DurableSessionBootstrapFailure(
                    category: .rootIdentityViolation,
                    isFatal: true,
                    underlyingDescription: path
                )
            case .writeFailure(let path):
                return DurableSessionBootstrapFailure(
                    category: .insufficientSpaceOrWriteFailure,
                    isFatal: false,
                    underlyingDescription: path
                )
            case .unknown(let path):
                return DurableSessionBootstrapFailure(
                    category: .unknownIOFailure,
                    isFatal: false,
                    underlyingDescription: path
                )
            }
        }

        let nsError = error as NSError
        let category: DurableSessionFailureCategory
        if nsError.domain == NSPOSIXErrorDomain {
            switch Int32(nsError.code) {
            case EACCES, EPERM:
                category = .permissionDenied
            case ENOENT:
                category = .unavailableParent
            case ENOSPC, EDQUOT:
                category = .insufficientSpaceOrWriteFailure
            default:
                category = phase == .recovery || phase == .history
                    ? .metadataRecoveryFailure
                    : .unknownIOFailure
            }
        } else if nsError.code == NSFileReadNoPermissionError
                    || nsError.code == NSFileWriteNoPermissionError {
            category = .permissionDenied
        } else if nsError.code == NSFileWriteOutOfSpaceError {
            category = .insufficientSpaceOrWriteFailure
        } else if nsError.code == NSFileNoSuchFileError {
            category = .unavailableParent
        } else {
            category = phase == .recovery || phase == .history
                ? .metadataRecoveryFailure
                : .unknownIOFailure
        }
        return DurableSessionBootstrapFailure(
            category: category,
            isFatal: category == .rootIdentityViolation,
            underlyingDescription: String(describing: error)
        )
    }
}

@MainActor
public final class DurableSessionCapability {
    private static let shutdownWaitNanoseconds: UInt64 = 2_000_000_000

    public private(set) var health: DurableSessionHealth = .checking
    public private(set) var store: SessionStore?
    public private(set) var history: [SessionHistoryEntry] = []
    public var onChange: (() -> Void)?

    private let bootstrapper: any DurableSessionBootstrapping
    private var currentAttempt: Task<Void, Never>?
    private var pendingShutdownAttempts: [Task<Void, Never>] = []
    private var generation: UInt64 = 0

    public init(bootstrapper: any DurableSessionBootstrapping) {
        self.bootstrapper = bootstrapper
    }

    @discardableResult
    public func start() -> Bool {
        beginAttempt()
    }

    @discardableResult
    public func retry() -> Bool {
        beginAttempt()
    }

    public func shutdown() {
        generation &+= 1
        if let currentAttempt {
            currentAttempt.cancel()
            pendingShutdownAttempts.append(currentAttempt)
        }
        currentAttempt = nil
    }

    public func markUnhealthy(
        _ category: DurableSessionFailureCategory,
        fatal: Bool = false
    ) {
        generation &+= 1
        currentAttempt?.cancel()
        currentAttempt = nil
        store = nil
        history = []
        health = fatal ? .fatallyInvalid(category) : .recoverablyUnavailable(category)
        onChange?()
    }

    public func waitForCurrentAttempt() async {
        let task = currentAttempt
        let pendingAttempts = task == nil ? pendingShutdownAttempts : []
        if task == nil {
            pendingShutdownAttempts.removeAll(keepingCapacity: false)
        }
        if let task {
            await waitForAttempt(task)
        }
        for attempt in pendingAttempts {
            await waitForAttempt(attempt)
        }
    }

    private func waitForAttempt(_ attempt: Task<Void, Never>) async {
        let waiter = DurableSessionAttemptWaiter()
        await withCheckedContinuation { continuation in
            Task.detached {
                await attempt.value
                waiter.resume(continuation)
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: Self.shutdownWaitNanoseconds)
                waiter.resume(continuation)
            }
        }
    }

    public func withHealthyStore<T>(
        _ operation: @MainActor (SessionStore) async throws -> T
    ) async throws -> T {
        guard health.isReady, let store else {
            throw DurableSessionAccessError.storageUnavailable(health.failureCategory)
        }
        return try await operation(store)
    }

    private func beginAttempt() -> Bool {
        guard currentAttempt == nil else {
            return false
        }
        generation &+= 1
        let attempt = generation
        health = .checking
        store = nil
        history = []
        onChange?()

        let bootstrapper = self.bootstrapper
        currentAttempt = Task { [weak self] in
            do {
                let result = try await bootstrapper.bootstrap()
                guard !Task.isCancelled else {
                    return
                }
                self?.publish(result, for: attempt)
            } catch let failure as DurableSessionBootstrapFailure {
                guard !Task.isCancelled else {
                    return
                }
                self?.publish(failure, for: attempt)
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                self?.publish(
                    DurableSessionBootstrapFailure(
                        category: .unknownIOFailure,
                        isFatal: false,
                        underlyingDescription: String(describing: error)
                    ),
                    for: attempt
                )
            }
            self?.finishAttempt(for: attempt)
        }
        return true
    }

    private func publish(_ result: DurableSessionBootstrapResult, for attempt: UInt64) {
        guard attempt == generation else {
            return
        }
        store = result.store
        history = result.history
        health = .ready(result.report)
        onChange?()
    }

    private func publish(_ failure: DurableSessionBootstrapFailure, for attempt: UInt64) {
        guard attempt == generation else {
            return
        }
        store = nil
        history = []
        health = failure.isFatal
            ? .fatallyInvalid(failure.category)
            : .recoverablyUnavailable(failure.category)
        onChange?()
    }

    private func finishAttempt(for attempt: UInt64) {
        guard attempt == generation else {
            return
        }
        currentAttempt = nil
    }
}
