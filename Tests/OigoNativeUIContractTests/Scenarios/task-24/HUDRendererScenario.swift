import Foundation

final class HUDRendererScenario: NativeUIContractScenario {
    private struct Fixture: Codable {
        struct State: Codable {
            let id: String
            let width: Double
            let height: Double
            let preview: Bool
            let timer: Bool
            let dismissal: String
        }

        let scenario: String
        let fixture: String
        let shortcutReleaseHint: String
        let radius: Double
        let currentGeneration: UInt64
        let staleGeneration: UInt64
        let targetDisplayID: UInt32
        let states: [State]
    }

    override class var scenarioName: String { "hud-renderer" }

    override class func run(arguments: ContractArguments) throws {
        guard arguments.defaultsSuite == "com.oigo.qa.task24" else {
            throw ContractInputError(category: "invalid-defaults-suite")
        }
        let fixture = try loadFixture(from: arguments.fixtureRoot)
        try validate(fixture)

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sources = [
            "OigoHUDState.swift",
            "OigoHUDPolicy.swift",
            "OigoHUDLifecycle.swift",
            "HUDTargetGeometry.swift",
            "OigoHUDController.swift"
        ].map { root.appendingPathComponent("Sources/Oigo/UI/HUD/\($0)") }
        guard sources.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw ContractInputError(category: "missing-hud-renderer")
        }

