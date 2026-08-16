import Foundation
import FoundationModels
import OigoCore
import os
import Darwin

@available(macOS 26.0, *)
public enum TranscriptCleanupMode: String, Codable, CaseIterable, Sendable {
    case instant
    case clean

    public var displayName: String {
        rawValue.capitalized
    }
}

@available(macOS 26.0, *)
public enum TranscriptCleanerInstruction {
    public static let v1 = """
Lightly clean the following speech transcript.

Correct punctuation, capitalization, and obvious speech-recognition errors.
Remove filler sounds and abandoned false starts only when unambiguous.
Do not summarize, add information, or change intent, tone, or detail.
Preserve commands, source code, URLs, filenames, paths, package names,
product names, identifiers, numbers, and quoted text exactly.
Return only the cleaned transcript.
"""
}

@available(macOS 26.0, *)
public enum TranscriptCleanupAvailability: Equatable, Sendable {
    case available
    case unavailable(String)
}

@available(macOS 26.0, *)
public enum TranscriptCleanupGeneration: Equatable, Sendable {
    case success(String)
    case unavailable(String)
    case timedOut
    case cancelled
    case contextOverflow
    case failed(String)
}

@available(macOS 26.0, *)
public enum TranscriptCleanupFallbackReason: Equatable, Sendable, CustomStringConvertible {
    case unavailable(String)
    case timeout
    case cancellation
    case contextOverflow
    case incompleteChunks
    case generationFailure(String)
    case emptyOutput
    case persistenceFailure(String)

    public var description: String {
        switch self {
        case .unavailable(let reason):
            "model unavailable: " + reason
        case .timeout:
            "automatic cleanup exceeded its deadline"
        case .cancellation:
            "automatic cleanup was cancelled"
        case .contextOverflow:
            "transcript could not fit safely in the model context"
        case .incompleteChunks:
            "automatic cleanup did not complete every transcript chunk"
        case .generationFailure(let reason):
            "cleanup generation failed: " + reason
        case .emptyOutput:
            "cleanup returned no transcript"
        case .persistenceFailure(let reason):
            "clean transcript could not be persisted: " + reason
        }
    }
}

@available(macOS 26.0, *)
public struct TranscriptCleanupDecision: Equatable, Sendable {
    public let rawText: String
    public let insertionText: String
    public let cleanText: String?
    public let insertionSource: TranscriptInsertionSource
    public let fallbackReason: TranscriptCleanupFallbackReason?
    public let chunkCount: Int

    public init(
        rawText: String,
        insertionText: String,
        cleanText: String?,
        insertionSource: TranscriptInsertionSource,
        fallbackReason: TranscriptCleanupFallbackReason? = nil,
        chunkCount: Int = 1
    ) {
        self.rawText = rawText
        self.insertionText = insertionText
        self.cleanText = cleanText
        self.insertionSource = insertionSource
        self.fallbackReason = fallbackReason
        self.chunkCount = max(1, chunkCount)
    }
}

@available(macOS 26.0, *)
public enum TranscriptCleanupEvent: String, Hashable, Sendable {
    case availability
    case cleanupStart
    case cleanupCompletion
    case timeout
    case fallback
    case resourceRelease
}

@available(macOS 26.0, *)
public protocol TranscriptCleanupInstrumentation: Sendable {
    func record(_ event: TranscriptCleanupEvent)
}

@available(macOS 26.0, *)
public struct NoopTranscriptCleanupInstrumentation: TranscriptCleanupInstrumentation {
    public init() {}

    public func record(_ event: TranscriptCleanupEvent) {
        _ = event
    }
}

@available(macOS 26.0, *)
public protocol TranscriptCleaner: Sendable {
    func availability() -> TranscriptCleanupAvailability

    func cancel()

    func clean(
        chunk: String,
        deadlineNanoseconds: UInt64
    ) async -> TranscriptCleanupGeneration
}

@available(macOS 26.0, *)
public final class TranscriptCleanupCoordinator: @unchecked Sendable {
    private let cleanerFactory: @Sendable () -> TranscriptCleaner
    private let instrumentation: TranscriptCleanupInstrumentation

