import Foundation
import OigoCore

final class SettingsPanesScenario: NativeUIContractScenario {
    override class var scenarioName: String { "settings-panes" }

    override class func run(arguments: ContractArguments) throws {
        guard arguments.defaultsSuite == "com.oigo.qa.task18" else {
            throw ContractInputError(category: "invalid-defaults-suite")
        }
        guard OigoSettingsPane.allCases.map(\.rawValue) == [
            "general", "dictation", "dictionary", "data-privacy"
        ],
        OigoSettingsPane.allCases.map(\.title) == [
            "General", "Dictation", "Dictionary", "Data & Privacy"
        ],
        OigoSettingsCommitPolicy.immediate.contains(.defaultMode),
        OigoSettingsCommitPolicy.immediate.contains(.audioRetention),
        OigoSettingsCommitPolicy.transactional.contains(.globalShortcut),
        OigoSettingsCommitPolicy.transactional.contains(.localeIdentifier),
        OigoSettingsCommitPolicy.immediate.isDisjoint(with: OigoSettingsCommitPolicy.transactional),
        OigoSettingsCommitPolicy.immediate.union(OigoSettingsCommitPolicy.transactional)
            == Set(OigoSettingsField.allCases) else {
            throw ContractInputError(category: "settings-pane-contract")
        }
        print("PASS settings-panes toolbar=4 policies=immediate+transactional")
    }
}