        let output = try runCompiledContract(sources: sources, fixture: fixture)
        guard output.contains("PASS hud-renderer") else {
            throw ContractInputError(category: "unexpected-hud-renderer-output")
        }
        try writeReceipt(output: output, fixture: fixture, evidenceRoot: arguments.evidenceRoot)
        print(output, terminator: "")
    }

    private static func loadFixture(from root: URL) throws -> Fixture {
        let provided = root.appendingPathComponent("fixture.json")
        let url = FileManager.default.fileExists(atPath: provided.path)
            ? provided
            : root.appendingPathComponent("hud-placement-success/fixture.json")
        guard let data = try? Data(contentsOf: url),
              let fixture = try? JSONDecoder().decode(Fixture.self, from: data) else {
            throw ContractInputError(category: "malformed-hud-renderer")
        }
        return fixture
    }

    private static func validate(_ fixture: Fixture) throws {
        let required = Set([
            "preparing", "recording", "degraded-recording", "finalizing", "cleaning", "pasting",
            "paste-attempted", "copied", "copy-only", "saved-retry", "preserved-failure",
            "cleanup-fallback", "cancelled-before-raw", "cancelled-after-raw", "interrupted",
            "paste-again-destination", "terminal", "shutdown"
        ])
        guard fixture.scenario == scenarioName,
              fixture.fixture.hasPrefix("hud-placement-"),
              fixture.shortcutReleaseHint.contains("Command-A"),
              fixture.radius == 12,
              fixture.currentGeneration > fixture.staleGeneration,
              fixture.states.count == 18,
              Set(fixture.states.map(\.id)) == required,
              fixture.states.allSatisfy({ $0.width == 224 || $0.width == 280 }),
              fixture.states.allSatisfy({ $0.height == ($0.width == 224 ? 42 : 64) }) else {
            throw ContractInputError(category: "incomplete-hud-renderer-fixture")
        }
    }

    private static func runCompiledContract(sources: [URL], fixture: Fixture) throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-native-ui-redesign.task24." + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let driver = root.appendingPathComponent("main.swift")
        let payload = root.appendingPathComponent("fixture.json")
        let executable = root.appendingPathComponent("hud-renderer-contract")
        try JSONEncoder().encode(fixture).write(to: payload, options: .atomic)
        try contractDriver.write(to: driver, atomically: true, encoding: .utf8)
        _ = try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["swiftc"] + sources.map(\.path) + [driver.path, "-framework", "AppKit", "-o", executable.path]
        )
        let data = try runProcess(executable: executable, arguments: [payload.path])
        guard let output = String(data: data, encoding: .utf8) else {
            throw ContractInputError(category: "unreadable-hud-renderer-output")
        }
        return output
    }

    private static func writeReceipt(output: String, fixture: Fixture, evidenceRoot: URL) throws {
        let lines = output.split(separator: "\n")
        let receipt: [String: Any] = [
            "scenario": scenarioName,
            "fixture": fixture.fixture,
            "states": fixture.states.count,
            "targetScreen": fixture.targetDisplayID,
            "compact": "224x42",
            "expanded": "280x64",
            "radius": fixture.radius,
            "previewItalicPointSize": 12,
            "output": lines.map(String.init)
        ]
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
        try data.write(to: evidenceRoot.appendingPathComponent("hud-renderer.json"), options: .atomic)
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
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let standardOutput = String(data: output, encoding: .utf8) ?? ""
            throw ContractInputError(category: "hud-renderer-build-failed:exit=\(process.terminationStatus):" + (error + standardOutput).prefix(2000))
        }
        return output
    }

    private static let contractDriver = #"""
    import AppKit
    import Darwin
    import Foundation

    struct Fixture: Decodable {
        struct State: Decodable {
            let id: String
            let width: Double
            let height: Double
            let preview: Bool
            let timer: Bool
            let dismissal: String
        }
        let fixture: String
        let shortcutReleaseHint: String
        let radius: Double
        let currentGeneration: UInt64
        let staleGeneration: UInt64
        let targetDisplayID: UInt32
        let states: [State]
    }

    final class SessionReference: NSObject {}

    @MainActor
    final class Delegate: NSObject, NSApplicationDelegate {
        let fixture: Fixture

        init(fixture: Fixture) { self.fixture = fixture }

        func applicationDidFinishLaunching(_ notification: Notification) {
            let controller = OigoHUDController()
            let displays = [
                HUDDisplayGeometry(id: 1, visibleFrame: HUDRect(x: 0, y: 0, width: 1440, height: 900)),
                HUDDisplayGeometry(id: 2, visibleFrame: HUDRect(x: 1440, y: 0, width: 1440, height: 900))
            ]
            let snapshot = HUDTargetGeometrySnapshot(
                generation: fixture.currentGeneration,
                captureToken: UUID(),
                fieldFrame: HUDRect(x: 1800, y: 650, width: 200, height: 24),
                windowFrame: HUDRect(x: 1600, y: 300, width: 900, height: 500),
                targetDisplayID: fixture.targetDisplayID
            )
            let input = HUDPlacementInput(
                snapshot: snapshot,
                currentGeneration: fixture.currentGeneration,
                displays: displays,
                frontmostDisplayID: 1,
                mainDisplayID: 1,
                panelSize: HUDSize(width: 224, height: 42)
            )
            let reference = SessionReference()

            guard controller.present(
                .recording,
                generation: fixture.currentGeneration,
                placementInput: input,
                startedAt: Date(),
                sessionReference: reference,
                shortcutReleaseHint: fixture.shortcutReleaseHint
            ) else { exit(10) }
            let targetFrame = controller.renderedFrame
            guard controller.renderedSize == HUDSize(width: 224, height: 42),
                  controller.renderedCornerRadius == fixture.radius,
                  (fixture.targetDisplayID == 2 ? targetFrame.origin.x >= 1440 : targetFrame.origin.x < 1440),
                  targetFrame.origin.y < 650,
                  controller.resourceSnapshot.recordingTimerActive else { exit(11) }
            guard controller.updatePreview("preview", generation: fixture.currentGeneration, at: 10) else { exit(12) }
            guard controller.renderedSize == HUDSize(width: 280, height: 64),
                  controller.resourceSnapshot.previewCharacters > 0 else { exit(13) }
            guard !controller.present(
                .savedRetry,
                generation: fixture.staleGeneration,
                shortcutReleaseHint: fixture.shortcutReleaseHint
            ), controller.resourceSnapshot.state == .recording,
                  controller.renderedSize == HUDSize(width: 280, height: 64) else { exit(14) }

            var generation = fixture.currentGeneration + 1
            for expected in fixture.states {
                guard let state = OigoHUDState(rawValue: expected.id),
                      controller.present(
                          state,
                          generation: generation,
                          shortcutReleaseHint: fixture.shortcutReleaseHint
                      ) else { exit(20) }
                if state == .shutdown {
                    guard !controller.isVisible,
                          controller.resourceSnapshot.state == nil,
                          controller.resourceSnapshot.generation == nil else { exit(21) }
                } else {
                    guard controller.renderedSize == HUDSize(width: expected.width, height: expected.height),
                          controller.resourceSnapshot.recordingTimerActive == expected.timer,
                          controller.resourceSnapshot.dismissalTaskActive == (expected.dismissal == "timed") else { exit(22) }
                    if expected.preview {
                        guard OigoHUDShellPolicy.content(
                            for: state,
                            releaseHint: fixture.shortcutReleaseHint,
                            preview: "preview"
                        ).size == .expanded else { exit(23) }
                    }
                }
                generation += 1
            }

            let missingSnapshot = HUDTargetGeometrySnapshot(
                generation: generation,
                captureToken: UUID(),
                fieldFrame: nil,
                windowFrame: nil,
                targetDisplayID: 99
            )
            let missingInput = HUDPlacementInput(
                snapshot: missingSnapshot,
                currentGeneration: generation,
                displays: displays,
                frontmostDisplayID: 1,
                mainDisplayID: 1,
                panelSize: HUDSize(width: 280, height: 64)
            )
            guard controller.present(
                .savedRetry,
                generation: generation,
                placementInput: missingInput,
                shortcutReleaseHint: fixture.shortcutReleaseHint
            ), controller.renderedFrame.origin.x < 1440,
                  controller.hide(generation: generation) else { exit(30) }
            let hidden = controller.resourceSnapshot
            guard !hidden.visible,
                  !hidden.recordingTimerActive,
                  !hidden.dismissalTaskActive,
                  hidden.previewCharacters == 0,
                  !hidden.sessionReferenceHeld else { exit(31) }
            guard !controller.hide(generation: fixture.staleGeneration),
                  !controller.present(
                      .recording,
                      generation: fixture.staleGeneration,
                      shortcutReleaseHint: fixture.shortcutReleaseHint
                  ) else { exit(32) }

            print("PASS hud-renderer fixture=\(fixture.fixture) states=\(fixture.states.count) target-screen=\(fixture.targetDisplayID) fallback=main-screen stale=no-render dismissal=clean")
            NSApp.terminate(nil)
        }
    }

    let fixtureData = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let fixture = try! JSONDecoder().decode(Fixture.self, from: fixtureData)
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let delegate = MainActor.assumeIsolated { Delegate(fixture: fixture) }
    application.delegate = delegate
    application.run()
    """#
}
