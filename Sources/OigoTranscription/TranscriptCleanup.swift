import Foundation
import FoundationModels
@_spi(Testing) import OigoCore
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
    case priorGenerationBusy

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
        case .priorGenerationBusy:
            "prior cleanup still owns model resources"
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
    func recordTimeoutReturnLatency(nanoseconds: UInt64)
    func recordResourceReleaseLatency(nanoseconds: UInt64)
}

@available(macOS 26.0, *)
extension TranscriptCleanupInstrumentation {
    public func recordTimeoutReturnLatency(nanoseconds: UInt64) {
        _ = nanoseconds
    }

    public func recordResourceReleaseLatency(nanoseconds: UInt64) {
        _ = nanoseconds
    }
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
    private let faultInjector: DictationFaultInjector?
    private let lock = NSLock()
    private var currentGeneration: UInt64 = 0
    private var activeLifecycle: TranscriptCleanupLifecycle?

    public init(
        cleanerFactory: @escaping @Sendable () -> TranscriptCleaner,
        instrumentation: TranscriptCleanupInstrumentation = NoopTranscriptCleanupInstrumentation()
    ) {
        self.cleanerFactory = cleanerFactory
        self.instrumentation = instrumentation
        self.faultInjector = nil
    }

    @_spi(Testing)
    public init(
        cleanerFactory: @escaping @Sendable () -> TranscriptCleaner,
        instrumentation: TranscriptCleanupInstrumentation = NoopTranscriptCleanupInstrumentation(),
        faultInjector: DictationFaultInjector
    ) {
        self.cleanerFactory = cleanerFactory
        self.instrumentation = instrumentation
        self.faultInjector = faultInjector
    }

    public var isRetainingTimedOutGeneration: Bool {
        let lifecycle = withLock { activeLifecycle }
        guard let lifecycle else {
            return false
        }
        return lifecycle.wasInvalidated && lifecycle.holdsModelResources
    }

