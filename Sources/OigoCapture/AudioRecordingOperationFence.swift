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
