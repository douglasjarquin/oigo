import Foundation

public enum GlobalShortcutIntentEdge: Equatable, Sendable {
    case pressed
    case released
}

public enum GlobalShortcutIntentResult: Equatable, Sendable {
    case start
    case stop
    case releaseLatched
    case awaitingSecondPress(generation: UInt64)
    case locked
    case ignoredRepeat
    case ignoredDuplicatePress
    case ignoredDuplicateRelease
    case ignoredProcessing(DictationState)
    case ignoredRecordingNotOwned
    case ignoredBusy(DictationState)
    case reset
}

public enum GlobalShortcutGesturePhase: Equatable, Sendable {
    case idle
    case holding
    case awaitingSecondPress
    case locked
}

public struct GlobalShortcutIntentController: Sendable {
    public static let tapWindow: Duration = .milliseconds(350)

    private enum GestureState: Sendable {
        case idle
        case holding(since: Duration)
        case awaitingSecondPress(deadline: Duration, generation: UInt64)
        case locked
    }

    private var physicalDown = false
    private var keyboardOwnsOperation = false
    private var releaseLatched = false
    private var gestureState: GestureState = .idle
    private var generation: UInt64 = 0

    public init() {}

    public var isPhysicalDown: Bool {
        physicalDown
    }

    public var ownsKeyboardOperation: Bool {
        keyboardOwnsOperation
    }

    public var hasLatchedRelease: Bool {
        releaseLatched
    }

    public var gesturePhase: GlobalShortcutGesturePhase {
        switch gestureState {
        case .idle:
            .idle
        case .holding:
            .holding
        case .awaitingSecondPress:
            .awaitingSecondPress
        case .locked:
            .locked
        }
    }

    public mutating func receive(
        _ edge: GlobalShortcutIntentEdge,
        state: DictationState,
        isRepeat: Bool = false,
        now: Duration = .zero
    ) -> GlobalShortcutIntentResult {
        if state.isIssue82Processing {
            return .ignoredProcessing(state)
        }

        if state.isIssue82Terminal,
           physicalDown || keyboardOwnsOperation || releaseLatched {
            clearOwnership()
            if edge == .released {
                return .reset
            }
        }

        switch edge {
        case .pressed:
            return receivePress(state: state, isRepeat: isRepeat, now: now)
        case .released:
            return receiveRelease(state: state, isRepeat: isRepeat, now: now)
        }
    }

    public mutating func timeout(
        generation expectedGeneration: UInt64,
        state: DictationState
    ) -> GlobalShortcutIntentResult? {
        guard case .awaitingSecondPress(_, let activeGeneration) = gestureState,
              activeGeneration == expectedGeneration else {
            return nil
        }

        if state.isIssue82Processing {
            clearOwnership()
            return .ignoredProcessing(state)
        }
        if state.isIssue82Terminal {
            clearOwnership()
            return .reset
        }
        return finish(state: state)
    }

    public mutating func observe(_ state: DictationState) -> GlobalShortcutIntentResult? {
        if state == .recording, keyboardOwnsOperation, releaseLatched {
            releaseLatched = false
            physicalDown = false
            keyboardOwnsOperation = false
            return .stop
        }

        guard state.isIssue82Terminal else {
            return nil
        }

        guard physicalDown || keyboardOwnsOperation || releaseLatched else {
            return nil
        }

        clearOwnership()
        return .reset
    }

    public mutating func reset() -> GlobalShortcutIntentResult {
        clearOwnership()
        return .reset
    }

    private mutating func receivePress(
        state: DictationState,
        isRepeat: Bool,
        now: Duration
    ) -> GlobalShortcutIntentResult {
        if isRepeat {
            return .ignoredRepeat
        }

        switch gestureState {
        case .holding:
            return .ignoredDuplicatePress
        case .awaitingSecondPress(let deadline, _):
            guard now < deadline else {
                return finish(state: state)
            }
            physicalDown = true
            gestureState = .locked
            return .locked
        case .locked:
            guard !physicalDown else {
                return .ignoredDuplicatePress
            }
            physicalDown = true
            return finish(state: state)
        case .idle:
            break
        }

        guard state.isIssue82Startable else {
            if state == .recording {
                return .ignoredRecordingNotOwned
            }
            return .ignoredBusy(state)
        }

        physicalDown = true
        keyboardOwnsOperation = true
        releaseLatched = false
        generation &+= 1
        gestureState = .holding(since: now)
        return .start
    }

    private mutating func receiveRelease(
        state: DictationState,
        isRepeat: Bool,
        now: Duration
    ) -> GlobalShortcutIntentResult {
        if isRepeat {
            return .ignoredRepeat
        }

        if case .locked = gestureState, physicalDown {
            physicalDown = false
            return .ignoredDuplicateRelease
        }

        guard case .holding(let since) = gestureState, physicalDown else {
            return state == .recording && !keyboardOwnsOperation
                ? .ignoredRecordingNotOwned
                : .ignoredDuplicateRelease
        }
        physicalDown = false

        guard keyboardOwnsOperation else {
            return .ignoredRecordingNotOwned
        }

        guard now - since < Self.tapWindow else {
            return finish(state: state)
        }

        let deadline = now + Self.tapWindow
        gestureState = .awaitingSecondPress(deadline: deadline, generation: generation)
        return .awaitingSecondPress(generation: generation)
    }

    private mutating func finish(state: DictationState) -> GlobalShortcutIntentResult {
        gestureState = .idle
        physicalDown = false
        switch state {
        case .idle, .complete, .failed, .cancelled, .interrupted, .preparing:
            releaseLatched = true
            return .releaseLatched
        case .recording:
            releaseLatched = false
            keyboardOwnsOperation = false
            return .stop
        default:
            clearOwnership()
            return .ignoredDuplicateRelease
        }
    }

    private mutating func clearOwnership() {
        generation &+= 1
        physicalDown = false
        keyboardOwnsOperation = false
        releaseLatched = false
        gestureState = .idle
    }
}

private extension DictationState {
    var isIssue82Processing: Bool {
        switch self {
        case .finalizing, .cleaning, .inserting:
            true
        default:
            false
        }
    }

    var isIssue82Startable: Bool {
        switch self {
        case .idle, .complete, .failed, .cancelled, .interrupted:
            true
        default:
            false
        }
    }

    var isIssue82Terminal: Bool {
        switch self {
        case .complete, .failed, .cancelled, .interrupted:
            true
        default:
            false
        }
    }
}
