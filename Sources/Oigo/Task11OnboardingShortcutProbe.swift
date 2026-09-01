import AppKit
import Foundation
import OigoCore
import OigoHotKey

struct Task11OnboardingShortcutRow: Codable {
    let action: String
    let stage: String
    let persistedShortcut: String
    let committedShortcut: String
    let recorderValue: String
    let recorderAccessibilityValue: String
    let continueEnabled: Bool
    let visibleContentContained: Bool
    let visibleButtons: [String]
    let visibleText: [String]
}

struct Task11OnboardingShortcutReceipt: Codable {
    let mode: String
    let rows: [Task11OnboardingShortcutRow]
    let captures: [String]
    let completedCount: Int
    let defaultsCleaned: Bool
}

@available(macOS 26.0, *)
@MainActor
enum Task11OnboardingShortcutProbe {
    static func run(mode: String, defaultsSuite: String, outputURL: URL) throws {
        guard ["all", "success", "failure"].contains(mode),
              defaultsSuite == "com.oigo.qa.task11",
              let defaults = UserDefaults(suiteName: defaultsSuite) else {
            throw Task11ProbeError.invalidInput
        }
        defaults.removePersistentDomain(forName: defaultsSuite)
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        NSApplication.shared.setActivationPolicy(.prohibited)

        var rows: [Task11OnboardingShortcutRow] = []
        var captures: [String] = []
        var completedCount = 0
        if mode != "failure" {
            let result = try runSuccess(defaults: defaults, evidenceRoot: outputURL.deletingLastPathComponent())
            rows.append(contentsOf: result.rows)
            captures.append(contentsOf: result.captures)
            completedCount += result.completedCount
        }
        if mode != "success" {
            let result = try runFailureAndRecovery(
                defaults: defaults,
                evidenceRoot: outputURL.deletingLastPathComponent()
            )
            rows.append(contentsOf: result.rows)
            captures.append(contentsOf: result.captures)
        }

        defaults.removePersistentDomain(forName: defaultsSuite)
        let receipt = Task11OnboardingShortcutReceipt(
            mode: mode,
            rows: rows,
            captures: captures,
            completedCount: completedCount,
            defaultsCleaned: defaults.persistentDomain(forName: defaultsSuite) == nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(receipt).write(to: outputURL, options: .atomic)
        print("PASS task-11-onboarding-probe mode=\(mode) rows=\(rows.count)")
    }

    private static func runSuccess(defaults: UserDefaults, evidenceRoot: URL) throws -> (
        rows: [Task11OnboardingShortcutRow], captures: [String], completedCount: Int
    ) {
        let old = ToggleShortcut(keyCode: 13, modifiers: ToggleShortcutModifiers.command)
        let candidate = ToggleShortcut(keyCode: 0, modifiers: ToggleShortcutModifiers.command)
        let harness = try Task11OnboardingHarness(defaults: defaults, committed: old)
        let onboarding = harness.makeController(initialStep: .system, accessibility: .granted)
        var rows = [harness.observe("stage-1", controller: onboarding)]
        var captures = [try capture(onboarding, name: "success-stage-1", root: evidenceRoot)]

        try click("Continue", in: onboarding)
        try pump("source-generation", until: { harness.sourceGeneration != nil })
        guard let sourceGeneration = harness.sourceGeneration else {
            throw Task11ProbeError.missingSourceGeneration
        }
        onboarding.applySourceProbeUpdate(OigoOnboardingSourceProbeUpdate(
            generation: sourceGeneration &+ 1,
            usedInput: .systemDefault,
            usedChannel: 0,
            acceptedCanonicalBuffer: true,
            signalHealth: .usable,
            meterLevel: 0.99
        ))
        rows.append(harness.observe("stale-source-ignored", controller: onboarding))
        onboarding.applySourceProbeUpdate(OigoOnboardingSourceProbeUpdate(
            generation: sourceGeneration,
            usedInput: .systemDefault,
            usedChannel: 0,
            acceptedCanonicalBuffer: true,
            signalHealth: .usable,
            meterLevel: 0.42
        ))
        try pump("languages-loaded", until: {
            harness.observe("language-loading", controller: onboarding).visibleText.contains {
                $0.contains("Speech assets:")
            }
        })
        try click("Install speech assets", in: onboarding)
        try pump("language-ready", until: { button("Continue", in: onboarding)?.isEnabled == true })
        rows.append(harness.observe("stage-2", controller: onboarding))
        captures.append(try capture(onboarding, name: "success-stage-2", root: evidenceRoot))

        try click("Continue", in: onboarding)
        rows.append(harness.observe("stage-3", controller: onboarding))
        try capture(candidate, in: onboarding)
        rows.append(harness.observe("candidate-selected", controller: onboarding))
        captures.append(try capture(onboarding, name: "success-stage-3-candidate", root: evidenceRoot))
        try click("Continue", in: onboarding)
        rows.append(harness.observe("stage-4", controller: onboarding))
        captures.append(try capture(onboarding, name: "success-stage-4", root: evidenceRoot))

        if button("Start test dictation", in: onboarding)?.isEnabled == true {
            try click("Start test dictation", in: onboarding)
            guard let generation = harness.testGeneration else {
                throw Task11ProbeError.missingTestGeneration
            }
            let sessionID = UUID()
            onboarding.bindTestSession(sessionID)
            guard let testField = view(in: onboarding, matching: {
                $0.identifier?.rawValue == "oigo.onboarding.test-field"
            }) as? NSTextField else {
                throw Task11ProbeError.missingControl
            }
            let insertedText = "Task eleven production path"
            testField.stringValue = insertedText
            onboarding.applyTestCompletion(
                generation: generation &+ 1,
                sessionID: sessionID,
                report: productionReport(sessionID: sessionID),
                selectedInsertionText: insertedText
            )
            rows.append(harness.observe("late-generation-ignored", controller: onboarding))
            onboarding.applyTestCompletion(
                generation: generation,
                sessionID: sessionID,
                report: productionReport(sessionID: sessionID),
                selectedInsertionText: insertedText
            )
            rows.append(harness.observe("test-passed", controller: onboarding))
            try click("Continue", in: onboarding)
            rows.append(harness.observe("done", controller: onboarding))
            captures.append(try capture(onboarding, name: "success-done", root: evidenceRoot))
            try click("Finish setup", in: onboarding)
        }

        let reopened = harness.makeController(
            initialStep: .shortcut,
            accessibility: .granted,
            committed: harness.settingsStore.load().globalShortcut
        )
        rows.append(harness.observe("reopen", controller: reopened))
        captures.append(try capture(reopened, name: "success-reopen", root: evidenceRoot))
        reopened.window?.close()
        return (rows, captures, harness.completedCount)
    }

    private static func runFailureAndRecovery(defaults: UserDefaults, evidenceRoot: URL) throws -> (
        rows: [Task11OnboardingShortcutRow], captures: [String]
    ) {
        let old = ToggleShortcut(keyCode: 13, modifiers: ToggleShortcutModifiers.command)
        let candidate = ToggleShortcut(keyCode: 0, modifiers: ToggleShortcutModifiers.command)
        var rows: [Task11OnboardingShortcutRow] = []
        var captures: [String] = []

        do {
            let harness = try Task11OnboardingHarness(defaults: defaults, committed: old)
            harness.registrar.failProbeFor = candidate
            let onboarding = harness.makeController(initialStep: .shortcut, accessibility: .granted)
            try capture(candidate, in: onboarding)
            rows.append(harness.observe("conflict", controller: onboarding))
            captures.append(try capture(onboarding, name: "failure-conflict", root: evidenceRoot))
            harness.registrar.failProbeFor = nil
            try capture(candidate, in: onboarding)
            rows.append(harness.observe("conflict-retry", controller: onboarding))
            try click("Continue", in: onboarding)
            rows.append(harness.observe("conflict-recovered", controller: onboarding))
            onboarding.window?.close()
        }

        do {
            let harness = try Task11OnboardingHarness(defaults: defaults, committed: old)
            let onboarding = harness.makeController(initialStep: .shortcut, accessibility: .granted)
            try beginRecording(in: onboarding)
            try sendKey(keyCode: 53, modifiers: [], to: onboarding)
            rows.append(harness.observe("cancel", controller: onboarding))
            try capture(candidate, in: onboarding)
            try beginRecording(in: onboarding)
            try sendKey(keyCode: 53, modifiers: [], to: onboarding)
            rows.append(harness.observe("cancel-resume", controller: onboarding))
            try beginRecording(in: onboarding)
            try sendKey(keyCode: 53, modifiers: [], to: onboarding)
            try sendKey(keyCode: 53, modifiers: [], to: onboarding)
            rows.append(harness.observe("repeated-interruption", controller: onboarding))
            try capture(candidate, in: onboarding)
            try click("Back", in: onboarding)
            rows.append(harness.observe("back", controller: onboarding))
            onboarding.window?.close()
        }

        do {
            let harness = try Task11OnboardingHarness(defaults: defaults, committed: old)
            let onboarding = harness.makeController(initialStep: .shortcut, accessibility: .granted)
            try capture(candidate, in: onboarding)
            onboarding.window?.close()
            let reopened = harness.makeController(
                initialStep: .shortcut,
                accessibility: .granted,
                committed: harness.settingsStore.load().globalShortcut
            )
            rows.append(harness.observe("close-reopen", controller: reopened))
            reopened.window?.close()
        }

        do {
            let harness = try Task11OnboardingHarness(defaults: defaults, committed: old)
            harness.persistenceFails = true
            let onboarding = harness.makeController(initialStep: .shortcut, accessibility: .granted)
            try capture(candidate, in: onboarding)
            try click("Continue", in: onboarding)
            rows.append(harness.observe("save-failed", controller: onboarding))
            captures.append(try capture(onboarding, name: "failure-save", root: evidenceRoot))
            onboarding.window?.close()
        }

        do {
            let harness = try Task11OnboardingHarness(defaults: defaults, committed: old)
            let onboarding = harness.makeController(initialStep: .shortcut, accessibility: .denied)
            try capture(candidate, in: onboarding)
            rows.append(harness.observe("copy-only-offered", controller: onboarding))
            captures.append(try capture(onboarding, name: "failure-copy-only-offered", root: evidenceRoot))
            try click("Continue with copy-only", in: onboarding)
            rows.append(harness.observe("copy-only-accepted", controller: onboarding))
            captures.append(try capture(onboarding, name: "failure-copy-only-accepted", root: evidenceRoot))
            try click("Continue", in: onboarding)
            rows.append(harness.observe("copy-only-advanced", controller: onboarding))
            onboarding.window?.close()
        }
        return (rows, captures)
    }

    private static func productionReport(sessionID: UUID) -> OigoOnboardingProductionReport {
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

    private static func capture(
        _ controller: OnboardingWindowController,
        name: String,
        root: URL
    ) throws -> String {
        guard let view = controller.window?.contentView else { throw Task11ProbeError.missingControl }
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
            throw Task11ProbeError.captureFailure
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
            throw Task11ProbeError.captureFailure
        }
        let output = captures.appendingPathComponent(name + ".png")
        try data.write(to: output, options: .atomic)
        return output.path
    }

    private static func click(_ title: String, in controller: OnboardingWindowController) throws {
        guard let control = button(title, in: controller), control.isEnabled else {
            throw Task11ProbeError.missingControl
        }
        control.performClick(nil)
        pumpEvents()
    }

    private static func capture(_ shortcut: ToggleShortcut, in controller: OnboardingWindowController) throws {
        try beginRecording(in: controller)
        var modifiers: NSEvent.ModifierFlags = []
        if shortcut.modifiers & ToggleShortcutModifiers.command != 0 { modifiers.insert(.command) }
        if shortcut.modifiers & ToggleShortcutModifiers.control != 0 { modifiers.insert(.control) }
        if shortcut.modifiers & ToggleShortcutModifiers.option != 0 { modifiers.insert(.option) }
        if shortcut.modifiers & ToggleShortcutModifiers.shift != 0 { modifiers.insert(.shift) }
        try sendKey(keyCode: UInt16(shortcut.keyCode), modifiers: modifiers, to: controller)
    }

    private static func beginRecording(in controller: OnboardingWindowController) throws {
        guard let recorder = view(in: controller, matching: { $0 is ShortcutRecorderControl })
            as? ShortcutRecorderControl else {
            throw Task11ProbeError.missingControl
        }
        recorder.beginRecording()
    }

    private static func sendKey(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        to controller: OnboardingWindowController
    ) throws {
        guard let recorder = view(in: controller, matching: { $0 is ShortcutRecorderControl })
            as? ShortcutRecorderControl,
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
            throw Task11ProbeError.missingControl
        }
        recorder.keyDown(with: event)
        pumpEvents()
    }

