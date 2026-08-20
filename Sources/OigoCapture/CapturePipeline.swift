import AVFAudio
import Foundation
import OigoCore

public enum CapturePipelineFailure: String, Sendable {
    case overflow = "audio_pipeline_overflow"
}

public enum CaptureAcceptResult: Equatable, Sendable {
    case accepted
    case ignored
    case overflow
    case conversionFailed
}

public enum CapturePipelineLimits {
    public static let defaultCapacity = 32
    public static let defaultMaxFrames = 4_096
    public static let defaultMaxBytes = defaultCapacity * defaultMaxFrames * MemoryLayout<Float>.size
}

public final class CapturePipeline: @unchecked Sendable {
    public let generation: UInt64
    public let capacity: Int
    public let maxBytes: Int
    public let maxFrames: Int

    private let adapter: CanonicalMonoAdapter
    private let writer: CanonicalAudioWriting
    private let workQueue: DispatchQueue
    private let speechQueue: DispatchQueue
    private let lock = NSLock()
    private let finishedGroup = DispatchGroup()

    private var onBuffer: (@Sendable (AudioCaptureBuffer) -> Void)?
    private var onFinish: (@Sendable () -> Void)?
    private var onInterruption: (@Sendable (String) -> Void)?
    private var onFailure: (@Sendable (String) -> Void)?
    private var teardownHandler: (@Sendable () -> Void)?
    private var onTerminalized: (@Sendable () -> Void)?
    private let permissionCheck: @Sendable () -> Bool

    private var slots: [Slot]
    private var pending: [Int] = []
    private var pendingBytes = 0
    private var accepting = true
    private var finalized = false
    private var terminal = TerminalKind.none
    private var firstBuffer = true

    private let instrumentation: PerformanceInstrumentation?

    public init(
        generation: UInt64,
        adapter: CanonicalMonoAdapter,
        writer: CanonicalAudioWriting,
        capacity: Int = CapturePipelineLimits.defaultCapacity,
        maxFrames: Int = CapturePipelineLimits.defaultMaxFrames,
        maxBytes: Int = CapturePipelineLimits.defaultMaxBytes,
        instrumentation: PerformanceInstrumentation? = nil,
        onBuffer: @escaping @Sendable (AudioCaptureBuffer) -> Void,
        onFinish: @escaping @Sendable () -> Void,
        onInterruption: @escaping @Sendable (String) -> Void,
        onFailure: @escaping @Sendable (String) -> Void,
        teardownHandler: @escaping @Sendable () -> Void,
        onTerminalized: @escaping @Sendable () -> Void = {},
        permissionCheck: @escaping @Sendable () -> Bool = { true }
    ) {
        self.generation = generation
        self.adapter = adapter
        self.writer = writer
        self.capacity = max(1, capacity)
        self.maxFrames = max(1, maxFrames)
        self.maxBytes = max(MemoryLayout<Float>.size, maxBytes)
        self.instrumentation = instrumentation
        self.onBuffer = onBuffer
        self.onFinish = onFinish
        self.onInterruption = onInterruption
        self.onFailure = onFailure
        self.teardownHandler = teardownHandler
        self.onTerminalized = onTerminalized
        self.permissionCheck = permissionCheck
        self.workQueue = DispatchQueue(label: "com.oigo.capture.producer")
        self.speechQueue = DispatchQueue(label: "com.oigo.capture.speech")
        self.slots = (0..<max(1, capacity)).map { _ in
            Slot(sampleCapacity: max(1, maxFrames))
        }
        finishedGroup.enter()
    }

    deinit {
        for slot in slots {
            slot.deallocate()
        }
        if !finalized {
            finishedGroup.leave()
        }
        writer.close()
    }

    public func tryAccept(_ buffer: AVAudioPCMBuffer, generation: UInt64) -> CaptureAcceptResult {
        guard generation == self.generation else {
            return .ignored
        }

        lock.lock()
        let canAccept = accepting && !finalized && terminal == .none
        lock.unlock()
        guard canAccept else {
            return .ignored
        }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else {
            return .accepted
        }
        if frameCount > maxFrames {
            requestTerminal(.failure("audio buffer exceeds the capture pipeline frame bound"))
            return .conversionFailed
        }
        let byteCount = frameCount * MemoryLayout<Float>.size

        lock.lock()
        guard accepting, !finalized, terminal == .none else {
            lock.unlock()
            return .ignored
        }
        guard let slotIndex = reserveSlotLocked(byteCount: byteCount) else {
            lock.unlock()
            requestTerminal(.overflow)
            return .overflow
        }
        lock.unlock()

        let converted: Int
        do {
            converted = try adapter.convert(
                buffer,
                into: slots[slotIndex].samples,
                frameCapacity: maxFrames
            )
        } catch {
            recycle(slotIndex)
            requestTerminal(.failure(String(describing: error)))
            return .conversionFailed
        }

        lock.lock()
        if !accepting || finalized || terminal == .overflow {
            lock.unlock()
            recycle(slotIndex)
            return .ignored
        }
        slots[slotIndex].frameCount = converted
        slots[slotIndex].sampleRate = adapter.outputFormat.sampleRate
        pending.append(slotIndex)
        pendingBytes += converted * MemoryLayout<Float>.size
        lock.unlock()
        workQueue.async { [weak self] in
            self?.processAvailable()
        }
        return .accepted
    }

    public func stopAndWait() {
        requestTerminal(.userStop)
        finishedGroup.wait()
    }

    public func cancelAndWait() {
        requestTerminal(.cancel)
        finishedGroup.wait()
    }

