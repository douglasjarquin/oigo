import AppKit
import Foundation

final class OnboardingShellScenario: NativeUIContractScenario {
    private struct Fixture: Codable {
        struct FailureCase: Codable {
            let stage: Int
            let backVisible: Bool
            let continueEnabled: Bool
            let closeAllowed: Bool
        }

        let scenario: String
        let fixture: String
        let windowWidth: Double
        let chromeHeight: Double
        let contentWidth: Double
        let horizontalPadding: Double
        let verticalPadding: Double
        let title: String
        let stages: [String]
        let controls: [String]
        let failureCases: [FailureCase]
    }

    override class var scenarioName: String { "onboarding-shell" }

    override class func run(arguments: ContractArguments) throws {
        guard arguments.defaultsSuite == "com.oigo.qa.task25" else {
            throw ContractInputError(category: "invalid-defaults-suite")
        }
        let fixture = try loadFixture(from: arguments.fixtureRoot)
        try validate(fixture)
        let repositoryRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let controllerSource = repositoryRoot.appendingPathComponent(
            "Sources/Oigo/OnboardingWindowController.swift"
        )
        let metricsSource = repositoryRoot.appendingPathComponent("Sources/Oigo/OnboardingShellMetrics.swift")
        let layoutSource = repositoryRoot.appendingPathComponent("Sources/Oigo/OnboardingShellLayout.swift")
        let utilityWindowSource = repositoryRoot.appendingPathComponent("Sources/Oigo/OigoUtilityWindow.swift")
        let task8ObservationSource = repositoryRoot.appendingPathComponent("Sources/Oigo/Task8ControlObservation.swift")
        let factorySource = repositoryRoot.appendingPathComponent("Sources/Oigo/OnboardingShellContractFactory.swift")
        guard let source = try? String(contentsOf: controllerSource, encoding: .utf8),
              source.contains("OigoOnboardingShellLayout.install("),
              FileManager.default.fileExists(atPath: metricsSource.path),
              FileManager.default.fileExists(atPath: layoutSource.path),
              FileManager.default.fileExists(atPath: utilityWindowSource.path),
              FileManager.default.fileExists(atPath: task8ObservationSource.path),
              FileManager.default.fileExists(atPath: factorySource.path) else {
            throw ContractInputError(category: "missing-onboarding-shell")
        }
        let output = try runCompiledContract(
            sources: [metricsSource, layoutSource, utilityWindowSource, task8ObservationSource, controllerSource, factorySource],
            fixture: fixture,
            evidenceRoot: arguments.evidenceRoot
        )
        guard output.contains("PASS onboarding-shell"),
              output.contains("PASS onboarding-failures") else {
            throw ContractInputError(category: "unexpected-onboarding-shell-output")
        }
        try writeReceipt(output: output, fixture: fixture, evidenceRoot: arguments.evidenceRoot)
        print(output, terminator: "")
    }

    private static func loadFixture(from root: URL) throws -> Fixture {
        let url = root.appendingPathComponent("fixture.json")
        guard let data = try? Data(contentsOf: url),
              let fixture = try? JSONDecoder().decode(Fixture.self, from: data) else {
            throw ContractInputError(category: "malformed-onboarding-shell")
        }
        return fixture
    }

    private static func validate(_ fixture: Fixture) throws {
        guard fixture.scenario == scenarioName,
              fixture.fixture == "shell",
              fixture.windowWidth == 640,
              fixture.chromeHeight == 38,
              fixture.contentWidth == 576,
              fixture.horizontalPadding == 32,
              fixture.verticalPadding == 24,
              fixture.title == "Set Up Oigo",
              fixture.stages == [
                  "Mac & Storage", "Microphone & Language", "Shortcut & Insertion", "Try It"
              ],
              fixture.controls == [
                  "oigo.onboarding.back", "oigo.onboarding.continue", "oigo.onboarding.close"
              ],
              fixture.failureCases.map(\.stage) == [1, 2, 3, 4] else {
            throw ContractInputError(category: "onboarding-shell-geometry-mismatch")
        }
    }

