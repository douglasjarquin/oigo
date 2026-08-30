import AppKit
import Foundation
import OigoCore
import OigoHotKey

struct Task12SettingsShortcutRow: Codable {
    let action: String
    let ownerIdentity: String
    let persistedShortcut: String
    let committedShortcut: String
    let recorderValue: String
    let recorderAccessibilityValue: String
    let message: String
    let status: String
    let hint: String
    let localeIdentifier: String
    let previewEnabled: Bool
    let registrationActive: Bool
    let accessibilityText: [String]
    let actionIdentifiers: [String]
    let unidentifiedActionCount: Int
    let navigationCenteredIconAndLabel: Bool
}

struct Task12SettingsShortcutReceipt: Codable {
    let mode: String
    let rows: [Task12SettingsShortcutRow]
    let captures: [String]
    let shortcutSaveCount: Int
    let settingsSaveCount: Int
    let appDelegateValidationCount: Int
    let appDelegateShortcutSaveCount: Int
    let appDelegateSettingsSaveCount: Int
    let defaultsCleaned: Bool
}

private typealias Task12SettingsShortcutResult = (
    rows: [Task12SettingsShortcutRow],
    captures: [String],
    shortcutSaveCount: Int,
    settingsSaveCount: Int,
    appDelegateValidationCount: Int,
    appDelegateShortcutSaveCount: Int,
    appDelegateSettingsSaveCount: Int
)

