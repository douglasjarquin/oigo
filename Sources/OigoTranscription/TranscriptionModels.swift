import Foundation
import OigoCore

@available(macOS 26.0, *)
public enum SpeechAssetState: Equatable, Sendable, CustomStringConvertible {
    case unavailable(String)
    case installing(String)
    case failed(String)
    case ready(String)

    public var description: String {
        switch self {
        case .unavailable(let reason):
            return "unavailable: " + reason
        case .installing(let localeIdentifier):
            return "installing: " + localeIdentifier
        case .failed(let reason):
            return "failed: " + reason
        case .ready(let localeIdentifier):
            return "ready: " + localeIdentifier
        }
    }
}

@available(macOS 26.0, *)
public enum TranscriptionError: Error, Equatable, Sendable, CustomStringConvertible, DictationStartupFailureEvidence {
    case unsupportedLocale(String)
    case speechAssetsUnavailable(String)
    case speechAssetsInstalling(String)
    case speechAssetsFailed(String)
    case recognitionUnavailable(String)
    case malformedAudio(URL, String)
    case cancelled
    case timedOut(TranscriptionStage)
    case analysisFailed(String)
    case liveQueueSaturated
    case liveContinuationTerminated
    case liveConversionFailed
    case persistenceFailed(String)
    case notRunning
    case alreadyRunning
    case invalidCaptureFormat
    case invalidSessionState(DictationSessionState)

    public var isTimedOut: Bool {
        if case .timedOut = self {
            return true
        }
        return false
    }

    public var description: String {
        switch self {
        case .unsupportedLocale(let identifier):
            return "speech transcription does not support locale " + identifier
        case .speechAssetsUnavailable(let reason):
            return "speech assets are unavailable: " + reason
        case .speechAssetsInstalling(let identifier):
            return "speech assets are still installing for " + identifier
        case .speechAssetsFailed(let reason):
            return "speech asset installation failed: " + reason
        case .recognitionUnavailable(let reason):
            return "on-device speech recognition is unavailable: " + reason
        case .malformedAudio(let url, let reason):
            return "saved audio is malformed at " + url.path + ": " + reason
        case .cancelled:
            return "speech transcription was cancelled"
        case .timedOut(let stage):
            return "speech transcription timed out during " + stage.rawValue
        case .analysisFailed(let reason):
            return "speech analysis failed: " + reason
        case .liveQueueSaturated:
            return "speech analysis queue saturated"
        case .liveContinuationTerminated:
            return "speech analysis continuation terminated"
        case .liveConversionFailed:
            return "speech analysis conversion failed"
        case .persistenceFailed(let reason):
            return "canonical raw transcript could not be persisted: " + reason
        case .notRunning:
            return "speech transcription is not running"
        case .alreadyRunning:
            return "speech transcription is already running"
        case .invalidCaptureFormat:
            return "audio capture format is not compatible with on-device transcription"
        case .invalidSessionState(let state):
            return "saved-audio retry requires a failed, interrupted, or retrying session, not " + state.rawValue
        }
    }

    public var dictationStartupFailureReason: String {
        description
    }
}

@available(macOS 26.0, *)
public struct TranscriptionRange: Hashable, Sendable, Comparable {
    public let startMilliseconds: Int64
    public let endMilliseconds: Int64

    public init(startMilliseconds: Int64, endMilliseconds: Int64) {
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
    }

    public static func < (lhs: TranscriptionRange, rhs: TranscriptionRange) -> Bool {
        if lhs.startMilliseconds != rhs.startMilliseconds {
            return lhs.startMilliseconds < rhs.startMilliseconds
        }
        return lhs.endMilliseconds < rhs.endMilliseconds
    }

    fileprivate func overlaps(_ other: TranscriptionRange) -> Bool {
        if startMilliseconds == other.startMilliseconds && endMilliseconds == other.endMilliseconds {
            return true
        }
        return max(startMilliseconds, other.startMilliseconds) < min(endMilliseconds, other.endMilliseconds)
    }
}

@available(macOS 26.0, *)
public struct TranscriptionSnapshot: Equatable, Sendable {
    public let finalizedText: String
    public let volatileText: String
    public let displayedText: String

    public init(finalizedText: String, volatileText: String, displayedText: String) {
        self.finalizedText = finalizedText
        self.volatileText = volatileText
        self.displayedText = displayedText
    }
}

