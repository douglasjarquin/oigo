import Foundation
import Speech

@available(macOS 26.0, *)
final class TranscriptStore: @unchecked Sendable {
    private let lock = NSLock()
    private var accumulator = TranscriptionAccumulator()

    func ingest(_ result: DictationTranscriber.Result) {
        let start = max(0, result.range.start.seconds)
        let end = max(start, result.range.end.seconds)
        _ = ingest(
            range: TranscriptionRange(
                startMilliseconds: Int64(start * 1_000),
                endMilliseconds: Int64(end * 1_000)
            ),
            text: String(result.text.characters),
            isFinal: result.isFinal
        )
    }

    @discardableResult
    func ingest(
        range: TranscriptionRange,
        text: String,
        isFinal: Bool
    ) -> TranscriptionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return accumulator.ingest(range: range, text: text, isFinal: isFinal)
    }

    var snapshot: TranscriptionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return accumulator.snapshot
    }
}
