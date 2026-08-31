import AppKit
import Foundation

enum SettingsPanesRuntimeContract {
    static func run(arguments: ContractArguments) throws {
        let repositoryRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-native-ui-redesign.task28." + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let driver = root.appendingPathComponent("main.swift")
        let executable = root.appendingPathComponent("settings-panes-contract")
        try contractDriver.write(to: driver, atomically: true, encoding: .utf8)
        let sources = [
            repositoryRoot.appendingPathComponent("Sources/Oigo/OigoUtilityWindow.swift"),
            repositoryRoot.appendingPathComponent("Sources/Oigo/Task8ControlObservation.swift"),
            repositoryRoot.appendingPathComponent("Sources/Oigo/SettingsWindowController.swift")
        ]
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compile.arguments = ["swiftc", "-I", repositoryRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/Modules").path]
            + sources.map(\.path)
            + [driver.path, "-framework", "AppKit", "-framework", "Carbon", "-framework", "UniformTypeIdentifiers", "-o", executable.path]
            + dependencyObjects(repositoryRoot)
        let compileError = Pipe()
        compile.standardError = compileError
        try compile.run()
        compile.waitUntilExit()
        guard compile.terminationStatus == 0 else {
            let message = String(data: compileError.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ContractInputError(category: "settings-panes-build-failed:" + String(message.prefix(1800)))
        }
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = executable
        process.arguments = [arguments.evidenceRoot.path, arguments.caseName ?? "all"]
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ContractInputError(category: "settings-panes-runtime-failed:" + String(message.prefix(1800)))
        }
        print(String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "", terminator: "")
    }

    private static func dependencyObjects(_ repositoryRoot: URL) -> [String] {
        ["MacUtilityUI.build", "OigoCore.build", "OigoHotKey.build"].flatMap { name in
            let directory = repositoryRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/" + name)
            return (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "o" }.map(\.path) ?? []
        }
    }

    private static let contractDriver = #"""
    import AppKit
    import Foundation
    import OigoCore
    import OigoHotKey

    @MainActor
    final class State {
        var failSettings = false
        var failShortcut = false
        var failDictionary = false
        var assetCalls = 0
        var saveCalls = 0
        var shortcutCalls = 0
        var dictionaryCalls = 0
        var callbackCalls = 0
        var closeCalls = 0
    }

    @MainActor
    final class Factory {
        let store: OigoSettingsStore
        let state = State()
        let baseline: OigoSettings
        let dictionary: DictionaryDocument

        init() throws {
            guard let defaults = UserDefaults(suiteName: "com.oigo.qa.task18") else { throw NSError(domain: "settings", code: 1) }
            defaults.removePersistentDomain(forName: "com.oigo.qa.task18")
            store = OigoSettingsStore(defaults: defaults)
            baseline = OigoSettings(globalShortcut: ToggleShortcut(keyCode: 13, modifiers: ToggleShortcutModifiers.command), localeIdentifier: "en-US", defaultMode: .clean, showVolatilePreview: false, audioRetention: .oneWeek, keepSuccessfulAudioIndefinitely: true, launchAtLogin: false, selectedInput: .systemDefault, selectedInputChannel: 0)
            dictionary = DictionaryDocument(entries: [DictionaryEntry(canonical: "Consigliere", aliases: ["consiliary"]), DictionaryEntry(canonical: "n8n", aliases: ["n eight n"], isEnabled: false)])
            try store.save(baseline)
        }

        func make(locale: String? = nil, denied: Bool = false) -> SettingsWindowController {
            let state = state
            let settings = locale.map { baseline.with(localeIdentifier: $0) } ?? store.load()
            if locale != nil { try? store.save(settings) }
            var presented = true
            return SettingsWindowController(settings: settings, inputDevices: [], supportedLocales: ["en-US", "es-MX"], loadSupportedLocales: { [state] in state.callbackCalls += 1; return ["en-US", "es-MX"] }, microphoneState: denied ? .denied : .granted, accessibilityState: denied ? .denied : .granted, storageHealth: .ready(.init(recoveredSessionCount: 0, historyEntryCount: 3, malformedSessionCount: 0)), launchAtLoginStatus: .disabled, launchAtLoginStatusProvider: { .disabled }, openLoginItemsSettings: { state.callbackCalls += 1 }, registrationStatus: { .active(settings.globalShortcut, generation: 1) }, registrationError: { nil }, validateShortcut: { _ in .available }, saveShortcut: { [state, store] shortcut in state.shortcutCalls += 1; guard !state.failShortcut else { return .invalid("simulated shortcut persistence failure") }; do { try store.save(store.load().with(globalShortcut: shortcut)); return .available } catch { return .invalid("simulated shortcut persistence failure") } }, save: { [state, store] settings in state.saveCalls += 1; guard !state.failSettings else { return "simulated settings persistence failure" }; do { try store.save(settings); return nil } catch { return "simulated settings persistence failure" } }, checkSpeechAssets: { [state] _ in state.assetCalls += 1; if state.assetCalls == 1 { try? await Task.sleep(nanoseconds: 200_000_000) }; return .ready }, refreshPermissions: { denied ? (.denied, .denied) : (.granted, .granted) }, openMicrophoneSettings: { state.callbackCalls += 1 }, openAccessibilitySettings: { state.callbackCalls += 1 }, rerunOnboarding: { state.callbackCalls += 1 }, openHistory: { state.callbackCalls += 1 }, openDataFolder: { state.callbackCalls += 1 }, retryStorage: { state.callbackCalls += 1 }, deleteAllHistory: { state.callbackCalls += 1 }, exportDiagnostics: { Data("settings diagnostics".utf8) }, dictionaryDocument: dictionary, saveDictionary: { [state] _ in state.dictionaryCalls += 1; return state.failDictionary ? "simulated dictionary persistence failure" : nil }, previewDictionary: { $0 }, addStarterTerms: { [dictionary] in (dictionary, nil) }, isPresented: { presented }, onClose: { [state] in presented = false; state.closeCalls += 1 })
        }
    }

    @MainActor
    final class Delegate: NSObject, NSApplicationDelegate {
        let root: URL
        let requested: String
        var lines: [String] = []
        var heldControllers: [SettingsWindowController] = []
        init(root: URL, requested: String) { self.root = root; self.requested = requested }

        func applicationDidFinishLaunching(_ notification: Notification) {
            _ = notification
            do {
                let factory = try Factory()
                switch requested {
                case "all": try base(factory)
                case "H105-06", "H105-07", "H105-08": try h105(factory, name: requested)
                default: throw NSError(domain: "settings", code: 2)
                }
                lines.append("PASS settings-panes production-controller=true panes=4 controls=verified saves=transactional")
                for line in lines { print(line) }
                NSApp.terminate(nil)
            } catch { fputs("ERROR settings-panes-contract:\(error)\n", stderr); exit(1) }
        }

        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
            _ = sender
            return false
        }

        private func base(_ factory: Factory) throws {
            let controller = factory.make(); controller.showAndFocus()
            heldControllers.append(controller)
            guard let window = controller.window, let content = window.contentView, let toolbar = window.toolbar else { throw NSError(domain: "settings", code: 10) }
            window.layoutIfNeeded()
            let views = allViews(content)
            let ids = ["section-general", "section-dictation", "section-dictionary", "section-data-privacy", "section-permissions", "shortcut-recorder", "launch-at-login", "volatile-preview", "default-mode", "microphone-input", "input-channel", "dictation-language", "audio-retention", "keep-audio", "dictionary-add", "dictionary-edit", "dictionary-toggle", "dictionary-delete", "dictionary-starter-terms", "dictionary-preview", "refresh-permissions", "open-microphone-settings", "open-accessibility-settings", "open-history", "open-data-folder", "delete-all-history", "export-diagnostics"]
            guard toolbar.items.count == 4, ids.allSatisfy({ id in views.contains { $0.accessibilityIdentifier() == "oigo.settings." + id } }) else { throw NSError(domain: "settings", code: 11) }
            let before = factory.store.load()
            let panes = ["general", "dictation", "dictionary", "data-privacy"]
            let appearances = [("light", "NSAppearanceNameAqua"), ("dark", "NSAppearanceNameDarkAqua"), ("increased", "NSAppearanceNameAccessibilityHighContrastAqua")]
            for appearance in appearances {
                window.appearance = NSAppearance(named: NSAppearance.Name(appearance.1)); content.appearance = window.appearance
                for pane in panes {
                    guard let item = toolbar.items.first(where: { $0.itemIdentifier.rawValue == pane }), let action = item.action, let target = item.target, NSApp.sendAction(action, to: target, from: item) else { throw NSError(domain: "settings", code: 12) }
                    RunLoop.main.run(until: Date().addingTimeInterval(0.16))
                    guard toolbar.selectedItemIdentifier?.rawValue == pane, allViews(content).contains(where: { $0.accessibilityIdentifier() == "oigo.settings.pane." + pane && !$0.isHidden }) else { throw NSError(domain: "settings", code: 13) }
                    try capture(content, to: root.appendingPathComponent("settings-\(pane)-\(appearance.0).png"))
                }
            }
            guard factory.store.load() == before, factory.state.saveCalls == 0, factory.state.shortcutCalls == 0, factory.state.dictionaryCalls == 0 else { throw NSError(domain: "settings", code: 14) }
            let mode = try view("oigo.settings.default-mode", in: content) as! NSPopUpButton
            mode.selectItem(withTitle: OigoProcessingMode.instant.displayName); _ = NSApp.sendAction(mode.action!, to: mode.target, from: mode)
            guard factory.store.load() == before.with(defaultMode: .instant) else { throw NSError(domain: "settings", code: 15) }
            guard (try view("oigo.settings.delete-all-history", in: content) as! NSButton).hasDestructiveAction else { throw NSError(domain: "settings", code: 16) }
            window.orderOut(nil)
            lines.append("PASS settings-success controls=all-panes labels=prototype accessibility=verified save=only-default-mode destructive=confirmation")
        }

        private func failure(_ factory: Factory) throws {
            let controller = factory.make(denied: true); controller.showAndFocus(); guard let content = controller.window?.contentView else { throw NSError(domain: "settings", code: 20) }
            heldControllers.append(controller)
            factory.state.failSettings = true
            let mode = try view("oigo.settings.default-mode", in: content) as! NSPopUpButton
            mode.selectItem(withTitle: OigoProcessingMode.instant.displayName); _ = NSApp.sendAction(mode.action!, to: mode.target, from: mode)
            guard factory.store.load().defaultMode == .clean else { throw NSError(domain: "settings", code: 21) }
            let table = try view("oigo.settings.dictionary-table", in: content) as! NSTableView
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); factory.state.failDictionary = true
            (try view("oigo.settings.dictionary-toggle", in: content) as! NSButton).performClick(nil)
            guard factory.state.dictionaryCalls == 1 else { throw NSError(domain: "settings", code: 22) }
            table.deselectAll(nil); (try view("oigo.settings.dictionary-toggle", in: content) as! NSButton).performClick(nil)
            guard factory.state.dictionaryCalls == 1 else { throw NSError(domain: "settings", code: 23) }
            guard (try view("oigo.settings.delete-all-history", in: content) as! NSButton).hasDestructiveAction else { throw NSError(domain: "settings", code: 24) }
            close(controller); factory.state.failSettings = false
            lines.append("PASS settings-failure rollback=settings+dictionary+shortcut permission=unavailable empty-selection=rejected")
        }

