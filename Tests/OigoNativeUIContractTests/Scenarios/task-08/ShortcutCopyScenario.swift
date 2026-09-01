import AppKit
import Foundation
import OigoCore
import OigoHotKey
import OigoPresentation

final class ShortcutCopyScenario: NativeUIContractScenario {
    private struct Fixture: Decodable {
        let shortcut: ToggleShortcut
        let expectedDisplayName: String
        let expectedCompactName: String
        let expectedAccessibilityLabel: String
        let expectedHoldHint: String
        let expectedInactiveHint: String
        let expectedReleaseHint: String
    }

    private struct Receipt: Encodable {
        let fixture: String
        let displayName: String
        let compactName: String
        let accessibilityLabel: String
        let holdHint: String
        let inactiveHint: String
        let releaseHint: String
        let popoverGlyphs: [String]
        let popoverActive: PopoverObservation
        let popoverConflict: PopoverObservation
        let nativeConsumers: ConsumerReceipt
        let gallery: GalleryReceipt
        let conflictNoticeActionable: Bool
        let mouseStartEnabled: Bool
        let keyboardAvailable: Bool
    }

    private struct PopoverObservation: Codable {
        let shortcutAccessibilityLabel: String
        let primaryTitle: String
        let primaryEnabled: Bool
        let noticeActionTitle: String?
        let noticeActionEnabled: Bool
    }

    private struct ControlObservation: Codable {
        let status: String
        let hint: String
        let recorderDisplay: String
        let recorderAccessibilityValue: String
    }

    private struct HUDObservation: Codable {
        let title: String
        let detail: String
        let accessibilityLabel: String
        let visible: Bool
    }

    private struct StatusObservation: Codable {
        let title: String
        let toolTip: String
        let menuTitle: String
        let accessibilityLabel: String
    }

    private struct ConsumerReceipt: Codable {
        let shortcut: ToggleShortcut
        let hud: HUDObservation
        let onboardingActive: ControlObservation
        let onboardingConflict: ControlObservation
        let settingsActive: ControlObservation
        let settingsConflict: ControlObservation
        let statusActive: StatusObservation
        let statusError: StatusObservation
        let statusConflict: StatusObservation
    }

    private struct GalleryObservation: Codable {
        let row: String
        let shortcutText: String
        let shortcutAccessibilityLabel: String
        let primaryTitle: String
        let mouseStartEnabled: Bool
        let keyboardAvailable: Bool
        let noticeText: String?
        let noticeActionTitle: String?
        let noticeActionable: Bool
    }

    private struct GalleryReceipt: Codable {
        let shortcut: ToggleShortcut
        let selectedRow: String
        let observations: [GalleryObservation]
    }

    override class var scenarioName: String {
        "shortcut-copy"
    }

    override class func run(arguments: ContractArguments) throws {
        guard arguments.defaultsSuite == "com.oigo.qa.task08" else {
            throw ContractInputError(category: "invalid-defaults-suite")
        }
        let fixtures = try loadFixtures(from: arguments.fixtureRoot)
        try buildRuntimeProducts()
        var receipts: [Receipt] = []
        for (name, fixture) in fixtures {
            let fixtureRoot = arguments.fixtureRoot.appendingPathComponent(name, isDirectory: true)
            let actualFixtureRoot = FileManager.default.fileExists(
                atPath: arguments.fixtureRoot.appendingPathComponent("fixture.json").path
            ) ? arguments.fixtureRoot : fixtureRoot
            let receipt = try exercise(
                name: name,
                fixture: fixture,
                fixtureRoot: actualFixtureRoot,
                evidenceRoot: arguments.evidenceRoot,
                defaultsSuite: arguments.defaultsSuite
            )
            receipts.append(receipt)
            print(
                "COPY fixture=\(name) display=\(receipt.displayName) compact=\(receipt.compactName) "
                    + "accessibility=\(receipt.accessibilityLabel) hold=\(receipt.holdHint) "
                    + "inactive=\(receipt.inactiveHint) release=\(receipt.releaseHint)"
            )
        }
        try validateConsumerSources()
        try write(receipts: receipts, to: arguments.evidenceRoot)
        print("PASS shortcut-copy fixtures=\(receipts.count) surfaces=popover,hud,onboarding,settings,errors,hints,tooltips,accessibility")
    }

