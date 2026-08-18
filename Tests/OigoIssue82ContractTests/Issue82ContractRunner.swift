import Darwin
import Foundation
import OigoCore
import OigoHotKey

@main
@available(macOS 13.0, *)
@MainActor
struct OigoIssue82ContractTests {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let filter: String? = if let index = arguments.firstIndex(of: "--filter"),
                                  arguments.indices.contains(index + 1) {
            arguments[index + 1]
        } else {
            nil
        }
        let normalizedFilter = filter?.replacingOccurrences(of: "-", with: " ")
        let scenarios: [(String, () throws -> Void)] = [
            ("registrar atomic replacement", testRegistrarAtomicReplacement),
            ("registrar failure and generation", testRegistrarFailureAndGeneration),
            ("intent rapid tap", testIntentRapidTap),
            ("intent duplicates and processing", testIntentDuplicatesAndProcessing),
            ("shortcut contract default and migration", testShortcutContractDefaultAndMigration),
            ("shortcut keycode zero", testShortcutKeyCodeZero),
            ("recorder keycode zero", testRecorderKeyCodeZero),
            ("recorder rejection", testRecorderRejection),
            ("app bridge release during startup", testAppBridgeReleaseDuringStartup),
            ("app bridge processing feedback", testAppBridgeProcessingFeedback),
            ("configuration atomic save", testConfigurationAtomicSave),
            ("configuration failure restoration", testConfigurationFailureRestoration),
            ("settings store persistence failure restoration", testSettingsStorePersistenceFailureRestoration),
            ("compound rollback failure fails closed", testCompoundRollbackFailureFailsClosed)
        ]
        let selected = scenarios.filter { normalizedFilter == nil || $0.0.contains(normalizedFilter ?? "") }
        guard !selected.isEmpty else {
            print("FAIL: no issue #82 contract scenarios matched filter")
            exit(1)
        }

        var failures = 0
        for (name, test) in selected {
            do {
                try test()
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