    private static func button(_ title: String, in controller: OnboardingWindowController) -> NSButton? {
        view(in: controller, matching: { ($0 as? NSButton)?.title == title }) as? NSButton
    }

    private static func view(
        in controller: OnboardingWindowController,
        matching predicate: (NSView) -> Bool
    ) -> NSView? {
        guard let root = controller.window?.contentView else { return nil }
        if predicate(root) { return root }
        for child in root.subviews {
            if let result = descendant(child, matching: predicate) { return result }
        }
        return nil
    }

    private static func descendant(_ view: NSView, matching predicate: (NSView) -> Bool) -> NSView? {
        if predicate(view) { return view }
        for child in view.subviews {
            if let result = descendant(child, matching: predicate) { return result }
        }
        return nil
    }

    private static func pump(_ label: String, until condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(1)
        while !condition(), Date() < deadline { pumpEvents() }
        guard condition() else { throw Task11ProbeError.asyncTimeout(label) }
    }

    private static func pumpEvents() {
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}

@available(macOS 26.0, *)
@MainActor
private final class Task11OnboardingHarness {
    let settingsStore: OigoSettingsStore
    let registrar = Task11ProbeRegistrar()
    let registration: AppShortcutRegistrationController
    var sourceGeneration: UInt64?
    var testGeneration: UInt64?
    var persistenceFails = false
    private(set) var completedCount = 0

