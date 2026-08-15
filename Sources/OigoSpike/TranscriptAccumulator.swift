import Foundation

public struct TranscriptRange: Hashable, Sendable, Comparable {
    public let startMilliseconds: Int64
    public let endMilliseconds: Int64

    public init(startMilliseconds: Int64, endMilliseconds: Int64) {
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
    }

    public static func < (lhs: TranscriptRange, rhs: TranscriptRange) -> Bool {
        if lhs.startMilliseconds != rhs.startMilliseconds {
            return lhs.startMilliseconds < rhs.startMilliseconds
        }
        return lhs.endMilliseconds < rhs.endMilliseconds
    }

    fileprivate func overlaps(_ other: TranscriptRange) -> Bool {
        if startMilliseconds == other.startMilliseconds && endMilliseconds == other.endMilliseconds {
            return true
        }
        return max(startMilliseconds, other.startMilliseconds) < min(endMilliseconds, other.endMilliseconds)
    }
}

public struct TranscriptSnapshot: Equatable, Sendable {
    public let finalizedText: String
    public let volatileText: String
    public let displayedText: String

    public init(finalizedText: String, volatileText: String, displayedText: String) {
        self.finalizedText = finalizedText
        self.volatileText = volatileText
        self.displayedText = displayedText
    }
}

public struct TranscriptAccumulator: Sendable {
    private struct Segment: Sendable {
        let range: TranscriptRange
        let text: String
    }

    private var finalized: [Segment] = []
    private var volatile: [Segment] = []

    public init() {}

    @discardableResult
    public mutating func ingest(
        range: TranscriptRange,
        text: String,
        isFinal: Bool
    ) -> TranscriptSnapshot {
        let segment = Segment(range: range, text: text)
        if isFinal {
            finalized.removeAll { $0.range.overlaps(range) }
            volatile.removeAll { $0.range.overlaps(range) }
            finalized.append(segment)
        } else {
            volatile.removeAll { $0.range.overlaps(range) }
            volatile.append(segment)
        }
        return snapshot
    }

    public var snapshot: TranscriptSnapshot {
        let visibleFinalized = finalized.filter { finalSegment in
            !volatile.contains { finalSegment.range.overlaps($0.range) }
        }
        let orderedFinalized = visibleFinalized.sorted { $0.range < $1.range }
        let orderedVolatile = volatile.sorted { $0.range < $1.range }
        return TranscriptSnapshot(
            finalizedText: join(orderedFinalized),
            volatileText: join(orderedVolatile),
            displayedText: join(orderedFinalized + orderedVolatile)
        )
    }

    public mutating func reset() {
        finalized.removeAll(keepingCapacity: true)
        volatile.removeAll(keepingCapacity: true)
    }

    private func join(_ segments: [Segment]) -> String {
        segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

public final class TranscriptStore: @unchecked Sendable {
    private let lock = NSLock()
    private var accumulator = TranscriptAccumulator()

    public init() {}

    @discardableResult
    public func ingest(
        range: TranscriptRange,
        text: String,
        isFinal: Bool
    ) -> TranscriptSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return accumulator.ingest(range: range, text: text, isFinal: isFinal)
    }

    public var snapshot: TranscriptSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return accumulator.snapshot
    }
}
