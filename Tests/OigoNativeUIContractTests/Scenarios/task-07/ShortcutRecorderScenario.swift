import AppKit
import OigoCore
import OigoHotKey

final class ShortcutRecorderScenario: NativeUIContractScenario {
    override class var scenarioName: String {
        "shortcut-recorder"
    }

    override class func run(arguments: ContractArguments) throws {
        guard arguments.defaultsSuite == "com.oigo.qa.task07" else {
            throw ContractInputError(category: "invalid-defaults-suite")
        }

        try MainActor.assumeIsolated {
            try runShortcutRepair()
            try runRecordingLifecycle()
            try runRegistrationFailures()
            try ShortcutStatusRefreshContract.run(evidenceRoot: arguments.evidenceRoot)
            try assertNestedEvidenceRootIsCreated(arguments: arguments)
            let selected = arguments.fixtureRoot.lastPathComponent
            guard ["task-07", "success", "failure"].contains(selected) else {
                throw ContractInputError(category: "unsupported-shortcut-fixture")
            }
            if selected != "failure" {
                try runSuccess()
            }
            if selected != "success" {
                try runFailureAndReuse()
            }
            print(
                "PASS shortcut-recorder focus=first-responder keyCode=0 capture-count=1 "
                    + "repeat=ignored modifiers=0xf00 cancel=preserved clear=default-committed "
                    + "focus-loss=preserved reuse=committed"
                    + " command=window-equivalent fn=captured suspension=restored errors=visible stale-events=ignored"
            )
        }
    }

