@MainActor
public final class GlobalShortcutOperationBridge {
    public typealias StateProvider = () -> DictationState
    public typealias Operation = () -> Void
    public typealias Feedback = (GlobalShortcutIntentResult) -> Void

    private let stateProvider: StateProvider
    private let start: Operation
    private let stop: Operation
    private let feedback: Feedback
    private var intent = GlobalShortcutIntentController()
    private var keyboardStartupInFlight = false

    public private(set) var lastResult: GlobalShortcutIntentResult?

    public init(
        state: @escaping StateProvider,
        start: @escaping Operation,
        stop: @escaping Operation,
        feedback: @escaping Feedback = { _ in }
    ) {
        stateProvider = state
        self.start = start
        self.stop = stop
        self.feedback = feedback
    }

    @discardableResult
    public func receive(
        _ edge: GlobalShortcutIntentEdge,
        isRepeat: Bool = false
    ) -> GlobalShortcutIntentResult {
        let state = keyboardStartupInFlight ? .preparing : stateProvider()
        let result = intent.receive(edge, state: state, isRepeat: isRepeat)
        lastResult = result
        switch result {
        case .start:
            keyboardStartupInFlight = true
            start()
        case .stop:
            stop()
        case .ignoredBusy, .ignoredProcessing, .ignoredRecordingNotOwned:
            feedback(result)
        default:
            break
        }
        return result
    }

    @discardableResult
    public func observeState() -> GlobalShortcutIntentResult? {
        let state = stateProvider()
        let result = intent.observe(state)
        if state == .recording || state.isIssue82TerminalForBridge {
            keyboardStartupInFlight = false
        }
        guard let result else {
            return nil
        }

        lastResult = result
        if result == .stop {
            stop()
        } else {
            feedback(result)
        }
        return result
    }

    @discardableResult
    public func reset() -> GlobalShortcutIntentResult {
        keyboardStartupInFlight = false
        let result = intent.reset()
        lastResult = result
        return result
    }
}

private extension DictationState {
    var isIssue82TerminalForBridge: Bool {
        switch self {
        case .complete, .failed, .cancelled, .interrupted:
            true
        default:
            false
        }
    }
}