    public init(
        cleanerFactory: @escaping @Sendable () -> TranscriptCleaner,
        instrumentation: TranscriptCleanupInstrumentation = NoopTranscriptCleanupInstrumentation()
    ) {
        self.cleanerFactory = cleanerFactory
        self.instrumentation = instrumentation
    }

    public func resolve(
        mode: TranscriptCleanupMode,
        rawText: String,
        deadlineNanoseconds: UInt64
    ) async -> TranscriptCleanupDecision {
        guard mode == .clean else {
            return TranscriptCleanupDecision(
                rawText: rawText,
                insertionText: rawText,
                cleanText: nil,
                insertionSource: .raw
            )
        }

        let cleaner = cleanerFactory()
        let availability = cleaner.availability()
        instrumentation.record(.availability)
        if case .unavailable(let reason) = availability {
            return fallback(
                rawText: rawText,
                reason: .unavailable(reason)
            )
        }

        instrumentation.record(.cleanupStart)
        var chunks = TranscriptChunker.split(rawText)
        let start = DispatchTime.now().uptimeNanoseconds
        let deadline = start.addingReportingOverflow(deadlineNanoseconds).partialValue
        var cleanedParts: [String] = []
        cleanedParts.reserveCapacity(chunks.count)

        var chunkIndex = 0
        while chunkIndex < chunks.count {
            let chunk = chunks[chunkIndex]
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else {
                instrumentation.record(.timeout)
                return fallback(rawText: rawText, reason: .timeout)
            }

            let generationResult = await TranscriptCleanupDeadline.run(
                deadlineNanoseconds: deadline,
                cancel: cleaner.cancel
            ) {
                await cleaner.clean(
                    chunk: chunk.text,
                    deadlineNanoseconds: deadline - now
                )
            }
            let generation: TranscriptCleanupGeneration = DispatchTime.now().uptimeNanoseconds < deadline
                ? generationResult
                : .timedOut
            switch generation {
            case .success(let cleanedText):
                guard !cleanedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return fallback(
                        rawText: rawText,
                        reason: .emptyOutput,
                        chunkCount: chunks.count
                    )
                }
                cleanedParts.append(cleanedText.trimmingCharacters(in: .whitespacesAndNewlines))
                chunkIndex += 1
            case .unavailable(let reason):
                return fallback(
                    rawText: rawText,
                    reason: .unavailable(reason),
                    chunkCount: chunks.count
                )
            case .timedOut:
                instrumentation.record(.timeout)
                return fallback(
                    rawText: rawText,
                    reason: .timeout,
                    chunkCount: chunks.count
                )
            case .cancelled:
                return fallback(
                    rawText: rawText,
                    reason: .cancellation,
                    chunkCount: chunks.count
                )
            case .contextOverflow:
                let smallerLimit = max(1, chunk.estimatedTokenCount / 2)
                let subdivisions = TranscriptChunker.split(
                    chunk.text,
                    maxTokenCount: smallerLimit,
                    separatorBefore: chunk.separatorBefore
                )
                guard subdivisions.count > 1 else {
                    return fallback(
                        rawText: rawText,
                        reason: .contextOverflow,
                        chunkCount: chunks.count
                    )
                }
                chunks.replaceSubrange(chunkIndex...chunkIndex, with: subdivisions)
            case .failed(let reason):
                return fallback(
                    rawText: rawText,
                    reason: .generationFailure(reason),
                    chunkCount: chunks.count
                )
            }
        }

        guard cleanedParts.count == chunks.count else {
            return fallback(rawText: rawText, reason: .incompleteChunks)
        }
        let cleanedText = zip(chunks, cleanedParts)
            .enumerated()
            .map { index, pair in
                index == 0 ? pair.1 : pair.0.separatorBefore + pair.1
            }
            .joined()
        guard !cleanedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallback(
                rawText: rawText,
                reason: .emptyOutput,
                chunkCount: chunks.count
            )
        }
        instrumentation.record(.cleanupCompletion)
        return TranscriptCleanupDecision(
            rawText: rawText,
            insertionText: cleanedText,
            cleanText: cleanedText,
            insertionSource: .clean,
            chunkCount: chunks.count
        )
    }

    private func fallback(
        rawText: String,
        reason: TranscriptCleanupFallbackReason,
        chunkCount: Int = 1
    ) -> TranscriptCleanupDecision {
        instrumentation.record(.fallback)
        return TranscriptCleanupDecision(
            rawText: rawText,
            insertionText: rawText,
            cleanText: nil,
            insertionSource: .raw,
            fallbackReason: reason,
            chunkCount: chunkCount
        )
    }
}

