import AppKit
import Foundation

final class SettingsShellScenario: NativeUIContractScenario {
    private struct Fixture: Codable {
        struct Pane: Codable {
            let id: String
            let label: String
            let icon: String
        }

        let scenario: String
        let fixture: String
        let windowWidth: Double
        let paneHorizontalPadding: Double
        let paneTopPadding: Double
        let paneBottomPadding: Double
        let windowIdentifier: String
        let toolbarIdentifier: String
        let contentIdentifier: String
        let panes: [Pane]
        let controls: [String]
    }

    override class var scenarioName: String { "settings-shell" }

    override class func run(arguments: ContractArguments) throws {
        guard arguments.defaultsSuite == "com.oigo.qa.task27" else {
            throw ContractInputError(category: "invalid-defaults-suite")
        }
        let fixture = try loadFixture(from: arguments.fixtureRoot)
        try validate(fixture)
        let repositoryRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let output = try runCompiledContract(
            fixture: fixture,
            sourceFiles: [
                repositoryRoot.appendingPathComponent("Sources/Oigo/OigoUtilityWindow.swift"),
                repositoryRoot.appendingPathComponent("Sources/Oigo/Task8ControlObservation.swift"),
                repositoryRoot.appendingPathComponent("Sources/Oigo/SettingsWindowController.swift")
            ],
            evidenceRoot: arguments.evidenceRoot
        )
        guard output.contains("PASS settings-shell"),
              output.contains("PASS settings-failure") else {
            throw ContractInputError(category: "unexpected-settings-shell-output")
        }
        print(output, terminator: "")
    }

    private static func loadFixture(from root: URL) throws -> Fixture {
        let url = root.appendingPathComponent("fixture.json")
        guard let data = try? Data(contentsOf: url),
              let fixture = try? JSONDecoder().decode(Fixture.self, from: data) else {
            throw ContractInputError(category: "malformed-settings-shell")
        }
        return fixture
    }

    private static func validate(_ fixture: Fixture) throws {
        guard fixture.scenario == scenarioName,
              fixture.fixture == "shell",
              fixture.windowWidth == 720,
              fixture.paneHorizontalPadding == 40,
              fixture.paneTopPadding == 22,
              fixture.paneBottomPadding == 28,
              fixture.windowIdentifier == "com.oigo.settings.window",
              fixture.toolbarIdentifier == "oigo.settings.toolbar",
              fixture.contentIdentifier == "oigo.settings.content",
              fixture.panes.map(\.id) == ["general", "dictation", "dictionary", "data-privacy"],
              fixture.panes.map(\.label) == ["General", "Dictation", "Dictionary", "Data & Privacy"],
              fixture.panes.map(\.icon) == ["gearshape", "waveform", "text.book.closed", "lock.shield"],
              fixture.controls == [
                  "oigo.settings.shortcut-recorder",
                  "oigo.settings.default-mode",
                  "oigo.settings.dictation-language",
                  "oigo.settings.dictionary-preview",
                  "oigo.settings.refresh-permissions"
              ] else {
            throw ContractInputError(category: "settings-shell-fixture-mismatch")
        }
    }

