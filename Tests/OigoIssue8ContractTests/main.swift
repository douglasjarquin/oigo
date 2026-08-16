import Foundation
@_spi(Testing) import OigoTranscription

private struct ContractFailure: Error, CustomStringConvertible {
    let message: String

    var description: String {
        message
    }
}

@main
private struct OigoIssue8ContractTests {
    static func main() async {
        do {
            try await testInstantModeDoesNotInitializeCleaner()
            print("GREEN: Instant mode does not initialize Foundation Models")
            exit(0)
        } catch {
            print("FAIL: Instant mode does not initialize Foundation Models: " + String(describing: error))
            exit(1)
        }
    }

    private static func testInstantModeDoesNotInitializeCleaner() async throws {
        let factory = RecordingCleanerFactory()
        let coordinator = TranscriptCleanupCoordinator(cleanerFactory: factory.make)
        let decision = await coordinator.resolve(
            mode: .instant,
            rawText: "raw transcript",
            deadlineNanoseconds: 1_000_000
        )

        guard decision.insertionText == "raw transcript",
              decision.insertionSource == .raw,
              decision.cleanText == nil,
              factory.instantiationCount == 0 else {
            throw ContractFailure(message: "Instant mode initialized cleanup or changed the raw transcript")
        }
    }
}

private final class RecordingCleanerFactory: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var instantiationCount = 0

    func make() -> TranscriptCleaner {
        lock.lock()
        instantiationCount += 1
        lock.unlock()
        return RecordingCleaner()
    }
}

private final class RecordingCleaner: TranscriptCleaner, @unchecked Sendable {
    func availability() -> TranscriptCleanupAvailability {
        .available
    }

    func clean(
        rawText: String,
        deadlineNanoseconds: UInt64
    ) async -> TranscriptCleanupGeneration {
        _ = deadlineNanoseconds
        return .success(rawText)
    }
}
