import Foundation

public struct AudioRecordingOperationFence: Sendable {
    private var currentGeneration: UInt64 = 0

    public init() {}

    public mutating func begin() -> UInt64 {
        currentGeneration &+= 1
        return currentGeneration
    }

    public mutating func invalidate() {
        currentGeneration &+= 1
    }

    public func accepts(_ generation: UInt64) -> Bool {
        generation == currentGeneration
    }
}

@_spi(Testing)
public final class AudioRecordingCallbackGate: @unchecked Sendable {
    private let lock = NSRecursiveLock()

    public init() {}

    @discardableResult
    public func deliverIfAllowed(
        _ isAllowed: () -> Bool,
        _ callback: () -> Void
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isAllowed() else {
            return false
        }
        callback()
        return true
    }

    public func performExclusively<T>(_ action: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try action()
    }
}
