import OigoCore

@MainActor
final class ManualGestureScheduler {
    final class ScheduledAction {
        let deadline: Duration
        let action: @MainActor () -> Void
        var isCancelled = false

        init(deadline: Duration, action: @escaping @MainActor () -> Void) {
            self.deadline = deadline
            self.action = action
        }
    }

    private(set) var now: Duration = .zero
    private(set) var actions: [ScheduledAction] = []

    func schedule(
        after delay: Duration,
        action: @escaping @MainActor () -> Void
    ) -> @MainActor () -> Void {
        let scheduled = ScheduledAction(deadline: now + delay, action: action)
        actions.append(scheduled)
        return { scheduled.isCancelled = true }
    }

    func setNow(milliseconds: Int64) {
        now = .milliseconds(milliseconds)
    }

    func advance(toMilliseconds milliseconds: Int64) {
        setNow(milliseconds: milliseconds)
        for scheduled in actions where !scheduled.isCancelled && scheduled.deadline <= now {
            scheduled.isCancelled = true
            scheduled.action()
        }
    }

    func fireRetiredAction(at index: Int) {
        actions[index].action()
    }
}

@MainActor
final class GestureFixture {
    var state: DictationState = .idle
    var actions: [String] = []
    let scheduler = ManualGestureScheduler()

    lazy var bridge = GlobalShortcutOperationBridge(
        state: { [weak self] in self?.state ?? .failed },
        start: { [weak self] in self?.actions.append("start") },
        stop: { [weak self] in self?.actions.append("stop") },
        clock: { [weak self] in self?.scheduler.now ?? .zero },
        scheduler: { [weak self] delay, action in
            self?.scheduler.schedule(after: delay, action: action) ?? {}
        }
    )

    func press(at milliseconds: Int64, isRepeat: Bool = false) -> GlobalShortcutIntentResult {
        scheduler.setNow(milliseconds: milliseconds)
        return bridge.receive(.pressed, isRepeat: isRepeat)
    }

    func release(at milliseconds: Int64, isRepeat: Bool = false) -> GlobalShortcutIntentResult {
        scheduler.setNow(milliseconds: milliseconds)
        return bridge.receive(.released, isRepeat: isRepeat)
    }
}

@MainActor
extension OigoIssue82ContractTests {
    static func testGesturePressStartsBeforeRelease() throws {
        // Given an idle gesture fixture.
        let fixture = GestureFixture()

        // When the shortcut is pressed without a release.
        let result = fixture.press(at: 0)

        // Then recording starts immediately and keyboard ownership is holding.
        guard result == .start,
              fixture.actions == ["start"],
              fixture.bridge.gesturePhase == .holding,
              fixture.bridge.ownsKeyboardOperation else {
            throw ContractFailure(message: "first valid press did not start before release")
        }
    }

    static func testGestureTapAt349Milliseconds() throws {
        // Given a keyboard-owned recording started at zero.
        let fixture = GestureFixture()
        _ = fixture.press(at: 0)
        fixture.state = .recording

        // When the key is released at 349 ms.
        let result = fixture.release(at: 349)

        // Then the gesture remains active awaiting a second press.
        guard case .awaitingSecondPress = result,
              fixture.actions == ["start"],
              fixture.bridge.gesturePhase == .awaitingSecondPress,
              fixture.bridge.ownsKeyboardOperation else {
            throw ContractFailure(message: "349 ms release was not classified as a short tap")
        }
    }

    static func testGestureHoldAt350Milliseconds() throws {
        // Given a keyboard-owned recording started at zero.
        let fixture = GestureFixture()
        _ = fixture.press(at: 0)
        fixture.state = .recording

        // When the key is released at exactly 350 ms.
        let result = fixture.release(at: 350)

        // Then the hold finishes immediately on release.
        guard result == .stop,
              fixture.actions == ["start", "stop"],
              fixture.bridge.gesturePhase == .idle,
              !fixture.bridge.ownsKeyboardOperation else {
            throw ContractFailure(message: "350 ms release did not finish as a long hold")
        }
    }