    private static func loadFixtures(from root: URL) throws -> [(String, Fixture)] {
        let direct = root.appendingPathComponent("fixture.json")
        let roots = FileManager.default.fileExists(atPath: direct.path)
            ? [root]
            : ["success", "failure"].map { root.appendingPathComponent($0, isDirectory: true) }
        return try roots.map { fixtureRoot in
            let fixtureURL = fixtureRoot.appendingPathComponent("fixture.json")
            guard let data = try? Data(contentsOf: fixtureURL) else {
                throw ContractInputError(category: "missing-committed-shortcut")
            }
            let fixture: Fixture
            do {
                fixture = try JSONDecoder().decode(Fixture.self, from: data)
            } catch {
                throw ContractInputError(category: "malformed-shortcut-fixture")
            }
            let shortcut = fixture.shortcut
            guard shortcut.modifiers & ToggleShortcutModifiers.supportedMask != 0,
                  shortcut.modifiers & ~ToggleShortcutModifiers.supportedMask == 0 else {
                throw ContractInputError(category: "unsupported-shortcut-fixture")
            }
            return (fixtureRoot.lastPathComponent, fixture)
        }
    }

    private static func exercise(
        name: String,
        fixture: Fixture,
        fixtureRoot: URL,
        evidenceRoot: URL,
        defaultsSuite: String
    ) throws -> Receipt {
        let shortcut = fixture.shortcut
        let displayName = OigoShortcutPresentation.displayName(for: shortcut)
        let compactName = ShortcutFormatter.displayName(for: shortcut)
        let input = presentationInputs(shortcut: shortcut, registration: .registered)
        let state = OigoPresentationState.project(input)
        let popover = OigoPopoverPresentation.compose(state: state, inputs: input)
        let holdHint = popover.shortcut.holdHint
        let releaseHint = shortcut.copy.releaseHint
        let conflictInputs = presentationInputs(shortcut: shortcut, registration: .conflict)
        let conflictState = OigoPresentationState.project(conflictInputs)
        let conflict = OigoPopoverPresentation.compose(state: conflictState, inputs: conflictInputs)
        guard displayName == fixture.expectedDisplayName,
              compactName == fixture.expectedCompactName,
              popover.shortcut.accessibilityLabel == fixture.expectedAccessibilityLabel,
              holdHint == fixture.expectedHoldHint,
              conflict.shortcut.inactiveHint == fixture.expectedInactiveHint,
              releaseHint == fixture.expectedReleaseHint else {
            throw ContractInputError(category: "shortcut-copy-mismatch")
        }

        guard conflict.notice?.action.isEnabled == true,
              conflict.notice?.action.action == .openSettings,
              conflict.primaryAction.isEnabled,
              conflict.primaryAction.action == .startDictation,
              !conflict.shortcut.isAvailable else {
            throw ContractInputError(category: "shortcut-conflict-contract")
        }
        let popoverActive = try renderedPopoverObservation(popover)
        let popoverConflict = try renderedPopoverObservation(conflict)
        let runtimeRoot = evidenceRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        let nativeConsumers = try observeNativeConsumers(
            fixtureRoot: fixtureRoot,
            outputRoot: runtimeRoot
        )
        let gallery = try observeGallery(
            fixtureRoot: fixtureRoot,
            outputRoot: runtimeRoot.appendingPathComponent("gallery", isDirectory: true),
            defaultsSuite: defaultsSuite
        )
        guard nativeConsumers.shortcut == shortcut,
              nativeConsumers.hud.visible,
              nativeConsumers.hud.detail == fixture.expectedReleaseHint,
              nativeConsumers.hud.accessibilityLabel.contains(fixture.expectedReleaseHint),
              [nativeConsumers.onboardingActive, nativeConsumers.settingsActive].allSatisfy({
                  $0.status.contains(fixture.expectedDisplayName)
                      && $0.recorderDisplay == fixture.expectedCompactName
                      && $0.recorderAccessibilityValue == fixture.expectedCompactName
              }),
              [nativeConsumers.onboardingConflict, nativeConsumers.settingsConflict].allSatisfy({
                  $0.status.contains(fixture.expectedDisplayName)
                      && $0.recorderAccessibilityValue == fixture.expectedCompactName
              }),
              nativeConsumers.settingsActive.hint.contains(fixture.expectedDisplayName),
              nativeConsumers.statusActive.title.contains(fixture.expectedDisplayName),
              nativeConsumers.statusActive.menuTitle.contains(fixture.expectedDisplayName),
              nativeConsumers.statusActive.toolTip.contains(fixture.expectedDisplayName),
              nativeConsumers.statusError.title == "Fn Dictation Active - Open Settings…",
              nativeConsumers.statusError.menuTitle == nativeConsumers.statusError.title,
              nativeConsumers.statusError.toolTip.contains(fixture.expectedDisplayName),
              nativeConsumers.statusError.toolTip.contains("Synthetic registration warning"),
              nativeConsumers.statusConflict.title == "Fn Dictation Unavailable - Open Settings…",
              nativeConsumers.statusConflict.menuTitle == nativeConsumers.statusConflict.title,
              nativeConsumers.statusConflict.toolTip.contains(fixture.expectedDisplayName),
              [nativeConsumers.statusActive, nativeConsumers.statusError, nativeConsumers.statusConflict]
                .allSatisfy({ $0.accessibilityLabel.contains(fixture.expectedDisplayName) }) else {
            throw ContractInputError(category: "native-consumer-copy-mismatch")
        }
        guard gallery.shortcut == shortcut,
              let galleryActive = gallery.observations.first(where: { $0.row == "storage-ready-idle" }),
              let galleryConflict = gallery.observations.first(where: { $0.row == "shortcut-inactive-conflict" }),
              galleryActive.shortcutText == fixture.expectedHoldHint,
              galleryActive.shortcutAccessibilityLabel == fixture.expectedHoldHint,
              galleryActive.keyboardAvailable,
              galleryConflict.shortcutText == fixture.expectedInactiveHint,
              galleryConflict.shortcutAccessibilityLabel == fixture.expectedInactiveHint,
              galleryConflict.noticeActionable,
              galleryConflict.noticeActionTitle == "Open Settings",
              galleryConflict.mouseStartEnabled,
              !galleryConflict.keyboardAvailable else {
            throw ContractInputError(category: "gallery-consumer-copy-mismatch")
        }
        guard popoverActive.shortcutAccessibilityLabel == fixture.expectedHoldHint,
              popoverConflict.shortcutAccessibilityLabel == fixture.expectedInactiveHint,
              popoverConflict.noticeActionTitle == "Open Settings",
              popoverConflict.noticeActionEnabled,
              popoverConflict.primaryEnabled,
              popoverConflict.primaryTitle == "Start Dictation" else {
            throw ContractInputError(category: "rendered-shortcut-conflict-contract")
        }
        return Receipt(
            fixture: name,
            displayName: displayName,
            compactName: compactName,
            accessibilityLabel: popover.shortcut.accessibilityLabel,
            holdHint: holdHint,
            inactiveHint: conflict.shortcut.inactiveHint,
            releaseHint: releaseHint,
            popoverGlyphs: popover.shortcut.glyphs,
            popoverActive: popoverActive,
            popoverConflict: popoverConflict,
            nativeConsumers: nativeConsumers,
            gallery: gallery,
            conflictNoticeActionable: popoverConflict.noticeActionEnabled,
            mouseStartEnabled: popoverConflict.primaryEnabled,
            keyboardAvailable: conflict.shortcut.isAvailable
        )
    }

