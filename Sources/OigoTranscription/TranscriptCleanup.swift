import Foundation
import FoundationModels
import OigoCore
import os

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
    case unsafeOutput
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
        case .unsafeOutput:
            "cleanup changed protected transcript content"
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
public protocol TranscriptCleanupModel: Sendable {
    func generate(
        chunk: String,
        instructions: String
    ) async throws -> String
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
                let trimmedCleanedText = cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedCleanedText.isEmpty else {
                    return fallback(
                        rawText: rawText,
                        reason: .emptyOutput,
                        chunkCount: chunks.count
                    )
                }
                guard TranscriptCleanupOutputGuard.accepts(
                    rawText: chunk.text,
                    cleanedText: trimmedCleanedText
                ) else {
                    return fallback(
                        rawText: rawText,
                        reason: .unsafeOutput,
                        chunkCount: chunks.count
                    )
                }
                cleanedParts.append(trimmedCleanedText)
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
        guard TranscriptCleanupOutputGuard.accepts(
            rawText: rawText,
            cleanedText: cleanedText
        ) else {
            return fallback(rawText: rawText, reason: .unsafeOutput, chunkCount: chunks.count)
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
private enum TranscriptCleanupOutputGuard {
    private struct SemanticToken {
        let text: String
        let allowsCaseChange: Bool
    }

    private static let protectedPatterns = [
        "\"(?:\\\\.|[^\"])*\"",
        "https?://[^\\s]+",
        "(?<![A-Za-z0-9])/(?:[A-Za-z0-9._-]+/)+[A-Za-z0-9._-]+",
        "--[A-Za-z0-9][A-Za-z0-9-]*",
        "\\b\\d+(?:[.,]\\d+)*\\b",
        "\\b[A-Za-z0-9]+(?:_[A-Za-z0-9]+)+\\b",
        "\\b[A-Za-z][A-Za-z0-9_./-]*[0-9_./-][A-Za-z0-9_./-]*\\b",
        "\\b[A-Z][A-Za-z0-9_./-]*[A-Z][A-Za-z0-9_./-]*\\b",
        "\\b[A-Z][a-z][A-Za-z0-9_./-]+\\b"
    ]
    private static let removableFillers: Set<String> = ["ah", "er", "hmm", "mm", "uh", "um"]

    static func accepts(rawText: String, cleanedText: String) -> Bool {
        let rawTokens = semanticTokenSequence(in: rawText)
        let cleanedTokens = semanticTokenSequence(in: cleanedText)
        let cleanedTokensPreserved = isSubsequence(
            cleanedTokens,
            of: rawTokens,
            matching: { cleaned, raw in
                tokenMatches(raw: raw, cleaned: cleaned)
            }
        )
        let rawTokensPreserved = isSubsequence(
            rawTokens.filter { !removableFillers.contains($0.text.lowercased()) },
            of: cleanedTokens,
            matching: { raw, cleaned in
                tokenMatches(raw: raw, cleaned: cleaned)
            }
        )
        let punctuationPreserved = isCharacterSubsequence(
            punctuationSequence(in: rawText),
            of: punctuationSequence(in: cleanedText)
        )
        guard !cleanedTokens.isEmpty,
              cleanedTokensPreserved,
              rawTokensPreserved,
              punctuationPreserved else {
            return false
        }

        var searchStart = cleanedText.startIndex
        for token in protectedTokens(in: rawText) {
            guard let range = cleanedText.range(
                of: token,
                options: [.literal],
                range: searchStart..<cleanedText.endIndex
            ) else {
                return false
            }
            searchStart = range.upperBound
        }
        return true
    }

    private static func semanticTokenSequence(in text: String) -> [SemanticToken] {
        var tokens: [SemanticToken] = []
        var current = ""
        var allowsCaseChange = true
        var sentenceTokens: [String] = []
        var sentenceStart = true
        for character in text {
            if character.isLetter || character.isNumber || character == "_" {
                if current.isEmpty {
                    allowsCaseChange = sentenceStart
                        || sentenceTokens.allSatisfy {
                            removableFillers.contains($0.lowercased())
                        }
                }
                current.append(character)
                sentenceStart = false
            } else {
                if !current.isEmpty {
                    tokens.append(
                        SemanticToken(
                            text: current,
                            allowsCaseChange: allowsCaseChange
                        )
                    )
                    sentenceTokens.append(current)
                    current = ""
                }
                if ".!?\n".contains(character) {
                    sentenceStart = true
                    sentenceTokens.removeAll(keepingCapacity: true)
                }
            }
        }
        if !current.isEmpty {
            tokens.append(
                SemanticToken(
                    text: current,
                    allowsCaseChange: allowsCaseChange
                )
            )
        }
        return tokens
    }

    private static func isSubsequence(
        _ candidate: [SemanticToken],
        of source: [SemanticToken],
        matching: (SemanticToken, SemanticToken) -> Bool
    ) -> Bool {
        var sourceIndex = source.startIndex
        for candidateToken in candidate {
            guard let matchIndex = source[sourceIndex...].firstIndex(where: {
                matching(candidateToken, $0)
            }) else {
                return false
            }
            sourceIndex = source.index(after: matchIndex)
        }
        return true
    }

    private static func tokenMatches(raw: SemanticToken, cleaned: SemanticToken) -> Bool {
        guard raw.text.lowercased() == cleaned.text.lowercased() else {
            return false
        }
        let requiresExactCase = raw.text.contains(where: { $0.isUppercase || $0.isNumber })
            || raw.text.contains("_")
        return raw.text == cleaned.text || (!requiresExactCase && raw.allowsCaseChange)
    }

    private static func punctuationSequence(in text: String) -> [Character] {
        text.filter {
            !$0.isWhitespace && !$0.isLetter && !$0.isNumber && $0 != "_"
        }
    }

    private static func isCharacterSubsequence(
        _ candidate: [Character],
        of source: [Character]
    ) -> Bool {
        var sourceIndex = source.startIndex
        for character in candidate {
            guard let matchIndex = source[sourceIndex...].firstIndex(of: character) else {
                return false
            }
            sourceIndex = source.index(after: matchIndex)
        }
        return true
    }

    private static func protectedTokens(in text: String) -> [String] {
        let value = text as NSString
        let matches = protectedPatterns.flatMap { pattern -> [(NSRange, String)] in
            guard let expression = try? NSRegularExpression(pattern: pattern) else {
                return []
            }
            return expression.matches(
                in: text,
                range: NSRange(location: 0, length: value.length)
            ).map { match in
                (
                    match.range,
                    value.substring(with: match.range)
                        .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
                )
            }
        }
        var protected: [(location: Int, token: String)] = []
        var lastEnd = 0
        for match in matches.sorted(by: {
            if $0.0.location == $1.0.location {
                return $0.0.length > $1.0.length
            }
            return $0.0.location < $1.0.location
        }) {
            guard !match.1.isEmpty else {
                continue
            }
            guard match.0.location >= lastEnd else {
                continue
            }
            protected.append((location: match.0.location, token: match.1))
            lastEnd = NSMaxRange(match.0)
        }
        return protected.map(\.token)
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
                    append(
                        smallPiece.text,
                        separator: smallIndex == 0
                            ? sentenceSeparator
                            : smallPiece.separatorBefore
                    )
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
    ) -> [(text: String, separatorBefore: String)] {
        guard tokenEstimate(text) > maxTokenCount else {
            return [(text: text, separatorBefore: "")]
        }

        var pieces: [(text: String, separatorBefore: String)] = []
        var remaining = text
        var separatorBefore = ""
        while tokenEstimate(remaining) > maxTokenCount {
            var end = remaining.startIndex
            var bytes = 0
            var whitespaceRunStart: String.Index?
            var lastWhitespaceStart: String.Index?
            var lastWhitespaceEnd: String.Index?
            while end < remaining.endIndex {
                let next = remaining.index(after: end)
                let characterBytes = remaining[end..<next].utf8.count
                guard bytes + characterBytes <= maxInputBytes else {
                    break
                }
                bytes += characterBytes
                if remaining[end].isWhitespace {
                    if whitespaceRunStart == nil {
                        whitespaceRunStart = end
                    }
                    lastWhitespaceStart = whitespaceRunStart
                    lastWhitespaceEnd = next
                } else {
                    whitespaceRunStart = nil
                }
                end = next
            }
            if end == remaining.startIndex {
                end = remaining.index(after: remaining.startIndex)
            }
            let splitStart = lastWhitespaceStart ?? end
            let splitEnd = lastWhitespaceEnd ?? end
            pieces.append(
                (
                    text: String(remaining[..<splitStart]),
                    separatorBefore: separatorBefore
                )
            )
            separatorBefore = String(remaining[splitStart..<splitEnd])
            remaining = String(remaining[splitEnd...])
        }
        if !remaining.isEmpty {
            pieces.append((text: remaining, separatorBefore: separatorBefore))
        }
        return pieces
    }

    private static func tokenEstimate(_ text: String) -> Int {
        max(1, (text.utf8.count + 3) / 4)
    }
}

@available(macOS 26.0, *)
private enum TranscriptCleanupDeadline {
    static func run(
        deadlineNanoseconds: UInt64,
        cancel: @escaping @Sendable () -> Void,
        operation: @escaping @Sendable () async -> TranscriptCleanupGeneration
    ) async -> TranscriptCleanupGeneration {
        return await withTaskCancellationHandler(operation: {
            await withTaskGroup(of: TranscriptCleanupGeneration.self) { group in
                group.addTask {
                    await operation()
                }
                group.addTask {
                    let now = DispatchTime.now().uptimeNanoseconds
                    guard now < deadlineNanoseconds else {
                        cancel()
                        return .timedOut
                    }
                    do {
                        try await Task.sleep(nanoseconds: deadlineNanoseconds - now)
                        guard !Task.isCancelled else {
                            return .cancelled
                        }
                        cancel()
                        return .timedOut
                    } catch {
                        return .cancelled
                    }
                }
                let result = await group.next() ?? .cancelled
                group.cancelAll()
                return result
            }
        }, onCancel: {
            cancel()
        }
    )
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
private struct FoundationModelsSessionModel: TranscriptCleanupModel {
    func generate(
        chunk: String,
        instructions: String
    ) async throws -> String {
        let session = LanguageModelSession(
            model: .default,
            instructions: instructions
        )
        try Task.checkCancellation()
        let response = try await session.respond(to: chunk)
        try Task.checkCancellation()
        return response.content
    }
}

@available(macOS 26.0, *)
public final class FoundationModelsTranscriptCleaner: TranscriptCleaner, @unchecked Sendable {
    private let instrumentation: TranscriptCleanupInstrumentation
    private let model: any TranscriptCleanupModel
    private let availabilityProvider: @Sendable () -> TranscriptCleanupAvailability
    private let activeTaskLock = NSLock()
    private var activeTask: Task<TranscriptCleanupGeneration, Never>?
    private var cancelRequested = false

    public init(
        instrumentation: TranscriptCleanupInstrumentation = TranscriptCleanupSignposts(),
        model: (any TranscriptCleanupModel)? = nil,
        availabilityProvider: (@Sendable () -> TranscriptCleanupAvailability)? = nil
    ) {
        self.instrumentation = instrumentation
        self.model = model ?? FoundationModelsSessionModel()
        self.availabilityProvider = availabilityProvider ?? Self.runtimeAvailability
    }

    public func availability() -> TranscriptCleanupAvailability {
        availabilityProvider()
    }

    private static func runtimeAvailability() -> TranscriptCleanupAvailability {
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            return .unavailable(String(describing: model.availability))
        }
        return .available
    }

    public func cancel() {
        activeTaskLock.lock()
        cancelRequested = true
        let task = activeTask
        activeTaskLock.unlock()
        task?.cancel()
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

        let task = Task { [model] () -> TranscriptCleanupGeneration in
            do {
                try Task.checkCancellation()
                let output = try await model.generate(
                    chunk: chunk,
                    instructions: TranscriptCleanerInstruction.v1
                )
                try Task.checkCancellation()
                return .success(output)
            } catch is CancellationError {
                return .cancelled
            } catch {
                let description = String(describing: error).lowercased()
                if description.contains("context")
                    || description.contains("token")
                    || description.contains("window") {
                    return .contextOverflow
                }
                return .failed("model generation failed")
            }
        }
        let shouldCancel = begin(task)
        if shouldCancel {
            task.cancel()
        }
        defer {
            end(task)
            instrumentation.record(.resourceRelease)
        }
        return await withTaskCancellationHandler(operation: {
            await task.value
        }, onCancel: {
            task.cancel()
        })
    }

    private func begin(_ task: Task<TranscriptCleanupGeneration, Never>) -> Bool {
        activeTaskLock.lock()
        activeTask = task
        let shouldCancel = cancelRequested
        activeTaskLock.unlock()
        return shouldCancel
    }

    private func end(_ task: Task<TranscriptCleanupGeneration, Never>) {
        activeTaskLock.lock()
        activeTask = nil
        cancelRequested = false
        activeTaskLock.unlock()
    }
}