    init(defaults: UserDefaults, committed: ToggleShortcut) throws {
        defaults.removePersistentDomain(forName: "com.oigo.qa.task11")
        settingsStore = OigoSettingsStore(defaults: defaults)
        try settingsStore.save(OigoSettings.default.with(globalShortcut: committed))
        registration = AppShortcutRegistrationController(
            committedShortcut: committed,
            registrar: registrar,
            onRegisteredEvent: { _ in }
        )
    }

    func makeController(
        initialStep: OigoOnboardingStep,
        accessibility: OigoPermissionState,
        committed: ToggleShortcut? = nil
    ) -> OnboardingWindowController {
        let displayed = committed ?? registration.committedShortcut
        return OnboardingWindowController(
            support: .init(isSupported: true, reason: "This Mac is supported"),
            initialStep: initialStep,
            processingMode: .instant,
            globalShortcut: displayed,
            inputDevices: [],
            selectedInput: .systemDefault,
            selectedInputChannel: 0,
            committedLocaleIdentifier: "en-US",
            microphoneState: .granted,
            accessibilityState: accessibility,
            storageHealth: .ready(.init(recoveredSessionCount: 0, historyEntryCount: 0, malformedSessionCount: 0)),
            loadSupportedLanguages: { ["en-US"] },
            checkSpeechAssets: { _ in .ready },
            saveLanguage: { _ in },
            saveStep: { _, _ in },
            saveInputSelection: { _, _ in },
            requestMicrophone: { .granted },
            openMicrophoneSettings: {},
            registrationStatus: { [registration] in registration.registrationStatus },
            registrationError: { [registration] in registration.lastError },
            validateShortcut: { [registration] candidate in
                registration.setCandidate(candidate)
                return registration.validate(candidate)
            },
            saveShortcut: { [weak self] candidate in
                guard let self else { return .invalid("Probe unavailable") }
                let previous = settingsStore.load()
                return registration.save(
                    candidate,
                    persist: { shortcut in
                        if self.persistenceFails { throw Task11ProbeError.persistenceFailure }
                        try self.settingsStore.save(previous.with(globalShortcut: shortcut))
                    },
                    restore: { try self.settingsStore.save(previous) }
                )
            },
            requestAccessibility: { accessibility },
            openAccessibilitySettings: {},
            retryStorage: {},
            openDataLocation: {},
            startSourceProbe: { [weak self] _, _, generation in self?.sourceGeneration = generation },
            stopSourceProbe: {},
            startTest: { [weak self] generation in self?.testGeneration = generation },
            stopTest: {},
            cancelTest: {},
            openHistory: {},
            onComplete: { [weak self] in self?.completedCount += 1 },
            onClose: {}
        )
    }

