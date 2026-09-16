import OigoCore
import OigoHotKey

@MainActor
extension OigoIssue82ContractTests {
    static func testIntentPressReleaseDuplicateCharacterization() throws {
        // Given a fresh shortcut intent owner.
        var controller = GlobalShortcutIntentController()

        // When one physical press is followed by repeat, duplicate, release, and duplicate release edges.
        let press = controller.receive(.pressed, state: .idle)
        let repeatPress = controller.receive(.pressed, state: .preparing, isRepeat: true)
        let duplicatePress = controller.receive(.pressed, state: .preparing)
        let release = controller.receive(.released, state: .preparing)
        let duplicateRelease = controller.receive(.released, state: .preparing)

        // Then exactly one start is emitted, release stays pending, and duplicate edges remain inert.
        guard press == .start,
              repeatPress == .ignoredRepeat,
              duplicatePress == .ignoredDuplicatePress,
              release != .stop,
              duplicateRelease == .ignoredDuplicateRelease,
              controller.ownsKeyboardOperation,
              !controller.isPhysicalDown else {
            throw ContractFailure(message: "press/release duplicate characterization changed")
        }

        print("CHARACTERIZATION: start=1 repeat=ignored duplicate-press=ignored release=pending duplicate-release=ignored ownership=keyboard")
    }

    static func testIntentRapidTap() throws {
        var controller = GlobalShortcutIntentController()
        let press = controller.receive(.pressed, state: .idle, now: .zero)
        let repeatPress = controller.receive(.pressed, state: .idle, isRepeat: true, now: .zero)
        let shortRelease = controller.receive(.released, state: .idle, now: .milliseconds(100))
        guard case .awaitingSecondPress(let generation) = shortRelease else {
            throw ContractFailure(message: "rapid release did not await a second press")
        }
        guard press == .start,
              repeatPress == .ignoredRepeat,
              controller.observe(.recording) == nil,
              controller.timeout(generation: generation, state: .recording) == .stop,
              controller.receive(.released, state: .finalizing) == .ignoredProcessing(.finalizing) else {
            throw ContractFailure(message: "rapid release did not remain active until its timeout")
        }

        print("TRACE: intent rapid tap start -> awaiting-second-press -> timeout -> stop")
    }

    static func testIntentDuplicatesAndProcessing() throws {
        var controller = GlobalShortcutIntentController()
        guard controller.receive(.pressed, state: .idle, now: .zero) == .start,
              controller.receive(.pressed, state: .preparing) == .ignoredDuplicatePress,
              controller.receive(.released, state: .preparing, now: .milliseconds(100)) == .awaitingSecondPress(generation: 1),
              controller.receive(.released, state: .preparing, now: .milliseconds(101)) == .ignoredDuplicateRelease,
              controller.observe(.recording) == nil,
              controller.timeout(generation: 1, state: .recording) == .stop else {
            throw ContractFailure(message: "duplicate shortcut edges changed ownership or stop count")
        }

        var mouseOwnedRecording = GlobalShortcutIntentController()
        guard mouseOwnedRecording.receive(.pressed, state: .recording) == .ignoredRecordingNotOwned,
              mouseOwnedRecording.receive(.released, state: .recording) == .ignoredRecordingNotOwned,
              controller.receive(.pressed, state: .cleaning) == .ignoredProcessing(.cleaning),
              controller.receive(.released, state: .inserting) == .ignoredProcessing(.inserting) else {
            throw ContractFailure(message: "processing or mouse-owned recording input was not ignored explicitly")
        }
    }

