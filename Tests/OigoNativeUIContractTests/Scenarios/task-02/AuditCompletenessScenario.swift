import Foundation

final class AuditCompletenessScenario: NativeUIContractScenario {
    override class var scenarioName: String {
        "audit-completeness"
    }

    override class func run(arguments: ContractArguments) throws {
        guard FileManager.default.fileExists(atPath: arguments.fixtureRoot.path) else {
            throw ContractInputError(category: "missing-fixture-root")
        }

        let auditURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("docs/ui-audit.md")
        guard FileManager.default.fileExists(atPath: auditURL.path) else {
            throw ContractInputError(category: "audit-missing-file")
        }

        let audit = try String(contentsOf: auditURL, encoding: .utf8)
        let requiredMetadata = [
            "BASE_SHA=f62686d6ccebd9806245483aa4904e95d116e8fd",
            "TASK_01_SHA=e717d74a1d4bfbf16d5fb29496598191cd83cec2",
            "AUDIT_SHA=a3c96c4f3d775ca9cd16ac55d5f68370fa24ab4d",
            "UNRELATED_WORKFLOW_RENAME=#140 ci: drop \"master\" from project workflow"
        ]
        let requiredRows = [
            "status-idle", "status-activity", "status-recording", "status-attention",
            "menu-start-stop", "menu-settings-history-quit", "popover-ready", "popover-recording",
            "popover-processing", "popover-storage-unavailable", "popover-shortcut-inactive",
            "popover-microphone-unavailable", "popover-input-unavailable", "popover-assets-unavailable",
            "popover-accessibility-copy-only", "popover-retry-required", "popover-last-session-actions",
            "popover-next-configuration", "hud-preparing", "hud-recording", "hud-processing",
            "hud-paste-attempted", "hud-copy-only", "hud-retry-required", "hud-preserved-failure",
            "hud-cancelled", "hud-interrupted", "onboarding-storage", "onboarding-microphone-language",
            "onboarding-shortcut-insertion", "onboarding-try-it", "onboarding-done", "settings-general",
            "settings-dictation", "settings-dictionary", "settings-data-privacy", "dictionary-actions",
            "history-list-detail", "history-toolbar-actions", "history-paste-again", "history-stale-load",
            "shutdown", "stale-generation"
        ]
        guard requiredMetadata.allSatisfy(audit.contains),
              requiredRows.allSatisfy({ audit.contains("| " + $0 + " |") }) else {
            throw ContractInputError(category: "audit-missing-required-contract")
        }
        guard !audit.contains("NATIVE PASS") else {
            throw ContractInputError(category: "audit-unproven-native-pass")
        }

        print("PASS audit-completeness")
    }
}