    func observe(_ action: String, controller: OnboardingWindowController) -> Task11OnboardingShortcutRow {
        let views = allViews(controller.window?.contentView)
        let visibleText = views.compactMap { view -> String? in
            guard !view.isHidden else { return nil }
            if let field = view as? NSTextField, !field.stringValue.isEmpty { return field.stringValue }
            return nil
        }
        let recorder = views.first { $0 is ShortcutRecorderControl } as? ShortcutRecorderControl
        let continueButton = views.first {
            guard let button = $0 as? NSButton else { return false }
            return button.title == "Continue" || button.title == "Finish setup"
        } as? NSButton
        let root = controller.window?.contentView
        let contained = root.map { root in
            views.filter { view in
                !isEffectivelyHidden(view) && (view is NSControl || view is NSTextField)
            }.allSatisfy { view in
                root.bounds.insetBy(dx: -0.5, dy: -0.5).contains(root.convert(view.bounds, from: view))
            }
        } ?? false
        return Task11OnboardingShortcutRow(
            action: action,
            stage: visibleText.first(where: { $0.hasPrefix("Stage ") || $0 == "Setup complete" }) ?? "unknown",
            persistedShortcut: settingsStore.load().globalShortcut.copy.displayName,
            committedShortcut: registration.committedShortcut.copy.displayName,
            recorderValue: recorder?.displayValue ?? "missing",
            recorderAccessibilityValue: recorder?.accessibilityValue() as? String ?? "missing",
            continueEnabled: continueButton?.isEnabled == true,
            visibleContentContained: contained,
            visibleButtons: views.compactMap { view in
                guard let button = view as? NSButton, !button.isHidden else { return nil }
                return button.title
            },
            visibleText: visibleText
        )
    }