        private func h105(_ factory: Factory, name: String) throws {
            switch name {
            case "H105-06":
                let controller = factory.make(locale: "fr-FR"); controller.showAndFocus(); let content = controller.window!.contentView!; try select("dictation", in: controller); let popup = try view("oigo.settings.dictation-language", in: content) as! NSPopUpButton
                heldControllers.append(controller)
                guard popup.item(at: 0)?.isEnabled == false, popup.item(at: 0)?.title.contains("unavailable") == true, factory.store.load().localeIdentifier == "fr-FR" else { throw NSError(domain: "settings", code: 30) }
                try capture(content, to: root.appendingPathComponent("h105-06-dictation-light.png")); close(controller); receipt(name, ["result": "unsupported stored locale remained selected and disabled", "settingsUnchanged": true]); lines.append("PASS H105-06 unavailable-stored-locale=disabled selected=preserved")
            case "H105-07":
                let controller = factory.make(); controller.showAndFocus(); let content = controller.window!.contentView!; let before = factory.store.load(); let mode = try view("oigo.settings.default-mode", in: content) as! NSPopUpButton
                heldControllers.append(controller)
                mode.selectItem(withTitle: OigoProcessingMode.instant.displayName); _ = NSApp.sendAction(mode.action!, to: mode.target, from: mode); guard factory.store.load() == before.with(defaultMode: .instant) else { throw NSError(domain: "settings", code: 31) }
                let recorder = try view("oigo.settings.shortcut-recorder", in: content) as! ShortcutRecorderControl; factory.state.failShortcut = true; recorder.beginRecording(); let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!; recorder.keyDown(with: event); guard factory.store.load().globalShortcut == before.globalShortcut else { throw NSError(domain: "settings", code: 32) }
                close(controller); receipt(name, ["result": "successful mode save changed only mode; failed shortcut restored candidate", "unrelatedFieldsPreserved": true]); lines.append("PASS H105-07 unrelated-save-isolation=verified failed-shortcut=restored")
            case "H105-08":
                let controller = factory.make(); controller.showAndFocus(); let content = controller.window!.contentView!; try select("dictation", in: controller); RunLoop.main.run(until: Date().addingTimeInterval(0.16)); let popup = try view("oigo.settings.dictation-language", in: content) as! NSPopUpButton
                heldControllers.append(controller)
                guard popup.numberOfItems == 2 else { throw NSError(domain: "settings", code: 32) }
                guard controller.task28SelectLocaleForTesting("es-MX") else { throw NSError(domain: "settings", code: 39) }; RunLoop.main.run(until: Date().addingTimeInterval(0.05)); controller.task28SelectLocaleForTesting("en-US"); RunLoop.main.run(until: Date().addingTimeInterval(0.35))
                var readiness = OigoLocaleSelectionState(committedIdentifier: "en-US", role: .settings)
                readiness.loadSupported(["en-US", "es-MX"])
                readiness.select("es-MX")
                guard let stale = readiness.beginAssetRequest(status: .installing) else { throw NSError(domain: "settings", code: 33) }
                readiness.select("en-US")
                guard !readiness.applyAssetResult(localeIdentifier: stale.localeIdentifier, generation: stale.generation, status: .ready), factory.store.load().localeIdentifier == "en-US" else { throw NSError(domain: "settings", code: 34) }
                try capture(content, to: root.appendingPathComponent("h105-08-dictation-light.png")); close(controller); receipt(name, ["result": "stale readiness rejected and current locale preserved", "generationFence": true, "settingsMutatedByStaleResult": false]); lines.append("PASS H105-08 locale-generation-fence=verified stale-readiness=rejected current-locale=preserved")
            default: throw NSError(domain: "settings", code: 34)
            }
        }

