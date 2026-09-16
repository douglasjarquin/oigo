import Foundation

@MainActor
public final class GlobalShortcutOperationBridge {
    public typealias StateProvider = () -> DictationState
    public typealias Operation = () -> Void
    public typealias Feedback = (GlobalShortcutIntentResult) -> Void
    public typealias Clock = () -> Duration
    public typealias Cancellation = @MainActor () -> Void
    public typealias Scheduler = (
        _ delay: Duration,
        _ action: @escaping @MainActor () -> Void
    ) -> Cancellation

    private let stateProvider: StateProvider
    private let start: Operation
    private let stop: Operation
    private let feedback: Feedback
    private let clock: Clock
    private let scheduler: Scheduler
    private var intent = GlobalShortcutIntentController()
    private var cancelPendingTimeout: Cancellation?

    public private(set) var lastResult: GlobalShortcutIntentResult?

    public var gesturePhase: GlobalShortcutGesturePhase {
        intent.gesturePhase
    }

    public var ownsKeyboardOperation: Bool {
        intent.ownsKeyboardOperation
    }

    public init(
        state: @escaping StateProvider,
        start: @escaping Operation,
        stop: @escaping Operation,
        feedback: @escaping Feedback = { _ in },
        clock: @escaping Clock = {
            .nanoseconds(Int64(DispatchTime.now().uptimeNanoseconds))
        },
        scheduler: @escaping Scheduler = { delay, action in
            let task = Task { @MainActor in
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                action()
            }
            return { task.cancel() }
        }
    ) {
        stateProvider = state
        self.start = start
        self.stop = stop
        self.feedback = feedback
        self.clock = clock
        self.scheduler = scheduler
    }

    @discardableResult
    public func receive(
        _ edge: GlobalShortcutIntentEdge,
        isRepeat: Bool = false
    ) -> GlobalShortcutIntentResult {
        let result = intent.receive(
            edge,
            state: stateProvider(),
            isRepeat: isRepeat,
            now: clock()
        )
        handle(result)
        return result
    }

    private func handle(_ result: GlobalShortcutIntentResult) {
        lastResult = result
        switch result {
        case .start:
            cancelTimeout()
            start()
        case .stop:
            cancelTimeout()
            stop()
        case .awaitingSecondPress(let generation):
            cancelTimeout()
            cancelPendingTimeout = scheduler(GlobalShortcutIntentController.tapWindow) { [weak self] in
                self?.receiveTimeout(generation: generation)
            }
        case .locked, .reset:
            cancelTimeout()
        case .ignoredBusy, .ignoredProcessing, .ignoredRecordingNotOwned:
            feedback(result)
        default:
            break
        }
    }

    private func receiveTimeout(generation: UInt64) {
        cancelPendingTimeout = nil
        guard let result = intent.timeout(generation: generation, state: stateProvider()) else {
            return
        }
        handle(result)
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
            cancelTimeout()
            stop()
        } else {
            if result == .reset {
                cancelTimeout()
            }
            feedback(result)
        }
        return result
    }

    @discardableResult
    public func reset() -> GlobalShortcutIntentResult {
        cancelTimeout()
        let result = intent.reset()
        lastResult = result
        return result
    }

    private func cancelTimeout() {
        cancelPendingTimeout?()
        cancelPendingTimeout = nil
    }
}
