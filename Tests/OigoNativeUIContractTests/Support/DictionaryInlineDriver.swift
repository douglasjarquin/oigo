import AppKit
import OigoCore
import OigoHotKey
import MacUtilityUI

@main
enum DictionaryInlineDriver {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        var document = DictionaryDocument(entries: [
            DictionaryEntry(canonical: "Oigo", aliases: ["oy go"]),
            DictionaryEntry(canonical: "AppKit", aliases: ["app kit"])
        ])
        var failSave = false
        var saves = 0
        var previews = 0
        let settings = OigoSettings()
        let controller = SettingsWindowController(
            settings: settings, inputDevices: [], supportedLocales: ["en-US", "es-MX"],
            loadSupportedLocales: { ["en-US", "es-MX"] },
            microphoneState: .granted, accessibilityState: .granted,
            storageHealth: .ready(.init(recoveredSessionCount: 0, historyEntryCount: 0, malformedSessionCount: 0)),
            launchAtLoginStatus: .disabled, launchAtLoginStatusProvider: { .disabled },
            openLoginItemsSettings: {}, registrationStatus: { .active(settings.globalShortcut, generation: 1) },
            registrationError: { nil }, validateShortcut: { _ in .available }, saveShortcut: { _ in .available },
            save: { _ in nil }, checkSpeechAssets: { _ in .ready }, refreshPermissions: { (.granted, .granted) },
            openMicrophoneSettings: {}, openAccessibilitySettings: {}, rerunOnboarding: {},
            openHistory: {}, openDataFolder: {}, retryStorage: {}, deleteAllHistory: {},
            exportDiagnostics: { Data() }, dictionaryDocument: document,
            saveDictionary: { candidate in
                saves += 1
                if failSave { return "Simulated dictionary save failure" }
                document = candidate
                return nil
            },
            previewDictionary: { text in
                previews += 1
                let snapshot = try! DictionaryCompiler.compile(document.entries, localeIdentifier: "en-US")
                return TerminologyNormalizer(snapshot: snapshot).normalize(text)
            },
            addStarterTerms: { (document, nil) }, isPresented: { true }, onClose: {}
        )
        let content = controller.window!.contentView!
        func find(_ suffix: String, in root: NSView) -> NSView? {
            if root.identifier?.rawValue == "oigo.settings." + suffix { return root }
            return root.subviews.lazy.compactMap { find(suffix, in: $0) }.first
        }
        func control<T: NSView>(_ suffix: String, as type: T.Type = T.self) -> T {
            guard let value = find(suffix, in: content) as? T else { fatalError("Missing " + suffix) }
            return value
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
        }
        func type(_ field: NSTextField, _ text: String, commit: Bool = false) {
            field.stringValue = text
            NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
            if commit {
                NotificationCenter.default.post(name: NSControl.textDidEndEditingNotification, object: field)
            }
        }
        func click(_ suffix: String) {
            let button: NSButton = control(suffix)
            button.performClick(nil)
        }
        func capture(_ name: String) throws {
            guard let path = ProcessInfo.processInfo.environment["OIGO_DICTIONARY_EVIDENCE_ROOT"] else { return }
            let view = content.superview ?? content
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                controller.window!.appearance = NSAppearance(named: appearance)
                view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    fatalError("Cannot render " + name)
                }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    fatalError("Cannot encode " + name)
                }
                try png.write(to: URL(fileURLWithPath: path).appendingPathComponent(name + "-" + suffix + ".png"))
            }
            controller.window!.appearance = NSAppearance(named: .aqua)
        }
        let table: NSTableView = control("dictionary-table")
        let canonical: NSTextField = control("dictionary-canonical")
        let sample: NSTextField = control("dictionary-preview")
        let result: NSTextField = control("dictionary-result")
        let status: NSTextField = control("dictionary-status")
        let toggle: NSButton = control("dictionary-toggle")
        let search: NSSearchField = control("dictionary-search")
        expect(table.tableColumns.count == 1 && table.headerView == nil, "Single-column term sidebar")
        expect(!canonical.isEnabled && !sample.isEnabled && !toggle.isEnabled, "Empty selection disables editor")
        try capture("dictionary-empty")
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        expect(canonical.isEnabled && canonical.stringValue == "Oigo", "Selection populates editor")
        let previewsBefore = previews
        type(sample, "use oy go")
        expect(previews > previewsBefore && result.stringValue == "Result: use Oigo", "Live preview updates without Return")
        content.layoutSubtreeIfNeeded()
        let editorSplit: NSView = control("dictionary-split")
        let canonicalRect = canonical.superview!.convert(canonical.alignmentRect(forFrame: canonical.frame), to: editorSplit)
        let topInset = editorSplit.bounds.maxY - canonicalRect.maxY
        expect(abs(topInset - 16) < 1, "Dictionary editor top inset: \(topInset), expected 16")
        expect(abs(sample.frame.width - canonical.frame.width) < 1, "Test field fills canonical control column")
        let firstAlias: NSTextField = control("dictionary-alias-0")
        expect(firstAlias.frame.width >= canonical.frame.width - 50, "Alias field fills column beside remove button")
        try capture("dictionary-populated")
        type(canonical, "OIGO", commit: true)
        expect(document.entries[0].canonical == "OIGO" && table.selectedRow == 0, "Canonical commits and keeps selection")
        expect(result.stringValue == "Result: use OIGO", "Save refreshes preview")
        let saved = document
        failSave = true
        type(canonical, "Broken", commit: true)
        expect(document == saved && canonical.stringValue == "OIGO", "Failed canonical save rolls editor back")
        expect(status.stringValue.contains("failure"), "Persistence failure is inline")
        click("dictionary-toggle")
        expect(toggle.state == .on && document == saved, "Failed toggle rolls back")
        click("dictionary-delete")
        expect(document == saved && table.selectedRow == 0, "Failed deletion preserves selection")
        failSave = false
        click("dictionary-add-alias")
        let alias: NSTextField = control("dictionary-alias-1")
        let savesBeforeInvalid = saves
        type(alias, "oy go", commit: true)
        expect(saves == savesBeforeInvalid && document == saved, "Duplicate aliases rejected before persistence")
        type(alias, "app kit", commit: true)
        expect(saves == savesBeforeInvalid && document == saved, "Conflicting aliases rejected by existing dictionary model")
        failSave = true
        type(alias, "oh go", commit: true)
        expect(document == saved && find("dictionary-alias-1", in: content) == nil, "Failed alias save restores committed rows")
        failSave = false
        click("dictionary-add-alias")
        let retryAlias: NSTextField = control("dictionary-alias-1")
        type(retryAlias, "oh go", commit: true)
        expect(document.entries[0].aliases == ["oy go", "oh go"], "Alias commits inline")
        click("dictionary-remove-alias-1")
        expect(document.entries[0].aliases == ["oy go"], "Alias removal commits")
        let locale: NSPopUpButton = control("dictionary-locale")
        failSave = true
        locale.selectItem(at: locale.itemArray.firstIndex { ($0.representedObject as? String) == "es-MX" }!)
        _ = NSApp.sendAction(locale.action!, to: locale.target, from: locale)
        expect(document.entries[0].localeIdentifier == nil && locale.indexOfSelectedItem == 0, "Failed locale save restores popup")
        failSave = false
        locale.selectItem(at: locale.itemArray.firstIndex { ($0.representedObject as? String) == "es-MX" }!)
        _ = NSApp.sendAction(locale.action!, to: locale.target, from: locale)
        expect(document.entries[0].localeIdentifier == "es-MX", "Locale commits")
        expect(result.stringValue == "Result: use oy go", "Preview uses committed locale scope")
        click("dictionary-toggle")
        expect(!document.entries[0].isEnabled, "Enabled state commits")
        type(search, "APP KIT")
        expect(table.numberOfRows == 1 && table.selectedRow == -1 && !canonical.isEnabled, "Search aliases and clear filtered selection")
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        expect(canonical.stringValue == "AppKit", "Filtered selection maps to correct entry")
        type(canonical, "AppKit Native", commit: true)
        expect(document.entries[1].canonical == "AppKit Native" && table.selectedRow == 1, "Save keeps selected identity")
        let countBeforeDraft = document.entries.count
        let savesBeforeDraft = saves
        click("dictionary-add")
        expect(document.entries.count == countBeforeDraft && saves == savesBeforeDraft, "Add begins an unsaved draft")
        type(canonical, "   ", commit: true)
        expect(saves == savesBeforeDraft && canonical.isEnabled, "Empty canonical remains editable without persistence")
        failSave = true
        type(canonical, "New Product", commit: true)
        expect(document.entries.count == countBeforeDraft && canonical.stringValue == "New Product", "Failed draft save retains unsaved input for retry")
        failSave = false
        type(canonical, "New Product", commit: true)
        expect(document.entries.count == countBeforeDraft + 1 && table.selectedRow == 2, "Valid draft commits and stays selected")
        click("dictionary-delete")
        expect(document.entries.count == countBeforeDraft && table.selectedRow == 1, "Delete selects adjacent term")
        click("dictionary-add")
        click("dictionary-delete")
        expect(document.entries.count == countBeforeDraft, "Unsaved draft can be discarded")
        table.deselectAll(nil)
        expect(!canonical.isEnabled && !(control("dictionary-delete", as: NSButton.self)).isEnabled, "Deselect disables destructive action")
        content.layoutSubtreeIfNeeded()
        let split: NSView = control("dictionary-split")
        expect(abs(split.frame.height - 400) < 1, "Dictionary split is 400 points high")
        expect(abs(search.superview!.frame.width - 200) < 1, "Dictionary sidebar is 200 points wide")
        var minimumFrame = controller.window!.frame
        minimumFrame.size.height = controller.window!.minSize.height
        controller.window!.setFrame(minimumFrame, display: false)
        content.layoutSubtreeIfNeeded()
        let splitRect = split.convert(split.bounds, to: content)
        expect(splitRect.minY >= 0 && splitRect.maxY <= content.bounds.height, "Split fits at Dictionary minimum window height")
        let recorder: ShortcutRecorderControl = control("shortcut-recorder")
        let help: NSTextField = control("shortcut-help")
        expect(recorder.toolTip == help.stringValue, "Shortcut accessibility help matches current shortcut")
        let newShortcut = ToggleShortcut(keyCode: 13, modifiers: ToggleShortcutModifiers.command)
        recorder.onCandidateChange?(newShortcut)
        expect(recorder.toolTip == newShortcut.copy.settingsHint && help.stringValue == newShortcut.copy.settingsHint, "Shortcut help refreshes immediately after saving")
        let general = controller.window!.toolbar!.items.first { $0.itemIdentifier.rawValue == "general" }!
        _ = NSApp.sendAction(general.action!, to: general.target, from: general)
        content.layoutSubtreeIfNeeded()
        let shortcutX = recorder.superview!.convert(recorder.alignmentRect(forFrame: recorder.frame), to: content).minX
        let generalPane: NSView = control("pane.general")
        expect(!generalPane.isHidden && find("section-general", in: content) == nil, "General has visible controls without obsolete heading")
        expect(recorder.frame.size == NSSize(width: 160, height: 24), "Shortcut recorder is compact")
        let recorderRect = recorder.convert(recorder.bounds, to: content)
        expect(abs(content.bounds.maxY - recorderRect.maxY - 22) < 1, "General starts directly with shortcut row at top padding")
        let registrationStatus: NSTextField = control("shortcut-status")
        expect(registrationStatus.font == MacUITokens.Typography.secondary, "Registration status uses caption typography")
        expect(recorder.accessibilityPerformPress() && recorder.isRecording, "Compact recorder retains direct capture")
        recorder.cancelRecording()
        expect(!recorder.isRecording && recorder.toolTip == help.stringValue, "Cancel restores shortcut status and accessibility help")
        for suffix in ["launch-at-login", "volatile-preview", "volatile-preview-help", "rerun-onboarding", "shortcut-help"] {
            let view: NSView = control(suffix)
            let controlX = view.superview!.convert(view.alignmentRect(forFrame: view.frame), to: content).minX
            expect(abs(controlX - shortcutX) < 1, "General alignment \(suffix): \(controlX), shortcut: \(shortcutX)")
        }
        for title in ["Launch at login:", "Recording HUD:", "Setup:"] {
            func labels(_ view: NSView) -> [NSTextField] {
                (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(labels)
            }
            let label = labels(content).first { $0.stringValue == title }!
            expect(label.alignment == .right && label.constraints.contains { $0.firstAttribute == .width && $0.constant == 180 }, "General form labels use 180-point right alignment")
        }
        try capture("settings-general")
        print("PASS dictionary-inline live-typing draft validation canonical aliases locale enabled search selection rollback geometry general-alignment shortcut-help")
    }
}
