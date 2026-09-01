@MainActor
extension OigoIssue82ContractTests {
    static func testKeyboardStartupReadinessProviderLifecycle() throws {
        try Task15AppDelegateStartupContracts.verifyRecoveryAndLocaleBinding()
    }

    static func testKeyboardStartupCancellationCleanup() async throws {
        try Task15AppDelegateStartupContracts.verifyRecoveryAndLocaleBinding()
    }

    static func testKeyboardStartupProductionSequence() async throws {
        try Task15AppDelegateStartupContracts.verifyProductionBridgeSequence()
    }

    static func testKeyboardStartupLocaleGenerationRejection() throws {
        try Task15AppDelegateStartupContracts.verifyRecoveryAndLocaleBinding()
    }

}
