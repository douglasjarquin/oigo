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
            "Sources/Oigo/OnboardingShellContractFactory.swift",
            "Sources/OigoHotKey/ShortcutFormatter.swift",
            "Sources/OigoHotKey/ShortcutRecorderControl.swift"
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
            try assertStage(controller, window: window, key: "system")
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
            try assertStage(controller, window: window, key: "language")
            try captureStage(controller, key: "language")
            guard let languageAction = findButton(in: content, identifier: fixture.controls.stageAction),
                  languageAction.title == "Check speech assets" else { throw ProbeError.missingControl }
            languageAction.performClick(nil)
            try wait(until: {
                self.findButton(in: content, identifier: fixture.controls.continue)?.isEnabled == true
            })
            try sendClick(in: content, identifier: fixture.controls.continue)
            try assertStage(controller, window: window, key: "shortcut")
            try captureStage(controller, key: "shortcut")
            let shortcutLabel = factory.settingsStore.load().globalShortcut.copy.displayName
            guard let recorder = findRecorder(in: content),
                  recorder.accessibilityLabel() == "Dictation shortcut",
                  recorder.accessibilityValue() as? String == recorder.displayValue else {
                throw ProbeError.missingAccessibilityValue
            }
            let candidate = ToggleShortcut(keyCode: 0, modifiers: ToggleShortcutModifiers.command)
            recorder.beginRecording()
            guard let candidateEvent = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "a",
                charactersIgnoringModifiers: "a",
                isARepeat: false,
                keyCode: 0
            ) else { throw ProbeError.keyboardMismatch }
            recorder.keyDown(with: candidateEvent)
            guard recorder.shortcut == candidate,
                  recorder.accessibilityValue() as? String == recorder.displayValue else {
                throw ProbeError.candidatePersistenceMismatch
            }
            guard visibleText(in: content, identifier: "oigo.onboarding.status").contains(shortcutLabel),
                  findButton(in: content, identifier: fixture.controls.copyOnly)?.accessibilityLabel() != nil else {
                throw ProbeError.missingAccessibilityValue
            }
            try sendClick(in: content, identifier: fixture.controls.continue)
            let candidateSettings = factory.settingsStore.load()
            guard settingsOnlyChangedShortcut(from: committed, to: candidateSettings, candidate: candidate) else {
                throw ProbeError.candidatePersistenceMismatch
            }
            try assertStage(controller, window: window, key: "tryIt")
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
            let staleObservation = controller.task8ShortcutObservation()
            let staleSettings = factory.settingsStore.load()
            controller.applyTestCompletion(
                generation: generation &+ 1,
                sessionID: sessionID,
                report: productionReport(sessionID: sessionID),
                selectedInsertionText: "stale completion"
            )
            let afterStaleObservation = controller.task8ShortcutObservation()
            guard afterStaleObservation.status == staleObservation.status,
                  afterStaleObservation.hint == staleObservation.hint,
                  afterStaleObservation.recorderDisplay == staleObservation.recorderDisplay,
                  afterStaleObservation.recorderAccessibilityValue == staleObservation.recorderAccessibilityValue,
                  factory.settingsStore.load() == staleSettings,
                  testField.stringValue.isEmpty,
                  window.firstResponder === testField || testField.currentEditor() === window.firstResponder else {
                throw ProbeError.staleCompletionMutation
            }
            testField.stringValue = "Task26 verified dictation"
            controller.bindTestSession(sessionID)
            controller.applyTestCompletion(
                generation: generation,
                sessionID: sessionID,
                report: productionReport(sessionID: sessionID),
                selectedInsertionText: testField.stringValue
            )
            try sendClick(in: content, identifier: fixture.controls.continue)
            try assertStage(controller, window: window, key: "done")
            guard visibleText(in: content, identifier: "oigo.onboarding.body").hasPrefix(
                fixture.stages["done"]!.body
            ) else { throw ProbeError.copyMismatch }
            try captureStage(controller, key: "done")
            try sendClick(in: content, identifier: fixture.controls.continue)
            try wait(until: { factory.completeCallbackCount == 1 })
            guard factory.onboardingStore.load().isComplete,
                  settingsOnlyChangedShortcut(
                      from: committed,
                      to: factory.settingsStore.load(),
                      candidate: candidate
                  ) else { throw ProbeError.persistenceMismatch }
            let reopened = factory.makeController(initialStep: .complete)
            reopened.showAndFocus()
            guard let reopenedWindow = reopened.window else { throw ProbeError.missingWindow }
            try assertStage(reopened, window: reopenedWindow, key: "done")
            guard settingsOnlyChangedShortcut(
                from: committed,
                to: factory.settingsStore.load(),
                candidate: candidate
            ) else { throw ProbeError.persistenceMismatch }
            reopened.window?.close()
            print("PASS onboarding-happy stages=5 screenshots=15 focus=test-field keyboard=return mouse=continue,action completion=verified")
        }

        func runFailures() throws {
            guard fixture.h105.count == 5 else { throw ProbeError.h105Mismatch }
            if caseName.isEmpty || caseName == "H105-01" { try runH10501() }
            if caseName.isEmpty || caseName == "H105-02" { try runH10502() }
            if caseName.isEmpty || caseName == "H105-03" { try runH10503() }
            if !caseName.isEmpty && !fixture.h105.contains(caseName) && caseName != "accessibility-copy-only" {
                throw ProbeError.h105Mismatch
            }
            if caseName.isEmpty || caseName == "H105-04" {
            let backFactory = try OnboardingShellContractFactory(defaultsSuite: "com.oigo.qa.task26")
            let backController = backFactory.makeController(
                initialStep: .language,
                checkSpeechAssets: { _ in
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    return .ready
                }
            )
            backController.showAndFocus()
            guard let backContent = backController.window?.contentView else { throw ProbeError.missingWindow }
            try wait(until: { self.findPopup(in: backContent, identifier: "oigo.onboarding.language")?.numberOfItems == 2 })
            let backSettings = backFactory.settingsStore.load()
            try sendClick(in: backContent, identifier: fixture.controls.stageAction)
            try sendClick(in: backContent, identifier: fixture.controls.back)
            try sendClick(in: backContent, identifier: fixture.controls.continue)
            try wait(until: { self.findButton(in: backContent, identifier: fixture.controls.continue)?.isEnabled == false })
            guard backSettings == backFactory.settingsStore.load() else { throw ProbeError.persistenceMismatch }
            backController.window?.close()
            print("PASS H105-04 back-during-install recheck=required generation-fenced=true")
            try writeCaseReceipt(
                name: "H105-04",
                setup: "production language controller with delayed asset installation",
                trigger: "start asset installation, press Back, then Forward",
                expected: "language readiness is revalidated and Continue remains disabled",
                failure: "no stale install success and committed settings unchanged"
            )
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
                let trySettings = tryFactory.settingsStore.load()
            tryController.showAndFocus()
            guard let tryContent = tryController.window?.contentView else { throw ProbeError.missingWindow }
            try sendClick(in: tryContent, identifier: fixture.controls.stageAction)
            try wait(until: { tryFactory.testGenerations.count == 1 })
            let testGeneration = tryFactory.testGenerations[0]
            let closedObservation = tryController.task8ShortcutObservation()
            tryController.window?.close()
            guard tryFactory.testCancelCount >= 1 else { throw ProbeError.cleanupMismatch }
            let staleSessionID = UUID()
            tryController.applyTestCompletion(
                generation: testGeneration,
                sessionID: staleSessionID,
                report: productionReport(sessionID: staleSessionID),
                selectedInsertionText: "stale completion"
            )
            guard sameObservation(tryController.task8ShortcutObservation(), closedObservation),
                  tryFactory.testCancelCount >= 1,
                  tryFactory.settingsStore.load() == trySettings else { throw ProbeError.cleanupMismatch }
            let reopened = tryFactory.makeController(initialStep: .testDictation)
            reopened.showAndFocus()
            guard let reopenedContent = reopened.window?.contentView,
                  let reopenedField = findField(in: reopenedContent, identifier: fixture.controls.testField),
                  reopenedField.stringValue.isEmpty else { throw ProbeError.staleSuccess }
            reopened.window?.close()
            print("PASS H105-05 close-during-try cancel=observed stale-completion=ignored reopen=clean stale-success=absent")
            try writeCaseReceipt(
                name: "H105-05",
                setup: "production Try It controller with active test generation",
                trigger: "start test, close, reopen the same stage",
                expected: "cancel callback runs and test field is empty on reopen",
                failure: "stale completion cannot produce success after close"
            )
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

        func runH10501() throws {
            let factory = try OnboardingShellContractFactory(defaultsSuite: "com.oigo.qa.task26")
            let controller = factory.makeController(
                initialStep: .language,
                loadSupportedLanguages: { ["en-US", "es-MX"] },
                checkSpeechAssets: { _ in
                    return .unavailable("assets not installed")
                }
            )
            let committed = factory.settingsStore.load()
            controller.showAndFocus()
            guard let content = controller.window?.contentView else { throw ProbeError.missingWindow }
            try wait(until: { self.findPopup(in: content, identifier: "oigo.onboarding.language")?.numberOfItems == 2 })
            try wait(until: { factory.sourceProbeGenerations.count == 1 })
            guard let sourceGeneration = factory.sourceProbeGenerations.last else {
                throw ProbeError.missingGeneration
            }
            controller.applySourceProbeUpdate(OigoOnboardingSourceProbeUpdate(
                generation: sourceGeneration,
                usedInput: .systemDefault,
                usedChannel: 0,
                acceptedCanonicalBuffer: true,
                signalHealth: .usable,
                meterLevel: 0.5
            ))
            guard let popup = findPopup(in: content, identifier: "oigo.onboarding.language") else { throw ProbeError.missingControl }
            try sendClick(in: content, identifier: fixture.controls.stageAction)
            try wait(until: { factory.assetRequestLocales.count == 1 })
            popup.selectItem(at: 1)
            popup.sendAction(popup.action, to: popup.target)
            guard findButton(in: content, identifier: fixture.controls.continue)?.isEnabled == false,
                  visibleText(in: content, identifier: "oigo.onboarding.status").contains("not verified") else {
                throw ProbeError.generationMismatch
            }
            try wait(until: { factory.assetCompletionCount == 1 })
            let continueEnabled = findButton(in: content, identifier: fixture.controls.continue)?.isEnabled
            let status = visibleText(in: content, identifier: "oigo.onboarding.status")
            guard continueEnabled == false,
                  status.contains("Speech assets: not verified"),
                  factory.settingsStore.load() == committed else {
                throw ProbeError.generationMismatch
            }
            controller.window?.close()
            print("PASS H105-01 active-readiness-locale-switch=observed stale-readiness=ignored persistence=unchanged")
            try writeCaseReceipt(
                name: "H105-01",
                setup: "production language controller with en-US committed and es-MX supported",
                trigger: "start the en-US readiness check, switch to es-MX while that check is active, then deliver the stale en-US result",
                expected: "readiness starts for en-US, locale switches to es-MX during the active check, and the stale result is rejected with Continue disabled",
                failure: "stale readiness cannot overwrite es-MX, commit the locale, enable Continue, or mutate any other setting"
            )
        }

        func runH10502() throws {
            let factory = try OnboardingShellContractFactory(defaultsSuite: "com.oigo.qa.task26")
            let controller = factory.makeController(
                initialStep: .language,
                loadSupportedLanguages: { ["en-US", "es-MX"] },
                checkSpeechAssets: { _ in
                    try? await Task.sleep(nanoseconds: 100_000_000)
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
            guard findButton(in: content, identifier: fixture.controls.continue)?.isEnabled == false else {
                throw ProbeError.generationMismatch
            }
            try wait(until: { factory.assetCompletionCount == 1 })
            let status = visibleText(in: content, identifier: "oigo.onboarding.status")
            guard findButton(in: content, identifier: fixture.controls.continue)?.isEnabled == false,
                  !status.contains("Speech assets: ready"),
                  factory.settingsStore.load() == committed else {
                throw ProbeError.generationMismatch
            }
            controller.window?.close()
            print("PASS H105-02 install-locale-switch=observed late-result=ignored persistence=unchanged")
            try writeCaseReceipt(
                name: "H105-02",
                setup: "production language controller with delayed en-US asset installation",
                trigger: "start installation, switch to es-MX while installing",
                expected: "the en-US result is rejected as stale and Continue remains disabled",
                failure: "no stale readiness and no settings mutation"
            )
        }

        func runH10503() throws {
            let factory = try OnboardingShellContractFactory(defaultsSuite: "com.oigo.qa.task26")
            let controller = factory.makeController(
                initialStep: .language,
                loadSupportedLanguages: { ["en-US", "es-MX"] },
                checkSpeechAssets: { _ in
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    return .ready
                }
            )
            let committed = factory.settingsStore.load()
            controller.showAndFocus()
            guard let content = controller.window?.contentView else { throw ProbeError.missingWindow }
            try wait(until: { self.findPopup(in: content, identifier: "oigo.onboarding.language")?.numberOfItems == 2 })
            try sendClick(in: content, identifier: fixture.controls.stageAction)
            try wait(until: { factory.assetRequestLocales.count == 1 })
            controller.window?.close()
            try wait(until: { factory.assetCompletionCount == 1 })
            guard controller.window?.isVisible == false,
                  factory.settingsStore.load() == committed else {
                throw ProbeError.generationMismatch
            }
            print("PASS H105-03 close-late-locale-result=ignored window=closed persistence=unchanged")
            try writeCaseReceipt(
                name: "H105-03",
                setup: "production language controller with delayed asset result",
                trigger: "start asset check, close before provider completion",
                expected: "late result is ignored after close and window remains closed",
                failure: "no stale success and committed settings unchanged"
            )
        }

        func assertStage(
            _ controller: OnboardingWindowController,
            window: NSWindow,
            key: String
        ) throws {
            guard let content = window.contentView,
                  let stage = fixture.stages[key],
                  visibleText(in: content, identifier: "oigo.onboarding.title") == stage.title,
                  visibleText(in: content, identifier: "oigo.onboarding.body").hasPrefix(stage.body),
                  accessibilityLabel(in: content, identifier: "oigo.onboarding.title") == stage.title,
                  accessibilityLabel(in: content, identifier: "oigo.onboarding.body") != "",
                  accessibilityLabel(in: content, identifier: "oigo.onboarding.progress") != "",
                  let close = window.standardWindowButton(.closeButton),
                  close.accessibilityIdentifier() == fixture.controls.close,
                  close.accessibilityLabel() == "Close",
                  let back = findButton(in: content, identifier: fixture.controls.back),
                  let next = findButton(in: content, identifier: fixture.controls.continue),
                  next.accessibilityLabel() as? String == (key == "done" ? "Finish setup" : "Continue") else {
                throw ProbeError.stageSemanticsMismatch
            }
            guard back.accessibilityLabel() as? String == "Back",
                  !next.isHidden,
                  !close.isHidden else { throw ProbeError.missingControl }
            switch key {
            case "system":
                guard back.isHidden, next.isEnabled, next.keyEquivalent == "\r",
                      findButton(in: content, identifier: fixture.controls.stageAction)?.isHidden == true,
                      findField(in: content, identifier: fixture.controls.testField)?.isHidden == true else {
                    throw ProbeError.stageSemanticsMismatch
                }
                try assertFocus(window, target: next)
            case "language":
                guard !back.isHidden,
                      back.isEnabled,
                      !next.isEnabled,
                      let popup = findPopup(in: content, identifier: "oigo.onboarding.language"),
                      popup.accessibilityLabel() as? String == "Transcription language",
                      popup.titleOfSelectedItem?.isEmpty == false,
                      findButton(in: content, identifier: fixture.controls.stageAction)?.title == "Check speech assets" else {
                    throw ProbeError.stageSemanticsMismatch
                }
                try assertFocus(window, target: popup)
            case "shortcut":
                guard !back.isHidden,
                      back.isEnabled,
                      next.isEnabled,
                      let recorder = findRecorder(in: content),
                      recorder.accessibilityLabel() == "Dictation shortcut",
                      recorder.accessibilityValue() as? String != "",
                      findButton(in: content, identifier: fixture.controls.copyOnly)?.isHidden == true else {
                    throw ProbeError.stageSemanticsMismatch
                }
                try assertFocus(window, target: recorder)
            case "tryIt":
                guard !back.isHidden,
                      back.isEnabled,
                      !next.isEnabled,
                      let field = findField(in: content, identifier: fixture.controls.testField),
                      field.accessibilityLabel() as? String == "Dictation test field",
                      field.isEditable,
                      findButton(in: content, identifier: fixture.controls.stageAction)?.isEnabled == true else {
                    throw ProbeError.stageSemanticsMismatch
                }
                try assertFocus(window, target: field)
            case "done":
                guard !back.isHidden, back.isEnabled, next.isEnabled else {
                    throw ProbeError.stageSemanticsMismatch
                }
                try assertFocus(window, target: next)
            default:
                throw ProbeError.stageSemanticsMismatch
            }
        }

        func assertFocus(_ window: NSWindow, target: NSView) throws {
            if let field = target as? NSTextField {
                guard window.firstResponder === field || field.currentEditor() === window.firstResponder else {
                    throw ProbeError.focusMismatch
                }
                return
            }
            guard window.firstResponder === target else {
                throw ProbeError.focusMismatch
            }
        }

        func accessibilityLabel(in root: NSView, identifier: String) -> String {
            (allViews(root).first { $0.accessibilityIdentifier() == identifier }?.accessibilityLabel() as? String) ?? ""
        }

        func sameObservation(_ lhs: Task8ControlObservation, _ rhs: Task8ControlObservation) -> Bool {
            lhs.status == rhs.status
                && lhs.hint == rhs.hint
                && lhs.recorderDisplay == rhs.recorderDisplay
                && lhs.recorderAccessibilityValue == rhs.recorderAccessibilityValue
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

        func findRecorder(in root: NSView) -> ShortcutRecorderControl? {
            allViews(root).first { $0.accessibilityIdentifier() == fixture.controls.shortcut }
                as? ShortcutRecorderControl
        }

        func settingsOnlyChangedShortcut(
            from original: OigoSettings,
            to updated: OigoSettings,
            candidate: ToggleShortcut
        ) -> Bool {
            updated.globalShortcut == candidate
                && updated.localeIdentifier == original.localeIdentifier
                && updated.defaultMode == original.defaultMode
                && updated.showVolatilePreview == original.showVolatilePreview
                && updated.audioRetention == original.audioRetention
                && updated.keepSuccessfulAudioIndefinitely == original.keepSuccessfulAudioIndefinitely
                && updated.launchAtLogin == original.launchAtLogin
                && updated.selectedInput == original.selectedInput
                && updated.selectedInputChannel == original.selectedInputChannel
        }

        func writeCaseReceipt(
            name: String,
            setup: String,
            trigger: String,
            expected: String,
            failure: String
        ) throws {
            let receipt: [String: Any] = [
                "scenario": "onboarding-states",
                "case": name,
                "productionController": true,
                "setup": setup,
                "trigger": trigger,
                "expected": expected,
                "failureAssertion": failure,
                "result": "PASS"
            ]
            let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
            try data.write(
                to: evidenceRoot.appendingPathComponent(name.lowercased() + ".json"),
                options: .atomic
            )
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
        case stageSemanticsMismatch, candidatePersistenceMismatch, staleCompletionMutation
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
