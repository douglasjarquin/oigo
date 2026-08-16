import Foundation
import OigoCore
import OigoInsertion
import OigoTranscription

private struct ContractFailure: Error, CustomStringConvertible {
    let message: String

    var description: String {
        message
    }
}

@main
@MainActor
private struct OigoIssue8ContractTests {
    static func main() async {
        do {
            try await testInstantModeDoesNotInitializeCleaner()
            print("GREEN: Instant mode does not initialize Foundation Models")
            try await testFoundationModelsAdapterUsesFixedInstructionAndReportsAvailability()
            print("GREEN: Foundation Models adapter exposes the fixed instruction and availability reason")
            try await testCleanupFailuresFallBackToRaw()
            print("GREEN: Cleanup failures fall back to raw without partial output")
            try await testLongTranscriptChunksSequentiallyAtStableBoundaries()
            print("GREEN: Long transcripts chunk sequentially with order and paragraphs preserved")
            try await testAutomaticDeadlineCancelsSlowCleanup()
            print("GREEN: Automatic cleanup deadline cancels slow generation")
            try await testCleanupInstrumentationRecordsLifecycleMetrics()
            print("GREEN: Cleanup availability, start, completion, and fallback metrics are recorded")
            try testCleanPersistenceLeavesRawUntouchedAndRecordsInsertionSource()
            print("GREEN: clean.txt is separate from raw.txt and insertion source is durable")
            try testCleanInsertionReadsCleanText()
            print("GREEN: Automatic insertion can use clean.txt without touching raw.txt")
            try testApprovedEvaluationCorpusProtectsTechnicalTokens()
            print("GREEN: Approved evaluation corpus preserves protected technical tokens")
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

    private static func testFoundationModelsAdapterUsesFixedInstructionAndReportsAvailability() async throws {
        let expectedInstruction = """
Lightly clean the following speech transcript.

Correct punctuation, capitalization, and obvious speech-recognition errors.
Remove filler sounds and abandoned false starts only when unambiguous.
Do not summarize, add information, or change intent, tone, or detail.
Preserve commands, source code, URLs, filenames, paths, package names,
product names, identifiers, numbers, and quoted text exactly.
Return only the cleaned transcript.
"""
        guard TranscriptCleanerInstruction.v1 == expectedInstruction else {
            throw ContractFailure(message: "the v1 cleanup instruction changed")
        }

        let cleaner = FoundationModelsTranscriptCleaner()
        switch cleaner.availability() {
        case .available:
            break
        case .unavailable(let reason):
            guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ContractFailure(message: "model unavailability did not expose a reason")
            }
        }
    }

    private static func testCleanupFailuresFallBackToRaw() async throws {
        let rawText = "deploy oigo --config /tmp/oigo.yaml"
        let failures: [TranscriptCleanupGeneration] = [
            .unavailable("device policy"),
            .timedOut,
            .cancelled,
            .contextOverflow,
            .failed("generation error"),
            .success("   ")
        ]

        for failure in failures {
            let coordinator = TranscriptCleanupCoordinator(
                cleanerFactory: { FixedResultCleaner(result: failure) }
            )
            let decision = await coordinator.resolve(
                mode: .clean,
                rawText: rawText,
                deadlineNanoseconds: 100_000_000
            )
            guard decision.insertionText == rawText,
                  decision.insertionSource == .raw,
                  decision.cleanText == nil,
                  decision.fallbackReason != nil else {
                throw ContractFailure(message: "cleanup failure produced partial or non-raw insertion")
            }
        }
    }

    private static func testLongTranscriptChunksSequentiallyAtStableBoundaries() async throws {
        let paragraphs = [
            (1...140).map { "Sentence \($0) preserves /tmp/file-\($0).json and 42." }.joined(separator: " "),
            (141...280).map { "Sentence \($0) preserves https://example.com/item/\($0) and 99." }.joined(separator: " ")
        ]
        let rawText = paragraphs.joined(separator: "\n\n")
        let recorder = ChunkRecorder()
        let coordinator = TranscriptCleanupCoordinator(
            cleanerFactory: { RecordingCleaner(recorder: recorder) }
        )
        let decision = await coordinator.resolve(
            mode: .clean,
            rawText: rawText,
            deadlineNanoseconds: 1_000_000_000
        )
        let expectedChunks = TranscriptChunker.split(rawText)
        let recordedChunks = await recorder.values()
        guard expectedChunks.count > 1,
              recordedChunks == expectedChunks.map(\.text),
              recordedChunks.allSatisfy({ TranscriptChunk(text: $0).estimatedTokenCount <= TranscriptChunker.maxTokenCount }),
              decision.insertionSource == .clean,
              decision.cleanText?.contains("\n\n") == true else {
            throw ContractFailure(message: "long cleanup did not preserve sequential chunk order or paragraph boundaries")
        }
    }

    private static func testAutomaticDeadlineCancelsSlowCleanup() async throws {
        let cancellationRecorder = CancellationRecorder()
        let cleaner = SlowCleaner(recorder: cancellationRecorder)
        let coordinator = TranscriptCleanupCoordinator(
            cleanerFactory: { cleaner }
        )
        let rawText = "a deliberately slow transcript"
        let decision = await coordinator.resolve(
            mode: .clean,
            rawText: rawText,
            deadlineNanoseconds: 5_000_000
        )
        guard decision.insertionText == rawText,
              decision.fallbackReason == .timeout || decision.fallbackReason == .cancellation,
              await cancellationRecorder.wasCancelledValue() else {
            throw ContractFailure(message: "deadline did not produce raw fallback and cancellation")
        }
    }

    private static func testCleanupInstrumentationRecordsLifecycleMetrics() async throws {
        let metrics = TranscriptCleanupMetrics(forwarding: NoopTranscriptCleanupInstrumentation())
        let coordinator = TranscriptCleanupCoordinator(
            cleanerFactory: { FixedResultCleaner(result: .success("cleaned")) },
            instrumentation: metrics
        )
        _ = await coordinator.resolve(
            mode: .clean,
            rawText: "raw",
            deadlineNanoseconds: 100_000_000
        )
        let snapshot = metrics.snapshot()
        guard snapshot.availabilityCount == 1,
              snapshot.cleanupStartCount == 1,
              snapshot.cleanupCompletionCount == 1,
              snapshot.fallbackCount == 0 else {
            throw ContractFailure(message: "cleanup lifecycle metrics did not record the successful path")
        }

        let fallbackCoordinator = TranscriptCleanupCoordinator(
            cleanerFactory: { FixedResultCleaner(result: .timedOut) },
            instrumentation: metrics
        )
        _ = await fallbackCoordinator.resolve(
            mode: .clean,
            rawText: "raw",
            deadlineNanoseconds: 100_000_000
        )
        let fallbackSnapshot = metrics.snapshot()
        guard fallbackSnapshot.timeoutCount == 1,
              fallbackSnapshot.fallbackCount == 1 else {
            throw ContractFailure(message: "cleanup timeout and fallback metrics were not recorded")
        }
    }

    private static func testCleanPersistenceLeavesRawUntouchedAndRecordsInsertionSource() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue8-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootDirectory: root)
        let session = try store.createSession()
        let rawText = "raw command curl https://example.com/api 42"
        let persistedRaw = try store.persistRawText(rawText, for: session)
        let persistedClean = try store.persistCleanText("Raw command: curl https://example.com/api 42", for: persistedRaw)
        let recorded = try store.update(
            persistedClean,
            state: .completed,
            insertionOutcome: .pasted,
            insertionTextSource: .clean
        )
        let reloaded = try store.load(id: recorded.id)
        guard try store.readRawText(for: reloaded) == rawText,
              try store.readCleanText(for: reloaded) == "Raw command: curl https://example.com/api 42",
              reloaded.metadata.insertionTextSource == .clean,
              reloaded.metadata.cleanupFallbackReason == nil,
              FileManager.default.fileExists(atPath: reloaded.rawTextURL.path),
              FileManager.default.fileExists(atPath: reloaded.cleanTextURL.path) else {
            throw ContractFailure(message: "clean persistence changed raw text or lost insertion metadata")
        }
        let changedRaw = try store.persistRawText("changed raw", for: reloaded)
        guard try store.readRawText(for: changedRaw) == "changed raw",
              try store.readCleanText(for: changedRaw).isEmpty else {
            throw ContractFailure(message: "a raw transcript replacement left stale clean output available")
        }
        let fallbackSession = try store.update(
            changedRaw,
            state: .completed,
            insertionOutcome: .pasted,
            insertionTextSource: .raw,
            cleanupFallbackReason: "automatic cleanup exceeded its deadline"
        )
        guard fallbackSession.metadata.insertionTextSource == .raw,
              fallbackSession.metadata.cleanupFallbackReason?.contains("deadline") == true else {
            throw ContractFailure(message: "raw fallback source or reason was not durable")
        }
    }

    private static func testCleanInsertionReadsCleanText() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue8-insert-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootDirectory: root)
        let session = try store.createSession()
        let persistedRaw = try store.persistRawText("raw only", for: session)
        let persistedClean = try store.persistCleanText("clean only", for: persistedRaw)
        let snapshot = InsertionTargetSnapshot(
            frontmostProcessIdentifier: 7,
            bundleIdentifier: "com.example.target",
            focusedElementIdentifier: "field",
            role: "AXTextField",
            isSecureTextField: false
        )
        let pasteboard = ContractPasteboard()
        let service = InsertionService(
            targetEnvironment: ContractTargetEnvironment(snapshot: snapshot),
            pasteboard: pasteboard,
            eventSender: ContractEventSender()
        )
        let result = service.insertText(
            for: persistedClean,
            source: .clean,
            store: store,
            target: snapshot
        )
        guard result.outcome == .pasted,
              pasteboard.value == "clean only",
              try store.readRawText(for: persistedClean) == "raw only" else {
            throw ContractFailure(message: "clean insertion did not use the separate clean transcript")
        }
    }

    private static func testApprovedEvaluationCorpusProtectsTechnicalTokens() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/cleanup-corpus-v1.json")
        let cases = try JSONDecoder().decode([EvaluationCase].self, from: Data(contentsOf: url))
        guard cases.count >= 3 else {
            throw ContractFailure(message: "cleanup evaluation corpus is too small to review")
        }
        for sample in cases {
            guard sample.approved,
                  !sample.rawTranscript.isEmpty,
                  !sample.modelOutput.isEmpty,
                  !sample.expectedMeaning.isEmpty,
                  !sample.protectedTechnicalTokens.isEmpty else {
                throw ContractFailure(message: "evaluation corpus contains an unapproved or incomplete sample")
            }
            for token in sample.protectedTechnicalTokens {
                guard sample.rawTranscript.contains(token),
                      sample.modelOutput.contains(token) else {
                    throw ContractFailure(
                        message: "evaluation sample changed protected token: " + sample.id
                    )
                }
            }
        }
    }
}

