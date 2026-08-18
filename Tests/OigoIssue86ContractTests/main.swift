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

private enum ContractFailure: Error, CustomStringConvertible {
    case expectedStorageToBeUnavailable
    case unexpectedStorageError(String)
    case unexpectedStorageHealth(String)
    case dictationDependencyWasReached
    case diagnosticsExportWasNotPreserved
    case unstableStorageMessage
    case healthyStoreWasNotPublished
    case healthyStoreWasNotPassedToGate

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
        }
    }
}