@available(macOS 26.0, *)
@MainActor
enum Task12SettingsShortcutProbe {
    static func run(mode: String, defaultsSuite: String, outputURL: URL) throws {
        guard ["all", "success", "failure"].contains(mode),
              defaultsSuite == "com.oigo.qa.task12",
              let defaults = UserDefaults(suiteName: defaultsSuite) else {
            throw Task12ProbeError.invalidInput
        }
        defaults.removePersistentDomain(forName: defaultsSuite)
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        NSApplication.shared.setActivationPolicy(.prohibited)

        var rows: [Task12SettingsShortcutRow] = []
        var captures: [String] = []
        var shortcutSaveCount = 0
        var settingsSaveCount = 0
        var appDelegateValidationCount = 0
        var appDelegateShortcutSaveCount = 0
        var appDelegateSettingsSaveCount = 0
        if mode != "failure" {
            let result = try runSuccess(defaults: defaults, evidenceRoot: outputURL.deletingLastPathComponent())
            rows.append(contentsOf: result.rows)
            captures.append(contentsOf: result.captures)
            shortcutSaveCount += result.shortcutSaveCount
            settingsSaveCount += result.settingsSaveCount
            appDelegateValidationCount += result.appDelegateValidationCount
            appDelegateShortcutSaveCount += result.appDelegateShortcutSaveCount
            appDelegateSettingsSaveCount += result.appDelegateSettingsSaveCount
        }
        if mode != "success" {
            let result = try runFailures(defaults: defaults, evidenceRoot: outputURL.deletingLastPathComponent())
            rows.append(contentsOf: result.rows)
            captures.append(contentsOf: result.captures)
            shortcutSaveCount += result.shortcutSaveCount
            settingsSaveCount += result.settingsSaveCount
            appDelegateValidationCount += result.appDelegateValidationCount
            appDelegateShortcutSaveCount += result.appDelegateShortcutSaveCount
            appDelegateSettingsSaveCount += result.appDelegateSettingsSaveCount
        }

        defaults.removePersistentDomain(forName: defaultsSuite)
        let receipt = Task12SettingsShortcutReceipt(
            mode: mode,
            rows: rows,
            captures: captures,
            shortcutSaveCount: shortcutSaveCount,
            settingsSaveCount: settingsSaveCount,
            appDelegateValidationCount: appDelegateValidationCount,
            appDelegateShortcutSaveCount: appDelegateShortcutSaveCount,
            appDelegateSettingsSaveCount: appDelegateSettingsSaveCount,
            defaultsCleaned: defaults.persistentDomain(forName: defaultsSuite) == nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(receipt).write(to: outputURL, options: .atomic)
        print("PASS task-12-settings-shortcut-probe mode=\(mode) rows=\(rows.count)")
    }

    private static func runSuccess(
        defaults: UserDefaults,
        evidenceRoot: URL
    ) throws -> Task12SettingsShortcutResult {
        let old = ToggleShortcut(keyCode: 13, modifiers: ToggleShortcutModifiers.command)
        let candidate = ToggleShortcut(keyCode: 0, modifiers: ToggleShortcutModifiers.command)
        let harness = try Task12SettingsHarness(defaults: defaults, seed: settings(shortcut: old))
        try harness.activate()
        let controller = harness.makeController()
        try capture(candidate, in: controller)
        guard let beforeShortcutSaveState = harness.appDelegate.settingsShortcutPreSaveState else {
            throw Task12ProbeError.missingControl("before-shortcut-save")
        }
        let beforeSave = harness.observe(
            "before-shortcut-save",
            controller: controller,
            ownerState: beforeShortcutSaveState
        )
        var rows = [beforeSave, harness.observe("saved", controller: controller)]
        guard harness.saveRequestedSettings(
            settings(shortcut: old).with(showVolatilePreview: true)
        ) == nil else {
            throw Task12ProbeError.persistenceFailure
        }
        rows.append(harness.observe("stale-state", controller: controller))
        var captures = [try capture(controller, name: "success-saved", root: evidenceRoot)]
        controller.window?.close()

        let reopened = harness.makeController()
        rows.append(harness.observe("reopen", controller: reopened))
        captures.append(try capture(reopened, name: "success-reopen", root: evidenceRoot))
        reopened.window?.close()

        let relaunched = try Task12SettingsHarness(defaults: defaults, seed: nil)
        try relaunched.activate()
        let relaunchedController = relaunched.makeController()
        rows.append(relaunched.observe("relaunch", controller: relaunchedController))
        try click("oigo.settings.volatile-preview", in: relaunchedController)
        rows.append(relaunched.observe("unrelated-save", controller: relaunchedController))
        captures.append(try capture(relaunchedController, name: "success-unrelated-save", root: evidenceRoot))

        try beginRecording(in: relaunchedController)
        try sendKey(keyCode: 53, modifiers: [], to: relaunchedController)
        try beginRecording(in: relaunchedController)
        try sendKey(keyCode: 53, modifiers: [], to: relaunchedController)
        rows.append(relaunched.observe("cancel-resume", controller: relaunchedController))
        try beginRecording(in: relaunchedController)
        try sendKey(keyCode: 53, modifiers: [], to: relaunchedController)
        try sendKey(keyCode: 53, modifiers: [], to: relaunchedController)
        rows.append(relaunched.observe("repeated-interruption", controller: relaunchedController))
        relaunchedController.window?.close()
        return (
            rows,
            captures,
            harness.shortcutSaveCount + relaunched.shortcutSaveCount,
            harness.settingsSaveCount + relaunched.settingsSaveCount,
            harness.appDelegateValidationCount + relaunched.appDelegateValidationCount,
            harness.appDelegateShortcutSaveCount + relaunched.appDelegateShortcutSaveCount,
            harness.appDelegateSettingsSaveCount + relaunched.appDelegateSettingsSaveCount
        )
    }

    private static func runFailures(
        defaults: UserDefaults,
        evidenceRoot: URL
    ) throws -> Task12SettingsShortcutResult {
        let old = ToggleShortcut(keyCode: 13, modifiers: ToggleShortcutModifiers.command)
        let candidate = ToggleShortcut(keyCode: 0, modifiers: ToggleShortcutModifiers.command)
        var rows: [Task12SettingsShortcutRow] = []
        var captures: [String] = []
        var shortcutSaveCount = 0
        var settingsSaveCount = 0
        var appDelegateValidationCount = 0
        var appDelegateShortcutSaveCount = 0
        var appDelegateSettingsSaveCount = 0

        do {
            let harness = try Task12SettingsHarness(defaults: defaults, seed: settings(shortcut: old))
            try harness.activate()
            harness.conflictingShortcut = candidate
            let controller = harness.makeController()
            try capture(candidate, in: controller)
            rows.append(harness.observe("conflict", controller: controller))
            captures.append(try capture(controller, name: "failure-conflict", root: evidenceRoot))
            shortcutSaveCount += harness.shortcutSaveCount
            settingsSaveCount += harness.settingsSaveCount
            appDelegateValidationCount += harness.appDelegateValidationCount
            appDelegateShortcutSaveCount += harness.appDelegateShortcutSaveCount
            appDelegateSettingsSaveCount += harness.appDelegateSettingsSaveCount
            controller.window?.close()
        }

        do {
            let harness = try Task12SettingsHarness(defaults: defaults, seed: settings(shortcut: old))
            try harness.activate()
            harness.persistenceFailuresRemaining = 1
            let controller = harness.makeController()
            try capture(candidate, in: controller)
            rows.append(harness.observe("persistence-failure", controller: controller))
            captures.append(try capture(controller, name: "failure-persistence", root: evidenceRoot))
            shortcutSaveCount += harness.shortcutSaveCount
            settingsSaveCount += harness.settingsSaveCount
            appDelegateValidationCount += harness.appDelegateValidationCount
            appDelegateShortcutSaveCount += harness.appDelegateShortcutSaveCount
            appDelegateSettingsSaveCount += harness.appDelegateSettingsSaveCount
            controller.window?.close()
        }

        do {
            let harness = try Task12SettingsHarness(defaults: defaults, seed: settings(shortcut: old))
            try harness.activate()
            harness.persistenceFailuresRemaining = 2
            let controller = harness.makeController()
            try capture(candidate, in: controller)
            rows.append(harness.observe("rollback-failure", controller: controller))
            captures.append(try capture(controller, name: "failure-rollback", root: evidenceRoot))
            shortcutSaveCount += harness.shortcutSaveCount
            settingsSaveCount += harness.settingsSaveCount
            appDelegateValidationCount += harness.appDelegateValidationCount
            appDelegateShortcutSaveCount += harness.appDelegateShortcutSaveCount
            appDelegateSettingsSaveCount += harness.appDelegateSettingsSaveCount
            controller.window?.close()
        }

        do {
            let harness = try Task12SettingsHarness(defaults: defaults, seed: settings(shortcut: old))
            try harness.activate()
            harness.persistenceFailuresRemaining = 1
            let controller = harness.makeController()
            try click("oigo.settings.volatile-preview", in: controller)
            rows.append(harness.observe("unrelated-save-failure", controller: controller))
            captures.append(try capture(controller, name: "failure-unrelated-save", root: evidenceRoot))
            shortcutSaveCount += harness.shortcutSaveCount
            settingsSaveCount += harness.settingsSaveCount
            appDelegateValidationCount += harness.appDelegateValidationCount
            appDelegateShortcutSaveCount += harness.appDelegateShortcutSaveCount
            appDelegateSettingsSaveCount += harness.appDelegateSettingsSaveCount
            controller.window?.close()
        }
        return (
            rows,
            captures,
            shortcutSaveCount,
            settingsSaveCount,
            appDelegateValidationCount,
            appDelegateShortcutSaveCount,
            appDelegateSettingsSaveCount
        )
    }

    private static func settings(shortcut: ToggleShortcut) -> OigoSettings {
        OigoSettings.default.with(globalShortcut: shortcut, localeIdentifier: "en-US")
    }

    private static func click(_ identifier: String, in controller: SettingsWindowController) throws {
        guard let button = allViews(controller.window?.contentView).first(where: {
            $0.identifier?.rawValue == identifier
        }) as? NSButton else {
            throw Task12ProbeError.missingControl(identifier)
        }
        button.performClick(nil)
        pumpEvents()
    }

    private static func capture(_ shortcut: ToggleShortcut, in controller: SettingsWindowController) throws {
        try beginRecording(in: controller)
        var modifiers: NSEvent.ModifierFlags = []
        if shortcut.modifiers & ToggleShortcutModifiers.command != 0 { modifiers.insert(.command) }
        if shortcut.modifiers & ToggleShortcutModifiers.control != 0 { modifiers.insert(.control) }
        if shortcut.modifiers & ToggleShortcutModifiers.option != 0 { modifiers.insert(.option) }
        if shortcut.modifiers & ToggleShortcutModifiers.shift != 0 { modifiers.insert(.shift) }
        try sendKey(keyCode: UInt16(shortcut.keyCode), modifiers: modifiers, to: controller)
    }

    private static func beginRecording(in controller: SettingsWindowController) throws {
        guard let recorder = allViews(controller.window?.contentView).first(where: {
            $0.identifier?.rawValue == "oigo.settings.shortcut-recorder"
        }) as? ShortcutRecorderControl else {
            throw Task12ProbeError.missingControl("shortcut-recorder")
        }
        recorder.beginRecording()
    }

    private static func sendKey(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        to controller: SettingsWindowController
    ) throws {
        guard let recorder = allViews(controller.window?.contentView).first(where: {
            $0.identifier?.rawValue == "oigo.settings.shortcut-recorder"
        }) as? ShortcutRecorderControl,
              let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "x",
                charactersIgnoringModifiers: "x",
                isARepeat: false,
                keyCode: keyCode
              ) else {
            throw Task12ProbeError.missingControl("shortcut-recorder")
        }
        recorder.keyDown(with: event)
        pumpEvents()
    }