    private static func runCompiledContract(
        fixture: Fixture,
        sourceFiles: [URL],
        evidenceRoot: URL
    ) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-native-ui-redesign.task27." + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let driver = root.appendingPathComponent("main.swift")
        let payload = root.appendingPathComponent("fixture.json")
        let executable = root.appendingPathComponent("settings-shell-contract")
        try JSONEncoder().encode(fixture).write(to: payload, options: .atomic)
        try contractDriver.write(to: driver, atomically: true, encoding: .utf8)
        _ = try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: [
                "swiftc",
                "-I", repositoryRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/Modules").path
            ] + sourceFiles.map(\.path) + [
                driver.path,
                "-framework", "AppKit",
                "-framework", "Carbon",
                "-framework", "UniformTypeIdentifiers",
                "-o", executable.path
            ] + dependencyObjects(repositoryRoot)
        )
        let data = try runProcess(executable: executable, arguments: [payload.path, evidenceRoot.path])
        guard let output = String(data: data, encoding: .utf8) else {
            throw ContractInputError(category: "unreadable-settings-shell-output")
        }
        return output
    }

    private static func dependencyObjects(_ repositoryRoot: URL) -> [String] {
        ["MacUtilityUI.build", "OigoCore.build", "OigoHotKey.build"].flatMap { directory in
            let root = repositoryRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/" + directory)
            return (try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            ))?.filter { $0.pathExtension == "o" }.map(\.path) ?? []
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
            let error = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            let standardOutput = String(data: output, encoding: .utf8) ?? ""
            throw ContractInputError(
                category: "settings-shell-build-failed:exit=\(process.terminationStatus):"
                    + (error + standardOutput).prefix(2000)
            )
        }
        return output
    }

    private static let contractDriver = #"""
    import AppKit
    import Foundation
    import OigoCore
    import OigoHotKey

    struct Fixture: Decodable {
        struct Pane: Decodable {
            let id: String
            let label: String
            let icon: String
        }
        let windowWidth: Double
        let paneHorizontalPadding: Double
        let paneTopPadding: Double
        let paneBottomPadding: Double
        let windowIdentifier: String
        let toolbarIdentifier: String
        let contentIdentifier: String
        let panes: [Pane]
        let controls: [String]
    }

    @MainActor
    final class CallbackState {
        var closeCount = 0
        var saveCount = 0
        var shortcutSaveCount = 0
        var callbackInvocations = 0
    }

    @MainActor
    final class SettingsShellContractFactory {
        let settingsStore: OigoSettingsStore
        let callbacks: CallbackState
        let committedSettings: OigoSettings

        init() throws {
            guard let defaults = UserDefaults(suiteName: "com.oigo.qa.task27") else {
                throw NSError(domain: "settings-shell", code: 1)
            }
            defaults.removePersistentDomain(forName: "com.oigo.qa.task27")
            settingsStore = OigoSettingsStore(defaults: defaults)
            callbacks = CallbackState()
            committedSettings = OigoSettings(
                globalShortcut: ToggleShortcut(keyCode: 13, modifiers: ToggleShortcutModifiers.command),
                localeIdentifier: "en-US",
                defaultMode: .clean,
                showVolatilePreview: false,
                audioRetention: .oneWeek,
                keepSuccessfulAudioIndefinitely: true,
                launchAtLogin: false,
                selectedInput: .systemDefault,
                selectedInputChannel: 0
            )
            try settingsStore.save(committedSettings)
        }

        func makeController() -> SettingsWindowController {
            var presented = true
            let state = callbacks
            return SettingsWindowController(
                settings: settingsStore.load(),
                inputDevices: [],
                supportedLocales: ["en-US", "es-MX"],
                loadSupportedLocales: { [state] in
                    state.callbackInvocations += 1
                    return ["en-US", "es-MX"]
                },
                microphoneState: .granted,
                accessibilityState: .granted,
                storageHealth: .ready(.init(
                    recoveredSessionCount: 0,
                    historyEntryCount: 0,
                    malformedSessionCount: 0
                )),
                launchAtLoginStatus: .disabled,
                launchAtLoginStatusProvider: { .disabled },
                openLoginItemsSettings: { state.callbackInvocations += 1 },
                registrationStatus: {
                    .active(
                        ToggleShortcut(keyCode: 13, modifiers: ToggleShortcutModifiers.command),
                        generation: 1
                    )
                },
                registrationError: { nil },
                validateShortcut: { _ in .available },
                saveShortcut: { [settingsStore, state] shortcut in
                    state.shortcutSaveCount += 1
                    do {
                        try settingsStore.save(settingsStore.load().with(globalShortcut: shortcut))
                        return .available
                    } catch {
                        return .invalid("Settings could not be saved")
                    }
                },
                save: { [settingsStore, state] settings in
                    state.saveCount += 1
                    do {
                        try settingsStore.save(settings)
                        return nil
                    } catch {
                        return "Settings could not be saved"
                    }
                },
                checkSpeechAssets: { _ in .ready },
                refreshPermissions: { (.granted, .granted) },
                openMicrophoneSettings: { state.callbackInvocations += 1 },
                openAccessibilitySettings: { state.callbackInvocations += 1 },
                rerunOnboarding: { state.callbackInvocations += 1 },
                openHistory: { state.callbackInvocations += 1 },
                openDataFolder: { state.callbackInvocations += 1 },
                retryStorage: { state.callbackInvocations += 1 },
                deleteAllHistory: { state.callbackInvocations += 1 },
                exportDiagnostics: { Data("settings-shell".utf8) },
                dictionaryDocument: .empty,
                saveDictionary: { _ in nil },
                previewDictionary: { $0 },
                addStarterTerms: { (.empty, nil) },
                isPresented: { presented },
                onClose: {
                    presented = false
                    state.closeCount += 1
                }
            )
        }
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
            let factory: SettingsShellContractFactory
            do {
                factory = try SettingsShellContractFactory()
            } catch {
                exit(20)
            }
            let priorSelectedPane = UserDefaults.standard.string(forKey: "oigo.settings.selected-pane")
            UserDefaults.standard.removeObject(forKey: "oigo.settings.selected-pane")
            defer {
                if let priorSelectedPane {
                    UserDefaults.standard.set(priorSelectedPane, forKey: "oigo.settings.selected-pane")
                } else {
                    UserDefaults.standard.removeObject(forKey: "oigo.settings.selected-pane")
                }
            }

            let controller = factory.makeController()
            controller.showAndFocus()
            guard let window = controller.window,
                  let content = window.contentView,
                  let toolbar = window.toolbar else { exit(10) }
            window.layoutIfNeeded()
            let views = allViews(content)
            let paneViews = Dictionary(uniqueKeysWithValues: fixture.panes.compactMap { pane in
                views.first { $0.accessibilityIdentifier() == "oigo.settings.pane." + pane.id }
                    .map { (pane.id, $0) }
            })
            let shellContent = views.first { $0.accessibilityIdentifier() == fixture.contentIdentifier }
            guard window.identifier?.rawValue == fixture.windowIdentifier,
                  abs(window.frame.width - fixture.windowWidth) < 0.5,
                  toolbar.identifier == fixture.toolbarIdentifier,
                  toolbar.displayMode == .iconAndLabel,
                  !toolbar.allowsUserCustomization,
                  toolbar.items.count == 4,
                  toolbar.items.allSatisfy({ $0.image != nil && !$0.label.isEmpty && $0.target != nil && $0.action != nil }),
                  Set(toolbar.items.map { $0.itemIdentifier.rawValue }) == Set(fixture.panes.map(\.id)),
                  shellContent != nil,
                  paneViews.count == 4 else { exit(10) }

            guard let shellContent,
                  abs(shellContent.bounds.width - (fixture.windowWidth - 80)) < 0.5,
                  abs(shellContent.frame.minX - fixture.paneHorizontalPadding) < 0.5,
                  abs((content.bounds.maxY - shellContent.frame.maxY) - fixture.paneTopPadding) < 0.5,
                  abs(shellContent.frame.minY - fixture.paneBottomPadding) < 0.5 else { exit(10) }
            for controlIdentifier in fixture.controls {
                guard views.contains(where: { $0.accessibilityIdentifier() == controlIdentifier }) else { exit(10) }
            }

            let settingsBefore = factory.settingsStore.load()
            var capturedScreenshots: [String] = []
            let appearances = [
                ("light", "NSAppearanceNameAqua"),
                ("dark", "NSAppearanceNameDarkAqua"),
                ("increased-contrast", "NSAppearanceNameAccessibilityHighContrastAqua")
            ]
            for appearance in appearances {
                window.appearance = NSAppearance(named: NSAppearance.Name(appearance.1))
                content.appearance = window.appearance
                for pane in fixture.panes {
                    guard let item = toolbar.items.first(where: { $0.itemIdentifier.rawValue == pane.id }) else { exit(11) }
                    guard let action = item.action,
                          let target = item.target,
                          NSApp.sendAction(action, to: target, from: item) else { exit(11) }
                    RunLoop.main.run(until: Date().addingTimeInterval(0.16))
                    guard toolbar.selectedItemIdentifier?.rawValue == pane.id,
                          paneViews[pane.id]?.isHidden == false,
                          paneViews.values.filter({ !$0.isHidden }).count == 1 else { exit(11) }
                    let screenshot = evidenceRoot.appendingPathComponent("settings-\(pane.id)-\(appearance.0).png")
                    guard capture(view: content, to: screenshot) else { exit(12) }
                    capturedScreenshots.append(screenshot.lastPathComponent)
                }
            }
            guard factory.settingsStore.load() == settingsBefore,
                  factory.callbacks.saveCount == 0,
                  factory.callbacks.shortcutSaveCount == 0 else { exit(13) }

            let keyboardItem = toolbar.items.first(where: { $0.itemIdentifier.rawValue == "general" })!
            NSApp.sendAction(keyboardItem.action!, to: keyboardItem.target, from: keyboardItem)
            RunLoop.main.run(until: Date().addingTimeInterval(0.16))
            guard toolbar.selectedItemIdentifier?.rawValue == "general" else { exit(14) }

            guard controller.toolbar(
                toolbar,
                itemForItemIdentifier: NSToolbarItem.Identifier("unknown-pane"),
                willBeInsertedIntoToolbar: false
            ) == nil else { exit(15) }

            let restoredPane = "data-privacy"
            if let item = toolbar.items.first(where: { $0.itemIdentifier.rawValue == restoredPane }),
               let action = item.action,
               let target = item.target {
                guard NSApp.sendAction(action, to: target, from: item) else { exit(16) }
            } else {
                exit(16)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.16))
            guard toolbar.selectedItemIdentifier?.rawValue == restoredPane else { exit(16) }
            window.close()
            guard !window.isVisible, factory.callbacks.closeCount == 1,
                  factory.settingsStore.load() == settingsBefore else { exit(17) }

            let reopened = factory.makeController()
            reopened.showAndFocus()
            guard let reopenedWindow = reopened.window,
                  let reopenedToolbar = reopenedWindow.toolbar,
                  reopenedToolbar.selectedItemIdentifier?.rawValue == restoredPane,
                  factory.settingsStore.load() == settingsBefore else { exit(18) }
            reopenedWindow.close()

            let receipt: [String: Any] = [
                "scenario": "settings-shell",
                "fixture": "shell",
                "productionController": true,
                "windowIdentifier": fixture.windowIdentifier,
                "windowWidth": fixture.windowWidth,
                "toolbarIdentifier": fixture.toolbarIdentifier,
                "toolbarDisplayMode": "iconAndLabel",
                "panes": fixture.panes.map { ["id": $0.id, "label": $0.label, "icon": $0.icon] },
                "contentIdentifier": fixture.contentIdentifier,
                "panePadding": [
                    "horizontal": fixture.paneHorizontalPadding,
                    "top": fixture.paneTopPadding,
                    "bottom": fixture.paneBottomPadding
                ],
                "controls": fixture.controls,
                "mouseNavigation": "4 panes reached through the production NSToolbarItem action target",
                "keyboardNavigation": "toolbar action dispatched through NSApp.sendAction",
                "selectedState": "NSToolbar.selectedItemIdentifier and one visible pane",
                "unknownToolbarRejected": true,
                "selectedPaneRestored": restoredPane,
                "settingsBeforeAfterEqual": true,
                "callbacks": [
                    "production SettingsWindowController callbacks installed",
                    "close=\(factory.callbacks.closeCount)",
                    "save=\(factory.callbacks.saveCount)",
                    "shortcutSave=\(factory.callbacks.shortcutSaveCount)"
                ],
                "screenshots": capturedScreenshots,
                "cleanup": "closed original and reopened Settings windows; no settings save during navigation"
            ]
            let data = try! JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
            try! FileManager.default.createDirectory(at: evidenceRoot, withIntermediateDirectories: true)
            try! data.write(to: evidenceRoot.appendingPathComponent("settings-shell.json"), options: .atomic)
            print("PASS settings-shell production-controller=true width=720 toolbar=icon+label panes=4 mouse=4 keyboard=action selected-state=verified padding=40/22/28 settings=unchanged")
            print("PASS settings-failure unknown-toolbar=rejected close-reopen=restored selected-pane=data-privacy callbacks=observed cleanup=clean")
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
        let draw = {
            NSColor.windowBackgroundColor.setFill()
            view.bounds.fill()
            view.displayIgnoringOpacity(view.bounds, in: graphicsContext)
        }
        if let window = view.window {
            window.effectiveAppearance.performAsCurrentDrawingAppearance(draw)
        } else {
            draw()
        }
        graphicsContext.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
            return true
        } catch { return false }
    }

    @MainActor
    func runSettingsShell() {
        let fixture = try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = Delegate(fixture: fixture, evidenceRoot: URL(fileURLWithPath: CommandLine.arguments[2]))
        application.delegate = delegate
        application.run()
    }

    Task { @MainActor in
        runSettingsShell()
    }
    dispatchMain()
    """#
}