private struct EvaluationCase: Codable {
    let id: String
    let rawTranscript: String
    let modelOutput: String
    let expectedMeaning: String
    let protectedTechnicalTokens: [String]
    let approved: Bool
}

private final class RecordingCleanerFactory: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var instantiationCount = 0

    func make() -> TranscriptCleaner {
        lock.lock()
        instantiationCount += 1
        lock.unlock()
        return FixedResultCleaner(result: .success("recording cleaner"))
    }
}

private actor ChunkRecorder {
    private var chunks: [String] = []

    func record(_ chunk: String) {
        chunks.append(chunk)
    }

    func values() -> [String] {
        chunks
    }
}

private struct RecordingCleaner: TranscriptCleaner {
    let recorder: ChunkRecorder

    func availability() -> TranscriptCleanupAvailability {
        .available
    }

    func clean(
        chunk: String,
        deadlineNanoseconds: UInt64
    ) async -> TranscriptCleanupGeneration {
        _ = deadlineNanoseconds
        await recorder.record(chunk)
        return .success(chunk)
    }
}

private struct FixedResultCleaner: TranscriptCleaner, Sendable {
    let result: TranscriptCleanupGeneration

    func availability() -> TranscriptCleanupAvailability {
        .available
    }

    func clean(
        chunk: String,
        deadlineNanoseconds: UInt64
    ) async -> TranscriptCleanupGeneration {
        _ = chunk
        _ = deadlineNanoseconds
        return result
    }
}