    private static func capture(
        _ controller: SettingsWindowController,
        name: String,
        root: URL
    ) throws -> String {
        guard let contentView = controller.window?.contentView else {
            throw Task12ProbeError.missingControl("content-view")
        }
        let view = contentView.superview ?? contentView
        let captures = root.appendingPathComponent("captures", isDirectory: true)
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        view.layoutSubtreeIfNeeded()
        let scale = controller.window?.backingScaleFactor ?? 2
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width * scale),
            pixelsHigh: Int(view.bounds.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw Task12ProbeError.captureFailure
        }
        bitmap.size = view.bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        NSColor.windowBackgroundColor.setFill()
        view.bounds.fill()
        view.displayIgnoringOpacity(view.bounds, in: context)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw Task12ProbeError.captureFailure
        }
        let output = captures.appendingPathComponent(name + ".png")
        try data.write(to: output, options: .atomic)
        return output.path
    }

    fileprivate static func allViews(_ root: NSView?) -> [NSView] {
        guard let root else { return [] }
        return [root] + root.subviews.flatMap(allViews)
    }

    private static func pumpEvents() {
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}

@available(macOS 26.0, *)
@MainActor
private final class Task12SettingsHarness {
    private let externalFailures: Task12ExternalFailures
    let appDelegate: OigoAppDelegate

