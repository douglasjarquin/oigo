import Foundation
import OigoCore
import OigoHotKey

final class OnboardingShortcutScenario: NativeUIContractScenario {
    override class var scenarioName: String { "onboarding-shortcut" }

    override class func run(arguments: ContractArguments) throws {
        guard arguments.defaultsSuite == "com.oigo.qa.task11" else {
            throw ContractInputError(category: "invalid-defaults-suite")
        }
        let selected = arguments.fixtureRoot.lastPathComponent
        let mode = switch selected {
        case "success": "success"
        case "failure": "failure"
        case "task-11": "all"
        default: throw ContractInputError(category: "unsupported-onboarding-shortcut-fixture")
        }
        try buildOigo()
        let output = arguments.evidenceRoot.appendingPathComponent("onboarding-shortcut.json")
        try runProcess(
            executable: URL(fileURLWithPath: ".build/debug/Oigo"),
            arguments: ["--task-11-onboarding-shortcut-probe", mode, arguments.defaultsSuite, output.path],
            environment: ["OIGO_QA_MODE": "1"]
        )
        let receipt = try JSONDecoder().decode(
            Task11OnboardingShortcutReceipt.self,
            from: Data(contentsOf: output)
        )
        try validate(receipt, mode: mode)
        print("PASS onboarding-shortcut mode=\(mode) rows=\(receipt.rows.count) transactional=production-controller")
    }

    private static func validate(_ receipt: Task11OnboardingShortcutReceipt, mode: String) throws {
        let old = ToggleShortcut(keyCode: 13, modifiers: ToggleShortcutModifiers.command).copy.displayName
        let candidateShortcut = ToggleShortcut(keyCode: 0, modifiers: ToggleShortcutModifiers.command)
        let candidate = candidateShortcut.copy.displayName
        let candidateCompact = ShortcutFormatter.displayName(for: candidateShortcut)
        let rows = Dictionary(uniqueKeysWithValues: receipt.rows.map { ($0.action, $0) })
        var failures: [String] = []

        if mode != "failure" {
            let expectedStages = ["stage-1": "Stage 1 of 4", "stage-2": "Stage 2 of 4", "stage-3": "Stage 3 of 4", "stage-4": "Stage 4 of 4", "done": "Setup complete"]
            for (action, stage) in expectedStages where rows[action]?.stage != stage {
                failures.append("four-stage-flow")
            }
            if rows["candidate-selected"]?.persistedShortcut != old
                || rows["candidate-selected"]?.recorderValue != candidateCompact {
                failures.append("candidate-committed-before-action")
            }
            if rows["stage-4"]?.persistedShortcut != candidate
                || rows["reopen"]?.recorderValue != candidateCompact
                || receipt.completedCount != 1 {
                failures.append("commit-or-reopen")
            }
            if rows["stale-source-ignored"]?.continueEnabled != false
                || rows["late-generation-ignored"]?.continueEnabled != false {
                failures.append("generation-fence")
            }
        }

        if mode != "success" {
            if rows["conflict"]?.continueEnabled != false
                || rows["conflict"]?.persistedShortcut != old
                || rows["conflict"]?.visibleText.contains(where: { $0.contains(old) && $0.contains("conflict") }) != true {
                failures.append("conflict-recovery")
            }
            if rows["conflict-recovered"]?.persistedShortcut != candidate {
                failures.append("conflict-retry")
            }
            for action in ["cancel", "back", "close-reopen", "save-failed"]
                where rows[action]?.persistedShortcut != old || rows[action]?.committedShortcut != old {
                failures.append("preservation-" + action)
            }
            if rows["cancel-resume"]?.persistedShortcut != old
                || rows["repeated-interruption"]?.persistedShortcut != old {
                failures.append("cancel-resume-interruption")
            }
            if rows["copy-only-offered"]?.visibleButtons.contains("Continue with copy-only") != true
                || rows["copy-only-accepted"]?.continueEnabled != true
                || rows["copy-only-accepted"]?.visibleButtons.contains("Continue with copy-only") == true
                || rows["copy-only-accepted"]?.visibleText.contains(where: {
                    $0.contains("Copy-only setup accepted")
                }) != true
                || rows["copy-only-advanced"]?.stage != "Stage 4 of 4"
                || rows["copy-only-advanced"]?.visibleText.contains(where: { $0.contains("Automatic paste is ready") }) == true {
                failures.append("copy-only-reachability")
            }
        }
        let pngSignature = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        if receipt.rows.contains(where: { !$0.visibleContentContained }) {
            failures.append("visible-content-overflow")
        }
        if receipt.captures.isEmpty || receipt.captures.contains(where: { path in
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return true }
            return !data.starts(with: pngSignature)
        }) {
            failures.append("rendered-capture")
        }
        guard failures.isEmpty, receipt.defaultsCleaned else {
            throw ContractInputError(category: failures.first ?? "defaults-not-cleaned")
        }
    }

    private static func buildOigo() throws {
        try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["swift", "build", "--product", "Oigo"]
        )
    }

    private static func runProcess(
        executable: URL,
        arguments: [String],
        environment: [String: String] = [:]
    ) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, requested in requested }
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let error = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            FileHandle.standardError.write(Data(error.utf8))
            throw ContractInputError(category: "onboarding-shortcut-probe-failed")
        }
    }
}

private struct Task11OnboardingShortcutReceipt: Decodable {
    let mode: String
    let rows: [Task11OnboardingShortcutRow]
    let captures: [String]
    let completedCount: Int
    let defaultsCleaned: Bool
}

private struct Task11OnboardingShortcutRow: Decodable {
    let action: String
    let stage: String
    let persistedShortcut: String
    let committedShortcut: String
    let recorderValue: String
    let recorderAccessibilityValue: String
    let continueEnabled: Bool
    let visibleContentContained: Bool
    let visibleButtons: [String]
    let visibleText: [String]
}
