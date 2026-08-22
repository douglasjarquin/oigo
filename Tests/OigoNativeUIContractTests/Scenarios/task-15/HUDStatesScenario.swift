import Foundation

final class HUDStatesScenario: NativeUIContractScenario {
    private struct Fixture: Codable {
        struct State: Codable {
            let id: String
            let title: String
            let detail: String
            let tone: String
            let iconRole: String
            let actionability: String
            let dismissal: String
            let dismissalSeconds: Double?
            let terminal: Bool
            let recordingTimer: Bool
            let preview: Bool
        }

        struct Cadence: Codable {
            let recordingTimes: [Double]
            let recordingResults: [Bool]
            let previewTimes: [Double]
            let previewResults: [Bool]
            let ordinaryDismissalSeconds: Double
            let actionableDismissalSeconds: Double
        }

        let scenario: String
        let fixture: String
        let states: [State]
        let cadence: Cadence
        let dirty: Bool?
        let reportedSuccess: Bool?
        let processExitStatus: Int?
    }

    override class var scenarioName: String {
        "hud-states"
    }

    override class func run(arguments: ContractArguments) throws {
        guard arguments.defaultsSuite == "com.oigo.qa.task15" else {
            throw ContractInputError(category: "invalid-defaults-suite")
        }
        let fixture = try loadFixture(from: arguments.fixtureRoot)
        try validateFixture(fixture)

        let repositoryRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let stateSource = repositoryRoot.appendingPathComponent("Sources/Oigo/UI/HUD/OigoHUDState.swift")
        let policySource = repositoryRoot.appendingPathComponent("Sources/Oigo/UI/HUD/OigoHUDPolicy.swift")
        let lifecycleSource = repositoryRoot.appendingPathComponent("Sources/Oigo/UI/HUD/OigoHUDLifecycle.swift")
        let geometrySource = repositoryRoot.appendingPathComponent("Sources/Oigo/UI/HUD/HUDTargetGeometry.swift")
        let controllerSource = repositoryRoot.appendingPathComponent("Sources/Oigo/UI/HUD/OigoHUDController.swift")
        guard [stateSource, policySource, lifecycleSource].allSatisfy({
            FileManager.default.fileExists(atPath: $0.path)
        }) else {
            throw ContractInputError(category: "missing-hud-shell")
        }
        let output = try runCompiledContract(
            sources: [stateSource, policySource, lifecycleSource],
            fixture: fixture
        )
        guard output.contains("PASS hud-state-matrix"),
              output.contains("PASS hud-preview-bound"),
              output.contains("PASS hud-cadence"),
              output.contains("PASS hud-generation") else {
            throw ContractInputError(category: "unexpected-hud-contract-output")
        }
        let controllerOutput = try runControllerContract(
            sources: [stateSource, policySource, lifecycleSource, geometrySource, controllerSource]
        )
        guard controllerOutput.contains("PASS hud-controller-shutdown") else {
            throw ContractInputError(category: "unexpected-hud-controller-output")
        }
        print("PASS hud-states fixture=exhaustive states=\(fixture.states.count) cadence=1hz/5hz controller=shutdown-clean")
    }

    private static func loadFixture(from root: URL) throws -> Fixture {
        let provided = root.appendingPathComponent("fixture.json")
        let bundled = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Fixtures/native-ui/task-15/hud-states-exhaustive.json")
        let url = FileManager.default.fileExists(atPath: provided.path) ? provided : bundled
        guard let data = try? Data(contentsOf: url),
              let fixture = try? JSONDecoder().decode(Fixture.self, from: data) else {
            throw ContractInputError(category: "malformed-hud-states")
        }
        return fixture
    }