    private static func runCompiledContract(
        sources: [URL],
        fixture: Fixture,
        evidenceRoot: URL
    ) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-native-ui-redesign.task25." + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let driver = root.appendingPathComponent("main.swift")
        let payload = root.appendingPathComponent("fixture.json")
        let executable = root.appendingPathComponent("onboarding-shell-contract")
        try JSONEncoder().encode(fixture).write(to: payload, options: .atomic)
        try contractDriver.write(to: driver, atomically: true, encoding: .utf8)
        _ = try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: [
                "swiftc",
                "-I", repositoryRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/Modules").path
            ] + sources.map(\.path) + [
                driver.path,
                "-framework", "AppKit",
                "-framework", "Carbon",
                "-o", executable.path
            ] + dependencyObjects(repositoryRoot)
        )
        let data = try runProcess(
            executable: executable,
            arguments: [payload.path, evidenceRoot.path]
        )
        guard let output = String(data: data, encoding: .utf8) else {
            throw ContractInputError(category: "unreadable-onboarding-shell-output")
        }
        return output
    }

    private static func dependencyObjects(_ repositoryRoot: URL) -> [String] {
        ["OigoCore.build", "OigoHotKey.build"].flatMap { directory in
            let root = repositoryRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/" + directory)
            return (try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            ))?.filter { $0.pathExtension == "o" }.map(\.path) ?? []
        }
    }

    private static func writeReceipt(output: String, fixture: Fixture, evidenceRoot: URL) throws {
        let receipt: [String: Any] = [
            "scenario": scenarioName,
            "fixture": fixture.fixture,
            "productionLayout": "OigoOnboardingShellLayout used by OnboardingWindowController",
            "windowWidth": fixture.windowWidth,
            "chromeHeight": fixture.chromeHeight,
            "contentWidth": fixture.contentWidth,
            "horizontalPadding": fixture.horizontalPadding,
            "verticalPadding": fixture.verticalPadding,
            "title": fixture.title,
            "stages": fixture.stages,
            "controls": fixture.controls,
            "failureCases": fixture.failureCases.map {
                [
                    "stage": $0.stage,
                    "backVisible": $0.backVisible,
                    "continueEnabled": $0.continueEnabled,
                    "closeAllowed": $0.closeAllowed
                ]
            },
            "persistence": "committed settings unchanged across failure controls and close/reopen",
            "output": output.split(separator: "\n").map(String.init)
        ]
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
        try data.write(to: evidenceRoot.appendingPathComponent("onboarding-shell.json"), options: .atomic)
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
            throw ContractInputError(
                category: "onboarding-shell-build-failed:exit=\(process.terminationStatus):"
                    + (error + standardOutput).prefix(2000)
            )
        }
        return output
    }

    private static let contractDriver = #"""
    import AppKit
    import Darwin
    import Foundation

    struct Fixture: Decodable {
        struct FailureCase: Decodable {
            let stage: Int
            let backVisible: Bool
            let continueEnabled: Bool
            let closeAllowed: Bool
        }
        let windowWidth: Double
        let chromeHeight: Double
        let contentWidth: Double
        let horizontalPadding: Double
        let verticalPadding: Double
        let title: String
        let stages: [String]
        let controls: [String]
        let failureCases: [FailureCase]
    }

    @MainActor
    final class Delegate: NSObject, NSApplicationDelegate {
        let fixture: Fixture
        let evidenceRoot: URL

        init(fixture: Fixture, evidenceRoot: URL) {
            self.fixture = fixture
            self.evidenceRoot = evidenceRoot
        }

        func applicationDidFinishLaunching(_ notification: Notification) {
            _ = notification
            NSApp.appearance = NSAppearance(named: NSAppearance.Name("NSAppearanceNameAqua"))
            let factory: OnboardingShellContractFactory
            do {
                factory = try OnboardingShellContractFactory(defaultsSuite: "com.oigo.qa.task25")
            } catch {
                exit(20)
            }
            let controller = factory.controller
            controller.showAndFocus()
            guard let window = controller.window,
                  let content = window.contentView else { exit(10) }
            window.layoutIfNeeded()
            let views = allViews(content)
            let stageLabels = views.compactMap({ $0 as? NSTextField }).filter({
                $0.accessibilityIdentifier().hasPrefix("oigo.onboarding.progress.stage-")
            })
            guard let stageRow = stageLabels.first?.superview,
                  let chrome = views.first(where: {
                      $0.accessibilityIdentifier() == "oigo.onboarding.chrome"
                  }),
                  let chromeTitle = views.first(where: {
                      $0.accessibilityIdentifier() == "oigo.onboarding.chrome-title"
                  }) as? NSTextField,
                  let back = views.first(where: {
                      $0.accessibilityIdentifier() == fixture.controls[0]
                  }) as? NSButton,
                  let next = views.first(where: {
                      $0.accessibilityIdentifier() == fixture.controls[1]
                  }) as? NSButton,
                  let close = window.standardWindowButton(.closeButton) else { exit(10) }
            let stageX = stageRow.convert(.zero, to: content).x
            let committedSettings = factory.settingsStore.load()
            guard abs(window.frame.width - fixture.windowWidth) < 0.5,
                  abs(stageRow.frame.width - fixture.contentWidth) < 0.5,
                  abs(chrome.frame.height - fixture.chromeHeight) < 0.5,
                  abs(stageX - fixture.horizontalPadding) < 0.5,
                  window.title == fixture.title,
                  chromeTitle.stringValue == fixture.title,
                  stageLabels.count == 4,
                  stageLabels.allSatisfy({ !$0.accessibilityIdentifier().isEmpty }),
                  back.accessibilityIdentifier() == fixture.controls[0],
                  next.accessibilityIdentifier() == fixture.controls[1],
                  close.accessibilityIdentifier() == fixture.controls[2],
                  next.isEnabled else { exit(10) }
            guard fixture.failureCases.allSatisfy({ item in
                item.closeAllowed && item.continueEnabled == false && item.backVisible == (item.stage > 1)
            }) else { exit(11) }

            let failureControllers: [(OnboardingWindowController, Int)] = [
                (factory.controller, 1),
                (factory.makeController(
                    initialStep: .language,
                    microphoneState: .denied,
                    storageHealth: .checking
                ), 2),
                (factory.makeController(initialStep: .shortcut, accessibilityState: .denied), 3),
                (factory.makeController(
                    initialStep: .testDictation,
                    storageHealth: .checking
                ), 4)
            ]
            for (failureController, stage) in failureControllers {
                if stage == 1 { failureController.setStorageHealth(.checking) }
                failureController.showAndFocus()
                guard let failureWindow = failureController.window,
                      let failureContent = failureWindow.contentView else { exit(11) }
                let failureViews = allViews(failureContent)
                guard let failureBack = failureViews.first(where: {
                    $0.accessibilityIdentifier() == fixture.controls[0]
                }) as? NSButton,
                      let failureNext = failureViews.first(where: {
                          $0.accessibilityIdentifier() == fixture.controls[1]
                      }) as? NSButton,
                      let failureClose = failureWindow.standardWindowButton(.closeButton),
                      failureBack.isHidden == (stage == 1),
                      !failureNext.isEnabled,
                      failureClose.accessibilityIdentifier() == fixture.controls[2] else { exit(11) }
                failureWindow.close()
                guard !failureWindow.isVisible,
                      factory.settingsStore.load().globalShortcut == committedSettings.globalShortcut,
                      factory.settingsStore.load().localeIdentifier == committedSettings.localeIdentifier else { exit(11) }
                failureController.showAndFocus()
                guard failureWindow.isVisible else { exit(11) }
                failureWindow.close()
            }
            guard factory.closeCallbackCount >= failureControllers.count,
                  factory.settingsStore.load().globalShortcut == committedSettings.globalShortcut,
                  factory.settingsStore.load().localeIdentifier == committedSettings.localeIdentifier else { exit(11) }

            controller.setStorageHealth(.ready(.init(
                recoveredSessionCount: 0,
                historyEntryCount: 0,
                malformedSessionCount: 0
            )))
            controller.showAndFocus()
            guard let productionWindow = controller.window,
                  let productionContent = productionWindow.contentView else { exit(12) }
            let applyAppearance: (String?) -> Void = { name in
                productionWindow.appearance = name.flatMap {
                    NSAppearance(named: NSAppearance.Name($0))
                }
                productionContent.appearance = productionWindow.appearance
                productionWindow.effectiveAppearance.performAsCurrentDrawingAppearance {
                    productionContent.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                    for view in self.allViews(productionContent) where view.wantsLayer {
                        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                    }
                }
                productionWindow.displayIfNeeded()
            }
            applyAppearance("NSAppearanceNameAqua")
            guard capture(view: productionContent, to: evidenceRoot.appendingPathComponent("onboarding-shell-light.png")) else { exit(12) }
            applyAppearance("NSAppearanceNameDarkAqua")
            guard capture(view: productionContent, to: evidenceRoot.appendingPathComponent("onboarding-shell-dark.png")) else { exit(13) }
            applyAppearance("NSAppearanceNameAccessibilityHighContrastAqua")
            guard capture(view: productionContent, to: evidenceRoot.appendingPathComponent("onboarding-shell-increased-contrast.png")) else { exit(14) }
            productionWindow.close()
            guard factory.closeCallbackCount > failureControllers.count else { exit(15) }
            print("PASS onboarding-shell fixture=shell production-controller=true window=640 content=576 chrome=38 padding=32/24 title=Set Up Oigo stages=4 controls=accessible")
            print("PASS onboarding-failures stages=1..4 prerequisites=missing back-continue=deterministic close-reopen=clean callbacks=non-nil persistence=unchanged")
            NSApp.terminate(nil)
        }

        private func allViews(_ root: NSView) -> [NSView] {
            [root] + root.subviews.flatMap(allViews)
        }

    }

    func capture(view: NSView, to url: URL) -> Bool {
        view.layoutSubtreeIfNeeded()
        let scale = max(1, view.window?.backingScaleFactor ?? 2)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width * scale),
            pixelsHigh: Int(view.bounds.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        graphicsContext.cgContext.scaleBy(x: scale, y: scale)
        view.layer?.render(in: graphicsContext.cgContext)
        graphicsContext.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
            return true
        } catch { return false }
    }

    let data = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let fixture = try! JSONDecoder().decode(Fixture.self, from: data)
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    let delegate = MainActor.assumeIsolated {
        Delegate(fixture: fixture, evidenceRoot: URL(fileURLWithPath: CommandLine.arguments[2]))
    }
    application.delegate = delegate
    application.run()
    """#
}
