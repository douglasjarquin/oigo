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
        guard arguments.defaultsSuite == "com.oigo.qa.task09" else {
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
        let assetRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Oigo/Assets.xcassets/OigoMenuBar.imageset", isDirectory: true)
        let asset1x = assetRoot.appendingPathComponent("oigo-menubar.png")
        let asset2x = assetRoot.appendingPathComponent("oigo-menubar@2x.png")
        guard FileManager.default.fileExists(atPath: asset1x.path),
              FileManager.default.fileExists(atPath: asset2x.path) else {
            throw ContractInputError(category: "missing-authoritative-identity-asset")
        }
        let output = try runCompiledContract(
            sources: [
                presentationRoot.appendingPathComponent("OigoPresentationInputs.swift"),
                presentationRoot.appendingPathComponent("OigoPresentationState.swift"),
                descriptorSource,
                rendererSource
            ],
            fixtureURL: fixtureURL,
            asset1x: asset1x,
            asset2x: asset2x
        )
        guard output.contains("IDENTITY states=\(fixture.states.count)"),
              output.contains("animation-count=0"),
              output.contains("interruptions=2"),
              output.contains("menu-actions=5") else {
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
        guard Set(fixture.states.map(\.mark)) == Set([
            "outline", "activity", "recording", "attention", "hidden"
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
            "button.title = \"Oigo\"", "prewarm", "idleTimer", "NSColor.white", "NSColor.black"
        ]
        guard !forbidden.contains(where: text.contains) else {
            throw ContractInputError(category: "forbidden-identity-dependency")
        }
    }

    private static func runCompiledContract(
        sources: [URL],
        fixtureURL: URL,
        asset1x: URL,
        asset2x: URL
    ) throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-native-ui-redesign.task09." + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let driver = root.appendingPathComponent("main.swift")
        let executable = root.appendingPathComponent("identity-contract")
        let moduleRoot = root.appendingPathComponent("Modules", isDirectory: true)
        let modulePath = moduleRoot.appendingPathComponent("OigoPresentation.swiftmodule")
        let libraryPath = moduleRoot.appendingPathComponent("libOigoPresentation.dylib")
        let packageBuildRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/arm64-apple-macosx/debug", isDirectory: true)
        let coreObjectRoot = packageBuildRoot.appendingPathComponent("OigoCore.build", isDirectory: true)
        let coreObjects = (try? FileManager.default.contentsOfDirectory(
            at: coreObjectRoot,
            includingPropertiesForKeys: [.isRegularFileKey]
        ))?.filter { $0.pathExtension == "o" }.sorted { $0.path < $1.path } ?? []
        guard !coreObjects.isEmpty else {
            throw ContractInputError(category: "missing-core-build-artifacts")
        }
        try FileManager.default.createDirectory(at: moduleRoot, withIntermediateDirectories: true)
        try contractDriver.write(to: driver, atomically: true, encoding: .utf8)
        try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: [
                "swiftc", "-enable-testing", "-parse-as-library", "-emit-library", "-emit-module",
                "-module-name", "OigoPresentation",
                sources[0].path, sources[1].path,
                "-I", packageBuildRoot.appendingPathComponent("Modules", isDirectory: true).path,
                "-L", packageBuildRoot.path,
                "-emit-module-path", modulePath.path, "-o", libraryPath.path
            ] + coreObjects.map(\.path)
        )
        try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: [
                "swiftc", "-enable-testing", "-I", moduleRoot.path,
                "-I", packageBuildRoot.appendingPathComponent("Modules", isDirectory: true).path
            ]
                + sources.dropFirst(2).map(\.path)
                + [
                    driver.path, "-L", moduleRoot.path, "-lOigoPresentation",
                    "-Xlinker", "-rpath", "-Xlinker", moduleRoot.path,
                    "-o", executable.path
                ]
        )
        let data = try runProcess(
            executable: executable,
            arguments: [fixtureURL.path, asset1x.path, asset2x.path]
        )
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
            FileHandle.standardError.write(
                Data(("IDENTITY_CONTRACT_EXIT=" + String(process.terminationStatus) + "\n").utf8)
            )
            throw ContractInputError(category: "compiled-contract-failed")
        }
        return output
    }

    private static let contractDriver = #"""
    import AppKit
    import Foundation
    @testable import OigoPresentation

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

    func failSemantic(_ message: String) -> Never {
        FileHandle.standardError.write(Data(("SEMANTIC_FAIL " + message + "\n").utf8))
        exit(20)
    }

    func requireSemantic(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { failSemantic(message) }
    }

    @MainActor
    func authoritativeAsset(oneX: URL, twoX: URL) throws -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 22))
        for url in [oneX, twoX] {
            guard let representation = NSBitmapImageRep(data: try Data(contentsOf: url)) else {
                failSemantic("authoritative-asset-unreadable")
            }
            representation.size = NSSize(width: 16, height: 22)
            image.addRepresentation(representation)
        }
        return image
    }

    @MainActor
    func rasterize(_ image: NSImage, pixels: Int = 18) -> NSBitmapImageRep {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { failSemantic("bitmap-allocation") }
        bitmap.size = NSSize(width: 18, height: 18)
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            failSemantic("bitmap-context")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 18, height: 18).fill()
        image.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    @MainActor
    func expectedEarMask(_ asset: NSImage) -> NSBitmapImageRep {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 18,
            pixelsHigh: 18,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            failSemantic("expected-mask-allocation")
        }
        bitmap.size = NSSize(width: 18, height: 18)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 18, height: 18).fill()
        asset.draw(in: NSRect(x: 1.5, y: 0.5, width: 13, height: 17))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    func isOpaque(_ color: NSColor?) -> Bool {
        (color?.alphaComponent ?? 0) > 0.2
    }

    func isRed(_ color: NSColor?) -> Bool {
        guard let color = color?.usingColorSpace(.deviceRGB) else { return false }
        return color.redComponent > 0.65
            && color.redComponent > color.greenComponent * 1.45
            && color.blueComponent < 0.45
            && color.alphaComponent > 0.2
    }

    func isOrange(_ color: NSColor?) -> Bool {
        guard let color = color?.usingColorSpace(.deviceRGB) else { return false }
        return color.redComponent > 0.7
            && color.greenComponent > 0.25
            && color.greenComponent < 0.8
            && color.blueComponent < 0.3
            && color.alphaComponent > 0.2
    }

    @MainActor
    func validateApprovedPixels(
        asset: NSImage,
        idle: NSImage,
        recording: NSImage,
        attention: NSImage,
        retina: NSImage
    ) {
        let expected = expectedEarMask(asset)
        let idleBitmap = rasterize(idle)
        let recordingBitmap = rasterize(recording)
        let attentionBitmap = rasterize(attention)
        var expectedCount = 0
        var maskDifference = 0
        var redEarCount = 0
        var recordingBadgeCount = 0
        var attentionBadgeCount = 0
        var attentionLowerOrangeCount = 0
        for y in 0..<18 {
            for x in 0..<18 {
                let expectedOpaque = isOpaque(expected.colorAt(x: x, y: y))
                let idleOpaque = isOpaque(idleBitmap.colorAt(x: x, y: y))
                if expectedOpaque { expectedCount += 1 }
                if expectedOpaque != idleOpaque { maskDifference += 1 }
                if expectedOpaque, x < 12, isRed(recordingBitmap.colorAt(x: x, y: y)) {
                    redEarCount += 1
                }
                if x >= 12, y >= 11, isRed(recordingBitmap.colorAt(x: x, y: y)) {
                    recordingBadgeCount += 1
                }
                if x >= 12, y <= 6, isOrange(attentionBitmap.colorAt(x: x, y: y)) {
                    attentionBadgeCount += 1
                }
                if x >= 9, y >= 9, isOrange(attentionBitmap.colorAt(x: x, y: y)) {
                    attentionLowerOrangeCount += 1
                }
            }
        }
        requireSemantic(expectedCount > 35, "authoritative-mask-empty")
        requireSemantic(maskDifference <= 14, "ear-o-mask-diverged")
        requireSemantic(redEarCount * 4 >= expectedCount * 3, "recording-ear-not-red")
        requireSemantic(recordingBadgeCount >= 5, "recording-bottom-dot-missing")
        requireSemantic(attentionBadgeCount >= 5, "attention-top-dot-missing")
        requireSemantic(attentionLowerOrangeCount <= 2, "attention-substitute-shape-present")
        guard let retinaBitmap = retina.representations
                .compactMap({ $0 as? NSBitmapImageRep })
                .first(where: { $0.pixelsWide == 36 && $0.pixelsHigh == 36 }) else {
            failSemantic("retina-not-36x36")
        }
        var retinaOpaqueCount = 0
        for y in 0..<36 {
            for x in 0..<36 where isOpaque(retinaBitmap.colorAt(x: x, y: y)) {
                retinaOpaqueCount += 1
            }
        }
        requireSemantic(
            retinaOpaqueCount * 2 >= expectedCount * 5,
            "retina-content-not-2x-\(retinaOpaqueCount)-of-\(expectedCount * 4)"
        )
    }

    @MainActor
    func runContract() throws {
        let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let asset = try authoritativeAsset(
            oneX: URL(fileURLWithPath: CommandLine.arguments[2]),
            twoX: URL(fileURLWithPath: CommandLine.arguments[3])
        )
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL))
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        let renderer = OigoStatusIdentityRenderer(sourceImageProvider: { asset })
        var typedStates: [String: OigoPresentationState] = [:]

    for expected in fixture.states {
        guard let state = presentationState(expected) else { exit(2) }
        let artwork = OigoStatusIdentityArtwork(state: state)
        let expectedVariant: String = switch expected.mark {
        case "activity": "processing"
        case "recording": "recording"
        case "attention": "attention"
        case "hidden": "inactive"
        default: "idle"
        }
        typedStates[expectedVariant] = state
        guard artwork.variant.rawValue == expectedVariant,
              artwork.isTemplate == ["idle", "inactive"].contains(expectedVariant),
              artwork.animatesWhenVisible == (expectedVariant == "processing" && !expected.terminal),
              artwork.accessibilityLabel == "Oigo",
              artwork.accessibilityValue == expected.value,
              artwork.accessibilityHelp == expected.help else { exit(3) }
        renderer.render(state, on: button, isVisible: expected.visible)
        guard renderer.activeAnimationCount
                == (artwork.animatesWhenVisible && expected.visible ? 1 : 0),
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
        guard OigoStatusIdentityArtwork(state: idle).image(
            environment: environment,
            sourceImage: asset
        ).size
                == NSSize(width: 18, height: 18) else { exit(14) }
    }
    let menuActions: [(OigoPresentationAction, String, String)] = [
        (.startDictation, OigoStatusMenuIdentity.startIdentifier, "Start Oigo dictation"),
        (.stopDictation, OigoStatusMenuIdentity.stopIdentifier, "Stop Oigo dictation"),
        (.openHistory, OigoStatusMenuIdentity.historyIdentifier, "Open Oigo History"),
        (.openSettings, OigoStatusMenuIdentity.settingsIdentifier, "Open Oigo Settings"),
        (.quit, OigoStatusMenuIdentity.quitIdentifier, "Quit Oigo")
    ]
    guard menuActions.allSatisfy({ action, identifier, label in
        OigoStatusMenuIdentity.identifier(for: action) == identifier
            && OigoStatusMenuIdentity.accessibilityName(for: action) == label
    }) else { exit(22) }
    print("menu-actions=5 ")
    let semanticEnvironment = OigoStatusIdentityEnvironment(
        appearanceName: .aqua,
        increasedContrast: false,
        active: true,
        scaleFactor: 1
    )
    let retinaEnvironment = OigoStatusIdentityEnvironment(
        appearanceName: .darkAqua,
        increasedContrast: true,
        active: true,
        scaleFactor: 2
    )
    guard let attention = typedStates["attention"] else { exit(21) }
    validateApprovedPixels(
        asset: asset,
        idle: OigoStatusIdentityArtwork(state: idle).image(
            environment: semanticEnvironment,
            sourceImage: asset
        ),
        recording: OigoStatusIdentityArtwork(state: recording).image(
            environment: semanticEnvironment,
            sourceImage: asset
        ),
        attention: OigoStatusIdentityArtwork(state: attention).image(
            environment: semanticEnvironment,
            sourceImage: asset
        ),
        retina: OigoStatusIdentityArtwork(state: idle).image(
            environment: retinaEnvironment,
            sourceImage: asset
        )
    )
    if fixture.captureArtwork == true {
        let captureRoot = fixtureURL.deletingLastPathComponent()
            .appendingPathComponent("captures", isDirectory: true)
        try FileManager.default.createDirectory(at: captureRoot, withIntermediateDirectories: true)
        for expected in fixture.states {
            guard let state = presentationState(expected) else { exit(18) }
            let artwork = OigoStatusIdentityArtwork(state: state)
            for (appearanceIndex, environment) in
                OigoStatusIdentityEnvironment.contractAppearances.enumerated() {
                let variant = artwork.variant.rawValue
                let phases: [CGFloat] = variant == "processing" ? [0, 0.125, 0.25] : [0]
                for (phaseIndex, phase) in phases.enumerated() {
                    let image = artwork.image(
                        environment: environment,
                        sourceImage: asset,
                        progressPhase: phase
                    )
                    let expectedPixels = Int((18 * environment.scaleFactor).rounded())
                    guard let bitmap = image.representations
                            .compactMap({ $0 as? NSBitmapImageRep })
                            .first(where: {
                                $0.pixelsWide == expectedPixels && $0.pixelsHigh == expectedPixels
                            }),
                          let png = bitmap.representation(using: .png, properties: [:]) else {
                        exit(19)
                    }
                    let scale = environment.scaleFactor == 2 ? "2x" : "1x"
                    let name = variant + "-appearance-\(appearanceIndex)-scale-\(scale)"
                        + "-\(expectedPixels)x\(expectedPixels)-phase-\(phaseIndex).png"
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