    var persistenceFailuresRemaining: Int {
        get { externalFailures.persistenceFailuresRemaining }
        set { externalFailures.persistenceFailuresRemaining = newValue }
    }

    var conflictingShortcut: ToggleShortcut? {
        get { externalFailures.conflictingShortcut }
        set { externalFailures.conflictingShortcut = newValue }
    }

    var shortcutSaveCount: Int {
        appDelegate.settingsShortcutCallbackCounts.shortcutSave
    }

    var settingsSaveCount: Int {
        appDelegate.settingsShortcutCallbackCounts.settingsSave
    }

    var appDelegateValidationCount: Int {
        appDelegate.settingsShortcutCallbackCounts.validation
    }

    var appDelegateShortcutSaveCount: Int {
        appDelegate.settingsShortcutCallbackCounts.shortcutSave
    }

    var appDelegateSettingsSaveCount: Int {
        appDelegate.settingsShortcutCallbackCounts.settingsSave
    }

    init(defaults: UserDefaults, seed: OigoSettings?) throws {
        if seed != nil {
            defaults.removePersistentDomain(forName: "com.oigo.qa.task12")
        }
        let externalFailures = Task12ExternalFailures()
        self.externalFailures = externalFailures
        appDelegate = try OigoAppDelegate.makeSettingsShortcutProbe(
            defaults: defaults,
            seed: seed,
            writeSettingsData: { data in
                if externalFailures.persistenceFailuresRemaining > 0 {
                    externalFailures.persistenceFailuresRemaining -= 1
                    throw Task12ProbeError.persistenceFailure
                }
                defaults.set(data, forKey: "oigo.settings.v1")
            },
            registerShortcut: { _ in },
            probeShortcut: { shortcut in
                if shortcut == externalFailures.conflictingShortcut {
                    throw Task12ProbeError.registrationConflict
                }
            },
            unregisterShortcut: {}
        )
    }

    func activate() throws {
        try appDelegate.activateSettingsShortcutOwnerForTesting()
    }

    func makeController() -> SettingsWindowController {
        let controller = appDelegate.presentSettings(supportedLocales: ["en-US"])
        controller.window?.layoutIfNeeded()
        return controller
    }

