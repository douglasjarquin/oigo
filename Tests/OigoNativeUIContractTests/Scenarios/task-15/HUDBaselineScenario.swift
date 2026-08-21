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
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-native-ui-redesign.task15.baseline." + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceText = try String(contentsOf: source, encoding: .utf8)
            .replacingOccurrences(of: "import OigoCore\n", with: "")
        let combined = root.appendingPathComponent("legacy.swift")
        try (legacyStubs + "\n" + sourceText + "\n" + legacyDriver).write(
            to: combined,
            atomically: true,
            encoding: .utf8
        )
        let executable = root.appendingPathComponent("legacy-baseline")
        try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["swiftc", combined.path, "-o", executable.path]
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

    public enum OigoPresentationStatus: String {
        case idle = "Idle"
    }

    public struct OigoPresentationState {
        public let status: OigoPresentationStatus
    }

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

    extension StatusSurfaceController {
        var baselinePanelCanBecomeKey: Bool { panel.canBecomeKey }
        var baselinePanelCanBecomeMain: Bool { panel.canBecomeMain }
        var baselineTimerInterval: TimeInterval? { recordingTimer?.timeInterval }
        var baselinePanelVisible: Bool { panel.isVisible }
        var baselineResourceCount: Int { resourceLedger.activeResourceCount }
    }

    final class BaselineDelegate: NSObject, NSApplicationDelegate {
        func applicationDidFinishLaunching(_ notification: Notification) {
            Task { @MainActor in
        let controller = StatusSurfaceController(commandHandler: { _ in })
        guard !controller.baselinePanelCanBecomeKey,
              !controller.baselinePanelCanBecomeMain else {
            print("BASELINE panel-key=\(controller.baselinePanelCanBecomeKey) panel-main=\(controller.baselinePanelCanBecomeMain)")
            exit(1)
        }
        controller.showRecording(
            startedAt: Date(),
            preview: "synthetic preview",
            anchoredTo: nil
        )
        guard controller.baselineTimerInterval == 0.2 else {
            print("BASELINE timer-interval=\(controller.baselineTimerInterval ?? -1)")
            exit(1)
        }
        controller.showProcessing(.pasteAttempted, detail: "synthetic terminal", anchoredTo: nil)
        try? await Task.sleep(nanoseconds: 50_000_000)
        let before = controller.baselinePanelVisible
        try? await Task.sleep(nanoseconds: 1_850_000_000)
        let after = controller.baselinePanelVisible
        controller.hide()
        print("BASELINE panel-key=false panel-main=false timer-interval=0.2 dismissal-before=\(before) dismissal-after=\(after) resources-after-hide=\(controller.baselineResourceCount)")
                let result = before && !after && controller.baselineResourceCount == 0
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
