import Foundation
import OigoCore

@available(macOS 26.0, *)
public enum SpeechAssetState: Equatable, Sendable, CustomStringConvertible {
    case unavailable(String)
    case installing(String)
    case ready(String)

    public var description: String {
        switch self {
        case .unavailable(let reason):
            return "unavailable: " + reason
        case .installing(let localeIdentifier):
            return "installing: " + localeIdentifier
        case .ready(let localeIdentifier):
            return "ready: " + localeIdentifier
        }
    }
}

@available(macOS 26.0, *)
public enum TranscriptionError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedLocale(String)
    case speechAssetsUnavailable(String)
    case speechAssetsInstalling(String)
    case recognitionUnavailable(String)
    case malformedAudio(URL, String)
    case cancelled
    case analysisFailed(String)
    case persistenceFailed(String)
    case notRunning
    case alreadyRunning
    case invalidCaptureFormat
    case invalidSessionState(DictationSessionState)

    public var description: String {
        switch self {
        case .unsupportedLocale(let identifier):
            return "speech transcription does not support locale " + identifier
        case .speechAssetsUnavailable(let reason):
            return "speech assets are unavailable: " + reason
        case .speechAssetsInstalling(let identifier):
            return "speech assets are still installing for " + identifier
        case .recognitionUnavailable(let reason):
            return "on-device speech recognition is unavailable: " + reason
        case .malformedAudio(let url, let reason):
            return "saved audio is malformed at " + url.path + ": " + reason
        case .cancelled:
            return "speech transcription was cancelled"
        case .analysisFailed(let reason):
            return "speech analysis failed: " + reason
        case .persistenceFailed(let reason):
            return "canonical raw transcript could not be persisted: " + reason
        case .notRunning:
            return "speech transcription is not running"
        case .alreadyRunning:
            return "speech transcription is already running"
        case .invalidCaptureFormat:
            return "audio capture format is not compatible with on-device transcription"
        case .invalidSessionState(let state):
            return "saved-audio retry requires a failed or interrupted session, not " + state.rawValue
        }
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
    }

    private static let maxRevisionTailSegments = 8
    private static let maxRevisionTailCharacters = 4_096
    private static let maxPreviewCharacters = 512
    private var finalizedTail: [Segment] = []
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
    mutating func ingestAndReport(
        range: TranscriptionRange,
        text: String,
        isFinal: Bool
    ) -> TranscriptIngestResult {
        if isFinal {
            let overlapping = finalizedTail.filter { $0.range.overlaps(range) }
            let acceptedText: String?
            if overlapping.isEmpty {
                guard range.startMilliseconds >= finalizedEndMilliseconds else {
                    return TranscriptIngestResult(snapshot: snapshot, acceptedFinalText: nil)
                }
                acceptedText = text
                finalizedTail.append(Segment(
                    range: range,
                    text: String(text.prefix(Self.maxRevisionTailCharacters))
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
                acceptedText = newlyAcceptedText(existing: existingText, incoming: text)
                finalizedTail.removeAll { $0.range.overlaps(range) }
                finalizedTail.append(Segment(
                    range: mergedRange,
                    text: String(mergedText(existing: existingText, incoming: text).prefix(Self.maxRevisionTailCharacters))
                ))
            }
            if volatile?.range.overlaps(range) == true {
                volatile = nil
            }
            finalizedTail.sort { $0.range < $1.range }
            compactFinalizedTailIfNeeded()
            return TranscriptIngestResult(snapshot: snapshot, acceptedFinalText: acceptedText)
        } else {
            volatile = Segment(
                range: range,
                text: String(text.prefix(Self.maxPreviewCharacters))
            )
        }
        return TranscriptIngestResult(
            snapshot: snapshot,
            acceptedFinalText: nil
        )
    }

    public var snapshot: TranscriptionSnapshot {
        let visibleFinalized = finalized.filter { finalSegment in
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
        volatile = nil
    }

    private var finalized: [Segment] {
        finalizedTail
    }

    private var finalizedEndMilliseconds: Int64 {
        finalizedTail.last?.range.endMilliseconds ?? 0
    }

    private mutating func compactFinalizedTailIfNeeded() {
        while finalizedTail.count > Self.maxRevisionTailSegments {
            finalizedTail.removeFirst()
        }
    }

    private func mergedText(existing: String, incoming: String) -> String {
        let existing = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let incoming = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
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
        return join([existing, incoming])
    }

    private func newlyAcceptedText(existing: String, incoming: String) -> String? {
        let existing = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let incoming = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !incoming.isEmpty else {
            return nil
        }
        guard !existing.isEmpty else {
            return incoming
        }
        if incoming == existing || existing.hasPrefix(incoming) {
            return nil
        }
        if incoming.hasPrefix(existing) {
            let suffix = String(incoming.dropFirst(existing.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return suffix.isEmpty ? nil : suffix
        }
        let overlap = wordOverlap(existing: existing, incoming: incoming)
        let incomingWords = incoming.split(whereSeparator: { $0.isWhitespace })
        let suffix = incomingWords.dropFirst(overlap).joined(separator: " ")
        return suffix.isEmpty ? nil : suffix
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
struct TranscriptIngestResult: Sendable {
    let snapshot: TranscriptionSnapshot
    let acceptedFinalText: String?
}