    public func waitForRetainedGenerationRelease() async {
        let lifecycle = withLock { activeLifecycle }
        await lifecycle?.waitForRelease()
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

        if isRetainingTimedOutGeneration {
            return fallback(rawText: rawText, reason: .priorGenerationBusy)
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

        guard let lifecycle = claimGeneration() else {
            return fallback(rawText: rawText, reason: .priorGenerationBusy)
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
            guard now < deadline, lifecycle.accepts(lifecycle.generation) else {
                return timeoutFallback(rawText: rawText, start: start, chunkCount: chunks.count)
            }

            let generationResult: TranscriptCleanupGeneration
            if faultInjector?.consume(.cleanupTimeout) == true {
                generationResult = .timedOut
            } else {
                generationResult = await TranscriptCleanupDeadline.run(
                    deadlineNanoseconds: deadline,
                    generation: lifecycle.generation,
                    lifecycle: lifecycle,
                    cancel: cleaner.cancel
                ) {
                    await cleaner.clean(
                        chunk: chunk.text,
                        deadlineNanoseconds: deadline - now
                    )
                }
            }
            guard lifecycle.accepts(lifecycle.generation) else {
                return timeoutFallback(rawText: rawText, start: start, chunkCount: chunks.count)
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
                return timeoutFallback(
                    rawText: rawText,
                    start: start,
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

    private func timeoutFallback(
        rawText: String,
        start: UInt64,
        chunkCount: Int
    ) -> TranscriptCleanupDecision {
        instrumentation.record(.timeout)
        instrumentation.recordTimeoutReturnLatency(
            nanoseconds: DispatchTime.now().uptimeNanoseconds &- start
        )
        return fallback(rawText: rawText, reason: .timeout, chunkCount: chunkCount)
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

    private func claimGeneration() -> TranscriptCleanupLifecycle? {
        withLock {
            if let activeLifecycle, activeLifecycle.holdsModelResources {
                return nil
            }
            currentGeneration &+= 1
            let lifecycle = TranscriptCleanupLifecycle(
                generation: currentGeneration,
                instrumentation: instrumentation
            )
            activeLifecycle = lifecycle
            return lifecycle
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

@available(macOS 26.0, *)
@_spi(Testing)
public enum TranscriptCleanupOutputGuard {
    public static let maxFalseStartTokens = 6
    public static let maxAbandonedExtraTokens = 2

    public static func substitutionBudget(ordinaryTokenCount: Int) -> Int {
        max(1, max(0, ordinaryTokenCount) / 50)
    }

    private struct SemanticToken {
        let text: String
        let utf16Location: Int
        let isProtected: Bool
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
    private static let canonicalTerms: Set<String> = ["oigo"]

    public static func accepts(rawText: String, cleanedText: String) -> Bool {
        let protectedSpans = protectedTokens(in: rawText)
        var searchStart = cleanedText.startIndex
        for token in protectedSpans {
            guard let range = cleanedText.range(
                of: token,
                options: [.literal],
                range: searchStart..<cleanedText.endIndex
            ) else {
                return false
            }
            searchStart = range.upperBound
        }

        let rawProtectedRanges = protectedRanges(in: rawText)
        let rawTokens = semanticTokenSequence(in: rawText, protectedRanges: rawProtectedRanges)
        let cleanedTokens = semanticTokenSequence(in: cleanedText, protectedRanges: [])
        guard !cleanedTokens.isEmpty else {
            return false
        }
        return aligns(raw: rawTokens, cleaned: cleanedTokens)
    }

    private static func aligns(raw: [SemanticToken], cleaned: [SemanticToken]) -> Bool {
        let ordinaryTokenCount = raw.filter(isOrdinaryWord).count
        let substitutionBudget = substitutionBudget(ordinaryTokenCount: ordinaryTokenCount)
        var rawIndex = 0
        var cleanedIndex = 0
        var substitutionsUsed = 0

        while rawIndex < raw.count || cleanedIndex < cleaned.count {
            if rawIndex < raw.count,
               isFiller(raw[rawIndex]),
               cleanedIndex >= cleaned.count || !tokensMatch(raw: raw[rawIndex], cleaned: cleaned[cleanedIndex]) {
                rawIndex += 1
                continue
            }

            if let skip = falseStartLength(raw: raw, rawIndex: rawIndex, cleaned: cleaned, cleanedIndex: cleanedIndex) {
                rawIndex += skip
                continue
            }

            if rawIndex < raw.count,
               cleanedIndex < cleaned.count,
               tokensMatch(raw: raw[rawIndex], cleaned: cleaned[cleanedIndex]) {
                rawIndex += 1
                cleanedIndex += 1
                continue
            }

            if rawIndex < raw.count,
               cleanedIndex < cleaned.count,
               isOrdinarySubstitutionCandidate(raw[rawIndex]),
               isOrdinarySubstitutionCandidate(cleaned[cleanedIndex]),
               !isCanonical(cleaned[cleanedIndex]),
               substitutionsUsed < substitutionBudget {
                substitutionsUsed += 1
                rawIndex += 1
                cleanedIndex += 1
                continue
            }

            return false
        }
        return true
    }

    private static func falseStartLength(
        raw: [SemanticToken],
        rawIndex: Int,
        cleaned: [SemanticToken],
        cleanedIndex: Int
    ) -> Int? {
        let remaining = raw.count - rawIndex
        guard remaining >= 2, cleanedIndex < cleaned.count else {
            return nil
        }

        let maxPrefix = min(maxFalseStartTokens, remaining / 2)
        for prefixLength in stride(from: maxPrefix, through: 1, by: -1) {
            let extraMax = min(maxAbandonedExtraTokens, remaining - (prefixLength * 2))
            for extra in 0...max(0, extraMax) {
                let skip = prefixLength + extra
                let restatementStart = rawIndex + skip
                let restatementEnd = restatementStart + prefixLength
                guard restatementEnd <= raw.count else {
                    continue
                }
                let abandoned = raw[rawIndex..<rawIndex + skip]
                guard abandoned.allSatisfy({ !$0.isProtected && !isCanonical($0) }) else {
                    continue
                }
                let prefix = raw[rawIndex..<rawIndex + prefixLength]
                let restatement = raw[restatementStart..<restatementEnd]
                guard tokensEqualIgnoringCase(prefix, restatement),
                      tokensMatch(raw: raw[restatementStart], cleaned: cleaned[cleanedIndex]),
                      (raw.count - restatementStart) >= (cleaned.count - cleanedIndex) else {
                    continue
                }
                return skip
            }
        }
        return nil
    }

    private static func tokensMatch(raw: SemanticToken, cleaned: SemanticToken) -> Bool {
        if raw.isProtected || isCanonical(raw) || isCanonical(cleaned) {
            return raw.text == cleaned.text
        }
        guard raw.text.lowercased() == cleaned.text.lowercased() else {
            return false
        }
        if requiresExactCase(raw) {
            return raw.text == cleaned.text
        }
        return true
    }

    private static func tokensEqualIgnoringCase(
        _ lhs: ArraySlice<SemanticToken>,
        _ rhs: ArraySlice<SemanticToken>
    ) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }
        return zip(lhs, rhs).allSatisfy { $0.text.lowercased() == $1.text.lowercased() }
    }

    private static func isFiller(_ token: SemanticToken) -> Bool {
        !token.isProtected && removableFillers.contains(token.text.lowercased())
    }

    private static func isCanonical(_ token: SemanticToken) -> Bool {
        canonicalTerms.contains(token.text.lowercased())
    }

    private static func requiresExactCase(_ token: SemanticToken) -> Bool {
        token.text.contains(where: { $0.isUppercase || $0.isNumber })
            || token.text.contains("_")
            || isCanonical(token)
    }

    private static func isOrdinaryWord(_ token: SemanticToken) -> Bool {
        !token.isProtected
            && !isFiller(token)
            && !isCanonical(token)
            && token.text.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) }
    }

    private static func isOrdinarySubstitutionCandidate(_ token: SemanticToken) -> Bool {
        isOrdinaryWord(token)
            && token.text.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz").contains($0) }
    }

    private static func semanticTokenSequence(
        in text: String,
        protectedRanges: [NSRange]
    ) -> [SemanticToken] {
        var tokens: [SemanticToken] = []
        var current = ""
        var currentLocation = 0
        var utf16Location = 0
        for character in text {
            let characterUTF16 = character.utf16.count
            if character.isLetter || character.isNumber || character == "_" {
                if current.isEmpty {
                    currentLocation = utf16Location
                }
                current.append(character)
            } else if !current.isEmpty {
                tokens.append(
                    makeToken(
                        text: current,
                        utf16Location: currentLocation,
                        protectedRanges: protectedRanges
                    )
                )
                current = ""
            }
            utf16Location += characterUTF16
        }
        if !current.isEmpty {
            tokens.append(
                makeToken(
                    text: current,
                    utf16Location: currentLocation,
                    protectedRanges: protectedRanges
                )
            )
        }
        return tokens
    }

    private static func makeToken(
        text: String,
        utf16Location: Int,
        protectedRanges: [NSRange]
    ) -> SemanticToken {
        let range = NSRange(location: utf16Location, length: (text as NSString).length)
        let isProtected = protectedRanges.contains { NSIntersectionRange($0, range).length > 0 }
        return SemanticToken(text: text, utf16Location: utf16Location, isProtected: isProtected)
    }

    private static func protectedTokens(in text: String) -> [String] {
        protectedMatches(in: text).map(\.token)
    }

    private static func protectedRanges(in text: String) -> [NSRange] {
        protectedMatches(in: text).map(\.range)
    }

    private static func protectedMatches(in text: String) -> [(range: NSRange, token: String)] {
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
        var protected: [(range: NSRange, token: String)] = []
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
            protected.append((range: match.0, token: match.1))
            lastEnd = NSMaxRange(match.0)
        }
        return protected
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
private final class TranscriptCleanupRace: @unchecked Sendable {
    private let lock = NSLock()
    private var result: TranscriptCleanupGeneration?
    private var continuation: CheckedContinuation<TranscriptCleanupGeneration, Never>?

    func install(_ continuation: CheckedContinuation<TranscriptCleanupGeneration, Never>) {
        let existing: TranscriptCleanupGeneration? = withLock {
            if let result {
                return result
            }
            self.continuation = continuation
            return nil
        }
        if let existing {
            continuation.resume(returning: existing)
        }
    }

    func complete(_ result: TranscriptCleanupGeneration) -> Bool {
        let won: Bool
        let continuation: CheckedContinuation<TranscriptCleanupGeneration, Never>?
        (won, continuation) = withLock {
            guard self.result == nil else {
                return (false, nil)
            }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            return (true, continuation)
        }
        continuation?.resume(returning: result)
        return won
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

@available(macOS 26.0, *)
private final class TranscriptCleanupLifecycle: @unchecked Sendable {
    let generation: UInt64
    private let lock = NSLock()
    private var valid = true
    private var released = false
    private var attachToken: UInt64 = 0
    private var task: Task<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var timeoutAt: UInt64?
    private let instrumentation: TranscriptCleanupInstrumentation

    init(
        generation: UInt64,
        instrumentation: TranscriptCleanupInstrumentation
    ) {
        self.generation = generation
        self.instrumentation = instrumentation
    }

    var holdsModelResources: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !released
    }

    var wasInvalidated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !valid
    }

    func beginHold() -> UInt64 {
        lock.lock()
        attachToken &+= 1
        released = false
        let token = attachToken
        lock.unlock()
        return token
    }

    func attach(_ task: Task<Void, Never>, token: UInt64) {
        lock.lock()
        if token == attachToken {
            self.task = task
            released = false
        }
        lock.unlock()
    }

    func accepts(_ generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return valid && self.generation == generation
    }

    func invalidate() {
        lock.lock()
        valid = false
        if timeoutAt == nil {
            timeoutAt = DispatchTime.now().uptimeNanoseconds
        }
        lock.unlock()
    }

    func markReleased(token: UInt64) {
        let timeoutAt: UInt64?
        let waiters: [CheckedContinuation<Void, Never>]
        lock.lock()
        guard token == attachToken, !released else {
            lock.unlock()
            return
        }
        released = true
        timeoutAt = self.timeoutAt
        waiters = self.waiters
        self.waiters.removeAll(keepingCapacity: true)
        lock.unlock()
        if let timeoutAt {
            let elapsed = DispatchTime.now().uptimeNanoseconds &- timeoutAt
            instrumentation.record(.resourceRelease)
            instrumentation.recordResourceReleaseLatency(nanoseconds: elapsed)
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitForRelease() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if released {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }
}

@available(macOS 26.0, *)
private enum TranscriptCleanupDeadline {
    static func run(
        deadlineNanoseconds: UInt64,
        generation: UInt64,
        lifecycle: TranscriptCleanupLifecycle,
        cancel: @escaping @Sendable () -> Void,
        operation: @escaping @Sendable () async -> TranscriptCleanupGeneration
    ) async -> TranscriptCleanupGeneration {
        let race = TranscriptCleanupRace()
        let holdToken = lifecycle.beginHold()
        let operationTask = Task<Void, Never> {
            let result = await operation()
            if lifecycle.accepts(generation) {
                _ = race.complete(result)
            }
            lifecycle.markReleased(token: holdToken)
        }
        lifecycle.attach(operationTask, token: holdToken)

        let timeoutTask = Task<Void, Never> {
            let now = DispatchTime.now().uptimeNanoseconds
            if now < deadlineNanoseconds {
                do {
                    try await Task.sleep(nanoseconds: deadlineNanoseconds - now)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else {
                return
            }
            if race.complete(.timedOut) {
                cancel()
                lifecycle.invalidate()
                operationTask.cancel()
            }
        }

        let result = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                race.install(continuation)
            }
        }, onCancel: {
            if race.complete(.cancelled) {
                cancel()
                lifecycle.invalidate()
                operationTask.cancel()
                timeoutTask.cancel()
            }
        })

        timeoutTask.cancel()
        if case .timedOut = result {
            cancel()
            lifecycle.invalidate()
            operationTask.cancel()
        } else if case .cancelled = result {
            cancel()
            lifecycle.invalidate()
            operationTask.cancel()
        } else {
            lifecycle.markReleased(token: holdToken)
        }
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
    public let timeoutReturnLatencyNanoseconds: [UInt64]
    public let resourceReleaseLatencyNanoseconds: [UInt64]

    public init(
        availabilityCount: Int = 0,
        cleanupStartCount: Int = 0,
        cleanupCompletionCount: Int = 0,
        timeoutCount: Int = 0,
        fallbackCount: Int = 0,
        resourceReleaseCount: Int = 0,
        timeoutReturnLatencyNanoseconds: [UInt64] = [],
        resourceReleaseLatencyNanoseconds: [UInt64] = []
    ) {
        self.availabilityCount = availabilityCount
        self.cleanupStartCount = cleanupStartCount
        self.cleanupCompletionCount = cleanupCompletionCount
        self.timeoutCount = timeoutCount
        self.fallbackCount = fallbackCount
        self.resourceReleaseCount = resourceReleaseCount
        self.timeoutReturnLatencyNanoseconds = timeoutReturnLatencyNanoseconds
        self.resourceReleaseLatencyNanoseconds = resourceReleaseLatencyNanoseconds
    }
}

@available(macOS 26.0, *)
public final class TranscriptCleanupMetrics: TranscriptCleanupInstrumentation, @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [TranscriptCleanupEvent: Int] = [:]
    private var timeoutReturnLatencyNanoseconds: [UInt64] = []
    private var resourceReleaseLatencyNanoseconds: [UInt64] = []
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

    public func recordTimeoutReturnLatency(nanoseconds: UInt64) {
        lock.lock()
        timeoutReturnLatencyNanoseconds.append(nanoseconds)
        lock.unlock()
        forwarding.recordTimeoutReturnLatency(nanoseconds: nanoseconds)
    }

    public func recordResourceReleaseLatency(nanoseconds: UInt64) {
        lock.lock()
        resourceReleaseLatencyNanoseconds.append(nanoseconds)
        lock.unlock()
        forwarding.recordResourceReleaseLatency(nanoseconds: nanoseconds)
    }

    public func snapshot() -> TranscriptCleanupMetricSnapshot {
        lock.lock()
        let snapshot = TranscriptCleanupMetricSnapshot(
            availabilityCount: counts[.availability, default: 0],
            cleanupStartCount: counts[.cleanupStart, default: 0],
            cleanupCompletionCount: counts[.cleanupCompletion, default: 0],
            timeoutCount: counts[.timeout, default: 0],
            fallbackCount: counts[.fallback, default: 0],
            resourceReleaseCount: counts[.resourceRelease, default: 0],
            timeoutReturnLatencyNanoseconds: timeoutReturnLatencyNanoseconds,
            resourceReleaseLatencyNanoseconds: resourceReleaseLatencyNanoseconds
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

@available(macOS 26.0, *)
public struct DictionaryTranscriptFinalizerResult: Equatable, Sendable {
    public let session: DictationSession
    public let decision: TranscriptCleanupDecision

    public init(session: DictationSession, decision: TranscriptCleanupDecision) {
        self.session = session
        self.decision = decision
    }
}

@available(macOS 26.0, *)
public enum DictionaryTranscriptFinalizer {
    public static func resolve(
        mode: TranscriptCleanupMode,
        session: DictationSession,
        store: SessionStore,
        snapshot: CompiledDictionarySnapshot,
        cleanup: TranscriptCleanupCoordinator,
        deadlineNanoseconds: UInt64
    ) async throws -> DictionaryTranscriptFinalizerResult {
        let rawText = try store.readRawText(for: session)
        let normalizer = TerminologyNormalizer(snapshot: snapshot)
        let normalizedText = normalizer.normalize(rawText)
        let persisted = try store.persistNormalizedText(normalizedText, for: session)
        guard mode == .clean else {
            return DictionaryTranscriptFinalizerResult(
                session: persisted,
                decision: TranscriptCleanupDecision(
                    rawText: rawText,
                    insertionText: normalizedText,
                    cleanText: nil,
                    insertionSource: .normalized
                )
            )
        }
        let decision = await cleanup.resolve(
            mode: .clean,
            rawText: normalizedText,
            deadlineNanoseconds: deadlineNanoseconds
        )
        try Task.checkCancellation()
        if let cleanText = decision.cleanText {
            let renormalized = normalizer.normalize(cleanText)
            do {
                let cleaned = try store.persistCleanText(renormalized, for: persisted)
                return DictionaryTranscriptFinalizerResult(
                    session: cleaned,
                    decision: TranscriptCleanupDecision(
                        rawText: rawText,
                        insertionText: renormalized,
                        cleanText: renormalized,
                        insertionSource: .clean,
                        chunkCount: decision.chunkCount
                    )
                )
            } catch {
                return DictionaryTranscriptFinalizerResult(
                    session: persisted,
                    decision: TranscriptCleanupDecision(
                        rawText: rawText,
                        insertionText: normalizedText,
                        cleanText: nil,
                        insertionSource: .normalized,
                        fallbackReason: .persistenceFailure(String(describing: error)),
                        chunkCount: decision.chunkCount
                    )
                )
            }
        }
        return DictionaryTranscriptFinalizerResult(
            session: persisted,
            decision: TranscriptCleanupDecision(
                rawText: rawText,
                insertionText: normalizedText,
                cleanText: nil,
                insertionSource: .normalized,
                fallbackReason: decision.fallbackReason,
                chunkCount: decision.chunkCount
            )
        )
    }

    public static func reapply(
        session: DictationSession,
        store: SessionStore,
        snapshot: CompiledDictionarySnapshot,
        cleanup: TranscriptCleanupCoordinator,
        deadlineNanoseconds: UInt64
    ) async throws -> DictionaryTranscriptFinalizerResult {
        let hadClean = FileManager.default.fileExists(atPath: session.cleanTextURL.path)
        guard hadClean else {
            return try await resolve(
                mode: .instant,
                session: session,
                store: store,
                snapshot: snapshot,
                cleanup: cleanup,
                deadlineNanoseconds: deadlineNanoseconds
            )
        }
        return try await resolve(
            mode: .clean,
            session: session,
            store: store,
            snapshot: snapshot,
            cleanup: cleanup,
            deadlineNanoseconds: deadlineNanoseconds
        )
    }
}
