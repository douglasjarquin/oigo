import Foundation

@MainActor
public final class HUDTargetGeometrySession {
    public typealias Capture = @MainActor (UInt64) -> HUDTargetGeometrySnapshot

    private let capture: Capture
    public private(set) var currentSnapshot: HUDTargetGeometrySnapshot?

    public init(capture: @escaping Capture) {
        self.capture = capture
    }

    @discardableResult
    public func beginDictation(generation: UInt64) -> HUDTargetGeometrySnapshot? {
        beginCapture(generation: generation)
    }

    @discardableResult
    public func beginPasteAgain(generation: UInt64) -> HUDTargetGeometrySnapshot? {
        beginCapture(generation: generation)
    }

    private func beginCapture(generation: UInt64) -> HUDTargetGeometrySnapshot? {
        guard generation > 0 else { return nil }
        if currentSnapshot?.generation == generation {
            return currentSnapshot
        }
        let snapshot = capture(generation)
        guard snapshot.generation == generation else {
            currentSnapshot = nil
            return nil
        }
        currentSnapshot = snapshot
        return snapshot
    }

    public func endDictation(generation: UInt64) {
        guard currentSnapshot?.generation == generation else { return }
        currentSnapshot = nil
    }

    public func shutdown() {
        currentSnapshot = nil
    }
}