    func observe(
        _ action: String,
        controller: SettingsWindowController,
        ownerState: OigoSettingsShortcutOwnerState? = nil
    ) -> Task12SettingsShortcutRow {
        let shortcutOwner = appDelegate.settingsShortcutOwnerBundle()
        let ownerState = ownerState ?? shortcutOwner.state()
        let views = Task12SettingsShortcutProbe.allViews(controller.window?.contentView)
        let recorder = views.first { $0.identifier?.rawValue == "oigo.settings.shortcut-recorder" }
            as? ShortcutRecorderControl
        let message = text("oigo.settings.save-message", in: views)
        let status = text("oigo.settings.shortcut-status", in: views)
        let hint = text("oigo.settings.shortcut-help", in: views)
        let preview = views.first { $0.identifier?.rawValue == "oigo.settings.volatile-preview" }
            as? NSButton
        let actionable = views.compactMap { view -> NSControl? in
            guard let control = view as? NSControl,
                  control.action != nil,
                  control.target === controller else { return nil }
            return control
        }
        let identifiers = actionable.compactMap { $0.identifier?.rawValue }
            + [recorder?.identifier?.rawValue].compactMap { $0 }
        let unidentified = actionable.filter { $0.identifier?.rawValue.isEmpty != false }.count
            + (recorder?.identifier?.rawValue.isEmpty == false ? 0 : 1)
        let toolbar = controller.window?.toolbar
        let toolbarItems = toolbar?.items ?? []
        let toolbarIdentifiers = toolbarItems.map { $0.itemIdentifier.rawValue }
        let navigation = toolbar?.displayMode == .iconAndLabel
            && controller.window?.toolbarStyle == .preference
            && Set(toolbarIdentifiers) == Set(OigoSettingsPane.allCases.map(\.rawValue))
            && toolbarItems.allSatisfy { !$0.label.isEmpty && $0.image != nil && $0.action != nil }
        return Task12SettingsShortcutRow(
            action: action,
            ownerIdentity: ownerState.ownerIdentity,
            persistedShortcut: ownerState.persistedSettings.globalShortcut.copy.displayName,
            committedShortcut: ownerState.committedShortcut.copy.displayName,
            recorderValue: recorder?.displayValue ?? "missing",
            recorderAccessibilityValue: recorder?.accessibilityValue() as? String ?? "missing",
            message: message,
            status: status,
            hint: hint,
            localeIdentifier: ownerState.persistedSettings.localeIdentifier,
            previewEnabled: preview?.state == .on,
            registrationActive: ownerState.registrationActive,
            accessibilityText: accessibilityText(views).sorted(),
            actionIdentifiers: (identifiers + toolbarIdentifiers).sorted(),
            unidentifiedActionCount: unidentified,
            navigationCenteredIconAndLabel: navigation
        )
    }

    func saveRequestedSettings(_ requested: OigoSettings) -> String? {
        appDelegate.settingsShortcutOwnerBundle().callbacks.saveSettings(requested)
    }

    private func text(_ identifier: String, in views: [NSView]) -> String {
        (views.first { $0.identifier?.rawValue == identifier } as? NSTextField)?.stringValue ?? ""
    }

    private func accessibilityText(_ views: [NSView]) -> [String] {
        views.flatMap { view -> [String] in
            var values: [String] = []
            if let label = view.accessibilityLabel(), !label.isEmpty { values.append(label) }
            if let value = view.accessibilityValue() as? String, !value.isEmpty { values.append(value) }
            if let field = view as? NSTextField, !field.stringValue.isEmpty { values.append(field.stringValue) }
            if let button = view as? NSButton, !button.title.isEmpty { values.append(button.title) }
            return values
        }
    }
}

private final class Task12ExternalFailures: @unchecked Sendable {
    var persistenceFailuresRemaining = 0
    var conflictingShortcut: ToggleShortcut?
}

private enum Task12ProbeError: Error, CustomStringConvertible {
    case invalidInput
    case missingControl(String)
    case persistenceFailure
    case registrationConflict
    case captureFailure

    var description: String {
        switch self {
        case .invalidInput: "invalid input"
        case .missingControl(let identifier): "missing control: " + identifier
        case .persistenceFailure: "simulated settings persistence failure"
        case .registrationConflict: "shortcut conflicts with another app"
        case .captureFailure: "capture failed"
        }
    }
}
