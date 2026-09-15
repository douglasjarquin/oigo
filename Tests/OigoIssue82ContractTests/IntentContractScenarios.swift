import OigoCore
import OigoHotKey

@MainActor
extension OigoIssue82ContractTests {
    static func testIntentRapidTap() throws {
        var controller = GlobalShortcutIntentController()
        guard controller.receive(.pressed, state: .idle) == .start,
              controller.receive(.pressed, state: .idle, isRepeat: true) == .ignoredRepeat,
              controller.receive(.released, state: .idle) == .releaseLatched,
              controller.observe(.recording) == .stop,
              controller.receive(.released, state: .finalizing) == .ignoredProcessing(.finalizing) else {
            throw ContractFailure(message: "rapid release before readiness did not produce one latched stop")
        }

        print("TRACE: intent rapid tap start -> release-latched -> stop")
    }

    static func testIntentDuplicatesAndProcessing() throws {
        var controller = GlobalShortcutIntentController()
        guard controller.receive(.pressed, state: .idle) == .start,
              controller.receive(.pressed, state: .preparing) == .ignoredDuplicatePress,
              controller.receive(.released, state: .preparing) == .releaseLatched,
              controller.receive(.released, state: .preparing) == .ignoredDuplicateRelease,
              controller.observe(.recording) == .stop else {
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
        let bridge = GlobalShortcutOperationBridge(
            state: { state },
            start: { starts += 1 },
            stop: { stops += 1 },
            feedback: { feedback.append($0) }
        )

        guard bridge.receive(.pressed) == .start,
              bridge.receive(.pressed, isRepeat: true) == .ignoredRepeat,
              bridge.receive(.released) == .releaseLatched,
              starts == 1,
              stops == 0 else {
            throw ContractFailure(message: "bridge did not preserve one keyboard start and latch release during startup")
        }

        state = .recording
        guard bridge.observeState() == .stop,
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

        print("COUNTS: startup_start=1 latched_stop=1 repeated_observe_stop=0 duplicate_release_stop=0")
    }

    static func testAppBridgeProcessingFeedback() throws {
        var state = DictationState.finalizing
        var starts = 0
        var stops = 0
        var feedback: [GlobalShortcutIntentResult] = []
        let bridge = GlobalShortcutOperationBridge(
            state: { state },
            start: { starts += 1 },
            stop: { stops += 1 },
            feedback: { feedback.append($0) }
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
        guard bridge.receive(.released) == .ignoredDuplicateRelease,
              bridge.receive(.pressed) == .start,
              bridge.receive(.released) == .releaseLatched,
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
        guard bridge.receive(.pressed) == .start else {
            throw ContractFailure(message: "keyboard operation did not resume after interruption reset")
        }
        state = .recording
        guard bridge.receive(.released) == .stop,
              starts == 2,
              stops == 1 else {
            throw ContractFailure(message: "resumed keyboard operation did not stop exactly once")
        }

        print("COUNTS: invalid_release_calls=0 interrupted_reset=1 repeated_interruption=0 resumed_start=1 resumed_stop=1")
    }


}