    private static func assertNestedEvidenceRootIsCreated(arguments: ContractArguments) throws {
        let nestedEvidenceRoot = arguments.evidenceRoot
            .appendingPathComponent("shortcut-recorder-nested-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: nestedEvidenceRoot) }
        guard !FileManager.default.fileExists(atPath: nestedEvidenceRoot.path) else {
            throw ContractInputError(category: "stale-nested-evidence-root")
        }
        let nested = try ContractArguments.parse([
            "--scenario", scenarioName,
            "--defaults-suite", arguments.defaultsSuite,
            "--fixture-root", arguments.fixtureRoot.path,
            "--evidence-root", nestedEvidenceRoot.path
        ])
        var isDirectory = ObjCBool(false)
        let normalizedNestedEvidenceRoot = nestedEvidenceRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard nested.evidenceRoot.path == normalizedNestedEvidenceRoot.path,
              FileManager.default.fileExists(atPath: nestedEvidenceRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ContractInputError(category: "nested-evidence-root-not-created")
        }
    }

    @MainActor
    private static func runRegistrationFailures() throws {
        let denied = CarbonGlobalShortcutRegistrar(backend: CarbonGlobalShortcutBackend(
            functionKeyBackend: FunctionKeyShortcutBackend(accessibilityTrusted: { false })
        ))
        let owner = AppShortcutRegistrationController(committedShortcut: .default, registrar: denied, onRegisteredEvent: { _ in })
        var persisted = false
        let result = owner.save(.fn, persist: { _ in persisted = true }, restore: {})
        guard !result.isAvailable, !persisted, owner.committedShortcut == .default,
              owner.lastError?.contains("Accessibility") == true, !owner.isOperationReady else {
            throw ContractInputError(category: "fn-permission-failure-was-not-transactional")
        }
        let fn = try JSONDecoder().decode(ToggleShortcut.self, from: JSONEncoder().encode(ToggleShortcut.fn))
        guard fn == .fn, fn.copy.displayName == "Fn",
              !OigoShortcutValidator.validate(fn, occupied: [.fn]).isAvailable,
              !OigoShortcutValidator.validate(ToggleShortcut(keyCode: 61, modifiers: 0), occupied: []).isAvailable else {
            throw ContractInputError(category: "fn-roundtrip-or-validation-failed")
        }

        let harness = makeHarness()
        let backend = RecorderRegistrationBackend()
        let registrar = CarbonGlobalShortcutRegistrar(backend: backend)
        let controller = AppShortcutRegistrationController(committedShortcut: .default, registrar: registrar, onRegisteredEvent: { _ in })
        try controller.synchronize(storageReady: true, onboardingComplete: true)
        harness.recorder.onRecordingChange = { try controller.setRecording($0) }
        harness.recorder.beginRecording()
        backend.failRegistration = true
        harness.recorder.cancelRecording()
        guard !controller.isOperationReady, !harness.recorder.isRecording,
              harness.recorder.validationError != nil, controller.lastError != nil else {
            throw ContractInputError(category: "restoration-failure-was-hidden")
        }
        backend.failRegistration = false
        try controller.synchronize(storageReady: true, onboardingComplete: true)
        backend.failUnregistration = true
        harness.recorder.beginRecording()
        guard !harness.recorder.isRecording, !controller.isOperationReady,
              harness.recorder.validationError != nil else {
            throw ContractInputError(category: "capture-started-after-unregister-failure")
        }
        backend.failUnregistration = false
        try controller.shutdown()
        try registrar.unregister()
    }

    @MainActor
    private static func runRecordingLifecycle() throws {
        let harness = makeHarness()
        let backend = RecorderRegistrationBackend()
        let registrar = CarbonGlobalShortcutRegistrar(backend: backend)
        var operations = 0
        let owner = AppShortcutRegistrationController(
            committedShortcut: .default, registrar: registrar, onRegisteredEvent: { _ in operations += 1 }
        )
        try owner.synchronize(storageReady: true, onboardingComplete: true)
        harness.recorder.onRecordingChange = { try owner.setRecording($0) }
        for end in ["cancel", "focus", "window", "close", "detach"] {
            harness.window.contentView?.addSubview(harness.recorder)
            harness.recorder.beginRecording()
            harness.recorder.beginRecording()
            try owner.synchronize(storageReady: true, onboardingComplete: true)
            backend.emitAll()
            guard !registrar.status.isActive, !owner.isOperationReady, operations == 0 else {
                throw ContractInputError(category: "recording-did-not-suspend-registration")
            }
            switch end {
            case "cancel": harness.recorder.cancelRecording()
            case "focus": _ = harness.window.makeFirstResponder(nil)
            case "window": NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: harness.window)
            case "close": NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: harness.window)
            default: harness.recorder.removeFromSuperview()
            }
            guard !harness.recorder.isRecording, registrar.status.isActive, owner.isOperationReady else {
                throw ContractInputError(category: "recording-did-not-restore-" + end)
            }
        }
        harness.window.contentView?.addSubview(harness.recorder)
        harness.recorder.onCandidateChange = { candidate in
            let result = owner.save(candidate, persist: { shortcut in
                guard case .active(let registered, _) = registrar.status, registered == shortcut else {
                    throw ContractInputError(category: "persist-before-real-registration")
                }
                backend.emitAll()
            }, restore: {})
            if !result.isAvailable { operations += 100 }
        }
        harness.recorder.beginRecording()
        _ = harness.recorder.performKeyEquivalent(with: try keyEvent(keyCode: 12, modifiers: [.command], isARepeat: false))
        guard owner.committedShortcut == harness.recorder.shortcut,
              owner.isOperationReady, operations == 0 else {
            throw ContractInputError(category: "capture-commit-triggered-operation-or-failed")
        }
        backend.emitAll()
        guard operations == 1 else {
            throw ContractInputError(category: "restored-shortcut-did-not-deliver-once")
        }
        let committed = owner.committedShortcut
        harness.recorder.beginRecording()
        let failedSave = owner.save(.fn, persist: { _ in
            backend.emitAll()
            throw ContractInputError(category: "simulated-persistence-failure")
        }, restore: {})
        guard !failedSave.isAvailable, owner.committedShortcut == committed,
              !owner.isOperationReady, operations == 1,
              case .active(let restored, _) = registrar.status, restored == committed else {
            throw ContractInputError(category: "recording-save-failure-did-not-roll-back")
        }
        harness.recorder.cancelRecording()
        guard owner.isOperationReady, owner.committedShortcut == committed else {
            throw ContractInputError(category: "recording-save-failure-did-not-resume")
        }
        try owner.shutdown()
    }

    @MainActor
    private static func runShortcutRepair() throws {
        let harness = makeHarness()
        var failures: [String] = []
        harness.recorder.beginRecording()
        let command = try keyEvent(keyCode: 12, modifiers: [.command], isARepeat: false)
        if !harness.window.performKeyEquivalent(with: command)
            || harness.recorder.shortcut != ToggleShortcut(keyCode: 12, modifiers: ToggleShortcutModifiers.command) {
            failures.append("command-equivalent-not-captured")
        }
        harness.recorder.cancelRecording()
        harness.recorder.beginRecording()
        let fn = NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: [.function], timestamp: 0,
            windowNumber: harness.window.windowNumber, context: nil, characters: "",
            charactersIgnoringModifiers: "", isARepeat: false, keyCode: 63
        )!
        harness.recorder.flagsChanged(with: fn)
        if harness.recorder.isRecording || harness.recorder.shortcut != ToggleShortcut(keyCode: 63, modifiers: 0) {
            failures.append("fn-flags-not-captured")
        }
        if !OigoShortcutValidator.validate(ToggleShortcut(keyCode: 63, modifiers: 0), occupied: []).isAvailable {
            failures.append("fn-not-valid")
        }
        if OigoShortcutValidator.validate(ToggleShortcut(keyCode: 63, modifiers: ToggleShortcutModifiers.command), occupied: []).isAvailable {
            failures.append("modified-fn-accepted")
        }
        harness.recorder.cancelRecording()
        guard failures.isEmpty else {
            throw ContractInputError(category: failures.joined(separator: ","))
        }
    }

    @MainActor
    private static func runSuccess() throws {
        let harness = makeHarness()
        let expected = ToggleShortcut(
            keyCode: 0,
            modifiers: ToggleShortcutModifiers.command
                | ToggleShortcutModifiers.control
                | ToggleShortcutModifiers.option
                | ToggleShortcutModifiers.shift
        )

        guard harness.recorder.accessibilityPerformPress(),
              harness.recorder.isAccessibilityElement(),
              harness.window.firstResponder === harness.recorder,
              harness.recorder.isRecording,
              harness.recorder.accessibilityValue() as? String == "Press a shortcut" else {
            throw ContractInputError(category: "recorder-is-not-an-accessibility-element")
        }

        harness.recorder.keyDown(with: try keyEvent(
            keyCode: 0,
            modifiers: [.command, .control, .option, .shift],
            isARepeat: true
        ))
        guard harness.recorder.isRecording,
              harness.recorder.shortcut == ToggleShortcut.default,
              harness.target.invocationCount == 0 else {
            throw ContractInputError(category: "repeated-keydown-was-captured")
        }

        harness.recorder.keyDown(with: try keyEvent(
            keyCode: 0,
            modifiers: [.command, .control, .option, .shift],
            isARepeat: false
        ))
        guard !harness.recorder.isRecording,
              harness.recorder.shortcut == expected,
              harness.target.invocationCount == 1,
              harness.target.lastSender === harness.recorder,
              harness.recorder.accessibilityValue() as? String == "⇧⌃⌥⌘A" else {
            throw ContractInputError(category: "key-code-zero-capture-failed")
        }
    }

    @MainActor
    private static func runFailureAndReuse() throws {
        let harness = makeHarness()
        let committed = ToggleShortcut(keyCode: 13, modifiers: ToggleShortcutModifiers.command)
        harness.recorder.restoreCandidate(committed)

        harness.recorder.beginRecording()
        harness.recorder.keyDown(with: try keyEvent(keyCode: 12, modifiers: [], isARepeat: false))
        guard harness.recorder.isRecording,
              harness.recorder.shortcut == committed,
              harness.target.invocationCount == 0,
              harness.recorder.validationError?.contains("modifier") == true else {
            throw ContractInputError(category: "modifier-free-key-was-accepted")
        }

        harness.recorder.keyDown(with: try keyEvent(keyCode: 12, modifiers: [.capsLock], isARepeat: false))
        guard harness.recorder.isRecording,
              harness.recorder.shortcut == committed,
              harness.target.invocationCount == 0,
              harness.recorder.validationError?.contains("supported") == true else {
            throw ContractInputError(category: "unsupported-modifier-was-accepted")
        }

        harness.recorder.cancelOperation(nil)
        guard !harness.recorder.isRecording,
              harness.recorder.shortcut == committed,
              harness.target.invocationCount == 0 else {
            throw ContractInputError(category: "cancel-operation-mutated-committed-shortcut")
        }

        harness.recorder.beginRecording()
        harness.recorder.keyDown(with: try keyEvent(keyCode: 53, modifiers: [], isARepeat: false))
        guard !harness.recorder.isRecording,
              harness.recorder.shortcut == committed,
              harness.target.invocationCount == 0 else {
            throw ContractInputError(category: "escape-mutated-committed-shortcut")
        }

        harness.recorder.beginRecording()
        guard harness.recorder.resignFirstResponder() else {
            throw ContractInputError(category: "focus-loss-not-delivered")
        }
        guard !harness.recorder.isRecording,
              harness.recorder.shortcut == committed,
              harness.target.invocationCount == 0 else {
            throw ContractInputError(category: "focus-loss-left-stale-recorder")
        }

        let reuse = ToggleShortcut(keyCode: 12, modifiers: ToggleShortcutModifiers.command)
        harness.recorder.beginRecording()
        harness.recorder.keyDown(with: try keyEvent(keyCode: 12, modifiers: [.command], isARepeat: false))
        guard !harness.recorder.isRecording,
              harness.recorder.shortcut == reuse,
              harness.target.invocationCount == 1,
              harness.target.lastSender === harness.recorder else {
            throw ContractInputError(category: "post-cancel-reuse-failed")
        }

        try runClearTransaction()
    }

    @MainActor
    private static func runClearTransaction() throws {
        let harness = makeHarness()
        let custom = ToggleShortcut(keyCode: 13, modifiers: ToggleShortcutModifiers.command)
        let registrar = ScenarioRegistrar(active: custom)
        let transaction = ShortcutConfigurationTransaction(
            committedShortcut: custom,
            registrar: registrar,
            onEvent: { _ in }
        )
        var persisted = custom
        harness.recorder.restoreCandidate(custom)
        harness.recorder.onCandidateChange = { transaction.setCandidate($0) }

        harness.recorder.beginRecording()
        harness.recorder.clearShortcut()
        guard !harness.recorder.isRecording,
              harness.recorder.shortcut == .default,
              transaction.candidateShortcut == .default,
              harness.target.invocationCount == 1,
              harness.target.lastSender === harness.recorder else {
            throw ContractInputError(category: "clear-did-not-remove-custom-candidate")
        }

        guard transaction.clear(
            persist: { persisted = $0 },
            restore: { persisted = custom }
        ).isAvailable,
              transaction.committedShortcut == .default,
              transaction.candidateShortcut == .default,
              persisted == .default,
              registrar.status == .active(.default, generation: 2) else {
            throw ContractInputError(category: "clear-did-not-commit-canonical-default")
        }
    }

    @MainActor
    private static func makeHarness() -> Harness {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 44),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let recorder = ShortcutRecorderControl(shortcut: .default)
        recorder.frame = NSRect(x: 0, y: 0, width: 280, height: 44)
        let target = RecorderActionTarget()
        recorder.target = target
        recorder.action = #selector(RecorderActionTarget.capture(_:))
        window.contentView?.addSubview(recorder)
        return Harness(
            window: window,
            recorder: recorder,
            target: target
        )
    }

    @MainActor
    private static func keyEvent(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        isARepeat: Bool
    ) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "x",
            charactersIgnoringModifiers: "x",
            isARepeat: isARepeat,
            keyCode: keyCode
        ) else {
            throw ContractInputError(category: "key-event-construction-failed")
        }
        return event
    }

    @MainActor
    private struct Harness {
        let window: NSWindow
        let recorder: ShortcutRecorderControl
        let target: RecorderActionTarget
    }
}