@available(macOS 26.0, *)
public struct TranscriptChunk: Equatable, Sendable {
    public let text: String
    public let separatorBefore: String

    public init(text: String, separatorBefore: String = "") {
        self.text = text
        self.separatorBefore = separatorBefore
    }

    public var estimatedTokenCount: Int {
        max(1, (text.utf8.count + 3) / 4)
    }
}

@available(macOS 26.0, *)
public enum TranscriptChunker {
    public static let targetTokenCount = 1_800
    public static let maxTokenCount = 2_000

    public static func split(
        _ text: String,
        maxTokenCount limit: Int? = nil,
        separatorBefore: String = ""
    ) -> [TranscriptChunk] {
        let chunkLimit = max(1, limit ?? Self.maxTokenCount)
        let maxInputBytes = chunkLimit * 4
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let paragraphs = normalized.components(separatedBy: "\n\n")
        var chunks: [TranscriptChunk] = []
        var currentText = ""
        var currentSeparator = ""

        func flush() {
            guard !currentText.isEmpty else {
                return
            }
            chunks.append(TranscriptChunk(
                text: currentText,
                separatorBefore: currentSeparator
            ))
            currentText = ""
            currentSeparator = ""
        }

        func append(_ piece: String, separator: String) {
            guard !piece.isEmpty else {
                return
            }
            let candidate = currentText.isEmpty
                ? piece
                : currentText + separator + piece
            if !currentText.isEmpty && tokenEstimate(candidate) > chunkLimit {
                flush()
                currentText = piece
                currentSeparator = separator
                return
            }
            if currentText.isEmpty {
                currentSeparator = separator
            }
            currentText = candidate
        }

        for (paragraphIndex, paragraph) in paragraphs.enumerated() {
            guard !paragraph.isEmpty else {
                continue
            }
            let paragraphSeparator = paragraphIndex == 0 && chunks.isEmpty && currentText.isEmpty
                ? separatorBefore
                : "\n\n"
            for (pieceIndex, piece) in sentencePieces(paragraph).enumerated() {
                let sentenceSeparator = pieceIndex == 0 ? paragraphSeparator : " "
                let pieces = splitOversized(
                    piece,
                    maxTokenCount: chunkLimit,
                    maxInputBytes: maxInputBytes
                )
                for (smallIndex, smallPiece) in pieces.enumerated() {
                    let separator: String
                    if smallIndex > 0 {
                        separator = ""
                    } else {
                        separator = sentenceSeparator
                    }
                    append(smallPiece, separator: separator)
                }
            }
        }

        flush()
        return chunks.isEmpty ? [TranscriptChunk(text: "")] : chunks
    }

    private static func sentencePieces(_ paragraph: String) -> [String] {
        var pieces: [String] = []
        var start = paragraph.startIndex
        var index = start
        while index < paragraph.endIndex {
            let character = paragraph[index]
            let next = paragraph.index(after: index)
            let isBoundary = ".!?".contains(character)
                && (next == paragraph.endIndex || paragraph[next].isWhitespace)
            if isBoundary {
                let piece = paragraph[start..<next]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty {
                    pieces.append(piece)
                }
                start = next
                while start < paragraph.endIndex,
                      paragraph[start].isWhitespace {
                    start = paragraph.index(after: start)
                }
            }
            index = next
        }
        let tail = paragraph[start...].trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            pieces.append(tail)
        }
        return pieces.isEmpty ? [paragraph] : pieces
    }

    private static func splitOversized(
        _ text: String,
        maxTokenCount: Int,
        maxInputBytes: Int
    ) -> [String] {
        guard tokenEstimate(text) > maxTokenCount else {
            return [text]
        }

        var pieces: [String] = []
        var remaining = text
        while tokenEstimate(remaining) > maxTokenCount {
            var end = remaining.startIndex
            var bytes = 0
            var lastWhitespaceEnd: String.Index?
            while end < remaining.endIndex {
                let next = remaining.index(after: end)
                let characterBytes = remaining[end..<next].utf8.count
                guard bytes + characterBytes <= maxInputBytes else {
                    break
                }
                bytes += characterBytes
                if remaining[end].isWhitespace {
                    lastWhitespaceEnd = next
                }
                end = next
            }
            if end == remaining.startIndex {
                end = remaining.index(after: remaining.startIndex)
            }
            let splitEnd = lastWhitespaceEnd ?? end
            pieces.append(String(remaining[..<splitEnd]))
            remaining = String(remaining[splitEnd...])
        }
        if !remaining.isEmpty {
            pieces.append(remaining)
        }
        return pieces
    }

    private static func tokenEstimate(_ text: String) -> Int {
        max(1, (text.utf8.count + 3) / 4)
    }
}