private actor CancellationRecorder {
    private var wasCancelled = false

    func markCancelled() {
        wasCancelled = true
    }

    func wasCancelledValue() -> Bool {
        wasCancelled
    }
}

private struct SlowCleaner: TranscriptCleaner {
    let recorder: CancellationRecorder

    func availability() -> TranscriptCleanupAvailability {
        .available
    }

    func clean(
        chunk: String,
        deadlineNanoseconds: UInt64
    ) async -> TranscriptCleanupGeneration {
        _ = chunk
        _ = deadlineNanoseconds
        do {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            return .success("unexpected completion")
        } catch {
            await recorder.markCancelled()
            return .cancelled
        }
    }
}

@MainActor
private final class ContractTargetEnvironment: InsertionTargetEnvironment {
    let snapshot: InsertionTargetSnapshot

    init(snapshot: InsertionTargetSnapshot) {
        self.snapshot = snapshot
    }

    func capture() -> InsertionTargetSnapshot {
        snapshot
    }

    func validate(_ snapshot: InsertionTargetSnapshot) -> TargetValidation {
        _ = snapshot
        return .safe
    }
}

@MainActor
private final class ContractPasteboard: InsertionPasteboard {
    private(set) var value: String?

    func write(_ rawText: String) -> Bool {
        value = rawText
        return true
    }
}

@MainActor
private final class ContractEventSender: InsertionEventSender {
    func sendPaste(
        to processIdentifier: Int32,
        revalidate: () -> TargetValidation
    ) -> InsertionEventResult {
        _ = processIdentifier
        return revalidate() == .safe ? .sent : .failed
    }
}