    static func testGestureHoldAt351Milliseconds() throws {
        // Given a keyboard-owned recording started at zero.
        let fixture = GestureFixture()
        _ = fixture.press(at: 0)
        fixture.state = .recording

        // When the key is released at 351 ms.
        let result = fixture.release(at: 351)

        // Then the hold finishes immediately on release.
        guard result == .stop,
              fixture.actions == ["start", "stop"],
              fixture.bridge.gesturePhase == .idle,
              !fixture.bridge.ownsKeyboardOperation else {
            throw ContractFailure(message: "351 ms release did not finish as a long hold")
        }
    }

    static func testGestureShortReleaseAwaitsSecondPress() throws {
        // Given a short first tap on a recording operation.
        let fixture = GestureFixture()
        _ = fixture.press(at: 0)
        fixture.state = .recording
        _ = fixture.release(at: 100)

        // When only 349 ms elapse after the release.
        fixture.scheduler.advance(toMilliseconds: 449)

        // Then no stop occurs and the second-press window remains owned.
        guard fixture.actions == ["start"],
              fixture.bridge.gesturePhase == .awaitingSecondPress,
              fixture.bridge.ownsKeyboardOperation else {
            throw ContractFailure(message: "short release did not remain active for the full second-press window")
        }
    }

    static func testGestureSecondPressAt349MillisecondsLocks() throws {
        // Given a short first tap released at 100 ms.
        let fixture = GestureFixture()
        _ = fixture.press(at: 0)
        fixture.state = .recording
        _ = fixture.release(at: 100)

        // When a second press arrives 349 ms after release.
        let result = fixture.press(at: 449)
        let release = fixture.release(at: 450)

        // Then the existing recording locks without a second start or stop.
        guard result == .locked,
              release == .ignoredDuplicateRelease,
              fixture.actions == ["start"],
              fixture.bridge.gesturePhase == .locked,
              fixture.bridge.ownsKeyboardOperation else {
            throw ContractFailure(message: "second press at 349 ms did not lock without another start")
        }
    }

    static func testGestureSecondPressAt350MillisecondsLosesToTimeout() throws {
        // Given a short first tap released at 100 ms with its timeout still queued.
        let fixture = GestureFixture()
        _ = fixture.press(at: 0)
        fixture.state = .recording
        _ = fixture.release(at: 100)

        // When a second press arrives at the exact 350 ms deadline before the queued callback runs.
        let result = fixture.press(at: 450)

        // Then timeout ordering wins, stopping the old recording instead of locking it.
        guard result == .stop,
              fixture.actions == ["start", "stop"],
              fixture.bridge.gesturePhase == .idle,
              !fixture.bridge.ownsKeyboardOperation else {
            throw ContractFailure(message: "second press at 350 ms did not lose to timeout")
        }
    }

    static func testGestureLockedNextTapStopsOnce() throws {
        // Given a double tap that has entered locked recording.
        let fixture = GestureFixture()
        _ = fixture.press(at: 0)
        fixture.state = .recording
        _ = fixture.release(at: 100)
        _ = fixture.press(at: 449)
        _ = fixture.release(at: 450)

        // When the next tap is pressed and released.
        let stop = fixture.press(at: 700)
        fixture.state = .finalizing
        let trailingRelease = fixture.release(at: 701)

        // Then exactly one stop occurs and the trailing edge is inert.
        guard stop == .stop,
              trailingRelease == .ignoredProcessing(.finalizing),
              fixture.actions == ["start", "stop"],
              fixture.bridge.gesturePhase == .idle,
              !fixture.bridge.ownsKeyboardOperation else {
            throw ContractFailure(message: "locked next tap did not stop exactly once")
        }
    }

    static func testGestureRetiredSchedulerGenerationCannotAct() throws {
        // Given a pending short-tap timeout that is reset and replaced by a newer gesture.
        let fixture = GestureFixture()
        _ = fixture.press(at: 0)
        fixture.state = .recording
        _ = fixture.release(at: 100)
        _ = fixture.bridge.reset()
        fixture.scheduler.fireRetiredAction(at: 0)
        fixture.state = .idle
        _ = fixture.press(at: 200)
        fixture.state = .recording
        _ = fixture.release(at: 250)

        // When the retired generation fires again before the current timeout.
        fixture.scheduler.fireRetiredAction(at: 0)

        // Then stale callbacks do nothing and only the current generation can stop.
        guard fixture.actions == ["start", "start"],
              fixture.bridge.gesturePhase == .awaitingSecondPress,
              fixture.bridge.ownsKeyboardOperation else {
            throw ContractFailure(message: "retired scheduler generation acted after reset")
        }
        fixture.scheduler.advance(toMilliseconds: 600)
        guard fixture.actions == ["start", "start", "stop"],
              fixture.bridge.gesturePhase == .idle,
              !fixture.bridge.ownsKeyboardOperation else {
            throw ContractFailure(message: "current scheduler generation did not finish exactly once")
        }
    }