private enum ShortcutStatusRefreshContract {
    static func run(evidenceRoot: URL) throws {
        let root = evidenceRoot.appendingPathComponent("shortcut-status-runtime")
        let fixtureHome = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: fixtureHome, withIntermediateDirectories: true)
        let driverURL = root.appendingPathComponent("main.swift")
        try driver.write(to: driverURL, atomically: true, encoding: .utf8)
        let executable = root.appendingPathComponent("shortcut-status-contract")
        let buildRoot = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        let dependencies = ["OigoCore", "OigoHotKey", "MacUtilityUI"]
        let usesAggregateObjects = FileManager.default.fileExists(atPath: buildRoot.appendingPathComponent("OigoCore.o").path)
        let modules = usesAggregateObjects ? buildRoot : buildRoot.appendingPathComponent("Modules")
        let objects = try dependencies.flatMap { dependency -> [String] in
            if usesAggregateObjects { return [buildRoot.appendingPathComponent(dependency + ".o").path] }
            return try FileManager.default.contentsOfDirectory(
                at: buildRoot.appendingPathComponent(dependency + ".build"), includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "o" }.map(\.path)
        }
        let sources = ["OigoUtilityWindow", "SettingsWindowController", "OnboardingWindowController", "OnboardingShellLayout", "OnboardingShellMetrics"]
            .map { "Sources/Oigo/" + $0 + ".swift" }
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compile.arguments = ["swiftc", "-target", "arm64-apple-macosx26.0", "-I", modules.path]
            + sources + [driverURL.path] + objects + ["-o", executable.path]
        try compile.run()
        compile.waitUntilExit()
        guard compile.terminationStatus == 0 else { throw ContractInputError(category: "shortcut-status-build-failed") }
        let process = Process()
        process.executableURL = executable
        var environment = ProcessInfo.processInfo.environment
        environment["CFFIXED_USER_HOME"] = fixtureHome.path
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ContractInputError(category: "shortcut-status-runtime-failed") }
    }

    private static let driver = #"""
    import AppKit
    import OigoCore
    import OigoHotKey

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    @MainActor
    final class Registration {
        var saved: ToggleShortcut
        var recording = false
        var failEnd = false
        var error: String?
        init(_ shortcut: ToggleShortcut) { saved = shortcut }
        var status: GlobalShortcutRegistrationStatus {
            if recording { return .inactive("Global shortcut is suspended while recording a shortcut") }
            if let error { return .inactive(error) }
            return .active(saved, generation: 1)
        }
        func record(_ recording: Bool) throws {
            self.recording = recording
            if !recording, failEnd {
                error = "simulated restoration failure"
                throw Failure(description: error!)
            }
        }
        func save(_ shortcut: ToggleShortcut) -> OigoShortcutValidation {
            saved = shortcut
            return .available
        }
    }

    @MainActor
    struct Driver {
        static let candidate = ToggleShortcut(keyCode: 15, modifiers: ToggleShortcutModifiers.command | ToggleShortcutModifiers.option)
        static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        static func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw Failure(description: message) }
        }
        static func exercise(_ controller: NSWindowController, registration: Registration, expected: String) throws {
            let all = views(controller.window!.contentView!)
            let recorder = all.compactMap { $0 as? ShortcutRecorderControl }.first!
            recorder.beginRecording()
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0, windowNumber: controller.window!.windowNumber, context: nil, characters: "r", charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15)!
            try require(controller.window!.performKeyEquivalent(with: event), "CmdOptionR was not consumed")
            try require(recorder.shortcut == candidate && !recorder.isRecording, "CmdOptionR was not captured")
            let labels = all.compactMap { ($0 as? NSTextField)?.stringValue }
            try require(!labels.contains { $0.contains("suspended while recording") }, "stale suspended registration label")
            try require(labels.contains { $0.contains(expected) }, "missing refreshed registration label: " + expected)
            registration.failEnd = true
            recorder.beginRecording()
            recorder.cancelRecording()
            let failures = all.compactMap { ($0 as? NSTextField)?.stringValue }
            try require(failures.contains { $0.contains("simulated restoration failure") }, "restoration failure was hidden")
        }
        static func main() {
            do {
                _ = NSApplication.shared
                NSApp.setActivationPolicy(.prohibited)
                UserDefaults.standard.register(defaults: ["oigo.settings.selected-pane": "general"])
                let settingsState = Registration(.fn)
                let settings = SettingsWindowController(
                    settings: OigoSettings(globalShortcut: .fn), inputDevices: [], supportedLocales: ["en-US"],
                    loadSupportedLocales: { ["en-US"] }, microphoneState: .granted, accessibilityState: .granted,
                    storageHealth: .checking, launchAtLoginStatus: .disabled, launchAtLoginStatusProvider: { .disabled },
                    openLoginItemsSettings: {}, registrationStatus: { settingsState.status }, registrationError: { settingsState.error },
                    setShortcutRecording: { try settingsState.record($0) }, validateShortcut: { _ in .available },
                    saveShortcut: { settingsState.save($0) }, save: { _ in nil }, checkSpeechAssets: { _ in .ready },
                    refreshPermissions: { (.granted, .granted) }, openMicrophoneSettings: {}, openAccessibilitySettings: {},
                    rerunOnboarding: {}, openHistory: {}, openDataFolder: {}, retryStorage: {}, deleteAllHistory: {},
                    exportDiagnostics: { Data() }, dictionaryDocument: DictionaryDocument(entries: []), saveDictionary: { _ in nil },
                    previewDictionary: { $0 }, addStarterTerms: { (DictionaryDocument(entries: []), nil) }, isPresented: { true }, onClose: {}
                )
                try exercise(settings, registration: settingsState, expected: candidate.copy.activeStatus)
                let onboardingState = Registration(candidate)
                let onboarding = OnboardingWindowController(
                    support: OigoSystemSupportResult(isSupported: true, reason: ""), initialStep: .shortcut,
                    processingMode: .instant, globalShortcut: candidate, inputDevices: [], selectedInput: .systemDefault,
                    selectedInputChannel: 0, committedLocaleIdentifier: "en-US", microphoneState: .granted,
                    accessibilityState: .granted, storageHealth: .checking, loadSupportedLanguages: { ["en-US"] },
                    checkSpeechAssets: { _ in .ready }, saveLanguage: { _ in }, saveStep: { _, _ in },
                    saveInputSelection: { _, _ in }, requestMicrophone: { .granted }, openMicrophoneSettings: {},
                    registrationStatus: { onboardingState.status }, registrationError: { onboardingState.error },
                    setShortcutRecording: { try onboardingState.record($0) }, validateShortcut: { _ in .available },
                    saveShortcut: { onboardingState.save($0) }, requestAccessibility: { .granted }, openAccessibilitySettings: {},
                    retryStorage: {}, openDataLocation: {}, startSourceProbe: { _, _, _ in }, stopSourceProbe: {},
                    startTest: { _ in }, stopTest: {}, cancelTest: {}, openHistory: {}, onComplete: {}, onClose: {}
                )
                try exercise(onboarding, registration: onboardingState, expected: candidate.copy.registeredStatus)
                print("PASS shortcut-status production-controllers=true CmdOptionR=active stale-suspension=cleared restoration-error=preserved")
            } catch {
                print("FAIL shortcut-status: \(error)")
                exit(1)
            }
        }
    }
    MainActor.assumeIsolated { Driver.main() }
    """#
}

@MainActor
private final class RecorderRegistrationBackend: GlobalShortcutRegistrationBackend {
    private final class Handle: GlobalShortcutRegistrationHandle {}
    private var receivers: [(UInt64, @MainActor (GlobalShortcutEvent) -> Void)] = []
    var failRegistration = false
    var failUnregistration = false

    func register(shortcut: ToggleShortcut, generation: UInt64, receive: @escaping @MainActor (GlobalShortcutEvent) -> Void) throws -> any GlobalShortcutRegistrationHandle {
        if failRegistration { throw GlobalShortcutRegistrationError.registerHotKey(-1) }
        receivers.append((generation, receive))
        receive(GlobalShortcutEvent(edge: .pressed, generation: generation))
        return Handle()
    }

    func unregister(_ handle: any GlobalShortcutRegistrationHandle) throws {
        if failUnregistration { throw GlobalShortcutRegistrationError.unregisterHotKey(-1) }
    }

    func emitAll() {
        for (generation, receive) in receivers {
            receive(GlobalShortcutEvent(edge: .pressed, generation: generation))
        }
    }
}

@MainActor
private final class RecorderActionTarget: NSObject {
    private(set) var invocationCount = 0
    private(set) weak var lastSender: AnyObject?

    @objc func capture(_ sender: Any?) {
        invocationCount += 1
        lastSender = sender as AnyObject?
    }
}
