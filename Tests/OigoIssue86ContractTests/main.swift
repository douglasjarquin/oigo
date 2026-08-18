import Darwin
import Foundation
@_spi(Testing) import OigoCore

@main
@MainActor
struct OigoIssue86ContractTests {
    static func main() async {
        do {
            try await storageGateDoesNotReachDictationDependenciesWhenUnhealthy()
            try await healthyStorageExposesThePersistedStore()
            try await failureMatrixExposesStableCategories()
            try malformedChildrenDoNotPoisonValidHistory()
            try await retryCoalescesAndFencesStaleCompletions()
            try await relaunchPreservesExistingSessionData()
            print("GREEN: all issue #86 contract scenarios")
        } catch {
            print("FAIL: " + String(describing: error))
            exit(1)
        }
    }

    private static func storageGateDoesNotReachDictationDependenciesWhenUnhealthy() async throws {
        let bootstrapper = FailingBootstrapper(
            failure: DurableSessionBootstrapFailure(
                category: .permissionDenied,
                isFatal: false,
                underlyingDescription: "/Users/user/private transcript content"
            )
        )
        let capability = DurableSessionCapability(bootstrapper: bootstrapper)
        capability.start()
        await capability.waitForCurrentAttempt()

        var recorderConstructed = 0
        var transcriberConstructed = 0
        var insertionConstructed = 0
        var startReached = 0
        do {
            _ = try await capability.withHealthyStore { _ in
                recorderConstructed += 1
                transcriberConstructed += 1
                insertionConstructed += 1
                startReached += 1
                return true
            }
            throw ContractFailure.expectedStorageToBeUnavailable
        } catch let error as DurableSessionAccessError {
            guard error == .storageUnavailable(.permissionDenied) else {
                throw ContractFailure.unexpectedStorageError(String(describing: error))
            }
        }

        guard case .recoverablyUnavailable(.permissionDenied) = capability.health else {
            throw ContractFailure.unexpectedStorageHealth(String(describing: capability.health))
        }
        guard recorderConstructed == 0,
              transcriberConstructed == 0,
              insertionConstructed == 0,
              startReached == 0 else {
            throw ContractFailure.dictationDependencyWasReached
        }
        guard await bootstrapper.diagnosticsExport() == "/Users/user/private transcript content" else {
            throw ContractFailure.diagnosticsExportWasNotPreserved
        }
        guard capability.health.statusMessage == "Storage unavailable: permission denied" else {
            throw ContractFailure.unstableStorageMessage
        }
    }

