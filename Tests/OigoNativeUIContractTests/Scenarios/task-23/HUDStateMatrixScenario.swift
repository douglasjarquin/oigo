import Foundation
import OigoCore

final class HUDStateMatrixScenario: NativeUIContractScenario {
    private struct Fixture: Codable {
        struct Shortcut: Codable {
            let keyCode: UInt32
            let modifiers: UInt32
            var releaseHint: String
        }

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
            let size: String
        }

        let scenario: String
        let fixture: String
        let shortcut: Shortcut
        let states: [State]
        let staleGeneration: UInt64
        let currentGeneration: UInt64
    }

    private struct StateReceipt: Codable {
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
        let size: String
        let width: Double
        let height: Double
        let shortcutReleaseHint: String
    }

    override class var scenarioName: String { "hud-state-matrix" }

    override class func run(arguments: ContractArguments) throws {
        guard arguments.defaultsSuite == "com.oigo.qa.task23" else {
            throw ContractInputError(category: "invalid-defaults-suite")
        }
        let fixture = try loadFixture(arguments.fixtureRoot)
        try validateFixture(fixture)

        let shortcut = ToggleShortcut(
            keyCode: fixture.shortcut.keyCode,
            modifiers: fixture.shortcut.modifiers
        )
        let releaseHint = OigoShortcutPresentation.copy(for: shortcut).releaseHint
        guard releaseHint == fixture.shortcut.releaseHint,
              !releaseHint.contains("Space") else {
            throw ContractInputError(category: "non-dynamic-shortcut-hint")
        }

        let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let hudDirectory = repository.appendingPathComponent("Sources/Oigo/UI/HUD")
        let sources = ["OigoHUDState.swift", "OigoHUDPolicy.swift", "OigoHUDLifecycle.swift"]
            .map { hudDirectory.appendingPathComponent($0) }
        guard sources.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw ContractInputError(category: "missing-hud-shell")
        }

        let output = try runCompiledContract(
            sources: sources,
            fixture: fixture,
            releaseHint: releaseHint
        )
        let receipts = try parseReceipts(output)
        guard receipts.count == fixture.states.count + 1,
              output.contains("PASS hud-state-matrix states=18"),
              output.contains("PASS hud-size recording-with-preview compact=224x42 expanded=280x64"),
              output.contains("PASS hud-generation stale-rejected preview-ineligible") else {
            throw ContractInputError(category: "unexpected-hud-contract-output")
        }
        guard receipts.allSatisfy({ !$0.shortcutReleaseHint.contains("Space") }) else {
            throw ContractInputError(category: "literal-shortcut-in-receipt")
        }
        try writeReceipts(receipts, evidenceRoot: arguments.evidenceRoot)
        print(
            "PASS hud-state-matrix states=\(fixture.states.count) receipts=\(receipts.count) "
                + "shortcut=\(shortcut.keyCode):\(shortcut.modifiers) sizes=224x42/280x64"
        )
    }

    private static func loadFixture(_ root: URL) throws -> Fixture {
        let url = root.appendingPathComponent("fixture.json")
        guard let data = try? Data(contentsOf: url),
              let fixture = try? JSONDecoder().decode(Fixture.self, from: data) else {
            throw ContractInputError(category: "malformed-hud-state-matrix")
        }
        return fixture
    }

    private static func validateFixture(_ fixture: Fixture) throws {
        guard fixture.scenario == "hud-state-matrix",
              fixture.fixture == "exhaustive",
              fixture.states.count == requiredStateIDs.count,
              Set(fixture.states.map(\.id)) == requiredStateIDs,
              fixture.staleGeneration < fixture.currentGeneration else {
            throw ContractInputError(category: "incomplete-hud-state-matrix")
        }
        guard fixture.states.allSatisfy({
            !$0.title.isEmpty && !$0.detail.isEmpty && ["compact", "expanded"].contains($0.size)
        }) else {
            throw ContractInputError(category: "incomplete-hud-state-matrix")
        }
    }

    private static let requiredStateIDs: Set<String> = [
        "preparing", "recording", "degraded-recording", "finalizing", "cleaning", "pasting",
        "paste-attempted", "copied", "copy-only", "saved-retry", "preserved-failure",
        "cleanup-fallback", "cancelled-before-raw", "cancelled-after-raw", "interrupted",
        "paste-again-destination", "terminal", "shutdown"
    ]

    private static func parseReceipts(_ output: String) throws -> [StateReceipt] {
        try output.split(separator: "\n").compactMap { line -> StateReceipt? in
            guard line.hasPrefix("RECEIPT ") else { return nil }
            let json = String(line.dropFirst("RECEIPT ".count))
            guard let data = json.data(using: .utf8) else {
                throw ContractInputError(category: "unreadable-hud-state-receipt")
            }
            do {
                return try JSONDecoder().decode(StateReceipt.self, from: data)
            } catch {
                throw ContractInputError(category: "malformed-hud-state-receipt")
            }
        }
    }

    private static func writeReceipts(_ receipts: [StateReceipt], evidenceRoot: URL) throws {
        try FileManager.default.createDirectory(at: evidenceRoot, withIntermediateDirectories: true)
        let statesRoot = evidenceRoot.appendingPathComponent("states", isDirectory: true)
        try FileManager.default.createDirectory(at: statesRoot, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for receipt in receipts {
            let data = try encoder.encode(receipt)
            try data.write(
                to: statesRoot.appendingPathComponent(receipt.id + ".json"),
                options: .atomic
            )
        }
        let manifest: [String: Any] = [
            "scenario": "hud-state-matrix",
            "stateCount": 18,
            "receiptCount": receipts.count,
            "compactSize": ["width": 224, "height": 42],
            "expandedSize": ["width": 280, "height": 64],
            "recordingWithoutPreview": "compact",
            "recordingWithPreview": "expanded",
            "dynamicShortcut": receipts.first?.shortcutReleaseHint ?? "",
            "literalOptionSpacePresent": false,
            "staleGenerationRejected": true,
            "previewIneligibleSuppressed": true,
            "synthetic": true
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try manifestData.write(
            to: evidenceRoot.appendingPathComponent("hud-state-matrix-manifest.json"),
            options: .atomic
        )
    }

    private static func runCompiledContract(
        sources: [URL],
        fixture: Fixture,
        releaseHint: String
    ) throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-native-ui-redesign.task23." + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let driver = root.appendingPathComponent("main.swift")
        let payload = root.appendingPathComponent("fixture.json")
        let executable = root.appendingPathComponent("hud-state-matrix-contract")
        try JSONEncoder().encode(fixture).write(to: payload, options: .atomic)
        try contractDriver.write(to: driver, atomically: true, encoding: .utf8)
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compile.arguments = ["swiftc"] + sources.map(\.path) + [driver.path, "-o", executable.path]
        try compile.run()
        compile.waitUntilExit()
        guard compile.terminationStatus == 0 else {
            throw ContractInputError(category: "hud-contract-build-failed")
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = [payload.path, releaseHint]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let result = String(
                  data: output.fileHandleForReading.readDataToEndOfFile(),
                  encoding: .utf8
              ) else {
            throw ContractInputError(category: "hud-contract-failed")
        }
        return result
    }

    private static let contractDriver = #"""
    import Foundation

    struct Fixture: Decodable {
        struct Shortcut: Decodable {
            let keyCode: UInt32
            let modifiers: UInt32
            let releaseHint: String
        }
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
            let size: String
        }
        let shortcut: Shortcut
        let states: [State]
        let staleGeneration: UInt64
        let currentGeneration: UInt64
    }

    struct StateReceipt: Encodable {
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
        let size: String
        let width: Double
        let height: Double
        let shortcutReleaseHint: String
    }

    func sizeName(_ width: Double, _ height: Double) -> String {
        width == 224 && height == 42 ? "compact" : width == 280 && height == 64 ? "expanded" : "invalid"
    }

    let fixture = try! JSONDecoder().decode(
        Fixture.self,
        from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    )
    let releaseHint = CommandLine.arguments[2]
    guard OigoHUDState.allCases.count == 18 else { exit(1) }
    for expected in fixture.states {
        guard let state = OigoHUDState(rawValue: expected.id) else { exit(2) }
        let content = OigoHUDShellPolicy.content(for: state, releaseHint: releaseHint)
        let receipt = StateReceipt(
            id: expected.id,
            title: content.title,
            detail: content.detail,
            tone: content.tone.rawValue,
            iconRole: content.iconRole.rawValue,
            actionability: content.actionability.rawValue,
            dismissal: content.dismissal.kind.rawValue,
            dismissalSeconds: content.dismissal.seconds,
            terminal: content.isTerminal,
            recordingTimer: content.showsRecordingElapsed,
            preview: content.allowsPreview,
            size: sizeName(content.size.width, content.size.height),
            width: content.size.width,
            height: content.size.height,
            shortcutReleaseHint: releaseHint
        )
        let expectedDetail = expected.detail == "__RELEASE_HINT__" ? releaseHint : expected.detail
        guard receipt.title == expected.title,
              receipt.detail == expectedDetail,
              receipt.tone == expected.tone,
              receipt.iconRole == expected.iconRole,
              receipt.actionability == expected.actionability,
              receipt.dismissal == expected.dismissal,
              receipt.dismissalSeconds == expected.dismissalSeconds,
              receipt.terminal == expected.terminal,
              receipt.recordingTimer == expected.recordingTimer,
              receipt.preview == expected.preview,
              receipt.size == expected.size,
              receipt.width > 0,
              receipt.height > 0,
              !receipt.title.lowercased().contains("verified") else { exit(3) }
        let data = try! JSONEncoder().encode(receipt)
        print("RECEIPT " + String(data: data, encoding: .utf8)!)
    }

    let recordingCompact = OigoHUDShellPolicy.content(
        for: .recording,
        releaseHint: releaseHint,
        preview: ""
    )
    let recordingExpanded = OigoHUDShellPolicy.content(
        for: .recording,
        releaseHint: releaseHint,
        preview: "synthetic preview"
    )
    let expandedReceipt = StateReceipt(
        id: "recording-preview-expanded",
        title: recordingExpanded.title,
        detail: recordingExpanded.detail,
        tone: recordingExpanded.tone.rawValue,
        iconRole: recordingExpanded.iconRole.rawValue,
        actionability: recordingExpanded.actionability.rawValue,
        dismissal: recordingExpanded.dismissal.kind.rawValue,
        dismissalSeconds: recordingExpanded.dismissal.seconds,
        terminal: recordingExpanded.isTerminal,
        recordingTimer: recordingExpanded.showsRecordingElapsed,
        preview: recordingExpanded.allowsPreview,
        size: sizeName(recordingExpanded.size.width, recordingExpanded.size.height),
        width: recordingExpanded.size.width,
        height: recordingExpanded.size.height,
        shortcutReleaseHint: releaseHint
    )
    let expandedData = try! JSONEncoder().encode(expandedReceipt)
    print("RECEIPT " + String(data: expandedData, encoding: .utf8)!)
    guard recordingCompact.size == .compact,
          recordingExpanded.size == .expanded,
          !OigoHUDShellPolicy.allowsPreview(.degradedRecording),
          !OigoHUDShellPolicy.allowsPreview(.savedRetry),
          OigoHUDShellPolicy.content(
              for: .savedRetry,
              releaseHint: releaseHint
          ).showsRecordingElapsed == false else { exit(4) }
    print("PASS hud-state-matrix states=18")
    print("PASS hud-size recording-with-preview compact=224x42 expanded=280x64")

    var lifecycle = OigoHUDLifecycle()
    guard lifecycle.present(.recording, generation: fixture.currentGeneration, visible: true),
          !lifecycle.present(.savedRetry, generation: fixture.staleGeneration, visible: true),
          lifecycle.state == .recording,
          lifecycle.visible else { exit(5) }
    guard lifecycle.present(.savedRetry, generation: fixture.currentGeneration + 1, visible: true),
          lifecycle.state == .savedRetry,
          !lifecycle.recordingTimerActive,
          !lifecycle.previewUpdatesActive,
          !lifecycle.previewPublicationAllowed(at: 1.0) else { exit(6) }
    print("PASS hud-generation stale-rejected preview-ineligible")
    """#
}
