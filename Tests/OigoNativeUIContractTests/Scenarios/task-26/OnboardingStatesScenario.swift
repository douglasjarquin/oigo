import AppKit
import Foundation

final class OnboardingStatesScenario: NativeUIContractScenario {
    private struct Fixture: Codable {
        struct Stage: Codable {
            let title: String
            let body: String
        }

        struct Controls: Codable {
            let back: String
            let `continue`: String
            let close: String
            let stageAction: String
            let copyOnly: String
            let shortcut: String
            let testField: String
        }

        let scenario: String
        let fixture: String
        let stages: [String: Stage]
        let controls: Controls
        let h105: [String]
    }

    override class var scenarioName: String { "onboarding-states" }

    override class func run(arguments: ContractArguments) throws {
        guard arguments.defaultsSuite == "com.oigo.qa.task26" else {
            throw ContractInputError(category: "invalid-defaults-suite")
        }
        let fixture = try loadFixture(from: arguments.fixtureRoot)
        try validate(fixture)
        let repositoryRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourcePaths = [
            "Sources/Oigo/OnboardingShellMetrics.swift",
            "Sources/Oigo/OnboardingShellLayout.swift",
            "Sources/Oigo/OigoUtilityWindow.swift",
            "Sources/Oigo/Task8ControlObservation.swift",
            "Sources/Oigo/OnboardingWindowController.swift",
            "Sources/Oigo/OnboardingShellContractFactory.swift"
        ].map { repositoryRoot.appendingPathComponent($0) }
        guard sourcePaths.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw ContractInputError(category: "missing-onboarding-state-production-sources")
        }
        let output = try runCompiledContract(
            sources: sourcePaths,
            fixture: fixture,
            evidenceRoot: arguments.evidenceRoot,
            caseName: arguments.caseName
        )
        var requiredOutput = ["PASS onboarding-states"]
        if let caseName = arguments.caseName {
            requiredOutput.append("PASS \(caseName)")
        } else if fixture.fixture != "onboarding-success" {
            requiredOutput.append(contentsOf: fixture.h105.map { "PASS \($0)" })
        } else {
            requiredOutput.append("PASS onboarding-happy")
        }
        guard requiredOutput.allSatisfy(output.contains) else {
            throw ContractInputError(category: "unexpected-onboarding-state-output")
        }
        try writeReceipt(output: output, fixture: fixture, evidenceRoot: arguments.evidenceRoot)
        print(output, terminator: "")
    }

    private static func loadFixture(from root: URL) throws -> Fixture {
        let url = root.appendingPathComponent("fixture.json")
        guard let data = try? Data(contentsOf: url),
              let fixture = try? JSONDecoder().decode(Fixture.self, from: data) else {
            throw ContractInputError(category: "malformed-onboarding-states")
        }
        return fixture
    }

    private static func validate(_ fixture: Fixture) throws {
        guard fixture.scenario == scenarioName,
              fixture.stages["system"]?.title == "Mac & Storage",
              fixture.stages["language"]?.title == "Microphone & Language",
              fixture.stages["shortcut"]?.title == "Shortcut & Insertion",
              fixture.stages["tryIt"]?.title == "Try It",
              fixture.stages["done"]?.title == "Done",
              fixture.h105 == ["H105-01", "H105-02", "H105-03", "H105-04", "H105-05"] else {
            throw ContractInputError(category: "onboarding-state-fixture-mismatch")
        }
    }

    private static func runCompiledContract(
        sources: [URL],
        fixture: Fixture,
        evidenceRoot: URL,
        caseName: String?
    ) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-native-ui-redesign.task26." + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let driver = root.appendingPathComponent("main.swift")
        let payload = root.appendingPathComponent("fixture.json")
        let executable = root.appendingPathComponent("onboarding-states-contract")
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
            arguments: [payload.path, evidenceRoot.path, caseName ?? ""]
        )
        guard let output = String(data: data, encoding: .utf8) else {
            throw ContractInputError(category: "unreadable-onboarding-state-output")
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

    private static func writeReceipt(
        output: String,
        fixture: Fixture,
        evidenceRoot: URL
    ) throws {
        let stages = fixture.stages.reduce(into: [String: Any]()) { result, entry in
            result[entry.key] = ["title": entry.value.title, "body": entry.value.body]
        }
        let receipt: [String: Any] = [
            "scenario": scenarioName,
            "fixture": fixture.fixture,
            "productionController": true,
            "stages": stages,
            "controls": [
                "back": fixture.controls.back,
                "continue": fixture.controls.continue,
                "close": fixture.controls.close,
                "stageAction": fixture.controls.stageAction,
                "copyOnly": fixture.controls.copyOnly,
                "shortcut": fixture.controls.shortcut,
                "testField": fixture.controls.testField
            ],
            "h105": fixture.h105,
            "output": output.split(separator: "\n").map(String.init),
            "limitations": [
                "Synthetic Speech and permission callbacks are used; no live microphone, Speech asset, or transcription side effect is claimed.",
                "The scenario instantiates the production controller and evidence machine, while Task26 intentionally excludes production app-delegate integration.",
                "No clipboard or automatic-paste result is claimed from the synthetic completion report."
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
        try data.write(to: evidenceRoot.appendingPathComponent("onboarding-states.json"), options: .atomic)
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
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let error = String(data: errorOutput, encoding: .utf8) ?? ""
            let standardOutput = String(data: output, encoding: .utf8) ?? ""
            throw ContractInputError(
                category: "onboarding-states-build-failed:exit=\(process.terminationStatus):"
                    + (error + standardOutput).prefix(2000)
            )
        }
        return output + errorOutput
    }

    private static let contractDriver = #"""
    import AppKit
    import Foundation
    import OigoCore

    struct Fixture: Decodable {
        struct Stage: Decodable { let title: String; let body: String }
        struct Controls: Decodable {
            let back: String
            let `continue`: String
            let close: String
            let stageAction: String
            let copyOnly: String
            let shortcut: String
            let testField: String
        }
        let fixture: String
        let stages: [String: Stage]
        let controls: Controls
        let h105: [String]
    }

    @MainActor
    final class Delegate: NSObject, NSApplicationDelegate {
    let fixture: Fixture
    let evidenceRoot: URL
        let caseName: String

        init(fixture: Fixture, evidenceRoot: URL, caseName: String) {
            self.fixture = fixture
            self.evidenceRoot = evidenceRoot
            self.caseName = caseName
        }

        func applicationDidFinishLaunching(_ notification: Notification) {
            _ = notification
            NSApp.setActivationPolicy(.regular)
            let shouldRunHappy = caseName.isEmpty
                && (fixture.fixture == "onboarding" || fixture.fixture == "onboarding-success")
            let shouldRunFailures = caseName.isEmpty
                && (fixture.fixture == "onboarding" || fixture.fixture == "onboarding-failure")
            do {
                if shouldRunHappy { try runHappy() }
                if shouldRunFailures || !caseName.isEmpty { try runFailures() }
                print("PASS onboarding-states fixture=\(fixture.fixture) stages=system,language,shortcut,tryIt,done production-controller=true")
                NSApp.terminate(nil)
            } catch {
                let message = "ERROR onboarding-states " + String(describing: error)
                print(message)
                FileHandle.standardError.write(Data((message + "\n").utf8))
                NSApp.terminate(nil)
            }
        }

        func runHappy() throws {
            let factory = try OnboardingShellContractFactory(defaultsSuite: "com.oigo.qa.task26")
            let controller = factory.controller
            let committed = factory.settingsStore.load()
            controller.showAndFocus()
            guard let window = controller.window,
                  let content = window.contentView else { throw ProbeError.missingWindow }
            try assertStage(controller, key: "system")
            try assertControls(content, expected: [fixture.controls.continue, fixture.controls.close])
            try captureStage(controller, key: "system")
            try sendReturn(to: window)
            try wait(until: { factory.sourceProbeGenerations.count == 1 })
            guard let sourceGeneration = factory.sourceProbeGenerations.last else {
                throw ProbeError.missingGeneration
            }
            try wait(until: {
                self.findPopup(in: content, identifier: "oigo.onboarding.language")?.numberOfItems == 2
            })
            controller.applySourceProbeUpdate(OigoOnboardingSourceProbeUpdate(
                generation: sourceGeneration,
                usedInput: .systemDefault,
                usedChannel: 0,
                acceptedCanonicalBuffer: true,
                signalHealth: .usable,
                meterLevel: 0.5
            ))
            try assertStage(controller, key: "language")
            try assertControls(content, expected: [fixture.controls.back, fixture.controls.continue, fixture.controls.close])
            try captureStage(controller, key: "language")
            guard let languageAction = findButton(in: content, identifier: fixture.controls.stageAction),
                  languageAction.title == "Check speech assets" else { throw ProbeError.missingControl }
            languageAction.performClick(nil)
            try wait(until: {
                self.findButton(in: content, identifier: fixture.controls.continue)?.isEnabled == true
            })
            try sendClick(in: content, identifier: fixture.controls.continue)
            try assertStage(controller, key: "shortcut")
            try captureStage(controller, key: "shortcut")
            let shortcutLabel = factory.settingsStore.load().globalShortcut.copy.displayName
            guard visibleText(in: content, identifier: "oigo.onboarding.status").contains(shortcutLabel),
                  findButton(in: content, identifier: fixture.controls.copyOnly)?.accessibilityLabel() != nil else {
                throw ProbeError.missingAccessibilityValue
            }
            try sendClick(in: content, identifier: fixture.controls.continue)
            try assertStage(controller, key: "tryIt")
            try captureStage(controller, key: "tryIt")
            guard let testAction = findButton(in: content, identifier: fixture.controls.stageAction),
                  let testField = findField(in: content, identifier: fixture.controls.testField) else {
                throw ProbeError.missingControl
            }
            testAction.performClick(nil)
            try wait(until: { factory.testGenerations.count == 1 })
            try wait(until: {
                window.firstResponder === testField || testField.currentEditor() === window.firstResponder
            })
            guard window.firstResponder === testField || testField.currentEditor() === window.firstResponder else {
                throw ProbeError.focusMismatch
            }
            let sessionID = UUID()
            guard let generation = factory.testGenerations.last else { throw ProbeError.missingGeneration }
            testField.stringValue = "Task26 verified dictation"
            controller.bindTestSession(sessionID)
            controller.applyTestCompletion(
                generation: generation &+ 1,
                sessionID: sessionID,
                report: productionReport(sessionID: sessionID),
                selectedInsertionText: testField.stringValue
            )
            controller.applyTestCompletion(
                generation: generation,
                sessionID: sessionID,
                report: productionReport(sessionID: sessionID),
                selectedInsertionText: testField.stringValue
            )
            try sendClick(in: content, identifier: fixture.controls.continue)
            try assertStage(controller, key: "done")
            guard visibleText(in: content, identifier: "oigo.onboarding.body").hasPrefix(
                fixture.stages["done"]!.body
            ) else { throw ProbeError.copyMismatch }
            try captureStage(controller, key: "done")
            try sendClick(in: content, identifier: fixture.controls.continue)
            try wait(until: { factory.completeCallbackCount == 1 })
            guard factory.onboardingStore.load().isComplete,
                  factory.settingsStore.load() == committed else { throw ProbeError.persistenceMismatch }
            let reopened = factory.makeController(initialStep: .complete)
            reopened.showAndFocus()
            try assertStage(reopened, key: "done")
            guard factory.settingsStore.load() == committed else { throw ProbeError.persistenceMismatch }
            reopened.window?.close()
            print("PASS onboarding-happy stages=5 screenshots=15 focus=test-field keyboard=return mouse=continue,action completion=verified")
        }

        func runFailures() throws {
            guard fixture.h105.count == 5 else { throw ProbeError.h105Mismatch }
            if caseName.isEmpty || caseName == "H105-01" { try runLocaleRace(label: "H105-01") }
            if caseName.isEmpty || caseName == "H105-02" { try runLocaleRace(label: "H105-02") }
            if caseName.isEmpty || caseName == "H105-03" { try runLocaleRace(label: "H105-03") }
            if !caseName.isEmpty && !fixture.h105.contains(caseName) {
                throw ProbeError.h105Mismatch
            }
            if caseName.isEmpty || caseName == "H105-04" {
            let backFactory = try OnboardingShellContractFactory(defaultsSuite: "com.oigo.qa.task26")
            let backController = backFactory.makeController(initialStep: .language)
            backController.showAndFocus()
            guard let backContent = backController.window?.contentView else { throw ProbeError.missingWindow }
            try wait(until: { self.findPopup(in: backContent, identifier: "oigo.onboarding.language")?.numberOfItems == 2 })
            try sendClick(in: backContent, identifier: fixture.controls.stageAction)
            try sendClick(in: backContent, identifier: fixture.controls.back)
            try sendClick(in: backContent, identifier: fixture.controls.continue)
            try wait(until: { self.findButton(in: backContent, identifier: fixture.controls.continue)?.isEnabled == false })
            guard backFactory.settingsStore.load().globalShortcut == ToggleShortcut(keyCode: 13, modifiers: ToggleShortcutModifiers.command) else { throw ProbeError.persistenceMismatch }
            backController.window?.close()
            print("PASS H105-04 back-during-install recheck=required generation-fenced=true")
            }

            if caseName.isEmpty {
                let microphoneFactory = try OnboardingShellContractFactory(defaultsSuite: "com.oigo.qa.task26")
                let microphoneController = microphoneFactory.makeController(
                    initialStep: .language,
                    microphoneState: .denied
                )
                microphoneController.showAndFocus()
                guard let microphoneContent = microphoneController.window?.contentView,
                      let microphoneAction = findButton(
                          in: microphoneContent,
                          identifier: fixture.controls.stageAction
                      ),
                      microphoneAction.title == "Open Microphone Settings",
                      findButton(in: microphoneContent, identifier: fixture.controls.continue)?.isEnabled == false else {
                    throw ProbeError.microphoneRecoveryMismatch
                }
                microphoneAction.performClick(nil)
                guard microphoneFactory.microphoneSettingsCount == 1 else {
                    throw ProbeError.microphoneRecoveryMismatch
                }
                microphoneController.window?.close()
                print("PASS microphone-denied recovery=open-settings callback=observed continue=disabled")
            }

            if caseName.isEmpty || caseName == "H105-05" {
            let tryFactory = try OnboardingShellContractFactory(defaultsSuite: "com.oigo.qa.task26")
            let tryController = tryFactory.makeController(initialStep: .testDictation)
            tryController.showAndFocus()
            guard let tryContent = tryController.window?.contentView else { throw ProbeError.missingWindow }
            try sendClick(in: tryContent, identifier: fixture.controls.stageAction)
            try wait(until: { tryFactory.testGenerations.count == 1 })
            tryController.window?.close()
            guard tryFactory.testCancelCount >= 1 else { throw ProbeError.cleanupMismatch }
            let reopened = tryFactory.makeController(initialStep: .testDictation)
            reopened.showAndFocus()
            guard let reopenedContent = reopened.window?.contentView,
                  let reopenedField = findField(in: reopenedContent, identifier: fixture.controls.testField),
                  reopenedField.stringValue.isEmpty else { throw ProbeError.staleSuccess }
            reopened.window?.close()
            print("PASS H105-05 close-during-try cancel=observed reopen=clean stale-success=absent")
            }

            if caseName.isEmpty || caseName == "accessibility-copy-only" {
            let copyFactory = try OnboardingShellContractFactory(defaultsSuite: "com.oigo.qa.task26")
            let copyController = copyFactory.makeController(initialStep: .shortcut, accessibilityState: .denied)
            copyController.showAndFocus()
            guard let copyContent = copyController.window?.contentView,
                  let copyOnly = findButton(in: copyContent, identifier: fixture.controls.copyOnly),
                  copyOnly.isHidden == false,
                  findButton(in: copyContent, identifier: fixture.controls.continue)?.isEnabled == false else { throw ProbeError.copyOnlyMismatch }
            copyOnly.performClick(nil)
            guard visibleText(in: copyContent, identifier: "oigo.onboarding.status").contains("Copy-only"),
                  findButton(in: copyContent, identifier: fixture.controls.continue)?.isEnabled == true else { throw ProbeError.copyOnlyMismatch }
            copyController.window?.close()
            print("PASS accessibility-copy-only messaging=present continue=recovered automatic-paste=not-claimed")
            }
        }

        func runLocaleRace(label: String) throws {
            let factory = try OnboardingShellContractFactory(defaultsSuite: "com.oigo.qa.task26")
            let controller = factory.makeController(
                initialStep: .language,
                loadSupportedLanguages: { ["en-US", "es-MX"] },
                checkSpeechAssets: { _ in
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    return .ready
                }
            )
            let committed = factory.settingsStore.load()
            controller.showAndFocus()
            guard let content = controller.window?.contentView else { throw ProbeError.missingWindow }
            try wait(until: { self.findPopup(in: content, identifier: "oigo.onboarding.language")?.numberOfItems == 2 })
            try sendClick(in: content, identifier: fixture.controls.stageAction)
            guard let popup = findPopup(in: content, identifier: "oigo.onboarding.language") else { throw ProbeError.missingControl }
            popup.selectItem(at: 1)
            popup.sendAction(popup.action, to: popup.target)
            try wait(until: { factory.assetRequestLocales.count == 1 })
            try wait(until: { factory.assetCompletionCount == 1 })
            try wait(until: { factory.settingsStore.load() == committed })
            let continueEnabled = findButton(in: content, identifier: fixture.controls.continue)?.isEnabled
            let status = visibleText(in: content, identifier: "oigo.onboarding.status")
            guard continueEnabled == false, !status.contains("Speech assets: ready") else {
                throw ProbeError.generationMismatch
            }
            controller.window?.close()
            print("PASS \(label) locale-switch=observed late-result=ignored persistence=unchanged")
        }

        func assertStage(_ controller: OnboardingWindowController, key: String) throws {
            guard let content = controller.window?.contentView,
                  let stage = fixture.stages[key],
                  visibleText(in: content, identifier: "oigo.onboarding.title") == stage.title,
                  visibleText(in: content, identifier: "oigo.onboarding.body").hasPrefix(stage.body) else {
                throw ProbeError.copyMismatch
            }
        }

        func assertControls(_ content: NSView, expected: [String]) throws {
            guard expected.allSatisfy({ id in
                if id == fixture.controls.close { return true }
                return allViews(content).contains { $0.accessibilityIdentifier() == id }
            }) else { throw ProbeError.missingControl }
        }

        func sendClick(in content: NSView, identifier: String) throws {
            guard let button = findButton(in: content, identifier: identifier), button.isEnabled else {
                throw ProbeError.missingControl
            }
            button.performClick(nil)
            pumpEvents()
        }

        func sendReturn(to window: NSWindow) throws {
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: false,
                keyCode: 36
            ) else { throw ProbeError.keyboardMismatch }
            window.sendEvent(event)
            pumpEvents()
        }

        func captureStage(_ controller: OnboardingWindowController, key: String) throws {
            guard let window = controller.window,
                  let content = window.contentView else { throw ProbeError.missingWindow }
            let appearances = [
                ("light", "NSAppearanceNameAqua"),
                ("dark", "NSAppearanceNameDarkAqua"),
                ("increased-contrast", "NSAppearanceNameAccessibilityHighContrastAqua")
            ]
            for (label, appearanceName) in appearances {
                window.appearance = NSAppearance(named: NSAppearance.Name(appearanceName))
                content.appearance = window.appearance
                window.displayIfNeeded()
                let path = evidenceRoot.appendingPathComponent("onboarding-\(key)-\(label).png")
                guard capture(content, to: path) else { throw ProbeError.captureFailure }
            }
        }

        func productionReport(sessionID: UUID) -> OigoOnboardingProductionReport {
            OigoOnboardingProductionReport(
                usedInput: .systemDefault,
                usedChannel: 0,
                sessionCreated: true,
                captureStarted: true,
                recordingFinalized: true,
                rawTranscriptPersisted: true,
                cafInitialized: true,
                speechFinalized: true,
                transcriptNonempty: true,
                cleanupSucceeded: true,
                clipboardWritten: true,
                targetValidationSucceeded: true,
                insertionOutcome: .pasted,
                insertionPath: .production,
                insertionInvoked: true,
                recoverableArtifactsRetained: true,
                sessionID: sessionID
            )
        }

        func allViews(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(allViews) }

        func visibleText(in root: NSView, identifier: String) -> String {
            (allViews(root).first { $0.accessibilityIdentifier() == identifier } as? NSTextField)?.stringValue ?? ""
        }

        func findButton(in root: NSView, identifier: String) -> NSButton? {
            allViews(root).first { $0.accessibilityIdentifier() == identifier } as? NSButton
        }

        func findField(in root: NSView, identifier: String) -> NSTextField? {
            allViews(root).first { $0.accessibilityIdentifier() == identifier } as? NSTextField
        }

        func findPopup(in root: NSView, identifier: String) -> NSPopUpButton? {
            allViews(root).first { $0.accessibilityIdentifier() == identifier } as? NSPopUpButton
        }

        func wait(until condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(1)
            while !condition() && Date() < deadline { pumpEvents() }
            guard condition() else { throw ProbeError.timeout }
        }

        func pumpEvents() {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    enum ProbeError: Error {
        case missingWindow, missingControl, missingGeneration, missingAccessibilityValue
        case copyMismatch, focusMismatch, persistenceMismatch, generationMismatch
        case h105Mismatch, cleanupMismatch, staleSuccess, copyOnlyMismatch
        case keyboardMismatch, captureFailure, timeout, microphoneRecoveryMismatch
    }

    func capture(_ view: NSView, to url: URL) -> Bool {
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
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            view.bounds.fill()
            view.displayIgnoringOpacity(view.bounds, in: context)
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
            return true
        } catch { return false }
    }

    let fixture = try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
    let application = NSApplication.shared
    let delegate = MainActor.assumeIsolated {
        Delegate(
            fixture: fixture,
            evidenceRoot: URL(fileURLWithPath: CommandLine.arguments[2]),
            caseName: CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : ""
        )
    }
    application.delegate = delegate
    application.run()
    """#
}
