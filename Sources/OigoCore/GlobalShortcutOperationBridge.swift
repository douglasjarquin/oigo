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
        let result = intent.receive(edge, state: stateProvider(), isRepeat: isRepeat)
        lastResult = result
        switch result {
        case .start:
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
        let result = intent.reset()
        lastResult = result
        return result
    }
}
