import Foundation

@available(macOS 26.0, *)
@_spi(Testing)
public final class TranscriptionStartupGate: @unchecked Sendable {
    private let resultPair = AsyncStream<Void>.makeStream()
    private let analysisPair = AsyncStream<Void>.makeStream()
    private let lock = NSLock()
    private var isFinished = false

    public init() {}

    public var resultStream: AsyncStream<Void> {
        resultPair.stream
    }

    public var analysisStream: AsyncStream<Void> {
        analysisPair.stream
    }

    public func release() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        lock.unlock()

        resultPair.continuation.yield(())
        resultPair.continuation.finish()
        analysisPair.continuation.yield(())
        analysisPair.continuation.finish()
    }

    public func finish() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        lock.unlock()

        resultPair.continuation.finish()
        analysisPair.continuation.finish()
    }
}
