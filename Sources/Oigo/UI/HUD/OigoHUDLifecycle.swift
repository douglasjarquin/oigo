import Foundation

public struct OigoHUDLifecycle: Equatable, Sendable {
    public private(set) var state: OigoHUDState?
    public private(set) var generation: UInt64?
    public private(set) var visible = false

    private var recordingLastTick: TimeInterval?
    private var previewLastPublication: TimeInterval?

    public init() {}

    public var recordingTimerActive: Bool {
        visible && state.map(OigoHUDShellPolicy.isRecording) == true
    }

    public var previewUpdatesActive: Bool {
        recordingTimerActive && state.map { OigoHUDShellPolicy.content(for: $0).allowsPreview } == true
    }

    public var resourceCount: Int {
        (recordingTimerActive ? 1 : 0) + (previewUpdatesActive ? 1 : 0)
    }

    @discardableResult
    public mutating func present(
        _ state: OigoHUDState,
        generation: UInt64,
        visible: Bool
    ) -> Bool {
        guard generation > 0,
              self.generation.map({ generation >= $0 }) ?? true else {
            return false
        }
        self.state = state
        self.generation = generation
        self.visible = visible && state != .shutdown
        resetCadence()
        return true
    }

    @discardableResult
    public mutating func hide(generation: UInt64) -> Bool {
        guard self.generation == generation else { return false }
        visible = false
        resetCadence()
        return true
    }

    public mutating func recordingTick(at time: TimeInterval) -> Bool {
        guard recordingTimerActive, time.isFinite else { return false }
        guard let recordingLastTick else {
            self.recordingLastTick = time
            return true
        }
        guard time - recordingLastTick >= OigoHUDShellPolicy.recordingTimerInterval else {
            return false
        }
        self.recordingLastTick = time
        return true
    }

    public mutating func previewPublicationAllowed(at time: TimeInterval) -> Bool {
        guard previewUpdatesActive, time.isFinite else { return false }
        guard let previewLastPublication else {
            self.previewLastPublication = time
            return true
        }
        guard time - previewLastPublication >= OigoHUDShellPolicy.previewInterval else {
            return false
        }
        self.previewLastPublication = time
        return true
    }

    public mutating func shutdown() {
        state = nil
        generation = nil
        visible = false
        resetCadence()
    }

    private mutating func resetCadence() {
        recordingLastTick = nil
        previewLastPublication = nil
    }
}