    private static func healthyStorageExposesThePersistedStore() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue86-healthy-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootDirectory: root)
        let bootstrapper = HealthyBootstrapper(
            result: DurableSessionBootstrapResult(
                store: store,
                history: [],
                report: DurableSessionBootstrapReport(
                    recoveredSessionCount: 0,
                    historyEntryCount: 0,
                    malformedSessionCount: 0
                )
            )
        )
        let capability = DurableSessionCapability(bootstrapper: bootstrapper)
        capability.start()
        await capability.waitForCurrentAttempt()

        guard capability.health.isReady, capability.store === store else {
            throw ContractFailure.healthyStoreWasNotPublished
        }
        let reached = try await capability.withHealthyStore { receivedStore in
            receivedStore === store
        }
        guard reached else {
            throw ContractFailure.healthyStoreWasNotPassedToGate
        }
    }
    private static func failureMatrixExposesStableCategories() async throws {
        for category in DurableSessionFailureCategory.allCases {
            let failure = DurableSessionBootstrapFailure(
                category: category,
                isFatal: category == .rootIdentityViolation,
                underlyingDescription: "/Users/user/private transcript content"
            )
            let capability = DurableSessionCapability(
                bootstrapper: FailingBootstrapper(failure: failure)
            )
            capability.start()
            await capability.waitForCurrentAttempt()

            guard capability.health.failureCategory == category else {
                throw ContractFailure.unexpectedStorageHealth(String(describing: capability.health))
            }
            guard capability.health.statusMessage == "Storage unavailable: " + category.statusDescription,
                  !capability.health.statusMessage.contains("/Users/user") else {
                throw ContractFailure.storageStatusLeakedContent
            }
        }

        let fileManager = FileManager.default
        let root = symlinkSafeTemporaryDirectory(fileManager)
            .appendingPathComponent("oigo-issue86-root-identity-" + UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let rootFile = root.appendingPathComponent("root", isDirectory: false)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("root sentinel".utf8).write(to: rootFile)
        let fileFailure = try await bootstrapFailure(
            using: DurableSessionBootstrapper(rootDirectory: rootFile)
        )
        guard fileFailure.category == .rootIdentityViolation, fileFailure.isFatal else {
            throw ContractFailure.rootIdentityWasNotFatal
        }

        let symlinkTarget = root.appendingPathComponent("target", isDirectory: true)
        let symlinkRoot = root.appendingPathComponent("symlink-root", isDirectory: true)
        try fileManager.createDirectory(at: symlinkTarget, withIntermediateDirectories: true)
        let sentinel = symlinkTarget.appendingPathComponent("sentinel.txt")
        try Data("target sentinel".utf8).write(to: sentinel)
        try fileManager.createSymbolicLink(at: symlinkRoot, withDestinationURL: symlinkTarget)
        let symlinkFailure = try await bootstrapFailure(
            using: DurableSessionBootstrapper(rootDirectory: symlinkRoot)
        )
        guard symlinkFailure.category == .rootIdentityViolation, symlinkFailure.isFatal else {
            throw ContractFailure.rootIdentityWasNotFatal
        }
        guard try Data(contentsOf: sentinel) == Data("target sentinel".utf8) else {
            throw ContractFailure.rootRecoveryModifiedTarget
        }

        let historyRoot = root.appendingPathComponent("history-root", isDirectory: true)
        let historySecret = historyRoot.appendingPathComponent("private-transcript-content")
        let historyFailure = try await bootstrapFailure(
            using: DurableSessionBootstrapper(
                rootPreparation: { historyRoot },
                storeFactory: { try SessionStore(rootDirectory: $0) },
                recovery: { _ in 0 },
                historyEnumeration: { _ in
                    throw SessionStoreError.invalidMetadata(historySecret)
                }
            )
        )
        guard historyFailure.category == .metadataRecoveryFailure else {
            throw ContractFailure.historyFailureWasNotClassified
        }
        guard !historyFailure.description.contains("private-transcript-content"),
              historyFailure.diagnosticsExport()?.contains("private-transcript-content") == true else {
            throw ContractFailure.diagnosticsExportWasNotPreserved
        }
    }

    private static func malformedChildrenDoNotPoisonValidHistory() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("oigo-issue86-history-" + UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let store = try SessionStore(rootDirectory: root)
        let valid = try store.createSession(now: Date(timeIntervalSince1970: 100))
        let completed = try store.update(
            valid,
            state: .completed,
            at: Date(timeIntervalSince1970: 101)
        )
        let malformed = root.appendingPathComponent("malformed-child", isDirectory: true)
        try fileManager.createDirectory(at: malformed, withIntermediateDirectories: false)
        try Data("not session metadata".utf8)
            .write(to: malformed.appendingPathComponent("session.json"))

        let linked = root.appendingPathComponent("linked-child", isDirectory: true)
        try fileManager.createSymbolicLink(at: linked, withDestinationURL: completed.directoryURL)

        let report = try store.listHistoryReport()
        guard report.entries.count == 1,
              report.entries.first?.session.id == completed.id,
              report.malformedSessionCount == 2 else {
            throw ContractFailure.malformedChildIsolationFailed
        }
        guard try store.load(id: completed.id).metadata.state == .completed else {
            throw ContractFailure.validSessionWasChanged
        }
    }

    private static func retryCoalescesAndFencesStaleCompletions() async throws {
        let fileManager = FileManager.default
        let firstRoot = fileManager.temporaryDirectory
            .appendingPathComponent("oigo-issue86-retry-first-" + UUID().uuidString, isDirectory: true)
        let secondRoot = fileManager.temporaryDirectory
            .appendingPathComponent("oigo-issue86-retry-second-" + UUID().uuidString, isDirectory: true)
        defer {
            try? fileManager.removeItem(at: firstRoot)
            try? fileManager.removeItem(at: secondRoot)
        }

        let firstStore = try SessionStore(rootDirectory: firstRoot)
        let secondStore = try SessionStore(rootDirectory: secondRoot)
        let emptyReport = DurableSessionBootstrapReport(
            recoveredSessionCount: 0,
            historyEntryCount: 0,
            malformedSessionCount: 0
        )
        let firstResult = DurableSessionBootstrapResult(
            store: firstStore,
            history: [],
            report: emptyReport
        )
        let secondResult = DurableSessionBootstrapResult(
            store: secondStore,
            history: [],
            report: emptyReport
        )
        let bootstrapper = DeferredBootstrapper()
        let capability = DurableSessionCapability(bootstrapper: bootstrapper)

        guard capability.start() else {
            throw ContractFailure.retryDidNotStart
        }
        await bootstrapper.waitForRequest(1)
        guard !capability.retry() else {
            throw ContractFailure.retryWasNotCoalesced
        }

        capability.shutdown()
        guard capability.retry() else {
            throw ContractFailure.retryDidNotStart
        }
        await bootstrapper.waitForRequest(2)
        await bootstrapper.complete(request: 2, with: secondResult)
        await capability.waitForCurrentAttempt()
        guard capability.health.isReady, capability.store === secondStore else {
            throw ContractFailure.retryDidNotPublishLatestResult
        }

        await bootstrapper.complete(request: 1, with: firstResult)
        await bootstrapper.waitForReturn(1)
        for _ in 0..<4 {
            await Task.yield()
        }
        guard capability.health.isReady, capability.store === secondStore else {
            throw ContractFailure.staleRetryOverwroteLatestResult
        }

        capability.markUnhealthy(.permissionDenied)
        guard capability.retry() else {
            throw ContractFailure.retryDidNotStart
        }
        await bootstrapper.waitForRequest(3)
        await bootstrapper.complete(request: 3, with: secondResult)
        await capability.waitForCurrentAttempt()
        guard capability.health.isReady, capability.store === secondStore else {
            throw ContractFailure.retryDidNotRecover
        }
    }

    private static func relaunchPreservesExistingSessionData() async throws {
        let fileManager = FileManager.default
        let root = symlinkSafeTemporaryDirectory(fileManager)
            .appendingPathComponent("oigo-issue86-relaunch-" + UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let store = try SessionStore(rootDirectory: root)
        let session = try store.createSession(now: Date(timeIntervalSince1970: 200))
        let completed = try store.update(
            session,
            state: .completed,
            at: Date(timeIntervalSince1970: 201)
        )
        let unfinished = try store.createSession(now: Date(timeIntervalSince1970: 202))
        let bootstrapper = DurableSessionBootstrapper(rootDirectory: root)

        let firstCapability = DurableSessionCapability(bootstrapper: bootstrapper)
        firstCapability.start()
        await firstCapability.waitForCurrentAttempt()
        guard firstCapability.health.isReady else {
            throw ContractFailure.unexpectedStorageHealth(
                String(describing: firstCapability.health) + " at " + root.path
            )
        }
        guard firstCapability.history.contains(where: { $0.session.id == completed.id }),
              firstCapability.history.contains(where: { $0.session.id == unfinished.id }),
              case .ready(let report) = firstCapability.health,
              report.recoveredSessionCount == 1 else {
            throw ContractFailure.relaunchLostExistingHistory
        }
        guard try store.load(id: unfinished.id).metadata.state == .interrupted else {
            throw ContractFailure.relaunchDidNotRecoverUnfinishedSession
        }
        firstCapability.shutdown()

        let relaunchedCapability = DurableSessionCapability(bootstrapper: bootstrapper)
        relaunchedCapability.start()
        await relaunchedCapability.waitForCurrentAttempt()
        guard relaunchedCapability.health.isReady else {
            throw ContractFailure.unexpectedStorageHealth(
                String(describing: relaunchedCapability.health) + " at " + root.path
            )
        }
        guard relaunchedCapability.history.contains(where: { $0.session.id == completed.id }),
              relaunchedCapability.history.contains(where: { $0.session.id == unfinished.id }) else {
            throw ContractFailure.relaunchLostExistingHistory
        }
        guard try store.load(id: completed.id).metadata.state == .completed else {
            throw ContractFailure.relaunchResetExistingSession
        }
    }

    private static func bootstrapFailure(
        using bootstrapper: any DurableSessionBootstrapping
    ) async throws -> DurableSessionBootstrapFailure {
        do {
            _ = try await bootstrapper.bootstrap()
        } catch let failure as DurableSessionBootstrapFailure {
            return failure
        } catch {
            throw ContractFailure.unexpectedBootstrapError(String(describing: error))
        }
        throw ContractFailure.expectedBootstrapFailure
    }

    private static func symlinkSafeTemporaryDirectory(_ fileManager: FileManager) -> URL {
        fileManager.homeDirectoryForCurrentUser
    }
}

private actor FailingBootstrapper: DurableSessionBootstrapping {
    private let failure: DurableSessionBootstrapFailure

    init(failure: DurableSessionBootstrapFailure) {
        self.failure = failure
    }

    func bootstrap() async throws -> DurableSessionBootstrapResult {
        throw failure
    }

    func diagnosticsExport() -> String? {
        failure.diagnosticsExport()
    }
}

private actor HealthyBootstrapper: DurableSessionBootstrapping {
    private let result: DurableSessionBootstrapResult

    init(result: DurableSessionBootstrapResult) {
        self.result = result
    }

    func bootstrap() async throws -> DurableSessionBootstrapResult {
        result
    }
}

private actor DeferredBootstrapper: DurableSessionBootstrapping {
    private var requestCount = 0
    private var pending: [Int: CheckedContinuation<DurableSessionBootstrapResult, Error>] = [:]
    private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var returnedRequests: Set<Int> = []
    private var returnWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func bootstrap() async throws -> DurableSessionBootstrapResult {
        requestCount += 1
        let request = requestCount
        for (expected, continuation) in requestWaiters where request >= expected {
            continuation.resume()
        }
        requestWaiters.removeAll { request >= $0.0 }

        let result = try await withCheckedThrowingContinuation { continuation in
            pending[request] = continuation
        }
        returnedRequests.insert(request)
        for (expected, continuation) in returnWaiters where returnedRequests.contains(expected) {
            continuation.resume()
        }
        returnWaiters.removeAll { returnedRequests.contains($0.0) }
        return result
    }

    func waitForRequest(_ expected: Int) async {
        guard requestCount < expected else {
            return
        }
        await withCheckedContinuation { continuation in
            requestWaiters.append((expected, continuation))
        }
    }

    func complete(request: Int, with result: DurableSessionBootstrapResult) {
        pending.removeValue(forKey: request)?.resume(returning: result)
    }

    func waitForReturn(_ request: Int) async {
        guard !returnedRequests.contains(request) else {
            return
        }
        await withCheckedContinuation { continuation in
            returnWaiters.append((request, continuation))
        }
    }
}

private enum ContractFailure: Error, CustomStringConvertible {
    case expectedStorageToBeUnavailable
    case unexpectedStorageError(String)
    case unexpectedStorageHealth(String)
    case dictationDependencyWasReached
    case diagnosticsExportWasNotPreserved
    case unstableStorageMessage
    case healthyStoreWasNotPublished
    case healthyStoreWasNotPassedToGate
    case storageStatusLeakedContent
    case rootIdentityWasNotFatal
    case rootRecoveryModifiedTarget
    case historyFailureWasNotClassified
    case malformedChildIsolationFailed
    case validSessionWasChanged
    case retryDidNotStart
    case retryWasNotCoalesced
    case retryDidNotPublishLatestResult
    case staleRetryOverwroteLatestResult
    case retryDidNotRecover
    case relaunchLostExistingHistory
    case relaunchDidNotRecoverUnfinishedSession
    case relaunchResetExistingSession
    case expectedBootstrapFailure
    case unexpectedBootstrapError(String)

    var description: String {
        switch self {
        case .expectedStorageToBeUnavailable:
            "storage gate allowed an unhealthy dictation"
        case .unexpectedStorageError(let error):
            "unexpected storage error: " + error
        case .unexpectedStorageHealth(let health):
            "unexpected storage health: " + health
        case .dictationDependencyWasReached:
            "a recorder, transcriber, insertion, or start dependency was reached while storage was unhealthy"
        case .diagnosticsExportWasNotPreserved:
            "explicit diagnostics export did not preserve the local underlying error"
        case .unstableStorageMessage:
            "storage status message was not stable and content-free"
        case .healthyStoreWasNotPublished:
            "healthy bootstrap did not publish its store"
        case .healthyStoreWasNotPassedToGate:
            "healthy storage gate did not pass its store to the operation"
        case .storageStatusLeakedContent:
            "storage status exposed local content"
        case .rootIdentityWasNotFatal:
            "root identity violation was not fatal"
        case .rootRecoveryModifiedTarget:
            "root identity recovery modified a symlink target"
        case .historyFailureWasNotClassified:
            "history metadata failure was not classified as a metadata or recovery failure"
        case .malformedChildIsolationFailed:
            "a malformed child poisoned valid history or was followed"
        case .validSessionWasChanged:
            "valid history entry changed while isolating malformed children"
        case .retryDidNotStart:
            "storage retry did not start"
        case .retryWasNotCoalesced:
            "a concurrent storage retry was not coalesced"
        case .retryDidNotPublishLatestResult:
            "latest storage retry result was not published"
        case .staleRetryOverwroteLatestResult:
            "a stale storage retry completion overwrote the latest result"
        case .retryDidNotRecover:
            "explicit storage retry did not recover"
        case .relaunchLostExistingHistory:
            "relaunch did not preserve existing history"
        case .relaunchDidNotRecoverUnfinishedSession:
            "bootstrap did not recover the unfinished session before history enumeration"
        case .relaunchResetExistingSession:
            "relaunch reset existing session data"
        case .expectedBootstrapFailure:
            "bootstrap unexpectedly succeeded"
        case .unexpectedBootstrapError(let error):
            "unexpected bootstrap error: " + error
        }
    }
}