@available(macOS 26.0, *)
private final class TranscriptCleanupResolution: @unchecked Sendable {
    private let lock = NSLock()
    private let deadlineNanoseconds: UInt64
    private var continuation: CheckedContinuation<TranscriptCleanupGeneration, Never>?
    private var result: TranscriptCleanupGeneration?

    init(deadlineNanoseconds: UInt64) {
        self.deadlineNanoseconds = deadlineNanoseconds
    }

    func install(_ continuation: CheckedContinuation<TranscriptCleanupGeneration, Never>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(returning: result)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resolve(_ result: TranscriptCleanupGeneration) {
        let result = DispatchTime.now().uptimeNanoseconds < deadlineNanoseconds
            ? result
            : .timedOut
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        lock.unlock()
        continuation?.resume(returning: result)
    }
}

@available(macOS 26.0, *)
private enum TranscriptCleanupDeadline {
    static func run(
        deadlineNanoseconds: UInt64,
        cancel: @escaping @Sendable () -> Void,
        operation: @escaping @Sendable () async -> TranscriptCleanupGeneration
    ) async -> TranscriptCleanupGeneration {
        let resolution = TranscriptCleanupResolution(deadlineNanoseconds: deadlineNanoseconds)
        let responseTask = Task {
            resolution.resolve(await operation())
        }
        let timeoutTask = Task {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadlineNanoseconds else {
                cancel()
                responseTask.cancel()
                resolution.resolve(.timedOut)
                return
            }
            do {
                try await Task.sleep(nanoseconds: deadlineNanoseconds - now)
                cancel()
                responseTask.cancel()
                resolution.resolve(.timedOut)
            } catch {
            }
        }
        let result = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                resolution.install(continuation)
            }
        }, onCancel: {
            cancel()
            responseTask.cancel()
            timeoutTask.cancel()
            resolution.resolve(.cancelled)
        })
        responseTask.cancel()
        timeoutTask.cancel()
        return result
    }
}

@available(macOS 26.0, *)
public final class TranscriptCleanupSignposts: TranscriptCleanupInstrumentation, @unchecked Sendable {
    private let log = OSLog(subsystem: "com.oigo.app", category: "transcript-cleanup")

    public init() {}

    public func record(_ event: TranscriptCleanupEvent) {
        switch event {
        case .availability:
            os_signpost(.event, log: log, name: "cleanup-availability")
        case .cleanupStart:
            os_signpost(.event, log: log, name: "cleanup-start")
        case .cleanupCompletion:
            os_signpost(.event, log: log, name: "cleanup-completion")
        case .timeout:
            os_signpost(.event, log: log, name: "cleanup-timeout")
        case .fallback:
            os_signpost(.event, log: log, name: "cleanup-fallback")
        case .resourceRelease:
            os_signpost(.event, log: log, name: "cleanup-resource-release")
        }
    }
}

@available(macOS 26.0, *)
public struct TranscriptCleanupMetricSnapshot: Equatable, Sendable {
    public let availabilityCount: Int
    public let cleanupStartCount: Int
    public let cleanupCompletionCount: Int
    public let timeoutCount: Int
    public let fallbackCount: Int
    public let resourceReleaseCount: Int

