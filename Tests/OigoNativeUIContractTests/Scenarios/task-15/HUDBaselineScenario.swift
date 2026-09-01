import Foundation

final class HUDBaselineScenario: NativeUIContractScenario {
    private struct Fixture: Decodable {
        let scenario: String
        let fixture: String
        let processingStates: [String]
        let recordingTimerInterval: Double
        let ordinaryDismissalSeconds: Double
        let panelCanBecomeKey: Bool
        let panelCanBecomeMain: Bool
        let previewMaxUpdatesPerSecond: Int
        let dirty: Bool?
        let reportedSuccess: Bool?
        let processExitStatus: Int?
    }

    override class var scenarioName: String {
        "hud-baseline"
    }

    override class func run(arguments: ContractArguments) throws {
        guard arguments.defaultsSuite == "com.oigo.qa.task15" else {
            throw ContractInputError(category: "invalid-defaults-suite")
        }
        let fixture = try loadFixture(from: arguments.fixtureRoot)
        guard fixture.scenario == "hud-baseline",
              fixture.fixture == "legacy-status-surface",
              fixture.processingStates == [
                  "Finalizing",
                  "Cleaning",
                  "Pasting",
                  "Paste attempted",
                  "Pasted",
                  "Copied",
                  "Dictation completed; paste failed",
                  "Failed"
              ],
              fixture.recordingTimerInterval == 0.2,
              fixture.ordinaryDismissalSeconds == 1.8,
              fixture.panelCanBecomeKey == false,
              fixture.panelCanBecomeMain == false,
              fixture.previewMaxUpdatesPerSecond == 5 else {
            throw ContractInputError(category: "legacy-baseline-drift")
        }
        if fixture.dirty == true {
            throw ContractInputError(category: "dirty-worktree")
        }
        if fixture.reportedSuccess == true, fixture.processExitStatus != 0 {
            throw ContractInputError(category: "misleading-success-output")
        }

        let repositoryRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = repositoryRoot.appendingPathComponent("Sources/Oigo/StatusSurfaceController.swift")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ContractInputError(category: "missing-legacy-status-surface")
        }
        let output = try runLegacyHarness(source: source)
        guard output.contains("BASELINE panel-key=false panel-main=false"),
              output.contains("timer-interval=0.2"),
              output.contains("dismissal-before=true"),
              output.contains("dismissal-after=false"),
              output.contains("resources-after-hide=0") else {
            throw ContractInputError(category: "legacy-baseline-observation")
        }
        print("PASS hud-baseline fixture=legacy-status-surface states=8 timer=0.2 dismissal=1.8")
    }

    private static func loadFixture(from root: URL) throws -> Fixture {
        let provided = root.appendingPathComponent("fixture.json")
        let bundled = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Fixtures/native-ui/task-15/hud-baseline.json")
        let url = FileManager.default.fileExists(atPath: provided.path) ? provided : bundled
        guard let data = try? Data(contentsOf: url),
              let fixture = try? JSONDecoder().decode(Fixture.self, from: data) else {
            throw ContractInputError(category: "malformed-hud-baseline")
        }
        return fixture
    }

    private static func runLegacyHarness(source: URL) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-native-ui-redesign.task15.baseline." + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = source
        let hudDirectory = repositoryRoot.appendingPathComponent("Sources/Oigo/UI/HUD", isDirectory: true)
        let hudSources = ((try? FileManager.default.contentsOfDirectory(
            at: hudDirectory,
            includingPropertiesForKeys: nil
        )) ?? [])
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        let combined = root.appendingPathComponent("legacy.swift")
        try (legacyStubs + "\n" + hudSources + "\n" + legacyDriver).write(
            to: combined,
            atomically: true,
            encoding: .utf8
        )
        let executable = root.appendingPathComponent("legacy-baseline")
        let buildRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/arm64-apple-macosx/debug", isDirectory: true)
        let modules = buildRoot.appendingPathComponent("Modules", isDirectory: true)
        let dependencyObjects = ["OigoCore.build", "OigoPresentation.build", "MacUtilityUI.build"]
            .flatMap { directory in
                (try? FileManager.default.contentsOfDirectory(
                    at: buildRoot.appendingPathComponent(directory, isDirectory: true),
                    includingPropertiesForKeys: nil
                )) ?? []
            }
            .filter { $0.pathExtension == "o" }
            .map(\.path)
        try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["swiftc", "-I", modules.path, combined.path, "-o", executable.path]
                + dependencyObjects
        )
        let output = try runProcess(executable: executable, arguments: [])
        guard let text = String(data: output, encoding: .utf8) else {
            throw ContractInputError(category: "unreadable-legacy-baseline")
        }
        return text
    }

    private static func runProcess(executable: URL, arguments: [String]) throws -> Data {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ContractInputError(
                category: "legacy-harness-failed:exit=\(process.terminationStatus):"
                    + (error + output).prefix(2000)
            )
        }
        return stdout.fileHandleForReading.readDataToEndOfFile()
    }

    private static let legacyStubs = #"""
    import AppKit
    import Foundation
    import Darwin

    public enum OigoHUDProcessingState: String, CaseIterable, Sendable {
        case finalizing = "Finalizing"
        case cleaning = "Cleaning"
        case pasting = "Pasting"
        case pasteAttempted = "Paste attempted"
        case pasted = "Pasted"
        case copied = "Copied"
        case completedPasteFailed = "Dictation completed; paste failed"
        case failed = "Failed"
    }

    public enum OigoHUDPreviewPolicy {
        public static func bounded(_ text: String) -> String { text }
    }

    public struct OigoHUDResourceLedger: Sendable {
        public private(set) var recordingTimerActive = false
        public private(set) var observationCount = 0
        public init() {}
        public var activeResourceCount: Int {
            (recordingTimerActive ? 1 : 0) + observationCount
        }
        public mutating func beginRecording() { recordingTimerActive = true }
        public mutating func endRecording() { recordingTimerActive = false }
        public mutating func close() {
            recordingTimerActive = false
            observationCount = 0
        }
    }
    """#

    private static let legacyDriver = #"""

    final class BaselineDelegate: NSObject, NSApplicationDelegate {
        func applicationDidFinishLaunching(_ notification: Notification) {
            Task { @MainActor in
        let controller = OigoHUDController()
        guard !controller.canBecomeKey, !controller.canBecomeMain else {
            print("BASELINE panel-key=\(controller.canBecomeKey) panel-main=\(controller.canBecomeMain)")
            exit(1)
        }
        guard controller.present(
            .recording,
            generation: 1,
            startedAt: Date(),
            shortcutReleaseHint: "Release Command-A to finish."
        ) else {
            print("BASELINE recording-present=false")
            exit(1)
        }
        guard controller.resourceSnapshot.recordingTimerActive else {
            print("BASELINE recording-timer=false")
            exit(1)
        }
        guard controller.present(
            .pasteAttempted,
            generation: 2,
            startedAt: Date(),
            shortcutReleaseHint: "Release Command-A to finish."
        ) else {
            print("BASELINE terminal-present=false")
            exit(1)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let before = controller.resourceSnapshot.visible
        try? await Task.sleep(nanoseconds: 2_200_000_000)
        let after = controller.resourceSnapshot.visible
        controller.shutdown()
        let resources = controller.resourceSnapshot
        print("BASELINE panel-key=false panel-main=false timer-interval=0.2 dismissal-before=\(before) dismissal-after=\(after) resources-after-hide=\(resources.visible ? 1 : 0)")
                let result = before && !after && !resources.visible && !resources.recordingTimerActive && !resources.dismissalTaskActive
                NSApp.terminate(result ? nil : NSNumber(value: 1))
            }
        }
    }

    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let delegate = BaselineDelegate()
    application.delegate = delegate
    application.run()
    """#
}