    private static func validateFixture(_ fixture: Fixture) throws {
        guard fixture.scenario == "hud-states",
              fixture.fixture == "exhaustive",
              fixture.states.count == 18,
              Set(fixture.states.map(\.id)).count == fixture.states.count,
              fixture.cadence.recordingTimes.count == fixture.cadence.recordingResults.count,
              fixture.cadence.previewTimes.count == fixture.cadence.previewResults.count else {
            throw ContractInputError(category: "incomplete-hud-state-fixture")
        }
        if fixture.dirty == true {
            throw ContractInputError(category: "dirty-worktree")
        }
        if fixture.reportedSuccess == true, fixture.processExitStatus != 0 {
            throw ContractInputError(category: "misleading-success-output")
        }
        let required = [
            "preparing", "recording", "degraded-recording", "finalizing", "cleaning", "pasting",
            "paste-attempted", "copied", "copy-only", "saved-retry", "preserved-failure",
            "cleanup-fallback", "cancelled-before-raw", "cancelled-after-raw", "interrupted",
            "paste-again-destination", "terminal", "shutdown"
        ]
        guard fixture.states.map(\.id).sorted() == required.sorted() else {
            throw ContractInputError(category: "incomplete-hud-state-fixture")
        }
    }

    private static func runCompiledContract(
        sources: [URL],
        fixture: Fixture
    ) throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-native-ui-redesign.task15.states." + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let driver = root.appendingPathComponent("main.swift")
        let payload = root.appendingPathComponent("fixture.json")
        let executable = root.appendingPathComponent("hud-states-contract")
        try JSONEncoder().encode(fixture).write(to: payload, options: .atomic)
        try contractDriver.write(to: driver, atomically: true, encoding: .utf8)
        _ = try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["swiftc"] + sources.map(\.path) + [driver.path, "-o", executable.path]
        )
        let data = try runProcess(executable: executable, arguments: [payload.path])
        guard let output = String(data: data, encoding: .utf8) else {
            throw ContractInputError(category: "unreadable-hud-contract-output")
        }
        return output
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
                category: "hud-contract-build-failed:exit=\(process.terminationStatus):"
                    + (error + output).prefix(2000)
            )
        }
        return stdout.fileHandleForReading.readDataToEndOfFile()
    }

    private static func runControllerContract(sources: [URL]) throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-native-ui-redesign.task15.controller." + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let driver = root.appendingPathComponent("main.swift")
        let executable = root.appendingPathComponent("hud-controller-contract")
        try controllerContractDriver.write(to: driver, atomically: true, encoding: .utf8)
        _ = try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["swiftc"] + sources.map(\.path) + [driver.path, "-framework", "AppKit", "-o", executable.path]
        )
        let data = try runProcess(executable: executable, arguments: [])
        guard let output = String(data: data, encoding: .utf8) else {
            throw ContractInputError(category: "unreadable-hud-controller-output")
        }
        return output
    }

    private static let contractDriver = #"""
    import Foundation
    import Darwin

    private struct Fixture: Decodable {
        struct State: Decodable {
            let id: String
            let title: String
            let detail: String
            let tone: String
            let iconRole: String
            let actionability: String
            let dismissal: String
            let dismissalSeconds: Double?
            let terminal: Bool
            let recordingTimer: Bool
            let preview: Bool
        }
        struct Cadence: Decodable {
            let recordingTimes: [Double]
            let recordingResults: [Bool]
            let previewTimes: [Double]
            let previewResults: [Bool]
            let ordinaryDismissalSeconds: Double
            let actionableDismissalSeconds: Double
        }
        let states: [State]
        let cadence: Cadence
    }

    let data = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    private let fixture = try! JSONDecoder().decode(Fixture.self, from: data)
    var statePass = true
    for expected in fixture.states {
        guard let state = OigoHUDState(rawValue: expected.id) else {
            statePass = false
            break
        }
        let content = OigoHUDShellPolicy.content(for: state)
        let dismissal = content.dismissal
        guard content.title == expected.title,
              content.detail == expected.detail,
              content.tone.rawValue == expected.tone,
              content.iconRole.rawValue == expected.iconRole,
              content.actionability.rawValue == expected.actionability,
              dismissal.kind.rawValue == expected.dismissal,
              dismissal.seconds == expected.dismissalSeconds,
              content.isTerminal == expected.terminal,
              content.showsRecordingElapsed == expected.recordingTimer,
              content.allowsPreview == expected.preview,
              !content.title.isEmpty,
              !content.detail.isEmpty,
              !content.title.lowercased().contains("verified"),
              !content.detail.lowercased().contains("verified") else {
            statePass = false
            break
        }
    }
    guard statePass else { exit(1) }
    print("PASS hud-state-matrix")

    let previewInput = String(repeating: "a", count: 179) + "👩‍💻" + String(repeating: "b", count: 70)
    let preview = OigoHUDShellPolicy.boundedPreview(previewInput)
    let expectedPreview = String(repeating: "a", count: 179) + "👩‍💻"
    guard OigoHUDShellPolicy.previewMaxCharacters == 180,
          preview.count == 180,
          preview == expectedPreview else { exit(5) }
    print("PASS hud-preview-bound")

    var cadence = OigoHUDLifecycle()
    guard cadence.present(.recording, generation: 10, visible: true) else { exit(1) }
    let recordingResults = fixture.cadence.recordingTimes.map { cadence.recordingTick(at: $0) }
    guard recordingResults == fixture.cadence.recordingResults else { exit(1) }
    let previewResults = fixture.cadence.previewTimes.map { cadence.previewPublicationAllowed(at: $0) }
    guard previewResults == fixture.cadence.previewResults else { exit(1) }
    cadence.hide(generation: 10)
    guard !cadence.recordingTick(at: 4), !cadence.previewPublicationAllowed(at: 4) else { exit(1) }
    guard fixture.cadence.ordinaryDismissalSeconds >= 1.5,
          fixture.cadence.ordinaryDismissalSeconds <= 2.0,
          fixture.cadence.actionableDismissalSeconds >= 2.5,
          fixture.cadence.actionableDismissalSeconds <= 3.5 else { exit(1) }
    print("PASS hud-cadence")

    guard cadence.present(.recording, generation: 20, visible: true),
          !cadence.present(.preparing, generation: 19, visible: true),
          cadence.state == .recording,
          cadence.visible,
          !cadence.hide(generation: 19),
          cadence.visible else { exit(1) }
    cadence.present(.pasteAgainDestination, generation: 20, visible: true)
    guard cadence.state == .pasteAgainDestination,
          cadence.visible,
          !cadence.previewPublicationAllowed(at: 5) else { exit(1) }
    cadence.shutdown()
    guard !cadence.visible,
          cadence.state == nil,
          cadence.generation == nil,
          cadence.resourceCount == 0 else { exit(1) }
    print("PASS hud-generation")
    """#

    private static let controllerContractDriver = #"""
    import AppKit
    import Foundation

    final class SyntheticSessionReference: NSObject {}

    @MainActor
    final class ControllerDelegate: NSObject, NSApplicationDelegate {
        func applicationDidFinishLaunching(_ notification: Notification) {
            let controller = OigoHUDController()
            let sessionReference = SyntheticSessionReference()
            guard controller.present(
                .recording,
                generation: 1,
                startedAt: Date(),
                sessionReference: sessionReference
            ) else {
                exit(1)
            }
            let recording = controller.resourceSnapshot
            guard controller.isVisible, recording.recordingTimerActive else {
                exit(2)
            }
            guard controller.present(.shutdown, generation: 2, sessionReference: sessionReference) else {
                exit(3)
            }
            let shutdown = controller.resourceSnapshot
            guard !controller.isVisible,
                  !shutdown.visible,
                  !shutdown.recordingTimerActive,
                  !shutdown.dismissalTaskActive,
                  shutdown.previewCharacters == 0,
                  !shutdown.sessionReferenceHeld,
                  shutdown.state == nil,
                  shutdown.generation == nil,
                  !controller.canBecomeKey,
                  !controller.canBecomeMain else {
                exit(4)
            }
            print("PASS hud-controller-shutdown")
            NSApp.terminate(nil)
        }
    }

    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let delegate = MainActor.assumeIsolated { ControllerDelegate() }
    application.delegate = delegate
    application.run()
    """#
}