    private static func renderedPopoverObservation(
        _ presentation: OigoPopoverPresentation
    ) throws -> PopoverObservation {
        try MainActor.assumeIsolated {
            let controller = OigoPopoverViewController(commandHandler: { _ in })
            controller.render(presentation, generation: 8, inputOptions: [])
            guard let shortcutRow = descendant(
                identifier: "popover-shortcut",
                in: controller.view
            ),
            let primaryAction = descendant(
                identifier: "popover-primary-action",
                in: controller.view
            ) as? NSButton else {
                throw ContractInputError(category: "rendered-shortcut-conflict-contract")
            }
            let notice = descendant(identifier: "popover-prioritized-notice", in: controller.view)
            let noticeButton = notice.flatMap(firstButton(in:))
            return PopoverObservation(
                shortcutAccessibilityLabel: shortcutRow.accessibilityLabel() ?? "",
                primaryTitle: primaryAction.title,
                primaryEnabled: primaryAction.isEnabled,
                noticeActionTitle: noticeButton?.title,
                noticeActionEnabled: noticeButton?.isEnabled == true
            )
        }
    }

    @MainActor
    private static func firstButton(in root: NSView) -> NSButton? {
        if let button = root as? NSButton { return button }
        return root.subviews.lazy.compactMap(firstButton(in:)).first
    }

