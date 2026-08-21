import Foundation

final class IdentityScenario: NativeUIContractScenario {
    private struct Fixture: Decodable {
        let schemaVersion: Int
        let mode: String
        let currentGeneration: UInt64
        let candidateGeneration: UInt64
        let dirty: Bool
        let appearanceGenerations: [UInt64]
        let animationSamples: [Int]
        let reportedSuccess: Bool
        let processExitStatus: Int
        let captureArtwork: Bool?
        let states: [State]
        let transitions: [Transition]
    }

    private struct State: Decodable {
        let row: String
        let mark: String
        let status: String
        let terminal: Bool
        let visible: Bool
        let variant: String
        let shape: String
        let color: String
        let template: Bool
        let animated: Bool
        let value: String
        let help: String
    }

    private struct Transition: Decodable {
        let event: String
        let expectedAnimationCount: Int
    }

    override class var scenarioName: String {
        "identity"
    }

    override class func run(arguments: ContractArguments) throws {
        guard arguments.defaultsSuite == "com.oigo.qa.task9" else {
            throw ContractInputError(category: "invalid-defaults-suite")
        }

        let fixtureURL = arguments.fixtureRoot.appendingPathComponent("fixture.json")
        let fixture = try loadFixture(fixtureURL)
        try validate(fixture)

        let sourceRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/Oigo", isDirectory: true)
        let identityRoot = sourceRoot.appendingPathComponent("UI/Identity", isDirectory: true)
        let descriptorSource = identityRoot.appendingPathComponent("OigoStatusIdentityArtwork.swift")
        let rendererSource = identityRoot.appendingPathComponent("OigoStatusIdentityRenderer.swift")
        guard FileManager.default.fileExists(atPath: descriptorSource.path),
              FileManager.default.fileExists(atPath: rendererSource.path) else {
            throw ContractInputError(category: "missing-identity-renderer")
        }
        try validateSourceBoundary([descriptorSource, rendererSource])

        let presentationRoot = sourceRoot.appendingPathComponent("UI/Presentation", isDirectory: true)
        let output = try runCompiledContract(
            sources: [
                presentationRoot.appendingPathComponent("OigoPresentationInputs.swift"),
                presentationRoot.appendingPathComponent("OigoPresentationState.swift"),
                descriptorSource,
                rendererSource
            ],
            fixtureURL: fixtureURL
        )
        guard output.contains("IDENTITY states=\(fixture.states.count)"),
              output.contains("animation-count=0"),
              output.contains("interruptions=2") else {
            throw ContractInputError(category: "unexpected-contract-output")
        }
        print(output, terminator: "")
        print("PASS identity resources=0")
    }

    private static func loadFixture(_ url: URL) throws -> Fixture {
        guard let data = try? Data(contentsOf: url) else {
            throw ContractInputError(category: "missing-fixture")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ContractInputError(category: "malformed-identity-fixture")
        }
        if containsForbiddenField(object) {
            throw ContractInputError(category: "forbidden-field")
        }
        do {
            return try JSONDecoder().decode(Fixture.self, from: data)
        } catch {
            throw ContractInputError(category: "malformed-identity-fixture")
        }
    }

    private static func validate(_ fixture: Fixture) throws {
        guard fixture.schemaVersion == 1,
              ["all-states", "color-removed-processing-stopped"].contains(fixture.mode),
              !fixture.states.isEmpty else {
            throw ContractInputError(category: "malformed-identity-fixture")
        }
        guard fixture.candidateGeneration >= fixture.currentGeneration else {
            throw ContractInputError(category: "stale-generation")
        }
        guard fixture.dirty == false else {
            throw ContractInputError(category: "dirty-worktree")
        }
        guard fixture.appearanceGenerations == fixture.appearanceGenerations.sorted() else {
            throw ContractInputError(category: "appearance-race")
        }
        guard Set(fixture.animationSamples).count <= 1 else {
            throw ContractInputError(category: "flaky-animation-timing")
        }
        if fixture.reportedSuccess, fixture.processExitStatus != 0 {
            print("PASS decoy-only")
            throw ContractInputError(category: "misleading-success-output")
        }
        guard Set(fixture.states.map(\.variant)).isSuperset(of: [
            "idle", "processing", "recording", "attention"
        ]), fixture.transitions.map(\.event) == [
            "replacement", "terminalization", "item-removal", "shutdown",
            "interruption", "interruption"
        ], fixture.transitions.allSatisfy({ $0.expectedAnimationCount == 0 }) else {
            throw ContractInputError(category: "incomplete-identity-matrix")
        }
    }