    private func allViews(_ root: NSView?) -> [NSView] {
        guard let root else { return [] }
        return [root] + root.subviews.flatMap(allViews)
    }

    private func isEffectivelyHidden(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let candidate = current {
            if candidate.isHidden { return true }
            current = candidate.superview
        }
        return false
    }
}

@MainActor
private final class Task11ProbeRegistrar: GlobalShortcutRegistrationClient {
    var status: GlobalShortcutRegistrationStatus = .inactive("Global shortcut registration is waiting for setup")
    var lastError: String?
    var failProbeFor: ToggleShortcut?
    private var generation: UInt64 = 0

    func register(shortcut: ToggleShortcut, onEvent: @escaping @MainActor (GlobalShortcutEvent) -> Void) throws {
        _ = onEvent
        if failProbeFor == shortcut { throw Task11ProbeRegistrationError() }
        generation &+= 1
        status = .active(shortcut, generation: generation)
        lastError = nil
    }

    func probe(shortcut: ToggleShortcut) throws {
        if failProbeFor == shortcut {
            lastError = "Shortcut conflicts with another app"
            throw Task11ProbeRegistrationError()
        }
        lastError = nil
    }

    func unregister() throws {
        status = .inactive("Global shortcut registration is waiting for setup")
    }
}

private enum Task11ProbeError: Error {
    case invalidInput
    case missingControl
    case missingSourceGeneration
    case missingTestGeneration
    case asyncTimeout(String)
    case persistenceFailure
    case captureFailure
}

private struct Task11ProbeRegistrationError: Error, CustomStringConvertible {
    var description: String { "Shortcut conflicts with another app" }
}
