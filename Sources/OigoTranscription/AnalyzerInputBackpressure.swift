import AVFAudio
import Foundation
import OigoCore
import Speech

/// Fixed live analyzer-input bound.
///
/// Canonical capture emits at most 4096 frames per hop. At 16 kHz that is 256 ms.
/// 32 slots absorb ~8 s of analyzer stall, matching `CapturePipelineLimits.defaultCapacity`
/// so the producer queue and this consumer cannot combine into an unbounded pipeline.
@available(macOS 26.0, *)
public enum AnalyzerInputLimits {
    public static let capacity = 32
    /// Covers 48 kHz resample of a 4096-frame hop plus converter headroom.
    public static let maxFramesPerInput = 16_384
    public static let maxBytesPerInput = maxFramesPerInput * MemoryLayout<Int16>.size
    public static let maxRetainedBytes = capacity * maxBytesPerInput
}

@available(macOS 26.0, *)
public enum AnalyzerInputYieldOutcome: String, Equatable, Sendable {
    case enqueued
    case saturated
    case terminated
    case rejected
}

@available(macOS 26.0, *)
public struct AnalyzerInputMetrics: Equatable, Sendable {
    public var enqueueAccepted = 0
    public var saturateCount = 0
    public var terminateCount = 0
    public var rejectedCount = 0
    public var depth = 0
    public var highWaterDepth = 0
    public var highWaterBytes = 0
    public var lastYieldOutcome: AnalyzerInputYieldOutcome?
    public var degradation: LiveTranscriptionDegradation?
    public var conversionLatencyNanosecondsHighWater: UInt64 = 0

    public init() {}
}

@available(macOS 26.0, *)
public enum LiveIntakeFixtureConsumer: Equatable, Sendable {
    case neverRead
    case slow(nanoseconds: UInt64)
    case terminateAfter(Int)
}

@available(macOS 26.0, *)
public final class AnalyzerInputBackpressure: @unchecked Sendable {
    public let generation: UUID
    public let capacity: Int
    public let maxRetainedBytes: Int
    public let stream: AsyncStream<AnalyzerInput>

    private let lock = NSLock()
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private var finished = false
    private var storedMetrics = AnalyzerInputMetrics()

    public init(
        generation: UUID,
        capacity: Int = AnalyzerInputLimits.capacity,
        maxRetainedBytes: Int = AnalyzerInputLimits.maxRetainedBytes
    ) {
        let boundedCapacity = max(1, capacity)
        self.generation = generation
        self.capacity = boundedCapacity
        self.maxRetainedBytes = max(MemoryLayout<Int16>.size, maxRetainedBytes)
        let pair = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingOldest(boundedCapacity)
        )
        stream = pair.stream
        continuation = pair.continuation
    }

    public var metrics: AnalyzerInputMetrics {
        lock.lock()
        defer { lock.unlock() }
        return storedMetrics
    }

    @discardableResult
    public func enqueue(
        _ input: AnalyzerInput,
        generation: UUID,
        byteCount: Int,
        waitForCapacity: Bool = false
    ) -> AnalyzerInputYieldOutcome {
        lock.lock()
        guard generation == self.generation,
              storedMetrics.degradation == nil else {
            storedMetrics.rejectedCount += 1
            storedMetrics.lastYieldOutcome = .rejected
            lock.unlock()
            return .rejected
        }
        if byteCount > AnalyzerInputLimits.maxBytesPerInput {
            storedMetrics.saturateCount += 1
            storedMetrics.lastYieldOutcome = .saturated
            if storedMetrics.degradation == nil {
                storedMetrics.degradation = .queueSaturated
            }
            finished = true
            lock.unlock()
            continuation.finish()
            return .saturated
        }
        let yieldResult = continuation.yield(input)
        switch yieldResult {
        case .enqueued(let remainingCapacity):
            let depth = min(capacity, max(0, capacity - remainingCapacity))
            let retainedBytes = min(
                maxRetainedBytes,
                depth * min(byteCount, AnalyzerInputLimits.maxBytesPerInput)
            )
            storedMetrics.enqueueAccepted += 1
            storedMetrics.depth = depth
            storedMetrics.highWaterDepth = max(storedMetrics.highWaterDepth, depth)
            storedMetrics.highWaterBytes = max(storedMetrics.highWaterBytes, retainedBytes)
            storedMetrics.lastYieldOutcome = .enqueued
            lock.unlock()
            return .enqueued
        case .dropped:
            storedMetrics.lastYieldOutcome = .saturated
            if waitForCapacity {
                lock.unlock()
                return .saturated
            }
            storedMetrics.saturateCount += 1
            if storedMetrics.degradation == nil {
                storedMetrics.degradation = .queueSaturated
            }
            finished = true
            lock.unlock()
            continuation.finish()
            return .saturated
        case .terminated:
            storedMetrics.terminateCount += 1
            storedMetrics.lastYieldOutcome = .terminated
            if storedMetrics.degradation == nil {
                storedMetrics.degradation = .continuationTerminated
            }
            finished = true
            lock.unlock()
            continuation.finish()
            return .terminated
        @unknown default:
            storedMetrics.saturateCount += 1
            storedMetrics.lastYieldOutcome = .saturated
            if storedMetrics.degradation == nil {
                storedMetrics.degradation = .queueSaturated
            }
            finished = true
            lock.unlock()
            continuation.finish()
            return .saturated
        }
    }

    public func recordConversionLatency(_ nanoseconds: UInt64) {
        lock.lock()
        storedMetrics.conversionLatencyNanosecondsHighWater = max(
            storedMetrics.conversionLatencyNanosecondsHighWater,
            nanoseconds
        )
        lock.unlock()
    }

    @discardableResult
    public func markDegraded(_ degradation: LiveTranscriptionDegradation) -> Bool {
        lock.lock()
        let assigned = storedMetrics.degradation == nil
        if assigned {
            storedMetrics.degradation = degradation
        }
        finished = true
        lock.unlock()
        continuation.finish()
        return assigned
    }

    public func finish() {
        lock.lock()
        finished = true
        lock.unlock()
        continuation.finish()
    }
}