@available(macOS 26.0, *)
public struct TranscriptionAccumulator: Sendable {
    private struct Segment: Sendable {
        let range: TranscriptionRange
        let text: String
        let isComplete: Bool
    }

    private static let maxRevisionTailSegments = 8
    private static let maxRevisionTailCharacters = 4_096
    private static let maxPreviewCharacters = 512
    private var finalizedTail: [Segment] = []
    private var hasCompactedHistory = false
    private var volatile: Segment?

    public init() {}

    @discardableResult
    public mutating func ingest(
        range: TranscriptionRange,
        text: String,
        isFinal: Bool
    ) -> TranscriptionSnapshot {
        ingestAndReport(range: range, text: text, isFinal: isFinal).snapshot
    }

    @discardableResult
    @_spi(Testing)
    public
    mutating func ingestAndReport(
        range: TranscriptionRange,
        text: String,
        isFinal: Bool
    ) -> TranscriptIngestResult {
        if isFinal {
            let overlapping = finalizedTail.filter { $0.range.overlaps(range) }
            let finalization: TranscriptFinalization?
            if overlapping.isEmpty {
                guard range.startMilliseconds >= finalizedEndMilliseconds else {
                    return TranscriptIngestResult(snapshot: snapshot, finalization: nil)
                }
                let normalizedText = normalized(text)
                finalization = normalizedText.isEmpty ? nil : .append(normalizedText)
                finalizedTail.append(Segment(
                    range: range,
                    text: boundedText(normalizedText),
                    isComplete: normalizedText.count <= Self.maxRevisionTailCharacters
                ))
            } else {
                let existingText = join(overlapping.map(\.text))
                let mergedRange = TranscriptionRange(
                    startMilliseconds: min(
                        range.startMilliseconds,
                        overlapping.map { $0.range.startMilliseconds }.min() ?? range.startMilliseconds
                    ),
                    endMilliseconds: max(
                        range.endMilliseconds,
                        overlapping.map { $0.range.endMilliseconds }.max() ?? range.endMilliseconds
                    )
                )
                let canReplace = overlapping.allSatisfy(\.isComplete)
                    && range.endMilliseconds <= finalizedEndMilliseconds
                    && (!hasCompactedHistory
                        || range.startMilliseconds >= (finalizedTail.first?.range.startMilliseconds ?? range.startMilliseconds))
                let canAppend = range.endMilliseconds > finalizedEndMilliseconds
                    && (!hasCompactedHistory
                        || range.startMilliseconds >= (finalizedTail.first?.range.startMilliseconds ?? range.startMilliseconds))
                let canAppendWithoutTextOverlap = canAppend && overlapping.count == 1
                finalization = canonicalFinalization(
                    existing: existingText,
                    incoming: text,
                    canReplace: canReplace,
                    canAppend: canAppend,
                    canAppendWithoutTextOverlap: canAppendWithoutTextOverlap
                )
                if case .some = finalization {
                    finalizedTail.removeAll { $0.range.overlaps(range) }
                    let normalizedIncoming = normalized(text)
                    let merged: String
                    if canAppendWithoutTextOverlap,
                       wordOverlap(existing: existingText, incoming: normalizedIncoming) == 0 {
                        merged = join([existingText, normalizedIncoming])
                    } else {
                        merged = mergedText(existing: existingText, incoming: normalizedIncoming)
                    }
                    finalizedTail.append(Segment(
                        range: mergedRange,
                        text: boundedText(merged),
                        isComplete: merged.count <= Self.maxRevisionTailCharacters
                    ))
                }
            }
            if volatile?.range.overlaps(range) == true {
                volatile = nil
            }
            finalizedTail.sort { $0.range < $1.range }
            compactFinalizedTailIfNeeded()
            return TranscriptIngestResult(snapshot: snapshot, finalization: finalization)
        } else {
            volatile = Segment(
                range: range,
                text: String(text.prefix(Self.maxPreviewCharacters)),
                isComplete: false
            )
        }
        return TranscriptIngestResult(
            snapshot: snapshot,
            finalization: nil
        )
    }

