import Darwin
import Foundation
import OigoCore
import OigoHotKey

@main
@available(macOS 26.0, *)
@MainActor
struct OigoIssue82ContractTests {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let filter: String? = if let index = arguments.firstIndex(of: "--filter"),
                                  arguments.indices.contains(index + 1) {
            arguments[index + 1]
        } else {
            nil
        }
        let normalizedFilter = filter?.replacingOccurrences(of: "-", with: " ")
        let scenarios: [(String, () async throws -> Void)] = [
            ("registrar atomic replacement", testRegistrarAtomicReplacement),
            ("registrar failure and generation", testRegistrarFailureAndGeneration),
            ("intent press release duplicate characterization", testIntentPressReleaseDuplicateCharacterization),
            ("gesture press starts before release", testGesturePressStartsBeforeRelease),
            ("gesture 349 ms tap", testGestureTapAt349Milliseconds),
            ("gesture 350 ms hold", testGestureHoldAt350Milliseconds),
            ("gesture 351 ms hold", testGestureHoldAt351Milliseconds),
            ("gesture short release awaits second press", testGestureShortReleaseAwaitsSecondPress),
            ("gesture second press at 349 ms locks", testGestureSecondPressAt349MillisecondsLocks),
            ("gesture second press at 350 ms times out", testGestureSecondPressAt350MillisecondsLosesToTimeout),
            ("gesture locked next tap stops once", testGestureLockedNextTapStopsOnce),
            ("gesture retired scheduler generation", testGestureRetiredSchedulerGenerationCannotAct),
            ("gesture terminal timeout retires pending generation", testGestureTerminalTimeoutRetiresPendingGeneration),
            ("gesture terminal press starts fresh generation", testGestureTerminalPressStartsFreshGeneration),
            ("gesture timeout wins deadline race exactly once", testGestureTimeoutWinsDeadlineRaceExactlyOnce),
            ("gesture reference receipt", testGestureReferenceReceipt),
            ("intent rapid tap", testIntentRapidTap),
            ("intent duplicates and processing", testIntentDuplicatesAndProcessing),
            ("shortcut contract default and migration", testShortcutContractDefaultAndMigration),
            ("speech assets gate dictation startup", testSpeechAssetsGateDictationStartup),
            ("shortcut keycode zero", testShortcutKeyCodeZero),
            ("recorder keycode zero", testRecorderKeyCodeZero),
            ("recorder rejection", testRecorderRejection),
            ("app bridge release during startup", testAppBridgeReleaseDuringStartup),
            ("native QA permission mechanism", testNativeQAPermissionMechanism),
            ("native QA destination confinement", testNativeQADestinationConfinement),
            ("native QA target field classification", testNativeQATargetFieldClassification),
            ("app bridge processing feedback", testAppBridgeProcessingFeedback),
            ("production bridge", testProductionBridge),
            ("configuration atomic save", testConfigurationAtomicSave),
            ("configuration failure restoration", testConfigurationFailureRestoration),
            ("settings store persistence failure restoration", testSettingsStorePersistenceFailureRestoration),
            ("compound rollback failure fails closed", testCompoundRollbackFailureFailsClosed),
            ("app delegate shortcut readiness", testAppDelegateShortcutReadiness),
            ("app delegate shortcut failure", testAppDelegateShortcutFailure)
        ]
        let selected = scenarios.filter { normalizedFilter == nil || $0.0.contains(normalizedFilter ?? "") }
        guard !selected.isEmpty else {
            print("FAIL: no issue #82 contract scenarios matched filter")
            exit(1)
        }

        var failures = 0
        for (name, test) in selected {
            do {
                try await test()
                print("GREEN: " + name)
            } catch {
                failures += 1
                print("FAIL: " + name + ": " + String(describing: error))
            }
        }
        guard failures == 0 else {
            print("FAILURES=" + String(failures))
            exit(1)
        }
        print("GREEN: all issue #82 contract scenarios")
    }

}