    @MainActor
    private static func descendant(identifier: String, in root: NSView) -> NSView? {
        if root.accessibilityIdentifier() == identifier {
            return root
        }
        for child in root.subviews {
            if let match = descendant(identifier: identifier, in: child) {
                return match
            }
        }
        return nil
    }

    private static func presentationInputs(
        shortcut: ToggleShortcut,
        registration: OigoShortcutRegistrationPresentationStatus
    ) -> OigoPresentationInputs {
        let locale = OigoLocaleIdentifier("en-US")!
        return OigoPresentationInputs(
            generation: 8,
            operationGate: .init(activeOperation: nil, busyReason: nil),
            coordinator: .init(state: .idle, generation: 8),
            storage: .init(status: .ready),
            shortcut: .init(
                registration: registration,
                isConfigured: true,
                shortcut: shortcut
            ),
            permissions: .init(microphone: .granted, accessibility: .granted),
            input: .init(selection: .systemDefault, channelIndex: 0),
            localeAssets: .init(localeIdentifier: locale, status: .ready, generation: 8),
            activeConfiguration: nil,
            nextConfiguration: .init(
                localeIdentifier: locale,
                input: .systemDefault,
                channelIndex: 0,
                appliesTo: .next
            ),
            terminal: nil,
            latestSession: nil,
            playback: .init(generation: 8, status: .idle),
            onboarding: .init(stage: .complete, status: .passed, failure: nil),
            shutdown: .init(status: .inactive, fencedOperationCount: 0)
        )
    }

