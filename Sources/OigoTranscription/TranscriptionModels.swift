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
            guard !finalizedTail.contains(where: { $0.range.overlaps(range) }),
                  range.startMilliseconds >= finalizedEndMilliseconds else {
                return TranscriptIngestResult(snapshot: snapshot, acceptedFinalText: nil)
            }
            finalizedTail.removeAll { $0.range.overlaps(range) }
            if volatile?.range.overlaps(range) == true {
                volatile = nil
            }
            finalizedTail.append(Segment(
                range: range,
                text: String(text.prefix(Self.maxRevisionTailCharacters))
            ))
            finalizedTail.sort { $0.range < $1.range }
            compactFinalizedTailIfNeeded()
        } else {
            volatile = Segment(
                range: range,
                text: String(text.prefix(Self.maxPreviewCharacters))
            )
        }
        return TranscriptIngestResult(
            snapshot: snapshot,
            acceptedFinalText: isFinal ? text : nil
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
