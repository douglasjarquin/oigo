import Foundation
import OigoCore
import OigoHotKey

final class SettingsShortcutScenario: NativeUIContractScenario {
    override class var scenarioName: String { "settings-shortcut" }

    override class func run(arguments: ContractArguments) throws {
        guard arguments.defaultsSuite == "com.oigo.qa.task12" else {
            throw ContractInputError(category: "invalid-defaults-suite")
        }
        let mode = switch arguments.fixtureRoot.lastPathComponent {
        case "success": "success"
        case "failure": "failure"
        case "task-12": "all"
        default: throw ContractInputError(category: "unsupported-settings-shortcut-fixture")
        }
        try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["swift", "build", "--product", "Oigo"]
        )
        let isolatedHome = arguments.evidenceRoot.appendingPathComponent("isolated-home", isDirectory: true)
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: isolatedHome) }
        let output = arguments.evidenceRoot.appendingPathComponent("settings-shortcut.json")
        try runProcess(
            executable: URL(fileURLWithPath: ".build/debug/Oigo"),
            arguments: ["--task-12-settings-shortcut-probe", mode, arguments.defaultsSuite, output.path],
            environment: [
                "CFFIXED_USER_HOME": isolatedHome.path,
                "HOME": isolatedHome.path,
                "OIGO_QA_MODE": "1"
            ],
            timeout: 4
        )
        let receipt = try JSONDecoder().decode(
            Task12SettingsShortcutReceipt.self,
            from: Data(contentsOf: output)
        )
        try validate(receipt, mode: mode)
        print("PASS settings-shortcut mode=\(mode) rows=\(receipt.rows.count) owner=app-delegate-callback-bundle")
    }

    private static func validate(_ receipt: Task12SettingsShortcutReceipt, mode: String) throws {
        let old = ToggleShortcut(keyCode: 13, modifiers: ToggleShortcutModifiers.command)
        let candidate = ToggleShortcut(keyCode: 0, modifiers: ToggleShortcutModifiers.command)
        let oldCopy = old.copy
        let candidateCopy = candidate.copy
        let rows = Dictionary(uniqueKeysWithValues: receipt.rows.map { ($0.action, $0) })
        var failures: [String] = []

        if mode != "failure" {
            guard let beforeSave = rows["before-shortcut-save"],
                  beforeSave.persistedShortcut == oldCopy.displayName,
                  beforeSave.committedShortcut == oldCopy.displayName,
                  beforeSave.recorderValue == candidateCopy.compactDisplayName,
                  !beforeSave.recorderAccessibilityValue.isEmpty,
                  beforeSave.registrationActive else {
                failures.append("candidate-not-persisted-before-save")
                try throwIfNeeded(failures, receipt: receipt)
                return
            }
            for action in ["saved", "stale-state", "reopen", "relaunch", "unrelated-save"] {
                guard let row = rows[action],
                      row.persistedShortcut == candidateCopy.displayName,
                      row.committedShortcut == candidateCopy.displayName,
                      row.recorderValue == candidateCopy.compactDisplayName,
                      row.hint.contains(candidateCopy.displayName),
                      row.registrationActive else {
                    failures.append("success-" + action)
                    continue
                }
            }
            if rows["unrelated-save"]?.previewEnabled != false {
                failures.append("unrelated-save-independence")
            }
            for action in ["cancel-resume", "repeated-interruption"]
                where rows[action]?.persistedShortcut != candidateCopy.displayName
                    || rows[action]?.recorderValue != candidateCopy.compactDisplayName {
                failures.append("cancellation-" + action)
            }
        }

        if mode != "success" {
            for action in ["conflict", "persistence-failure"] {
                guard let row = rows[action],
                      row.persistedShortcut == oldCopy.displayName,
                      row.committedShortcut == oldCopy.displayName,
                      row.recorderValue == oldCopy.compactDisplayName,
                      row.message.contains(oldCopy.displayName),
                      row.registrationActive else {
                    failures.append("failure-" + action)
                    continue
                }
            }
            if rows["unrelated-save-failure"]?.persistedShortcut != oldCopy.displayName
                || rows["unrelated-save-failure"]?.committedShortcut != oldCopy.displayName
                || rows["unrelated-save-failure"]?.localeIdentifier != "en-US"
                || rows["unrelated-save-failure"]?.previewEnabled != true
                || rows["unrelated-save-failure"]?.message.isEmpty != false {
                failures.append("unrelated-failure-atomicity")
            }
            guard let rollback = rows["rollback-failure"],
                  rollback.persistedShortcut == oldCopy.displayName,
                  rollback.committedShortcut == oldCopy.displayName,
                  rollback.recorderValue == oldCopy.compactDisplayName,
                  rollback.message.contains(oldCopy.displayName),
                  !rollback.registrationActive else {
                failures.append("rollback-fail-closed")
                try throwIfNeeded(failures, receipt: receipt)
                return
            }
        }
        let expectedCounts = switch mode {
        case "success": (validation: 1, shortcutSave: 1, settingsSave: 2)
        case "failure": (validation: 3, shortcutSave: 2, settingsSave: 1)
        default: (validation: 4, shortcutSave: 3, settingsSave: 3)
        }
        if receipt.shortcutSaveCount != expectedCounts.shortcutSave
            || receipt.settingsSaveCount != expectedCounts.settingsSave {
            failures.append("owner-invocation-count")
        }
        if receipt.appDelegateValidationCount != expectedCounts.validation
            || receipt.appDelegateShortcutSaveCount != expectedCounts.shortcutSave
            || receipt.appDelegateSettingsSaveCount != expectedCounts.settingsSave {
            failures.append("app-delegate-owner-invocation-count")
        }
        try throwIfNeeded(failures, receipt: receipt)
    }

    private static func throwIfNeeded(
        _ failures: [String],
        receipt: Task12SettingsShortcutReceipt
    ) throws {
        var failures = failures
        let forbidden = ["Option-Space", "⌥ Space"]
        if receipt.rows.flatMap(\.accessibilityText).contains(where: { text in
            forbidden.contains(where: text.contains)
        }) {
            failures.append("stale-default-accessibility-copy")
        }
        if receipt.rows.contains(where: {
            $0.unidentifiedActionCount != 0 || !$0.navigationCenteredIconAndLabel
        }) {
            failures.append("action-identifiers-or-navigation")
        }
        let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        if receipt.captures.isEmpty || receipt.captures.contains(where: { path in
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return true }
            return !data.starts(with: png)
        }) {
            failures.append("rendered-capture")
        }
        guard failures.isEmpty, receipt.defaultsCleaned else {
            throw ContractInputError(category: failures.first ?? "defaults-not-cleaned")
        }
    }

    private static func runProcess(
        executable: URL,
        arguments: [String],
        environment: [String: String] = [:],
        timeout: TimeInterval? = nil
    ) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, requested in requested }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        if let timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            if process.isRunning { process.terminate() }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            FileHandle.standardError.write(Data(message.utf8))
            throw ContractInputError(category: "settings-shortcut-probe-failed")
        }
    }
}

private struct Task12SettingsShortcutReceipt: Decodable {
    let rows: [Task12SettingsShortcutRow]
    let captures: [String]
    let shortcutSaveCount: Int
    let settingsSaveCount: Int
    let appDelegateValidationCount: Int
    let appDelegateShortcutSaveCount: Int
    let appDelegateSettingsSaveCount: Int
    let defaultsCleaned: Bool
}

private struct Task12SettingsShortcutRow: Decodable {
    let action: String
    let persistedShortcut: String
    let committedShortcut: String
    let recorderValue: String
    let recorderAccessibilityValue: String
    let message: String
    let status: String
    let hint: String
    let localeIdentifier: String
    let previewEnabled: Bool
    let registrationActive: Bool
    let accessibilityText: [String]
    let actionIdentifiers: [String]
    let unidentifiedActionCount: Int
    let navigationCenteredIconAndLabel: Bool
}
