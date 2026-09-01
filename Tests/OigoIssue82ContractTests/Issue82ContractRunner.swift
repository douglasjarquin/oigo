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
            ("intent rapid tap", testIntentRapidTap),
            ("intent duplicates and processing", testIntentDuplicatesAndProcessing),
            ("shortcut contract default and migration", testShortcutContractDefaultAndMigration),
            ("fixed Fn monitor ignores unrelated modifiers", testFixedFnMonitorIgnoresUnrelatedModifierChanges),
            ("speech assets gate dictation startup", testSpeechAssetsGateDictationStartup),
            ("fixed Fn shortcut gestures", testFixedFnShortcutGestures),
            ("shortcut keycode zero", testShortcutKeyCodeZero),
            ("recorder keycode zero", testRecorderKeyCodeZero),
            ("recorder rejection", testRecorderRejection),
            ("app bridge release during startup", testAppBridgeReleaseDuringStartup),
            ("keyboard release lifecycle", testKeyboardReleaseLifecycle),
            ("native QA permission mechanism", testNativeQAPermissionMechanism),
            ("native QA target field classification", testNativeQATargetFieldClassification),
            ("app bridge processing feedback", testAppBridgeProcessingFeedback),
            ("keyboard startup production bridge sequence", testKeyboardStartupProductionSequence),
            ("keyboard startup AppDelegate recovery and locale binding", testKeyboardStartupLocaleGenerationRejection),
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
