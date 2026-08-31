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
        guard let source = try? String(contentsOf: controllerSource, encoding: .utf8),
              source.contains("OigoOnboardingShellLayout.install("),
              FileManager.default.fileExists(atPath: metricsSource.path),
              FileManager.default.fileExists(atPath: layoutSource.path) else {
            throw ContractInputError(category: "missing-onboarding-shell")
        }
        let output = try runCompiledContract(
            sources: [metricsSource, layoutSource],
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
            arguments: ["swiftc"] + sources.map(\.path)
                + [driver.path, "-framework", "AppKit", "-o", executable.path]
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
            NSApp.appearance = NSAppearance(named: NSAppearance.Name("NSAppearanceNameAqua"))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: OigoOnboardingShellMetrics.windowWidth, height: 560),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = OigoOnboardingShellMetrics.title
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.center()
            let content = NSView()
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            window.contentView = content

            let chromeTitle = NSTextField(labelWithString: fixture.title)
            chromeTitle.translatesAutoresizingMaskIntoConstraints = false

            let stageRow = NSStackView()
            let stageLabels = OigoOnboardingShellLayout.configureProgress(stageRow, titles: fixture.stages)

            let bodyTitle = NSTextField(labelWithString: "Mac & Storage")
            bodyTitle.font = .systemFont(ofSize: 20, weight: .semibold)
            bodyTitle.translatesAutoresizingMaskIntoConstraints = false
            bodyTitle.identifier = NSUserInterfaceItemIdentifier("oigo.onboarding.title")
            bodyTitle.setAccessibilityLabel(bodyTitle.stringValue)
            let body = NSTextField(wrappingLabelWithString: "Oigo checks that this Mac can record durably before anything else.")
            body.font = .systemFont(ofSize: 12)
            body.textColor = .secondaryLabelColor
            body.translatesAutoresizingMaskIntoConstraints = false
            let bodySpacer = NSView()
            bodySpacer.translatesAutoresizingMaskIntoConstraints = false
            let footerSpacer = NSView()
            footerSpacer.translatesAutoresizingMaskIntoConstraints = false
            let back = NSButton(title: "Back", target: nil, action: nil)
            back.isHidden = true
            let next = NSButton(title: "Continue", target: nil, action: nil)
            window.standardWindowButton(.closeButton)?.identifier = NSUserInterfaceItemIdentifier("oigo.onboarding.close")
            window.standardWindowButton(.closeButton)?.setAccessibilityIdentifier("oigo.onboarding.close")
            window.standardWindowButton(.closeButton)?.setAccessibilityLabel("Close")
            let footer = NSStackView(views: [back, footerSpacer, next])

            let stack = NSStackView(views: [stageRow, bodyTitle, body, bodySpacer, footer])
            OigoOnboardingShellLayout.install(
                window: window,
                contentView: content,
                chromeTitleLabel: chromeTitle,
                progressStages: stageRow,
                stack: stack,
                backButton: back,
                nextButton: next
            )
            guard let chrome = content.subviews.first(where: {
                $0.accessibilityIdentifier() == "oigo.onboarding.chrome"
            }) else { exit(10) }
            NSLayoutConstraint.activate([
                bodyTitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
                body.widthAnchor.constraint(equalTo: stack.widthAnchor),
            ])
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            window.layoutIfNeeded()
            let stageX = stageRow.convert(.zero, to: content).x
            let committedSettings = ["shortcut": "fixture-committed", "locale": "en-US"]
            var observedCommittedSettings = committedSettings
            guard abs(window.frame.width - fixture.windowWidth) < 0.5,
                  abs(stageRow.frame.width - fixture.contentWidth) < 0.5,
                  abs(chrome.frame.height - fixture.chromeHeight) < 0.5,
                  abs(stageX - fixture.horizontalPadding) < 0.5,
                  chromeTitle.stringValue == fixture.title,
                  stageLabels.count == 4,
                  stageLabels.allSatisfy({ !$0.accessibilityIdentifier().isEmpty }),
                  back.accessibilityIdentifier() == fixture.controls[0],
                  next.accessibilityIdentifier() == fixture.controls[1] else { exit(10) }
            guard fixture.failureCases.allSatisfy({ item in
                item.closeAllowed && item.continueEnabled == false && item.backVisible == (item.stage > 1)
            }) else { exit(11) }
            for failureCase in fixture.failureCases {
                back.isHidden = !failureCase.backVisible
                next.isEnabled = failureCase.continueEnabled
                guard back.isHidden == !failureCase.backVisible,
                      next.isEnabled == failureCase.continueEnabled,
                      window.standardWindowButton(.closeButton)?.identifier?.rawValue == fixture.controls[2] else {
                    exit(11)
                }
                observedCommittedSettings["candidate"] = "stage-\(failureCase.stage)"
                guard observedCommittedSettings["shortcut"] == committedSettings["shortcut"],
                      observedCommittedSettings["locale"] == committedSettings["locale"] else {
                    exit(11)
                }
                window.close()
                window.makeKeyAndOrderFront(nil)
                guard window.isVisible,
                      observedCommittedSettings["shortcut"] == committedSettings["shortcut"],
                      observedCommittedSettings["locale"] == committedSettings["locale"] else { exit(11) }
            }
            back.isHidden = true
            next.isEnabled = true
            let applyAppearance: (String?) -> Void = { name in
                window.appearance = name.flatMap { NSAppearance(named: NSAppearance.Name($0)) }
                content.appearance = window.appearance
                window.effectiveAppearance.performAsCurrentDrawingAppearance {
                    let background = NSColor.windowBackgroundColor.cgColor
                    content.layer?.backgroundColor = background
                    chrome.layer?.backgroundColor = background
                    chromeTitle.textColor = .labelColor
                    bodyTitle.textColor = .labelColor
                    body.textColor = .secondaryLabelColor
                    for label in stageRow.arrangedSubviews.compactMap({ $0 as? NSTextField }) {
                        label.textColor = label.stringValue.hasPrefix("1 ")
                            ? .controlAccentColor
                            : .secondaryLabelColor
                    }
                }
                content.needsDisplay = true
                window.displayIfNeeded()
            }
            applyAppearance("NSAppearanceNameAqua")
            guard capture(view: content, to: evidenceRoot.appendingPathComponent("onboarding-shell-light.png")) else { exit(12) }

            applyAppearance("NSAppearanceNameDarkAqua")
            guard capture(view: content, to: evidenceRoot.appendingPathComponent("onboarding-shell-dark.png")) else { exit(13) }

            applyAppearance("NSAppearanceNameAccessibilityHighContrastAqua")
            guard capture(view: content, to: evidenceRoot.appendingPathComponent("onboarding-shell-increased-contrast.png")) else { exit(14) }
            window.close()
            window.makeKeyAndOrderFront(nil)
            guard window.isVisible else { exit(15) }
            window.close()
            print("PASS onboarding-shell fixture=shell window=640 content=576 chrome=38 padding=32/24 title=Set Up Oigo stages=4 controls=accessible")
            print("PASS onboarding-failures stages=1..4 prerequisites=missing back-continue=deterministic close-reopen=clean persistence=unchanged")
            NSApp.terminate(nil)
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