    static func testAppBridgeReleaseDuringStartup() throws {
        var state = DictationState.idle
        var starts = 0
        var stops = 0
        var feedback: [GlobalShortcutIntentResult] = []
        let scheduler = ManualGestureScheduler()
        let bridge = GlobalShortcutOperationBridge(
            state: { state },
            start: { starts += 1 },
            stop: { stops += 1 },
            feedback: { feedback.append($0) },
            clock: { scheduler.now },
            scheduler: { delay, action in scheduler.schedule(after: delay, action: action) }
        )

        scheduler.setNow(milliseconds: 0)
        let press = bridge.receive(.pressed)
        let repeatPress = bridge.receive(.pressed, isRepeat: true)
        scheduler.setNow(milliseconds: 100)
        let release = bridge.receive(.released)
        guard case .awaitingSecondPress = release else {
            throw ContractFailure(message: "bridge did not schedule the startup second-press window")
        }
        guard press == .start,
              repeatPress == .ignoredRepeat,
              starts == 1,
              stops == 0 else {
            throw ContractFailure(message: "bridge did not preserve one keyboard start during the short release window")
        }

        state = .recording
        guard bridge.observeState() == nil else {
            throw ContractFailure(message: "recording readiness stopped a short release before timeout")
        }
        scheduler.advance(toMilliseconds: 450)
        guard bridge.observeState() == nil,
              bridge.observeState() == nil,
              bridge.receive(.released) == .ignoredRecordingNotOwned,
              stops == 1,
              !feedback.contains(.ignoredProcessing(.finalizing)) else {
            throw ContractFailure(message: "latched release was not consumed exactly once at recording")
        }

        state = .finalizing
        guard bridge.receive(.released) == .ignoredProcessing(.finalizing),
              starts == 1,
              stops == 1 else {
            throw ContractFailure(message: "processing release changed the active operation")
        }

        print("COUNTS: startup_start=1 timeout_stop=1 repeated_observe_stop=0 duplicate_release_stop=0")
    }

    static func testAppBridgeProcessingFeedback() throws {
        var state = DictationState.finalizing
        var starts = 0
        var stops = 0
        var feedback: [GlobalShortcutIntentResult] = []
        let scheduler = ManualGestureScheduler()
        let bridge = GlobalShortcutOperationBridge(
            state: { state },
            start: { starts += 1 },
            stop: { stops += 1 },
            feedback: { feedback.append($0) },
            clock: { scheduler.now },
            scheduler: { delay, action in scheduler.schedule(after: delay, action: action) }
        )

        guard bridge.receive(.pressed) == .ignoredProcessing(.finalizing),
              bridge.receive(.released) == .ignoredProcessing(.finalizing),
              feedback == [.ignoredProcessing(.finalizing), .ignoredProcessing(.finalizing)],
              starts == 0,
              stops == 0 else {
            throw ContractFailure(message: "processing input did not produce explicit feedback without commands")
        }

        state = .recording
        guard bridge.receive(.pressed) == .ignoredRecordingNotOwned,
              bridge.receive(.released) == .ignoredRecordingNotOwned,
              starts == 0,
              stops == 0 else {
            throw ContractFailure(message: "keyboard input claimed a mouse-owned recording")
        }

        state = .idle
        scheduler.setNow(milliseconds: 0)
        let invalidRelease = bridge.receive(.released)
        let press = bridge.receive(.pressed)
        scheduler.setNow(milliseconds: 100)
        let shortRelease = bridge.receive(.released)
        guard case .awaitingSecondPress = shortRelease else {
            throw ContractFailure(message: "short release did not enter the second-press window")
        }
        guard invalidRelease == .ignoredDuplicateRelease,
              press == .start,
              starts == 1,
              stops == 0 else {
            throw ContractFailure(message: "invalid release or pre-readiness release changed operation ownership")
        }

        state = .interrupted
        guard bridge.observeState() == .reset,
              bridge.observeState() == nil else {
            throw ContractFailure(message: "repeated interruption did not clear keyboard ownership exactly once")
        }

        state = .idle
        scheduler.setNow(milliseconds: 1_000)
        guard bridge.receive(.pressed) == .start else {
            throw ContractFailure(message: "keyboard operation did not resume after interruption reset")
        }
        state = .recording
        scheduler.setNow(milliseconds: 1_350)
        guard bridge.receive(.released) == .stop,
              starts == 2,
              stops == 1 else {
            throw ContractFailure(message: "resumed keyboard operation did not stop exactly once")
        }

        print("COUNTS: invalid_release_calls=0 interrupted_reset=1 repeated_interruption=0 resumed_start=1 resumed_stop=1")
    }


}
