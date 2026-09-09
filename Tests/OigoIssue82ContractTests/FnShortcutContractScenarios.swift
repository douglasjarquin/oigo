import OigoCore

@MainActor
extension OigoIssue82ContractTests {
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
