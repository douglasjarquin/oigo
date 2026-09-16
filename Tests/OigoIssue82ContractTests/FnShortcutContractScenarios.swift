import OigoCore
import OigoHotKey

@MainActor
extension OigoIssue82ContractTests {
    static func testFunctionKeyTapLifecycle() throws {
        var state = FunctionKeyShortcutState(isDown: false)
        guard state.update(isDown: true) == .pressed,
              state.update(isDown: true) == nil,
              state.update(isDown: false) == .released,
              state.update(isDown: false) == nil else {
            throw ContractFailure(message: "Fn tap did not emit exactly one edge per transition")
        }

        var heldAtRegistration = FunctionKeyShortcutState(isDown: true)
        guard heldAtRegistration.update(isDown: true) == nil,
              heldAtRegistration.update(isDown: false) == nil,
              heldAtRegistration.update(isDown: true) == .pressed,
              heldAtRegistration.update(isDown: false) == .released else {
            throw ContractFailure(message: "Fn registration while held synthesized a gesture")
        }

        for stillHeld in [true, false] {
            _ = state.update(isDown: true)
            guard state.reset(isDown: stillHeld) == .released,
                  state.reset(isDown: stillHeld) == nil,
                  state.update(isDown: false) == nil,
                  state.update(isDown: true) == .pressed,
                  state.update(isDown: false) == .released else {
                throw ContractFailure(message: "Fn tap recovery did not release once and require a fresh press")
            }
        }
        guard state.reset(isDown: false) == nil else {
            throw ContractFailure(message: "Idle Fn tap reset synthesized a release")
        }
        print("FN_TAP_RECEIPT edges=once held-at-registration=ignored recovery=release-once fresh-press=required")
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

}