    public var snapshot: TranscriptionSnapshot {
        let visibleFinalized = finalizedTail.filter { finalSegment in
            !(volatile.map { finalSegment.range.overlaps($0.range) } ?? false)
        }
        let orderedFinalized = visibleFinalized.sorted { $0.range < $1.range }
        let orderedVolatile = volatile.map { [$0] } ?? []
        return TranscriptionSnapshot(
            finalizedText: join(orderedFinalized.map { $0.text }),
            volatileText: join(orderedVolatile.map { $0.text }),
            displayedText: join(
                orderedFinalized.map { $0.text } + orderedVolatile.map { $0.text }
            )
        )
    }

    public mutating func reset() {
        finalizedTail.removeAll(keepingCapacity: true)
        hasCompactedHistory = false
        volatile = nil
    }

    private var finalizedEndMilliseconds: Int64 {
        finalizedTail.last?.range.endMilliseconds ?? 0
    }

    private mutating func compactFinalizedTailIfNeeded() {
        while finalizedTail.count > Self.maxRevisionTailSegments {
            finalizedTail.removeFirst()
            hasCompactedHistory = true
        }
    }

    private func mergedText(existing: String, incoming: String) -> String {
        let existing = normalized(existing)
        let incoming = normalized(incoming)
        guard !existing.isEmpty else {
            return incoming
        }
        guard !incoming.isEmpty else {
            return existing
        }
        if incoming.hasPrefix(existing) || existing.hasPrefix(incoming) {
            return incoming.count >= existing.count ? incoming : existing
        }
        let overlap = wordOverlap(existing: existing, incoming: incoming)
        if overlap > 0 {
            let incomingWords = incoming.split(whereSeparator: { $0.isWhitespace })
            return join([existing, incomingWords.dropFirst(overlap).joined(separator: " ")])
        }
        return incoming
    }

    private func canonicalFinalization(
        existing: String,
        incoming: String,
        canReplace: Bool,
        canAppend: Bool,
        canAppendWithoutTextOverlap: Bool
    ) -> TranscriptFinalization? {
        let existing = normalized(existing)
        let incoming = normalized(incoming)
        guard !incoming.isEmpty else {
            return nil
        }
        guard !existing.isEmpty else {
            return .append(incoming)
        }
        if incoming == existing || existing.hasPrefix(incoming) {
            return nil
        }
        if incoming.hasPrefix(existing) {
            return appendSuffix(String(incoming.dropFirst(existing.count)))
        }
        if canAppend {
            let overlap = wordOverlap(existing: existing, incoming: incoming)
            if overlap > 0 {
                let incomingWords = incoming.split(whereSeparator: { $0.isWhitespace })
                return appendSuffix(incomingWords.dropFirst(overlap).joined(separator: " "))
            }
            return canAppendWithoutTextOverlap ? .append(incoming) : nil
        }
        guard canReplace else {
            return nil
        }
        return .replace(existing: existing, replacement: mergedText(existing: existing, incoming: incoming))
    }

    private func appendSuffix(_ suffix: String) -> TranscriptFinalization? {
        let suffix = normalized(suffix)
        return suffix.isEmpty ? nil : .append(suffix)
    }

    private func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func boundedText(_ text: String) -> String {
        String(text.suffix(Self.maxRevisionTailCharacters))
    }

    private func wordOverlap(existing: String, incoming: String) -> Int {
        let existingWords = existing.split(whereSeparator: { $0.isWhitespace })
        let incomingWords = incoming.split(whereSeparator: { $0.isWhitespace })
        let maximum = min(existingWords.count, incomingWords.count)
        guard maximum > 0 else {
            return 0
        }
        for count in stride(from: maximum, through: 1, by: -1) {
            if existingWords.suffix(count).elementsEqual(incomingWords.prefix(count)) {
                return count
            }
        }
        return 0
    }

    private func join(_ texts: [String]) -> String {
        texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

@available(macOS 26.0, *)
@_spi(Testing)
public enum TranscriptFinalization: Sendable {
    case append(String)
    case replace(existing: String, replacement: String)

    public var emittedText: String {
        switch self {
        case .append(let text):
            return text
        case .replace(_, let replacement):
            return replacement
        }
    }
}

@available(macOS 26.0, *)
@_spi(Testing)
public struct TranscriptIngestResult: Sendable {
    public let snapshot: TranscriptionSnapshot
    public let finalization: TranscriptFinalization?
}
