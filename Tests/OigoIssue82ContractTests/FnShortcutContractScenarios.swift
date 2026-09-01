import OigoCore
import OigoHotKey

@MainActor
extension OigoIssue82ContractTests {
    static func testFixedFnMonitorIgnoresUnrelatedModifierChanges() throws {
        var detector = FnKeyEdgeDetector()
        guard detector.receive(keyCode: 63, functionFlagSet: true) == .pressed else {
            throw ContractFailure(message: "Fn press was not detected")
        }
        guard detector.receive(keyCode: 56, functionFlagSet: false) == nil else {
            throw ContractFailure(message: "unrelated modifier change falsely released held Fn")
        }
        guard detector.receive(keyCode: 63, functionFlagSet: false) == .released else {
            throw ContractFailure(message: "physical Fn release was not detected")
        }
    }

    static func testSpeechAssetsGateDictationStartup() throws {
        let unavailable = AppCommandAvailability.evaluate(
            coordinatorState: .idle,
            occupiedKind: nil,
            acceptingCommands: true,
            setupComplete: true,
            storageReady: true,
            speechAssetsReady: false
        )
        let ready = AppCommandAvailability.evaluate(
            coordinatorState: .idle,
            occupiedKind: nil,
            acceptingCommands: true,
            setupComplete: true,
            storageReady: true,
            speechAssetsReady: true
        )
        guard !unavailable.canStartDictation, ready.canStartDictation else {
            throw ContractFailure(message: "dictation startup was not gated on onboarding speech asset readiness")
        }
    }

    static func testFixedFnShortcutGestures() throws {
        let fnShortcut = OigoSettings.default.globalShortcut
        guard fnShortcut.keyCode == 63, fnShortcut.modifiers == 0 else {
            throw ContractFailure(message: "fixed Fn shortcut did not use key code 63 without modifiers")
        }
        let registration = FixedFnShortcutRegistrationClient()
        try registration.register(shortcut: fnShortcut, onEvent: { _ in })
        guard registration.status == .active(fnShortcut, generation: 1) else {
            throw ContractFailure(message: "fixed Fn registration did not become active")
        }
        do {
            try registration.register(
                shortcut: ToggleShortcut(keyCode: 0, modifiers: ToggleShortcutModifiers.command),
                onEvent: { _ in }
            )
            throw ContractFailure(message: "fixed Fn registration accepted a custom shortcut")
        } catch FixedFnShortcutRegistrationError.nonFnShortcut {
        }

        var pushToTalk = FnShortcutGestureController()
        guard pushToTalk.receive(.pressed, at: 0) == .start,
              pushToTalk.receive(.released, at: 0.05) == .releaseDeferred,
              pushToTalk.advance(to: 0.31) == .stop,
              !pushToTalk.isHandsFree else {
            throw ContractFailure(message: "Fn hold did not start and stop push-to-talk")
        }

        var handsFree = FnShortcutGestureController()
        guard handsFree.receive(.pressed, at: 1) == .start else {
            throw ContractFailure(message: "Fn double-tap did not start the first tap")
        }
        guard handsFree.receive(.released, at: 1.05) == .releaseDeferred else {
            throw ContractFailure(message: "Fn double-tap did not defer the first release")
        }
        guard handsFree.receive(.pressed, at: 1.15) == .enterHandsFree else {
            throw ContractFailure(message: "Fn double-tap did not enter hands-free mode")
        }
        guard handsFree.receive(.released, at: 1.2) == .ignored,
              handsFree.isHandsFree else {
            throw ContractFailure(message: "Fn double-tap release exited hands-free mode")
        }
        guard handsFree.receive(.pressed, at: 2) == .stop,
              handsFree.receive(.released, at: 2.05) == .ignored,
              !handsFree.isHandsFree else {
            throw ContractFailure(message: "Fn did not stop hands-free mode")
        }
    }
}