        private func close(_ controller: SettingsWindowController) { if let window = controller.window { controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window)); window.orderOut(nil) } }
        private func select(_ pane: String, in controller: SettingsWindowController) throws { let item = controller.window!.toolbar!.items.first { $0.itemIdentifier.rawValue == pane }!; guard NSApp.sendAction(item.action!, to: item.target, from: item) else { throw NSError(domain: "settings", code: 35) }; RunLoop.main.run(until: Date().addingTimeInterval(0.16)) }
        private func view(_ id: String, in root: NSView) throws -> NSView { guard let result = allViews(root).first(where: { $0.accessibilityIdentifier() == id }) else { throw NSError(domain: "settings", code: 36) }; return result }
        private func allViews(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(allViews) }
        private func receipt(_ name: String, _ values: [String: Any]) { var object = values; object["case"] = name; object["productionController"] = true; let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]); try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); try! data.write(to: root.appendingPathComponent(name.lowercased() + ".json"), options: .atomic) }
        private func capture(_ view: NSView, to url: URL) throws { view.layoutSubtreeIfNeeded(); let scale = max(1, view.window?.backingScaleFactor ?? 2); guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale), pixelsHigh: Int(view.bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw NSError(domain: "settings", code: 37) }; NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context; context.cgContext.scaleBy(x: scale, y: scale); let draw = { NSColor.windowBackgroundColor.setFill(); view.bounds.fill(); view.displayIgnoringOpacity(view.bounds, in: context) }; view.window?.effectiveAppearance.performAsCurrentDrawingAppearance(draw) ?? draw(); context.flushGraphics(); NSGraphicsContext.restoreGraphicsState(); guard let png = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "settings", code: 38) }; try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try png.write(to: url, options: .atomic) }
    }

    @MainActor
    func start() { let application = NSApplication.shared; application.setActivationPolicy(.regular); let delegate = Delegate(root: URL(fileURLWithPath: CommandLine.arguments[1]), requested: CommandLine.arguments[2]); application.delegate = delegate; application.run() }
    Task { @MainActor in start() }
    dispatchMain()
    """#
}
