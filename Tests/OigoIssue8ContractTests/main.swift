import Foundation
import CryptoKit
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
            try testWorkerRejectsMalformedRequestsWithoutOutput()
            print("GREEN: Foundation Models worker rejects malformed requests without transcript output")
            try await testCleanupFailuresFallBackToRaw()
            print("GREEN: Cleanup failures fall back to raw without partial output")
            try await testLongTranscriptChunksSequentiallyAtStableBoundaries()
            print("GREEN: Long transcripts chunk sequentially with order and paragraphs preserved")
            try await testContextOverflowResplitsOversizedChunks()
            print("GREEN: Context overflow re-splits oversized chunks sequentially")
            try await testAutomaticDeadlineCancelsSlowCleanup()
            print("GREEN: Automatic cleanup deadline cancels and releases slow generation")
            try await testDeadlineUsesCleanerCancellationHook()
            print("GREEN: Automatic cleanup deadline stops cancellation-resistant generation")
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
        let instructionData = Data(TranscriptCleanerInstruction.v1.utf8)
        let instructionDigest = SHA256.hash(data: instructionData)
            .map { String(format: "%02x", $0) }
            .joined()
        guard instructionDigest == "a3384f019de02d823305bd2c292b8d7e62dad8e0ed4dd3727a342a0249e4beea" else {
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

    private static func testWorkerRejectsMalformedRequestsWithoutOutput() throws {
        let testExecutable = URL(fileURLWithPath: CommandLine.arguments[0])
            .standardizedFileURL
        let workerExecutable = testExecutable
            .deletingLastPathComponent()
            .appendingPathComponent("Oigo")
        guard FileManager.default.isExecutableFile(atPath: workerExecutable.path) else {
            throw ContractFailure(message: "the native cleanup worker executable was not built")
        }
        let input = Pipe()
        let output = Pipe()
        let process = Process()
        process.executableURL = workerExecutable
        process.arguments = ["--oigo-transcript-cleanup-worker"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data("not-json".utf8))
        try input.fileHandleForWriting.close()
        let response = try output.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        guard process.terminationStatus != 0, response.isEmpty else {
            throw ContractFailure(message: "malformed worker input produced output or a successful exit")
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
        let recordedChunks = await recorder.values()
        let recordedSentenceNumbers = recordedChunks.flatMap(Self.sentenceNumbers)
        guard recordedChunks.count > 1,
              recordedChunks.allSatisfy({ TranscriptChunk(text: $0).estimatedTokenCount <= TranscriptChunker.maxTokenCount }),
              recordedSentenceNumbers == Array(1...280),
              decision.insertionSource == .clean,
              decision.cleanText == rawText,
              decision.cleanText?.contains("\n\n") == true else {
            throw ContractFailure(message: "long cleanup did not preserve sequential chunk order or paragraph boundaries")
        }
    }

    private static func testContextOverflowResplitsOversizedChunks() async throws {
        let rawText = (1...220)
            .map { "Sentence \($0) preserves /tmp/file-\($0).json and 42." }
            .joined(separator: " ")
        let recorder = ChunkRecorder()
        let coordinator = TranscriptCleanupCoordinator(
            cleanerFactory: { OverflowThenSuccessCleaner(recorder: recorder) }
        )
        let decision = await coordinator.resolve(
            mode: .clean,
            rawText: rawText,
            deadlineNanoseconds: 1_000_000_000
        )
        let recordedChunks = await recorder.values()
        guard let firstAttempt = recordedChunks.first,
              TranscriptChunk(text: firstAttempt).estimatedTokenCount > 1_000,
              recordedChunks.dropFirst().allSatisfy({
                  TranscriptChunk(text: $0).estimatedTokenCount <= 1_000
              }),
              recordedChunks.count >= 3,
              decision.insertionSource == .clean,
              decision.fallbackReason == nil,
              decision.cleanText == rawText else {
            throw ContractFailure(message: "context overflow did not re-split and complete the transcript")
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
              await cancellationRecorder.wasCancelledValue(),
              await cancellationRecorder.wasFinishedValue() else {
            throw ContractFailure(message: "deadline did not produce raw fallback and release the cancelled operation")
        }
    }

    private static func testDeadlineUsesCleanerCancellationHook() async throws {
        let box = CancellationHookBox()
        let coordinator = TranscriptCleanupCoordinator(
            cleanerFactory: { CancellationResistantCleaner(box: box) }
        )
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let decision = await coordinator.resolve(
            mode: .clean,
            rawText: "a cancellation-resistant transcript",
            deadlineNanoseconds: 5_000_000
        )
        let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - startedAt
        guard decision.insertionSource == .raw,
              decision.fallbackReason == .timeout,
              elapsedNanoseconds < 100_000_000,
              box.wasCancelled(),
              box.waitForFinished(timeout: 100_000_000) else {
            throw ContractFailure(message: "deadline did not stop a cancellation-resistant cleaner")
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
        let approvedOutputs = [
            "command-path-and-number": "Open the file /Users/douglas/projects/oigo/Package.swift and run swift test --filter OigoTests 42.",
            "url-identifier-and-product": "Please check Oigo monitor https://api.example.com/v1/monitors?id=42 for monitor_id abc_123.",
            "quoted-text-and-package-name": "Say the exact text \"deploy nice baas\", then edit package name NiceBaaS."
        ]
        let approvedMeanings = [
            "command-path-and-number": "Open the Oigo Package.swift file and run the named Swift test filter with the number 42.",
            "url-identifier-and-product": "Check the specified Oigo monitor URL and preserve its identifier values.",
            "quoted-text-and-package-name": "Say the quoted text exactly and edit the package name NiceBaaS."
        ]
        guard cases.count >= 3 else {
            throw ContractFailure(message: "cleanup evaluation corpus is too small to review")
        }
        for sample in cases {
            guard sample.reviewStatus == "approved",
                  approvedOutputs[sample.id] == sample.modelOutput,
                  approvedMeanings[sample.id] == sample.expectedMeaning,
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

    private static func sentenceNumbers(in text: String) -> [Int] {
        guard let expression = try? NSRegularExpression(pattern: "Sentence ([0-9]+)") else {
            return []
        }
        let value = text as NSString
        return expression.matches(
            in: text,
            range: NSRange(location: 0, length: value.length)
        ).compactMap { match in
            Int(value.substring(with: match.range(at: 1)))
        }
    }
}

private struct EvaluationCase: Codable {
    let id: String
    let rawTranscript: String
    let modelOutput: String
    let expectedMeaning: String
    let protectedTechnicalTokens: [String]
    let reviewStatus: String
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

    func cancel() {}

    func clean(
        chunk: String,
        deadlineNanoseconds: UInt64
    ) async -> TranscriptCleanupGeneration {
        _ = deadlineNanoseconds
        await recorder.record(chunk)
        return .success(chunk)
    }
}

private struct OverflowThenSuccessCleaner: TranscriptCleaner {
    let recorder: ChunkRecorder

    func availability() -> TranscriptCleanupAvailability {
        .available
    }

    func cancel() {}

    func clean(
        chunk: String,
        deadlineNanoseconds: UInt64
    ) async -> TranscriptCleanupGeneration {
        _ = deadlineNanoseconds
        await recorder.record(chunk)
        return TranscriptChunk(text: chunk).estimatedTokenCount > 1_000
            ? .contextOverflow
            : .success(chunk)
    }
}

private struct FixedResultCleaner: TranscriptCleaner, Sendable {
    let result: TranscriptCleanupGeneration

    func availability() -> TranscriptCleanupAvailability {
        .available
    }

    func cancel() {}

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

    func markFinished() {
        didFinish = true
    }

    func wasCancelledValue() -> Bool {
        wasCancelled
    }

    func wasFinishedValue() -> Bool {
        didFinish
    }

    private var didFinish = false
}

private struct SlowCleaner: TranscriptCleaner {
    let recorder: CancellationRecorder

    func availability() -> TranscriptCleanupAvailability {
        .available
    }

    func cancel() {}

    func clean(
        chunk: String,
        deadlineNanoseconds: UInt64
    ) async -> TranscriptCleanupGeneration {
        _ = chunk
        _ = deadlineNanoseconds
        do {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            await recorder.markFinished()
            return .success("unexpected completion")
        } catch {
            await recorder.markCancelled()
            await recorder.markFinished()
            return .cancelled
        }
    }
}

private final class CancellationHookBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var finished = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func wasCancelled() -> Bool {
        lock.lock()
        let result = cancelled
        lock.unlock()
        return result
    }

    func markFinished() {
        lock.lock()
        finished = true
        lock.unlock()
    }

    func waitForFinished(timeout: UInt64) -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeout
        while DispatchTime.now().uptimeNanoseconds < deadline {
            lock.lock()
            let result = finished
            lock.unlock()
            if result {
                return true
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return false
    }
}

private struct CancellationResistantCleaner: TranscriptCleaner {
    let box: CancellationHookBox

    func availability() -> TranscriptCleanupAvailability {
        .available
    }

    func cancel() {
        box.cancel()
    }

    func clean(
        chunk: String,
        deadlineNanoseconds: UInt64
    ) async -> TranscriptCleanupGeneration {
        _ = chunk
        _ = deadlineNanoseconds
        while !box.wasCancelled() {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        box.markFinished()
        return .cancelled
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