    private static func validateConsumerSources() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let paths = [
            "Sources/Oigo/UI/Presentation/OigoPresentationInputs.swift",
            "Sources/Oigo/UI/Presentation/OigoPopoverPresentation.swift",
            "Sources/Oigo/UI/HUD/OigoHUDPolicy.swift",
            "Sources/Oigo/OnboardingWindowController.swift",
            "Sources/Oigo/SettingsWindowController.swift",
            "Sources/Oigo/OigoAppDelegate.swift",
            "Sources/OigoUIGallery/Scenarios/task-12/Task12PopoverFixture.swift",
            "Sources/OigoUIGallery/Scenarios/task-12/PopoverStatesGalleryScenario.swift"
        ]
        let sources = try paths.map { path -> (String, String) in
            let url = root.appendingPathComponent(path)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                throw ContractInputError(category: "missing-shortcut-consumer")
            }
            return (path, text)
        }
        let forbidden = try NSRegularExpression(pattern: #"Option[ -]Space|⌥\s*Space"#)
        guard sources.allSatisfy({ _, text in
            forbidden.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil
        }) else {
            throw ContractInputError(category: "stale-literal-shortcut-copy")
        }
        let required = [
            "OigoPresentationInputs.swift": "shortcut: ToggleShortcut",
            "OigoPopoverPresentation.swift": "shortcut.copy",
            "OigoHUDPolicy.swift": "releaseHint",
            "OnboardingWindowController.swift": "committedShortcutCopy",
            "SettingsWindowController.swift": "committedShortcutCopy",
            "OigoAppDelegate.swift": "committedShortcutCopy",
            "Task12PopoverFixture.swift": "committedShortcut",
            "PopoverStatesGalleryScenario.swift": "presentation.shortcut.holdHint"
        ]
        for (file, token) in required {
            guard sources.first(where: { $0.0.hasSuffix(file) })?.1.contains(token) == true else {
                throw ContractInputError(category: "unprojected-shortcut-consumer")
            }
        }
    }

    private static func buildRuntimeProducts() throws {
        try runProcess(executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: [
            "swift", "build", "--product", "Oigo"
        ])
        try runProcess(executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: [
            "swift", "build", "--product", "OigoUIGallery"
        ])
    }

    private static func observeNativeConsumers(
        fixtureRoot: URL,
        outputRoot: URL
    ) throws -> ConsumerReceipt {
        let output = outputRoot.appendingPathComponent("oigo-consumers.json")
        try runProcess(
            executable: URL(fileURLWithPath: ".build/debug/Oigo"),
            arguments: [
                "--task-08-shortcut-probe",
                fixtureRoot.appendingPathComponent("fixture.json").path,
                output.path
            ],
            environment: ["OIGO_QA_MODE": "1"]
        )
        return try JSONDecoder().decode(ConsumerReceipt.self, from: Data(contentsOf: output))
    }

    private static func observeGallery(
        fixtureRoot: URL,
        outputRoot: URL,
        defaultsSuite: String
    ) throws -> GalleryReceipt {
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        let repositoryRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let qaRoot = repositoryRoot.appendingPathComponent("T/oigo-shortcut-transcription-design-fidelity.qa")
        let receiptURL = outputRoot.appendingPathComponent("shortcut-gallery.json")
        let process = Process()
        process.executableURL = repositoryRoot.appendingPathComponent(".build/debug/OigoUIGallery")
        process.arguments = [
            "--scenario", "popover-states",
            "--defaults-suite", defaultsSuite,
            "--session-root", qaRoot.appendingPathComponent("session/task-08").path,
            "--fixture-root", fixtureRoot.path,
            "--evidence-root", outputRoot.path,
            "--pasteboard-provider", "synthetic",
            "--permission-provider", "synthetic",
            "--appearance", "light",
            "--contrast", "standard"
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = qaRoot.appendingPathComponent("home").path
        process.environment = environment
        try process.run()
        let deadline = Date().addingTimeInterval(8)
        while !FileManager.default.fileExists(atPath: receiptURL.path), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        guard FileManager.default.fileExists(atPath: receiptURL.path) else {
            throw ContractInputError(category: "missing-gallery-runtime-receipt")
        }
        return try JSONDecoder().decode(GalleryReceipt.self, from: Data(contentsOf: receiptURL))
    }

    private static func runProcess(
        executable: URL,
        arguments: [String],
        environment additions: [String: String] = [:]
    ) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        additions.forEach { environment[$0.key] = $0.value }
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw ContractInputError(category: "runtime-process-failed-" + String(process.terminationStatus) + "-" + text)
        }
    }

    private static func write(receipts: [Receipt], to evidenceRoot: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(receipts)
        try data.write(to: evidenceRoot.appendingPathComponent("shortcut-copy.json"), options: .atomic)
    }
}