    public init(
        availabilityCount: Int = 0,
        cleanupStartCount: Int = 0,
        cleanupCompletionCount: Int = 0,
        timeoutCount: Int = 0,
        fallbackCount: Int = 0,
        resourceReleaseCount: Int = 0
    ) {
        self.availabilityCount = availabilityCount
        self.cleanupStartCount = cleanupStartCount
        self.cleanupCompletionCount = cleanupCompletionCount
        self.timeoutCount = timeoutCount
        self.fallbackCount = fallbackCount
        self.resourceReleaseCount = resourceReleaseCount
    }
}

@available(macOS 26.0, *)
public final class TranscriptCleanupMetrics: TranscriptCleanupInstrumentation, @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [TranscriptCleanupEvent: Int] = [:]
    private let forwarding: TranscriptCleanupInstrumentation

    public init(
        forwarding: TranscriptCleanupInstrumentation = TranscriptCleanupSignposts()
    ) {
        self.forwarding = forwarding
    }

    public func record(_ event: TranscriptCleanupEvent) {
        lock.lock()
        counts[event, default: 0] += 1
        lock.unlock()
        forwarding.record(event)
    }

    public func snapshot() -> TranscriptCleanupMetricSnapshot {
        lock.lock()
        let snapshot = TranscriptCleanupMetricSnapshot(
            availabilityCount: counts[.availability, default: 0],
            cleanupStartCount: counts[.cleanupStart, default: 0],
            cleanupCompletionCount: counts[.cleanupCompletion, default: 0],
            timeoutCount: counts[.timeout, default: 0],
            fallbackCount: counts[.fallback, default: 0],
            resourceReleaseCount: counts[.resourceRelease, default: 0]
        )
        lock.unlock()
        return snapshot
    }
}

@available(macOS 26.0, *)
private struct TranscriptCleanupWorkerRequest: Codable {
    let chunk: String
}

@available(macOS 26.0, *)
private struct TranscriptCleanupWorkerResponse: Codable {
    let outcome: String
    let value: String?
}

@available(macOS 26.0, *)
private final class FoundationModelsWorkerProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelRequested = false

    func cancel() {
        lock.lock()
        cancelRequested = true
        let process = self.process
        lock.unlock()

        guard let process, process.isRunning else {
            return
        }
        process.terminate()
        let processIdentifier = process.processIdentifier
        if processIdentifier > 0 {
            _ = Darwin.kill(processIdentifier, SIGKILL)
        }
    }

    func run(
        executableURL: URL,
        requestData: Data
    ) -> TranscriptCleanupGeneration {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = ["--oigo-transcript-cleanup-worker"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        lock.lock()
        self.process = process
        let shouldCancel = cancelRequested
        lock.unlock()
        defer {
            lock.lock()
            self.process = nil
            lock.unlock()
        }

        do {
            try process.run()
            if shouldCancel || isCancelRequested() {
                cancel()
            }
            try input.fileHandleForWriting.write(contentsOf: requestData)
            try input.fileHandleForWriting.close()
            let responseData = try output.fileHandleForReading.readToEnd() ?? Data()
            process.waitUntilExit()
            if isCancelRequested() {
                return .cancelled
            }
            return Self.decode(responseData, terminationStatus: process.terminationStatus)
        } catch {
            cancel()
            return isCancelRequested()
                ? .cancelled
                : .failed("model cleanup worker failed")
        }
    }

    private func isCancelRequested() -> Bool {
        lock.lock()
        let requested = cancelRequested
        lock.unlock()
        return requested
    }

    private static func decode(
        _ data: Data,
        terminationStatus: Int32
    ) -> TranscriptCleanupGeneration {
        guard terminationStatus == 0,
              let response = try? JSONDecoder().decode(
                  TranscriptCleanupWorkerResponse.self,
                  from: data
              ) else {
            return .failed("model cleanup worker failed")
        }
        switch response.outcome {
        case "success":
            return .success(response.value ?? "")
        case "unavailable":
            return .unavailable(response.value ?? "model unavailable")
        case "cancelled":
            return .cancelled
        case "contextOverflow":
            return .contextOverflow
        default:
            return .failed(response.value ?? "model generation failed")
        }
    }
}