    private static func containsForbiddenField(_ object: Any) -> Bool {
        if let dictionary = object as? [String: Any] {
            let forbidden = Set([
                "transcript", "audio", "clipboard", "focusedText", "dictionaryEntries",
                "userContent", "userPath"
            ])
            return !forbidden.isDisjoint(with: dictionary.keys)
                || dictionary.values.contains(where: containsForbiddenField)
        }
        if let array = object as? [Any] {
            return array.contains(where: containsForbiddenField)
        }
        return false
    }

    private static func validateSourceBoundary(_ sources: [URL]) throws {
        let text = try sources.map { url -> String in
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                throw ContractInputError(category: "unreadable-identity-renderer")
            }
            return source
        }.joined(separator: "\n")
        let forbidden = [
            "MacUtilityUI", "NSStatusBar.system", "OigoAppDelegate", "StatusSurfaceController",
            "button.title = \"Oigo\"", "prewarm", "idleTimer"
        ]
        guard !forbidden.contains(where: text.contains) else {
            throw ContractInputError(category: "forbidden-identity-dependency")
        }
    }

    private static func runCompiledContract(sources: [URL], fixtureURL: URL) throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-native-ui-redesign.task09." + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let driver = root.appendingPathComponent("main.swift")
        let executable = root.appendingPathComponent("identity-contract")
        try contractDriver.write(to: driver, atomically: true, encoding: .utf8)
        try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["swiftc"] + sources.map(\.path) + [driver.path, "-o", executable.path]
        )
        let data = try runProcess(executable: executable, arguments: [fixtureURL.path])
        guard let output = String(data: data, encoding: .utf8) else {
            throw ContractInputError(category: "unexpected-contract-output")
        }
        return output
    }

    @discardableResult
    private static func runProcess(executable: URL, arguments: [String]) throws -> Data {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ContractInputError(category: "contract-process-launch")
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            FileHandle.standardError.write(errorOutput)
            throw ContractInputError(category: "compiled-contract-failed")
        }
        return output
    }

    private static let contractDriver = #"""
    import AppKit
    import Foundation

    struct Fixture: Decodable {
        let mode: String
        let captureArtwork: Bool?
        let states: [State]
        let transitions: [Transition]
    }

    struct State: Decodable {
        let row: String
        let mark: String
        let status: String
        let terminal: Bool
        let visible: Bool
        let variant: String
        let shape: String
        let color: String
        let template: Bool
        let animated: Bool
        let value: String
        let help: String
    }

    struct Transition: Decodable {
        let event: String
        let expectedAnimationCount: Int
    }

    func presentationState(_ fixture: State) -> OigoPresentationState? {
        guard let row = OigoPresentationStateRow(rawValue: fixture.row),
              let mark = OigoMenuMark(rawValue: fixture.mark),
              let status = OigoPresentationStatus(rawValue: fixture.status) else { return nil }
        let terminal: OigoTerminalPresentationClass? = fixture.terminal ? .interruption : nil
        return OigoPresentationState(
            row: row,
            menuMark: mark,
            status: status,
            primaryAction: .enabled(.startDictation),
            context: terminal.map(OigoPresentationContext.terminal) ?? .readiness,
            notice: nil,
            latestSessionActions: .init(),
            hud: .hidden,
            availability: .init(
                initiatorsEnabled: true,
                commandsEnabled: true,
                windowsEnabled: true
            ),
            nextDictation: .none,
            copyOnly: .inactive,
            terminal: terminal
        )
    }

    @MainActor
    func runContract() throws {
        let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL))
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        let renderer = OigoStatusIdentityRenderer()
        var typedStates: [String: OigoPresentationState] = [:]

    for expected in fixture.states {
        guard let state = presentationState(expected) else { exit(2) }
        typedStates[expected.variant] = state
        let artwork = OigoStatusIdentityArtwork(state: state)
        guard artwork.variant.rawValue == expected.variant,
              artwork.shapeRole.rawValue == expected.shape,
              artwork.colorRole.rawValue == expected.color,
              artwork.isTemplate == expected.template,
              artwork.animatesWhenVisible == expected.animated,
              artwork.accessibilityLabel == "Oigo",
              artwork.accessibilityValue == expected.value,
              artwork.accessibilityHelp == expected.help else { exit(3) }
        renderer.render(state, on: button, isVisible: expected.visible)
        guard renderer.activeAnimationCount == (expected.animated && expected.visible ? 1 : 0),
              button.accessibilityLabel() == "Oigo",
              button.accessibilityValue() as? String == expected.value,
              button.accessibilityHelp() == expected.help,
              button.image != nil,
              button.title.isEmpty else { exit(4) }
    }

    if fixture.mode == "color-removed-processing-stopped" {
        guard let recording = typedStates["recording"], let attention = typedStates["attention"],
              OigoStatusIdentityArtwork(state: recording).shapeRole
                != OigoStatusIdentityArtwork(state: attention).shapeRole,
              renderer.activeAnimationCount == 0 else { exit(5) }
    }

    guard let processing = typedStates["processing"],
          let recording = typedStates["recording"],
          let idle = typedStates["idle"] else { exit(6) }
    renderer.render(processing, on: button, isVisible: true)
    guard renderer.activeAnimationCount == 1 else { exit(7) }
    button.appearance = NSAppearance(named: .darkAqua)
    renderer.refreshAppearance()
    button.appearance = NSAppearance(named: .aqua)
    renderer.refreshAppearance()
    guard renderer.activeAnimationCount == 1, button.image != nil else { exit(15) }
    renderer.render(recording, on: button, isVisible: true)
    guard renderer.activeAnimationCount == fixture.transitions[0].expectedAnimationCount else { exit(8) }

    var terminalized = processing
    terminalized = OigoPresentationState(
        row: terminalized.row,
        menuMark: terminalized.menuMark,
        status: terminalized.status,
        primaryAction: terminalized.primaryAction,
        context: .terminal(.interruption),
        notice: terminalized.notice,
        latestSessionActions: terminalized.latestSessionActions,
        hud: terminalized.hud,
        availability: terminalized.availability,
        nextDictation: terminalized.nextDictation,
        copyOnly: terminalized.copyOnly,
        terminal: .interruption
    )
    renderer.render(terminalized, on: button, isVisible: true)
    guard renderer.activeAnimationCount == fixture.transitions[1].expectedAnimationCount else { exit(9) }
    renderer.render(terminalized, on: button, isVisible: true)
    guard renderer.activeAnimationCount == fixture.transitions[4].expectedAnimationCount else { exit(16) }
    renderer.render(terminalized, on: button, isVisible: true)
    guard renderer.activeAnimationCount == fixture.transitions[5].expectedAnimationCount else { exit(17) }
    renderer.render(processing, on: button, isVisible: true)
    renderer.removeItem()
    guard renderer.activeAnimationCount == fixture.transitions[2].expectedAnimationCount else { exit(10) }
    renderer.render(processing, on: button, isVisible: true)
    renderer.shutdown()
    guard renderer.activeAnimationCount == fixture.transitions[3].expectedAnimationCount else { exit(11) }
    renderer.render(idle, on: button, isVisible: true)
    guard renderer.activeAnimationCount == 0 else { exit(12) }
    renderer.removeItem()
    renderer.removeItem()
    let interruptions = fixture.transitions.filter { $0.event == "interruption" }
    guard interruptions.count == 2, interruptions.allSatisfy({ $0.expectedAnimationCount == 0 }) else {
        exit(13)
    }

    for environment in OigoStatusIdentityEnvironment.contractAppearances {
        guard OigoStatusIdentityArtwork(state: idle).image(environment: environment).size
                == NSSize(width: 18, height: 18) else { exit(14) }
    }
    if fixture.captureArtwork == true {
        let captureRoot = fixtureURL.deletingLastPathComponent()
            .appendingPathComponent("captures", isDirectory: true)
        try FileManager.default.createDirectory(at: captureRoot, withIntermediateDirectories: true)
        for expected in fixture.states {
            guard let state = presentationState(expected) else { exit(18) }
            let artwork = OigoStatusIdentityArtwork(state: state)
            for (appearanceIndex, environment) in
                OigoStatusIdentityEnvironment.contractAppearances.enumerated() {
                let phases: [CGFloat] = expected.variant == "processing" ? [0, 0.125, 0.25] : [0]
                for (phaseIndex, phase) in phases.enumerated() {
                    let image = artwork.image(environment: environment, progressPhase: phase)
                    guard let tiff = image.tiffRepresentation,
                          let bitmap = NSBitmapImageRep(data: tiff),
                          let png = bitmap.representation(using: .png, properties: [:]) else {
                        exit(19)
                    }
                    let name = expected.variant + "-appearance-\(appearanceIndex)"
                        + "-phase-\(phaseIndex).png"
                    try png.write(to: captureRoot.appendingPathComponent(name), options: .atomic)
                }
            }
        }
    }
        print(
            "IDENTITY states=\(fixture.states.count) mode=\(fixture.mode) "
                + "animation-count=\(renderer.activeAnimationCount) interruptions=\(interruptions.count)"
        )
    }

    try await runContract()
    """#
}