    static func testGestureTerminalTimeoutRetiresPendingGeneration() throws {
        // Given a short release whose operation is cancelled before its timeout.
        let fixture = GestureFixture()
        _ = fixture.press(at: 0)
        fixture.state = .recording
        _ = fixture.release(at: 100)
        fixture.state = .cancelled

        // When the pending timeout reaches its deadline.
        fixture.scheduler.advance(toMilliseconds: 450)

        // Then the cancelled generation is retired without a stop or retained ownership.
        guard fixture.actions == ["start"],
              fixture.bridge.lastResult == .reset,
              fixture.bridge.gesturePhase == .idle,
              !fixture.bridge.ownsKeyboardOperation else {
            throw ContractFailure(message: "terminal timeout retained or acted on cancelled gesture ownership")
        }
    }

    static func testGestureTerminalPressStartsFreshGeneration() throws {
        // Given a short release whose operation is interrupted before its timeout.
        let fixture = GestureFixture()
        _ = fixture.press(at: 0)
        fixture.state = .recording
        _ = fixture.release(at: 100)
        fixture.state = .interrupted

        // When a new press arrives before the retired timeout.
        let result = fixture.press(at: 200)
        fixture.scheduler.fireRetiredAction(at: 0)

        // Then it starts a fresh generation instead of locking or stopping the interrupted one.
        guard result == .start,
              fixture.actions == ["start", "start"],
              fixture.bridge.gesturePhase == .holding,
              fixture.bridge.ownsKeyboardOperation else {
            throw ContractFailure(message: "terminal press did not start a fresh gesture generation")
        }
    }

    static func testGestureTimeoutWinsDeadlineRaceExactlyOnce() throws {
        // Given a short release whose timeout and second press share the exact deadline.
        let fixture = GestureFixture()
        _ = fixture.press(at: 0)
        fixture.state = .recording
        _ = fixture.release(at: 100)

        // When the scheduler callback wins before the second press at 450 ms.
        fixture.scheduler.advance(toMilliseconds: 450)
        let result = fixture.press(at: 450)

        // Then the pending session stops once and the late press cannot claim foreign recording.
        guard result == .ignoredRecordingNotOwned,
              fixture.actions == ["start", "stop"],
              fixture.bridge.gesturePhase == .idle,
              !fixture.bridge.ownsKeyboardOperation else {
            throw ContractFailure(message: "deadline timeout race emitted a duplicate action or reclaimed ownership")
        }
    }

    static func testGestureReferenceReceipt() throws {
        // Given independent long-hold and double-tap-lock fixtures.
        let hold = GestureFixture()
        let locked = GestureFixture()

        // When both reference gestures run through the operation bridge.
        _ = hold.press(at: 0)
        hold.state = .recording
        _ = hold.release(at: 350)
        _ = locked.press(at: 0)
        locked.state = .recording
        _ = locked.release(at: 100)
        _ = locked.press(at: 449)
        _ = locked.release(at: 450)
        _ = locked.press(at: 700)

        // Then each surface emits one start and one stop with idle ownership.
        guard hold.actions == ["start", "stop"],
              locked.actions == ["start", "stop"],
              hold.bridge.gesturePhase == .idle,
              locked.bridge.gesturePhase == .idle,
              !hold.bridge.ownsKeyboardOperation,
              !locked.bridge.ownsKeyboardOperation else {
            throw ContractFailure(message: "reference gesture action or ownership receipt mismatch")
        }
        print("GESTURE_RECEIPT long-hold actions=start,stop phase=idle ownership=none")
        print("GESTURE_RECEIPT double-tap-lock actions=start,stop phase=idle ownership=none second-start=0 stop-count=1")
    }
}