@available(macOS 26.0, *)
public enum FoundationModelsTranscriptWorker {
    public static func run() async -> Int32 {
        do {
            let requestData = FileHandle.standardInput.readDataToEndOfFile()
            let request = try JSONDecoder().decode(
                TranscriptCleanupWorkerRequest.self,
                from: requestData
            )
            let response = await generate(chunk: request.chunk)
            let responseData = try JSONEncoder().encode(response)
            try FileHandle.standardOutput.write(contentsOf: responseData)
            return 0
        } catch {
            return 1
        }
    }

    private static func generate(
        chunk: String
    ) async -> TranscriptCleanupWorkerResponse {
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            return TranscriptCleanupWorkerResponse(
                outcome: "unavailable",
                value: String(describing: model.availability)
            )
        }

        let session = LanguageModelSession(
            model: model,
            instructions: TranscriptCleanerInstruction.v1
        )
        do {
            try Task.checkCancellation()
            let response = try await session.respond(to: chunk)
            try Task.checkCancellation()
            return TranscriptCleanupWorkerResponse(
                outcome: "success",
                value: response.content
            )
        } catch is CancellationError {
            return TranscriptCleanupWorkerResponse(
                outcome: "cancelled",
                value: nil
            )
        } catch {
            let description = String(describing: error).lowercased()
            if description.contains("context")
                || description.contains("token")
                || description.contains("window") {
                return TranscriptCleanupWorkerResponse(
                    outcome: "contextOverflow",
                    value: nil
                )
            }
            return TranscriptCleanupWorkerResponse(
                outcome: "failed",
                value: "model generation failed"
            )
        }
    }
}

@available(macOS 26.0, *)
public final class FoundationModelsTranscriptCleaner: TranscriptCleaner, @unchecked Sendable {
    private let instrumentation: TranscriptCleanupInstrumentation
    private let workerExecutable: URL?
    private let activeWorkerLock = NSLock()
    private var activeWorker: FoundationModelsWorkerProcess?
    private var cancelRequested = false

    public init(
        instrumentation: TranscriptCleanupInstrumentation = TranscriptCleanupSignposts(),
        workerExecutable: URL? = Bundle.main.executableURL
    ) {
        self.instrumentation = instrumentation
        self.workerExecutable = workerExecutable
    }

    public func availability() -> TranscriptCleanupAvailability {
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            return .unavailable(String(describing: model.availability))
        }
        return .available
    }

    public func cancel() {
        activeWorkerLock.lock()
        cancelRequested = true
        let worker = activeWorker
        activeWorkerLock.unlock()
        worker?.cancel()
    }

    public func clean(
        chunk: String,
        deadlineNanoseconds: UInt64
    ) async -> TranscriptCleanupGeneration {
        _ = deadlineNanoseconds
        let currentAvailability = availability()
        guard case .available = currentAvailability else {
            if case .unavailable(let reason) = currentAvailability {
                return .unavailable(reason)
            }
            return .unavailable("model availability changed before cleanup")
        }

        guard let workerExecutable else {
            return .failed("cleanup worker executable unavailable")
        }
        guard let requestData = try? JSONEncoder().encode(
            TranscriptCleanupWorkerRequest(chunk: chunk)
        ) else {
            return .failed("cleanup request could not be encoded")
        }
        let worker = FoundationModelsWorkerProcess()
        let shouldCancel = begin(worker)
        if shouldCancel {
            worker.cancel()
        }
        defer {
            end(worker)
            instrumentation.record(.resourceRelease)
        }
        return await withTaskCancellationHandler(operation: {
            worker.run(
                executableURL: workerExecutable,
                requestData: requestData
            )
        }, onCancel: {
            worker.cancel()
        })
    }

    private func begin(_ worker: FoundationModelsWorkerProcess) -> Bool {
        activeWorkerLock.lock()
        activeWorker = worker
        let shouldCancel = cancelRequested
        activeWorkerLock.unlock()
        return shouldCancel
    }

    private func end(_ worker: FoundationModelsWorkerProcess) {
        activeWorkerLock.lock()
        if activeWorker === worker {
            activeWorker = nil
            cancelRequested = false
        }
        activeWorkerLock.unlock()
    }
}