    public func interruptAndWait(_ reason: String) {
        requestTerminal(.interrupt(reason))
        finishedGroup.wait()
    }

    public func failAndWait(_ reason: String) {
        requestTerminal(.failure(reason))
        finishedGroup.wait()
    }

    @_spi(Testing)
    public var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    @_spi(Testing)
    public var isAccepting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return accepting && !finalized
    }

    @_spi(Testing)
    public var isFinalized: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finalized
    }

    @_spi(Testing)
    public func waitForSpeechHandoff() {
        speechQueue.sync(flags: .barrier) {}
    }

    private func requestTerminal(_ kind: TerminalKind) {
        lock.lock()
        if finalized {
            lock.unlock()
            return
        }
        accepting = false
        if terminal == .none || kind.overrides(terminal) {
            terminal = kind
        }
        lock.unlock()
        workQueue.async { [weak self] in
            self?.processAvailable()
        }
    }

    private func processAvailable() {
        while true {
            lock.lock()
            if finalized {
                lock.unlock()
                return
            }
            let currentTerminal = terminal
            if currentTerminal.discardsPending {
                let discarded = pending
                pending = []
                pendingBytes = 0
                lock.unlock()
                discarded.forEach(recycle)
                completeTerminal(currentTerminal)
                return
            }
            if let slotIndex = pending.first {
                pending.removeFirst()
                pendingBytes = max(0, pendingBytes - slots[slotIndex].byteCount)
                lock.unlock()
                if !writeAndDeliver(slotIndex) {
                    return
                }
                continue
            }
            if currentTerminal != .none {
                lock.unlock()
                completeTerminal(currentTerminal)
                return
            }
            lock.unlock()
            return
        }
    }

    private func writeAndDeliver(_ slotIndex: Int) -> Bool {
        if !permissionCheck() {
            recycle(slotIndex)
            completeTerminal(.interrupt("microphone permission revoked"))
            return false
        }
        let frameCount = slots[slotIndex].frameCount
        let sampleRate = slots[slotIndex].sampleRate
        let samples = slots[slotIndex].samples
        do {
            try writer.writeCanonicalMono(samples: samples, frameCount: frameCount)
        } catch {
            recycle(slotIndex)
            completeTerminal(.failure(String(describing: error)))
            return false
        }

        let pcmData = Data(bytes: samples, count: frameCount * MemoryLayout<Float>.size)
        recycle(slotIndex)
        let captureBuffer = AudioCaptureBuffer(
            frameCount: frameCount,
            sampleRate: sampleRate,
            channelCount: 1,
            pcmData: pcmData
        )
        lock.lock()
        let callback = onBuffer
        let markFirst = firstBuffer
        if markFirst {
            firstBuffer = false
        }
        lock.unlock()
        speechQueue.async { [instrumentation] in
            if markFirst {
                instrumentation?.mark(.firstAudioBuffer)
            }
            callback?(captureBuffer)
        }
        return true
    }

    private func completeTerminal(_ kind: TerminalKind) {
        lock.lock()
        guard !finalized else {
            lock.unlock()
            return
        }
        finalized = true
        accepting = false
        let discarded = pending
        pending = []
        pendingBytes = 0
        let onFinish = self.onFinish
        let onInterruption = self.onInterruption
        let onFailure = self.onFailure
        let teardownHandler = self.teardownHandler
        let onTerminalized = self.onTerminalized
        self.onBuffer = nil
        self.onFinish = nil
        self.onInterruption = nil
        self.onFailure = nil
        self.teardownHandler = nil
        self.onTerminalized = nil
        lock.unlock()

        discarded.forEach(recycle)
        teardownHandler?()
        writer.close()
        switch kind {
        case .userStop, .cancel:
            speechQueue.sync(flags: .barrier) {}
            onFinish?()
        case .none:
            break
        case .interrupt(let reason):
            onInterruption?(reason)
        case .overflow:
            onFailure?(CapturePipelineFailure.overflow.rawValue)
        case .failure(let reason):
            onFailure?(reason)
        }
        onTerminalized?()
        finishedGroup.leave()
    }

    private func reserveSlotLocked(byteCount: Int) -> Int? {
        guard pending.count < capacity,
              pendingBytes + byteCount <= maxBytes,
              let index = slots.firstIndex(where: { !$0.inUse }) else {
            return nil
        }
        slots[index].inUse = true
        return index
    }

    private func recycle(_ index: Int) {
        lock.lock()
        slots[index].inUse = false
        slots[index].frameCount = 0
        lock.unlock()
    }

    private final class Slot {
        let samples: UnsafeMutablePointer<Float>
        var frameCount = 0
        var sampleRate = 0.0
        var inUse = false

        var byteCount: Int {
            frameCount * MemoryLayout<Float>.size
        }

        init(sampleCapacity: Int) {
            samples = .allocate(capacity: sampleCapacity)
        }

        func deallocate() {
            samples.deallocate()
        }
    }

    private enum TerminalKind: Equatable {
        case none
        case userStop
        case cancel
        case interrupt(String)
        case overflow
        case failure(String)

        var discardsPending: Bool {
            switch self {
            case .cancel, .interrupt, .failure:
                true
            case .none, .userStop, .overflow:
                false
            }
        }

        func overrides(_ existing: TerminalKind) -> Bool {
            switch (existing, self) {
            case (.none, _):
                true
            case (_, .none):
                false
            case (.userStop, .failure), (.userStop, .overflow), (.userStop, .interrupt):
                true
            default:
                false
            }
        }
    }
}
