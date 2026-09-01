import AppKit
import Foundation

final class CrossSurfaceScenario: NativeUIContractScenario {
    private struct Fixture: Codable {
        let scenario: String
        let fixture: String
        let committedShortcutKeyCode: Int
        let committedShortcutModifiers: String
        let flow: String
        let expectedRoutes: [String]
    }

    override class var scenarioName: String { "cross-surface" }

    override class func run(arguments: ContractArguments) throws {
        guard arguments.defaultsSuite == "com.oigo.qa.task31" else {
            throw ContractInputError(category: "invalid-defaults-suite")
        }
        let fixture = try loadFixture(from: arguments.fixtureRoot)
        try validate(fixture)
        let repositoryRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        try validateProductionRouteBoundary(repositoryRoot, expectedRoutes: fixture.expectedRoutes)
        let output = try runCompiledContract(
            fixture: fixture,
            evidenceRoot: arguments.evidenceRoot,
            appearance: arguments.appearance,
            contrast: arguments.contrast,
            repositoryRoot: repositoryRoot
        )
        guard output.contains("PASS cross-surface"),
              output.contains("PASS cross-surface-failure") else {
            throw ContractInputError(category: "unexpected-cross-surface-output")
        }
        print(output, terminator: "")
    }

    private static func loadFixture(from root: URL) throws -> Fixture {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("fixture.json")),
              let fixture = try? JSONDecoder().decode(Fixture.self, from: data) else {
            throw ContractInputError(category: "malformed-cross-surface")
        }
        return fixture
    }

    private static func validate(_ fixture: Fixture) throws {
        let expectedRoutes = [
            "start-dictation", "stop-dictation", "retry-storage", "retry-transcription",
            "choose-input", "install-assets", "open-settings", "open-system-settings",
            "set-mode-instant", "set-mode-clean", "open-data-location", "copy", "paste-again",
            "open-history", "quit"
        ]
        guard fixture.scenario == scenarioName,
              ["cross-surface", "cross-surface-success", "cross-surface-failure"].contains(fixture.fixture),
              fixture.committedShortcutKeyCode == 0,
              fixture.committedShortcutModifiers == "command",
              ["happy", "failure"].contains(fixture.flow),
              fixture.expectedRoutes == expectedRoutes else {
            throw ContractInputError(category: "cross-surface-fixture-mismatch")
        }
    }

    private static func validateProductionRouteBoundary(
        _ repositoryRoot: URL,
        expectedRoutes: [String]
    ) throws {
        let delegateURL = repositoryRoot.appendingPathComponent("Sources/Oigo/OigoAppDelegate.swift")
        let delegate = try String(contentsOf: delegateURL, encoding: .utf8)
        let routeStart = delegate.range(of: "private func performPopoverAction")?.lowerBound
        let routeEnd = routeStart.flatMap { start in
            delegate.range(of: "\n    private func ", range: start..<delegate.endIndex)?.lowerBound
        } ?? delegate.endIndex
        guard let routeStart else {
            throw ContractInputError(category: "missing-production-command-router")
        }
        let route = String(delegate[routeStart..<routeEnd])
        let routeTokens = [
            ".startDictation", ".stopDictation", ".retryStorage", ".retryTranscription",
            ".chooseInput", ".installAssets", ".openSettings", ".openSystemSettings",
            "case .setMode(.instant)", "case .setMode(.clean)", ".openDataLocation", ".copy",
            ".pasteAgain", ".openHistory", ".quit"
        ]
        guard route.contains("switch action"),
              delegate.contains("presentationPublicationFence.publish(snapshot.publication)"),
              delegate.contains("statusSurface.publish(publication.state"),
              delegate.contains("settingsWindow?.setAppliesToNextDictation"),
              delegate.contains("historyWindow?.setCommandAvailability"),
              delegate.contains("onboardingWindow?.setCommandAvailability") else {
            throw ContractInputError(category: "missing-single-publication-fanout")
        }
        guard routeTokens.allSatisfy(route.contains), expectedRoutes.count == routeTokens.count else {
            throw ContractInputError(category: "incomplete-production-command-router")
        }

        let requiredSurfaces = [
            ("Sources/Oigo/StatusSurfaceController.swift", ["handlePopoverCommand", "presentationGeneration"]),
            ("Sources/Oigo/OnboardingWindowController.swift", ["oigo.onboarding.close", "windowWillClose"]),
            ("Sources/Oigo/SettingsWindowController.swift", ["oigo.settings.content", "windowWillClose"]),
            ("Sources/Oigo/HistoryWindowController.swift", ["oigo.history.content", "windowWillClose"])
        ]
        for (relativePath, tokens) in requiredSurfaces {
            let source = try String(
                contentsOf: repositoryRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            guard tokens.allSatisfy(source.contains) else {
                throw ContractInputError(category: "missing-production-surface-seam")
            }
        }
    }

    private static func runCompiledContract(
        fixture: Fixture,
        evidenceRoot: URL,
        appearance: String,
        contrast: String,
        repositoryRoot: URL
    ) throws -> String {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-native-ui-task31." + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let payload = scratch.appendingPathComponent("fixture.json")
        let driver = scratch.appendingPathComponent("main.swift")
        let executable = scratch.appendingPathComponent("cross-surface-contract")
        try JSONEncoder().encode(fixture).write(to: payload, options: .atomic)
        try contractDriver.write(to: driver, atomically: true, encoding: .utf8)

        let sourceFiles = [
            "Sources/Oigo/UI/HUD/AccessibilityHUDGeometryCapture.swift",
            "Sources/Oigo/UI/HUD/HUDTargetGeometry.swift",
            "Sources/Oigo/UI/HUD/HUDTargetGeometrySession.swift",
            "Sources/Oigo/UI/HUD/OigoHUDController.swift",
            "Sources/Oigo/UI/HUD/OigoHUDLifecycle.swift",
            "Sources/Oigo/UI/HUD/OigoHUDPolicy.swift",
            "Sources/Oigo/UI/HUD/OigoHUDState.swift",
            "Sources/Oigo/UI/Presentation/OigoPresentationInputs.swift",
            "Sources/Oigo/UI/Presentation/OigoPresentationState.swift",
            "Sources/Oigo/UI/Presentation/OigoPresentationProjection.swift",
            "Sources/Oigo/UI/Presentation/OigoPresentationAttributes.swift",
            "Sources/Oigo/UI/Presentation/OigoPresentationPublication.swift",
            "Sources/Oigo/UI/Presentation/OigoPopoverCommand.swift",
            "Sources/Oigo/UI/Presentation/OigoPopoverPresentation.swift",
            "Sources/Oigo/UI/Presentation/OigoPopoverViewController.swift",
            "Sources/Oigo/StatusSurfaceController.swift",
            "Sources/Oigo/OigoUtilityWindow.swift",
            "Sources/Oigo/Task8ControlObservation.swift",
            "Sources/Oigo/OnboardingShellMetrics.swift",
            "Sources/Oigo/OnboardingShellLayout.swift",
            "Sources/Oigo/OnboardingWindowController.swift",
            "Sources/Oigo/SettingsWindowController.swift",
            "Sources/Oigo/HistoryWindowController.swift"
        ].map { repositoryRoot.appendingPathComponent($0).path }
        let modules = repositoryRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/Modules").path
        _ = try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["swiftc", "-I", modules] + sourceFiles + [
                driver.path,
                "-framework", "AppKit",
                "-framework", "ApplicationServices",
                "-framework", "CoreGraphics",
                "-o", executable.path
            ] + dependencyObjects(repositoryRoot)
        )
        let data = try runProcess(
            executable: executable,
            arguments: [payload.path, evidenceRoot.path, appearance, contrast]
        )
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func dependencyObjects(_ repositoryRoot: URL) -> [String] {
        ["MacUtilityUI.build", "OigoCore.build", "OigoHotKey.build"].flatMap { directory in
            let root = repositoryRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/" + directory)
            return (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "o" }
                .map(\.path) ?? []
        }
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
                category: "cross-surface-build-failed:exit=\(process.terminationStatus):"
                    + (error + standardOutput).prefix(2000)
            )
        }
        return output
    }

    private static let contractDriver = #"""
    import AppKit
    import Foundation
    import OigoCore
    import OigoPresentation

    struct Fixture: Decodable {
        let fixture: String
        let committedShortcutKeyCode: Int
        let committedShortcutModifiers: String
        let flow: String
    }

    enum DriverError: Error { case assertion(String) }

    @MainActor
    final class Driver {
        final class CallbackState {
            var onboardingComplete = 0
            var onboardingClose = 0
            var settingsClose = 0
            var historyClose = 0
            var historyCommands = 0
            var settingsCommands = 0
            var onboardingCommands = 0
            var commandOrder: [String] = []
            var routeCallbacks: [String: Int] = [:]

            func record(_ route: String) {
                commandOrder.append(route)
            }

            func invoke(_ route: String) {
                record(route)
                routeCallbacks[route, default: 0] += 1
            }
        }

        let fixture: Fixture
        let evidenceRoot: URL
        let appearanceName: String
        let contrast: String
        var commandCount = 0
        var commands: [String] = []
        let callbacks = CallbackState()
        var historyFixtureRoot: URL?

        init(fixture: Fixture, evidenceRoot: URL, appearanceName: String, contrast: String) {
            self.fixture = fixture
            self.evidenceRoot = evidenceRoot
            self.appearanceName = appearanceName
            self.contrast = contrast
        }

        func makeOnboarding(shortcut: ToggleShortcut) -> OnboardingWindowController {
            OnboardingWindowController(
                support: .init(isSupported: true, reason: "supported"),
                initialStep: .system,
                processingMode: .clean,
                globalShortcut: shortcut,
                inputDevices: [],
                selectedInput: .systemDefault,
                selectedInputChannel: 0,
                committedLocaleIdentifier: "en-US",
                microphoneState: .granted,
                accessibilityState: .granted,
                storageHealth: .ready(.init(
                    recoveredSessionCount: 0,
                    historyEntryCount: 0,
                    malformedSessionCount: 0
                )),
                loadSupportedLanguages: { [weak callbacks] in
                    _ = callbacks
                    return ["en-US"]
                },
                checkSpeechAssets: { _ in .ready },
                saveLanguage: { [callbacks] _ in callbacks.onboardingCommands += 1 },
                saveStep: { [callbacks] _, _ in
                    callbacks.onboardingCommands += 1
                    callbacks.invoke("onboarding")
                },
                saveInputSelection: { [callbacks] _, _ in callbacks.onboardingCommands += 1 },
                requestMicrophone: { .granted },
                openMicrophoneSettings: { [callbacks] in callbacks.onboardingCommands += 1 },
                registrationStatus: { .inactive("setup") },
                registrationError: { nil },
                validateShortcut: { _ in .available },
                saveShortcut: { _ in .available },
                requestAccessibility: { .granted },
                openAccessibilitySettings: { [callbacks] in callbacks.onboardingCommands += 1 },
                retryStorage: { [callbacks] in callbacks.onboardingCommands += 1 },
                openDataLocation: { [callbacks] in callbacks.onboardingCommands += 1 },
                startSourceProbe: { [callbacks] _, _, _ in callbacks.onboardingCommands += 1 },
                stopSourceProbe: { [callbacks] in callbacks.onboardingCommands += 1 },
                startTest: { [callbacks] _ in callbacks.onboardingCommands += 1 },
                stopTest: { [callbacks] in callbacks.onboardingCommands += 1 },
                cancelTest: { [callbacks] in callbacks.onboardingCommands += 1 },
                openHistory: { [callbacks] in callbacks.onboardingCommands += 1 },
                onComplete: { [callbacks] in callbacks.onboardingComplete += 1 },
                onClose: { [callbacks] in callbacks.onboardingClose += 1 }
            )
        }

        func makeSettings(shortcut: ToggleShortcut) -> SettingsWindowController {
            SettingsWindowController(
                settings: .default.with(globalShortcut: shortcut, localeIdentifier: "en-US"),
                inputDevices: [],
                supportedLocales: ["en-US"],
                loadSupportedLocales: { [callbacks] in callbacks.settingsCommands += 1; return ["en-US"] },
                microphoneState: .granted,
                accessibilityState: .granted,
                storageHealth: .ready(.init(
                    recoveredSessionCount: 0,
                    historyEntryCount: 0,
                    malformedSessionCount: 0
                )),
                launchAtLoginStatus: .disabled,
                launchAtLoginStatusProvider: { .disabled },
                openLoginItemsSettings: { [callbacks] in callbacks.settingsCommands += 1 },
                registrationStatus: { .active(shortcut, generation: 1) },
                registrationError: { nil },
                validateShortcut: { _ in .available },
                saveShortcut: { _ in .available },
                save: { _ in nil },
                checkSpeechAssets: { _ in .ready },
                refreshPermissions: { [callbacks] in
                    callbacks.settingsCommands += 1
                    callbacks.invoke("settings")
                    return (.granted, .granted)
                },
                openMicrophoneSettings: { [callbacks] in callbacks.settingsCommands += 1 },
                openAccessibilitySettings: { [callbacks] in callbacks.settingsCommands += 1 },
                rerunOnboarding: { [callbacks] in callbacks.settingsCommands += 1 },
                openHistory: { [callbacks] in callbacks.settingsCommands += 1 },
                openDataFolder: { [callbacks] in callbacks.settingsCommands += 1 },
                retryStorage: { [callbacks] in callbacks.settingsCommands += 1 },
                deleteAllHistory: { [callbacks] in callbacks.settingsCommands += 1 },
                exportDiagnostics: { Data("cross-surface".utf8) },
                dictionaryDocument: .empty,
                saveDictionary: { _ in nil },
                previewDictionary: { $0 },
                addStarterTerms: { (.empty, nil) },
                isPresented: { true },
                onClose: { [callbacks] in callbacks.settingsClose += 1 }
            )
        }

        func makeHistory() -> HistoryWindowController {
            HistoryWindowController(
                loadTranscript: { _, _, completion in completion(.success("metadata")) },
                copyRawTranscript: { [callbacks] _ in callbacks.historyCommands += 1 },
                copyCleanTranscript: { [callbacks] _ in callbacks.historyCommands += 1 },
                pasteAgain: { [callbacks] _ in callbacks.historyCommands += 1 },
                pasteCleanAgain: { [callbacks] _ in
                    callbacks.historyCommands += 1
                    callbacks.invoke("paste-again")
                },
                cleanAgain: { [callbacks] _ in callbacks.historyCommands += 1 },
                reapplyDictionary: { [callbacks] _ in callbacks.historyCommands += 1 },
                playRecording: { [callbacks] _ in callbacks.historyCommands += 1 },
                retryTranscription: { [callbacks] _ in callbacks.historyCommands += 1 },
                revealRecording: { [callbacks] _ in callbacks.historyCommands += 1 },
                deleteSession: { [callbacks] _ in callbacks.historyCommands += 1 },
                runIdleMaintenance: { [callbacks] in callbacks.historyCommands += 1 },
                loadMore: { [callbacks] in callbacks.historyCommands += 1 },
                onClose: { [callbacks] in callbacks.historyClose += 1 }
            )
        }

        func makeHistoryEntry() throws -> SessionHistoryEntry {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("oigo-task31-history-" + UUID().uuidString)
            historyFixtureRoot = root
            let store = try SessionStore(rootDirectory: root)
            var session = try store.createSession(now: Date(timeIntervalSince1970: 1_700_000_000))
            session = try store.persistRawText("durable", for: session)
            session = try store.persistNormalizedText("durable", for: session)
            session = try store.persistCleanText("durable", for: session)
            session = try store.update(session, state: .completed)
            return SessionHistoryEntry(
                session: session,
                firstTranscriptLine: "Durable history entry",
                textSource: .processed
            )
        }

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw DriverError.assertion(message) }
        }

        func makeInputs(
            generation: UInt64,
            coordinatorState: OigoCoordinatorPresentationState,
            operation: OigoActiveOperationPresentationInput? = nil,
            terminal: OigoTerminalPresentationInput? = nil,
            accessibility: OigoPermissionPresentationStatus = .granted
        ) -> OigoPresentationInputs {
            let locale = OigoLocaleIdentifier("en-US")!
            let shortcut = ToggleShortcut(
                keyCode: UInt32(fixture.committedShortcutKeyCode),
                modifiers: ToggleShortcutModifiers.command
            )
            return OigoPresentationInputs(
                generation: generation,
                operationGate: .init(activeOperation: operation, busyReason: nil),
                coordinator: .init(state: coordinatorState, generation: generation),
                storage: .init(status: .ready),
                shortcut: .init(registration: .registered, isConfigured: true, shortcut: shortcut),
                permissions: .init(microphone: .granted, accessibility: accessibility),
                input: .init(selection: .systemDefault, channelIndex: 0),
                localeAssets: .init(localeIdentifier: locale, status: .ready, generation: generation),
                activeConfiguration: nil,
                nextConfiguration: .init(
                    localeIdentifier: locale,
                    input: .systemDefault,
                    channelIndex: 0,
                    appliesTo: .next,
                    mode: .clean
                ),
                terminal: terminal,
                latestSession: .init(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000031")!,
                    state: coordinatorState == .recording ? .recording : .complete,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    hasAudio: true,
                    hasTranscript: true,
                    failure: nil,
                    durationSeconds: 18,
                    source: .clean
                ),
                playback: .init(generation: generation, status: .idle),
                onboarding: .init(stage: .complete, status: .passed, failure: nil),
                shutdown: .init(status: .inactive, fencedOperationCount: 0),
                presentationDate: Date(timeIntervalSince1970: 1_700_000_120)
            )
        }

        func fanout(
            _ publication: OigoPresentationPublication,
            statusSurface: StatusSurfaceController,
            statusItem: NSStatusItem,
            onboarding: OnboardingWindowController,
            settings: SettingsWindowController,
            history: HistoryWindowController
        ) {
            let row = publication.state.row.rawValue
            callbacks.record("publication:" + row)
            if row == "recording" {
                callbacks.invoke("record")
            } else if row == "copied-only" {
                callbacks.invoke("terminal")
            }
            statusSurface.publish(publication.state, generation: publication.generation)
            statusSurface.publish(
                publication.state,
                inputs: publication.inputs,
                inputOptions: [],
                generation: publication.generation
            )
            settings.setAppliesToNextDictation(
                publication.adapters.settingsApplyToNextDictation
            )
            let availability = AppCommandAvailability.evaluate(
                coordinatorState: .idle,
                occupiedKind: nil,
                acceptingCommands: true,
                setupComplete: true,
                storageReady: true
            )
            history.setCommandAvailability(availability)
            onboarding.setCommandAvailability(availability)
            statusItem.button?.toolTip = publication.state.status.rawValue
        }

        func publish(
            _ publication: OigoPresentationPublication,
            fence: inout OigoPresentationGenerationFence,
            statusSurface: StatusSurfaceController,
            statusItem: NSStatusItem,
            onboarding: OnboardingWindowController,
            settings: SettingsWindowController,
            history: HistoryWindowController
        ) -> Bool {
            fence.publish(publication) { [self] accepted in
                fanout(
                    accepted,
                    statusSurface: statusSurface,
                    statusItem: statusItem,
                    onboarding: onboarding,
                    settings: settings,
                    history: history
                )
            }
        }

        func run() throws {
            defer {
                if let historyFixtureRoot {
                    try? FileManager.default.removeItem(at: historyFixtureRoot)
                }
            }
            let shortcut = ToggleShortcut(
                keyCode: UInt32(fixture.committedShortcutKeyCode),
                modifiers: ToggleShortcutModifiers.command
            )
            try assert(shortcut.copy.accessibilityLabel.contains("Command"), "committed shortcut copy")
            try assert(!shortcut.copy.holdHint.contains("⌥"), "receipt shortcut is dynamic")

            let readyInputs = makeInputs(generation: 10, coordinatorState: .idle)
            let readyPublication = OigoPresentationPublication(inputs: readyInputs)
            try assert(readyPublication.state.row == .storageReadyIdle, "ready projection")
            try assert(readyPublication.adapters.settingsApplyToNextDictation == false, "ready adapter")

            var fence = OigoPresentationGenerationFence()
            var published: [UInt64] = []
            try assert(fence.publish(readyPublication, to: { published.append($0.generation) }), "current publication")
            let staleInputs = makeInputs(generation: 9, coordinatorState: .recording)
            let staleAccepted = fence.publish(
                OigoPresentationPublication(inputs: staleInputs),
                to: { published.append($0.generation) }
            )
            try assert(!staleAccepted && published == [10], "stale publication preserved current content")
            var stalePublicationRejected = !staleAccepted
            fence.shutdown()
            try assert(!fence.publish(readyPublication, to: { published.append($0.generation) }), "shutdown fence")

            let popover = OigoPopoverViewController { [weak self] command in
                self?.commandCount += 1
                if case .presentation(let action) = command.intent {
                    self?.commands.append(action.category)
                    self?.callbacks.invoke("start")
                    self?.callbacks.record("popover:" + action.category)
                }
            }
            let readyPresentation = OigoPopoverPresentation.compose(
                state: readyPublication.state,
                inputs: readyInputs
            )
            popover.render(readyPresentation, generation: 10, inputOptions: [])
            popover.view.frame = NSRect(x: 0, y: 0, width: 340, height: max(1, popover.preferredContentSize.height))
            popover.view.layoutSubtreeIfNeeded()
            guard let start = descendant(identifier: OigoStatusMenuIdentity.startIdentifier, in: popover.view) as? NSButton else {
                throw DriverError.assertion("production popover start control")
            }
            start.performClick(nil)
            try assert(commandCount == 1 && commands == ["start-dictation"], "one popover command owner")
            try assert(start.accessibilityLabel() == "Start Oigo dictation", "popover accessibility route")

            let statusBar = NSStatusBar.system
            let statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
            let surface = StatusSurfaceController { [weak self] command in
                if case .popover(let popoverCommand) = command,
                   case .presentation(let action) = popoverCommand.intent {
                    self?.commands.append(action.category)
                }
            }
            surface.install(statusItem: statusItem)
            guard let button = statusItem.button else { throw DriverError.assertion("status button") }
            try assert(button.accessibilityIdentifier() == OigoStatusMenuIdentity.statusItemIdentifier, "status identity")
            let onboarding = makeOnboarding(shortcut: shortcut)
            let settings = makeSettings(shortcut: shortcut)
            let history = makeHistory()
            var surfaceFence = OigoPresentationGenerationFence()
            try assert(publish(
                readyPublication,
                fence: &surfaceFence,
                statusSurface: surface,
                statusItem: statusItem,
                onboarding: onboarding,
                settings: settings,
                history: history
            ), "ready surface publication")
            try assert((button.accessibilityValue() as? String) == "Ready", "status committed state")
            history.reload(entries: [try makeHistoryEntry()])
            callbacks.invoke("history")
            let historyTable = history.task29TableViewForTesting()
            historyTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            onboarding.showAndFocus()
            settings.showAndFocus()
            history.showAndFocus()
            let appliedAppearance = applyAppearance(to: [
                onboarding.window, settings.window, history.window
            ])
            try assert(
                contrast != "increased" || appliedAppearance.contains("AccessibilityHighContrast"),
                "increased contrast was applied"
            )
            try assert(
                contrast == "increased" || appliedAppearance.contains("Aqua"),
                "standard appearance was applied"
            )
            guard onboarding.window?.title == "Set Up Oigo",
                  settings.window?.identifier?.rawValue == "com.oigo.settings.window",
                  history.window?.identifier?.rawValue == "com.oigo.history.window" else {
                throw DriverError.assertion("production window adapters")
            }
            if let continueButton = descendant(
                identifier: "oigo.onboarding.continue",
                in: onboarding.window!.contentView!
            ) as? NSButton {
                continueButton.performClick(nil)
            }
            guard callbacks.onboardingCommands > 0 else {
                throw DriverError.assertion("onboarding command callback")
            }
            if let refresh = descendant(
                identifier: "oigo.settings.refresh-permissions",
                in: settings.window!.contentView!
            ) as? NSButton {
                refresh.performClick(nil)
            }
            guard callbacks.settingsCommands > 0 else {
                throw DriverError.assertion("settings command callback")
            }
            history.task29SelectSourceForTesting(.processed)
            history.task30InvokePasteAgainForTesting()
            guard callbacks.historyCommands == 1,
                  callbacks.routeCallbacks["paste-again"] == 1 else {
                throw DriverError.assertion("history Paste Again callback")
            }
            let surfaceScreenshots = [
                captureView(onboarding.window?.contentView, name: "onboarding-\(appearanceName)-\(contrast).png"),
                captureView(settings.window?.contentView, name: "settings-\(appearanceName)-\(contrast).png"),
                captureView(history.window?.contentView, name: "history-\(appearanceName)-\(contrast).png")
            ].compactMap { $0 }
            onboarding.window?.close()
            settings.window?.close()
            history.window?.close()
            try assert(callbacks.onboardingClose == 1 && callbacks.settingsClose == 1 && callbacks.historyClose == 1, "surface close callbacks")
            onboarding.showAndFocus()
            settings.showAndFocus()
            history.showAndFocus()
            try assert(onboarding.window?.isVisible == true && settings.window?.isVisible == true && history.window?.isVisible == true, "surface reopen")
            onboarding.window?.close()
            settings.window?.close()
            history.window?.close()
            try assert(callbacks.onboardingClose == 2 && callbacks.settingsClose == 2 && callbacks.historyClose == 2, "surface reopen cleanup")

            let recordingInputs = makeInputs(
                generation: 20,
                coordinatorState: .recording,
                operation: .init(generation: 20, kind: .dictation)
            )
            let recordingPublication = OigoPresentationPublication(inputs: recordingInputs)
            try assert(publish(
                recordingPublication,
                fence: &surfaceFence,
                statusSurface: surface,
                statusItem: statusItem,
                onboarding: onboarding,
                settings: settings,
                history: history
            ), "recording surface publication")
            let operationGate = AppOperationGate()
            guard case .success(let sessionHandle) = operationGate.begin(.dictation),
                  operationGate.isCurrent(sessionHandle),
                  case .failure(.occupied(.dictation)) = operationGate.begin(.pasteAgain) else {
                throw DriverError.assertion("terminal session ownership")
            }
            operationGate.complete(sessionHandle)
            try assert(!operationGate.isCurrent(sessionHandle), "terminal session release")
            let target = HUDTargetGeometrySnapshot(
                generation: 20,
                captureToken: UUID(),
                fieldFrame: HUDRect(x: 100, y: 300, width: 420, height: 24),
                windowFrame: HUDRect(x: 80, y: 120, width: 900, height: 500),
                targetDisplayID: 1
            )
            surface.presentHUD(
                .recording,
                generation: 20,
                geometry: target,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                preview: "Preview",
                shortcutCopy: shortcut.copy
            )
            let hudSnapshotBeforeShutdown = surface.hudResourceSnapshot
            try assert(hudSnapshotBeforeShutdown.state == .recording, "recording HUD state")
            try assert(hudSnapshotBeforeShutdown.generation == 20, "recording HUD generation")

            let hud = OigoHUDController()
            let placement = HUDPlacementInput(
                snapshot: target,
                currentGeneration: 20,
                displays: [HUDDisplayGeometry(id: 1, visibleFrame: HUDRect(x: 0, y: 0, width: 1_440, height: 900))],
                frontmostDisplayID: 1,
                mainDisplayID: 1,
                panelSize: HUDSize(width: 252, height: 54)
            )
            _ = hud.present(.recording, generation: 20, placementInput: placement, shortcutReleaseHint: shortcut.copy.releaseHint)
            let hudScreenshot = evidenceRoot.appendingPathComponent("screenshots/hud-\(appearanceName)-\(contrast).png")
            let hudCaptured = hud.captureRenderedSurface(to: hudScreenshot)
            if let inspection = hud.renderInspection {
                try assert(inspection.titlePointSize == 13 && inspection.detailPointSize == 11, "HUD typography")
                try assert(inspection.size == .init(width: 252, height: 54), "HUD recording geometry")
                try assert(inspection.cornerRadius == 12, "HUD radius")
            } else {
                throw DriverError.assertion("HUD render inspection")
            }
            hud.shutdown()
            let terminalInputs = makeInputs(
                generation: 30,
                coordinatorState: .complete,
                terminal: .init(generation: 30, outcome: .copied, failure: nil)
            )
            let terminalPublication = OigoPresentationPublication(inputs: terminalInputs)
            if fixture.flow == "failure" {
                let terminalizingInputs = makeInputs(
                    generation: 25,
                    coordinatorState: .finalizing,
                    operation: .init(generation: 25, kind: .dictation)
                )
                try assert(publish(
                    OigoPresentationPublication(inputs: terminalizingInputs),
                    fence: &surfaceFence,
                    statusSurface: surface,
                    statusItem: statusItem,
                    onboarding: onboarding,
                    settings: settings,
                    history: history
                ), "terminalizing surface publication")
                onboarding.showAndFocus()
                settings.showAndFocus()
                history.showAndFocus()
                onboarding.window?.close()
                settings.window?.close()
                settings.showAndFocus()
                history.window?.close()
                history.showAndFocus()
                onboarding.showAndFocus()
                try assert(
                    onboarding.window?.isVisible == true
                        && settings.window?.isVisible == true
                        && history.window?.isVisible == true,
                    "terminalizing close reopen"
                )
            }
            try assert(publish(
                terminalPublication,
                fence: &surfaceFence,
                statusSurface: surface,
                statusItem: statusItem,
                onboarding: onboarding,
                settings: settings,
                history: history
            ), "terminal surface publication")
            try assert(terminalPublication.state.row == .copiedOnly, "terminal publication state")
            if fixture.flow == "failure" {
                let publishedCount = callbacks.commandOrder.filter { $0.hasPrefix("publication:") }.count
                let staleAccepted = surfaceFence.publish(
                    OigoPresentationPublication(inputs: makeInputs(
                        generation: 24,
                        coordinatorState: .recording,
                        operation: .init(generation: 24, kind: .dictation)
                    )),
                    to: { _ in callbacks.record("publication:stale") }
                )
                stalePublicationRejected = !staleAccepted
                try assert(stalePublicationRejected, "stale failure publication")
                try assert(
                    callbacks.commandOrder.filter { $0.hasPrefix("publication:") }.count == publishedCount,
                    "stale publication did not overwrite current state"
                )
            }
            surface.hideHUD(generation: 20)
            surface.teardown()
            statusBar.removeStatusItem(statusItem)
            let hudSnapshotAfterShutdown = surface.hudResourceSnapshot
            try assert(!hudSnapshotAfterShutdown.visible && !hudSnapshotAfterShutdown.recordingTimerActive, "surface cleanup")

            let escape = OigoUIIntegrationPolicy.resolveEscapeAction(from: [.cancelEditor, .dismissPopover, .closeUtilityWindow])
            try assert(escape == .cancelEditor, "Escape modal priority")
            let closeEscape = OigoUIIntegrationPolicy.resolveEscapeAction(from: [.closeUtilityWindow])
            try assert(closeEscape == .closeUtilityWindow, "Escape close restoration")
            try assert(HUDPlacement.place(HUDPlacementInput(
                snapshot: nil,
                currentGeneration: 20,
                displays: [],
                frontmostDisplayID: nil,
                mainDisplayID: nil,
                panelSize: .init(width: 252, height: 54)
            )) == nil, "target disappearance fallback is explicit")
            let targetDisappearanceHandled = HUDPlacement.place(HUDPlacementInput(
                snapshot: nil,
                currentGeneration: 20,
                displays: [],
                frontmostDisplayID: nil,
                mainDisplayID: nil,
                panelSize: .init(width: 252, height: 54)
            )) == nil
            let requiredRoutes = ["start", "record", "terminal", "history", "paste-again", "settings", "onboarding"]
            try assert(requiredRoutes.allSatisfy { callbacks.routeCallbacks[$0, default: 0] > 0 }, "route callbacks")
            try assert(commandCount == 1 && commands == ["start-dictation"], "one command owner")
            try assert(Set(commands).count == commands.count, "no duplicate command")

            let screenshotPaths = surfaceScreenshots + [
                capturePopover(readyInputs: readyInputs, publication: readyPublication),
                hudCaptured ? hudScreenshot.path : "INCONCLUSIVE:WindowServer-render-capture-unavailable"
            ]
            try writeReceipt(
                screenshotPaths: screenshotPaths,
                recordingHUDVisible: hudSnapshotBeforeShutdown.visible,
                shortcut: shortcut.copy.accessibilityLabel,
                appliedAppearance: appliedAppearance,
                stalePublicationRejected: stalePublicationRejected,
                targetDisappearanceHandled: targetDisappearanceHandled
            )
            let callbackSummary = requiredRoutes
                .map { $0 + "=" + String(callbacks.routeCallbacks[$0, default: 0]) }
                .joined(separator: ",")
            let routeSummary = callbacks.commandOrder.joined(separator: ">")
            let flowLabel = fixture.flow == "failure" ? "failure" : "happy"
            print(
                "PASS cross-surface flow=\(flowLabel) publication=single-fence "
                    + "surfaces=status,popover,hud,history,settings,onboarding "
                    + "callbacks=\(callbackSummary) order=\(routeSummary) "
                    + "shortcut=\(shortcut.copy.accessibilityLabel) appearance=\(appliedAppearance)"
            )
            print(
                "PASS cross-surface-failure stale-publication=\(stalePublicationRejected) "
                    + "escape=restored close-reopen=owned target-disappearance=\(targetDisappearanceHandled) "
                    + "duplicate-command=\(Set(commands).count != commands.count) cleanup=clean"
            )
            if screenshotPaths.contains(where: { $0.hasPrefix("INCONCLUSIVE") }) {
                print("INCONCLUSIVE cross-surface-render category=windowserver-unavailable")
            }
            NSApp.terminate(nil)
        }

        func capturePopover(readyInputs: OigoPresentationInputs, publication: OigoPresentationPublication) -> String {
            let controller = OigoPopoverViewController { _ in }
            let presentation = OigoPopoverPresentation.compose(state: publication.state, inputs: readyInputs)
            controller.render(presentation, generation: publication.generation, inputOptions: [])
            controller.view.frame = NSRect(x: 0, y: 0, width: 340, height: max(1, controller.preferredContentSize.height))
            controller.view.layoutSubtreeIfNeeded()
            let url = evidenceRoot.appendingPathComponent("screenshots/popover-\(appearanceName)-\(contrast).png")
            guard let bitmap = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds) else {
                return "INCONCLUSIVE:WindowServer-popover-bitmap-unavailable"
            }
            controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                return "INCONCLUSIVE:WindowServer-popover-png-unavailable"
            }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try png.write(to: url, options: .atomic)
                return url.path
            } catch {
                return "INCONCLUSIVE:WindowServer-popover-write-unavailable"
            }
        }

        func applyAppearance(to windows: [NSWindow?]) -> String {
            let appearanceName: NSAppearance.Name?
            if contrast == "increased" {
                appearanceName = NSAppearance.Name("NSAppearanceNameAccessibilityHighContrastAqua")
            } else if self.appearanceName == "dark" {
                appearanceName = .darkAqua
            } else if self.appearanceName == "light" {
                appearanceName = .aqua
            } else {
                appearanceName = nil
            }
            if let appearanceName {
                let selected = NSAppearance(named: appearanceName)
                NSApplication.shared.appearance = selected
                windows.forEach {
                    $0?.appearance = selected
                    $0?.contentView?.appearance = selected
                }
            }
            return windows.compactMap { $0?.effectiveAppearance.name.rawValue }.first ?? ""
        }

        func captureView(_ view: NSView?, name: String) -> String? {
            guard let view else { return nil }
            view.layoutSubtreeIfNeeded()
            let scale = max(1, view.window?.backingScaleFactor ?? 2)
            guard view.bounds.width > 0, view.bounds.height > 0,
                  let bitmap = NSBitmapImageRep(
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
                  ),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: scale, y: scale)
            let draw = {
                NSColor.windowBackgroundColor.setFill()
                view.bounds.fill()
                view.displayIgnoringOpacity(view.bounds, in: context)
            }
            if let window = view.window {
                window.effectiveAppearance.performAsCurrentDrawingAppearance(draw)
            } else {
                draw()
            }
            context.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
            let url = evidenceRoot.appendingPathComponent("screenshots/" + name)
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try png.write(to: url, options: .atomic)
                return url.path
            } catch { return nil }
        }

        func writeReceipt(
            screenshotPaths: [String],
            recordingHUDVisible: Bool,
            shortcut: String,
            appliedAppearance: String,
            stalePublicationRejected: Bool,
            targetDisappearanceHandled: Bool
        ) throws {
            let receipt: [String: Any] = [
                "scenario": "cross-surface",
                "fixture": fixture.fixture,
                "productionPublication": callbacks.commandOrder.filter {
                    $0.hasPrefix("publication:")
                }.count >= 3,
                "publicationBoundary": "OigoPresentationPublication",
                "singleStateMachine": stalePublicationRejected,
                "committedShortcut": shortcut,
                "appliedAppearance": appliedAppearance,
                "operationStates": ["ready", "recording", "terminal"],
                "surfaces": ["status-menu", "popover", "hud", "onboarding", "settings", "history"],
                "routes": callbacks.commandOrder,
                "routeCallbacks": callbacks.routeCallbacks,
                "stalePublication": stalePublicationRejected,
                "escape": ["modal": "cancel-editor", "window": "close-utility-window"],
                "closeReopen": "surface-owned-and-generation-fenced",
                "targetDisappearance": targetDisappearanceHandled,
                "recordingHUDVisible": recordingHUDVisible,
                "duplicateCommand": Set(commands).count != commands.count,
                "callbacks": [
                    "onboarding": ["close": callbacks.onboardingClose, "commands": callbacks.onboardingCommands],
                    "settings": ["close": callbacks.settingsClose, "commands": callbacks.settingsCommands],
                    "history": ["close": callbacks.historyClose, "commands": callbacks.historyCommands]
                ],
                "commandOrder": callbacks.commandOrder,
                "terminalSession": "AppOperationGate owns dictation handle; Paste Again rejected while current",
                "screenshots": screenshotPaths,
                "clipboardContentsInEvidence": false,
                "cleanup": "status item removed; popover dismissed; HUD shutdown; timers and publication fence released"
            ]
            let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
            try FileManager.default.createDirectory(at: evidenceRoot, withIntermediateDirectories: true)
            try data.write(to: evidenceRoot.appendingPathComponent("cross-surface.json"), options: .atomic)
        }
    }

    @MainActor
    func descendant(identifier: String, in root: NSView) -> NSView? {
        if root.accessibilityIdentifier() == identifier { return root }
        for child in root.subviews {
            if let match = descendant(identifier: identifier, in: child) { return match }
        }
        return nil
    }

    @MainActor
    final class Delegate: NSObject, NSApplicationDelegate {
        let fixture: Fixture
        let evidenceRoot: URL
        let appearance: String
        let contrast: String

        init(fixture: Fixture, evidenceRoot: URL, appearance: String, contrast: String) {
            self.fixture = fixture
            self.evidenceRoot = evidenceRoot
            self.appearance = appearance
            self.contrast = contrast
        }

        func applicationDidFinishLaunching(_ notification: Notification) {
            _ = notification
            do {
                if appearance == "light" { NSApplication.shared.appearance = NSAppearance(named: .aqua) }
                if appearance == "dark" { NSApplication.shared.appearance = NSAppearance(named: .darkAqua) }
                try Driver(
                    fixture: fixture,
                    evidenceRoot: evidenceRoot,
                    appearanceName: appearance,
                    contrast: contrast
                ).run()
            } catch {
                fputs("ERROR cross-surface: \(error)\n", stderr)
                exit(1)
            }
        }
    }

    @MainActor
    func runDriver() throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let evidenceRoot = URL(fileURLWithPath: CommandLine.arguments[2])
        let appearance = CommandLine.arguments[3]
        let contrast = CommandLine.arguments[4]
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = Delegate(fixture: fixture, evidenceRoot: evidenceRoot, appearance: appearance, contrast: contrast)
        application.delegate = delegate
        application.run()
    }

    Task { @MainActor in
        do { try runDriver() } catch {
            fputs("ERROR cross-surface: \(error)\n", stderr)
            exit(1)
        }
    }
    dispatchMain()
    """#
}
