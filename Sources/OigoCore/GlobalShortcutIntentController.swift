public enum GlobalShortcutIntentEdge: Equatable, Sendable {
    case pressed
    case released
}

public enum GlobalShortcutIntentResult: Equatable, Sendable {
    case start
    case stop
    case releaseLatched
    case ignoredRepeat
    case ignoredDuplicatePress
    case ignoredDuplicateRelease
    case ignoredProcessing(DictationState)
    case ignoredRecordingNotOwned
    case ignoredBusy(DictationState)
    case reset
}

public struct GlobalShortcutIntentController: Sendable {
    private var physicalDown = false
    private var keyboardOwnsOperation = false
    private var releaseLatched = false

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

    public mutating func receive(
        _ edge: GlobalShortcutIntentEdge,
        state: DictationState,
        isRepeat: Bool = false
    ) -> GlobalShortcutIntentResult {
        if state.isIssue82Processing {
            return .ignoredProcessing(state)
        }

        switch edge {
        case .pressed:
            return receivePress(state: state, isRepeat: isRepeat)
        case .released:
            return receiveRelease(state: state, isRepeat: isRepeat)
        }
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
        isRepeat: Bool
    ) -> GlobalShortcutIntentResult {
        if isRepeat {
            return .ignoredRepeat
        }

        guard !physicalDown else {
            return .ignoredDuplicatePress
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
        return .start
    }

    private mutating func receiveRelease(
        state: DictationState,
        isRepeat: Bool
    ) -> GlobalShortcutIntentResult {
        if isRepeat {
            return .ignoredRepeat
        }

        guard physicalDown else {
            return state == .recording ? .ignoredRecordingNotOwned : .ignoredDuplicateRelease
        }

        physicalDown = false

        guard keyboardOwnsOperation else {
            return .ignoredRecordingNotOwned
        }

        switch state {
        case .preparing:
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
        physicalDown = false
        keyboardOwnsOperation = false
        releaseLatched = false
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
