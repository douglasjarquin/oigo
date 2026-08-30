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
        let conflictNoticeActionable: Bool
        let mouseStartEnabled: Bool
        let keyboardAvailable: Bool
    }

    override class var scenarioName: String {
        "shortcut-copy"
    }

    override class func run(arguments: ContractArguments) throws {
        guard arguments.defaultsSuite == "com.oigo.qa.task08" else {
            throw ContractInputError(category: "invalid-defaults-suite")
        }
        let fixtures = try loadFixtures(from: arguments.fixtureRoot)
        var receipts: [Receipt] = []
        for (name, fixture) in fixtures {
            let receipt = try exercise(name: name, fixture: fixture)
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

    private static func exercise(name: String, fixture: Fixture) throws -> Receipt {
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
        try assertRenderedConflict(
            conflict,
            expectedAccessibilityLabel: fixture.expectedInactiveHint
        )
        return Receipt(
            fixture: name,
            displayName: displayName,
            compactName: compactName,
            accessibilityLabel: popover.shortcut.accessibilityLabel,
            holdHint: holdHint,
            inactiveHint: conflict.shortcut.inactiveHint,
            releaseHint: releaseHint,
            popoverGlyphs: popover.shortcut.glyphs,
            conflictNoticeActionable: true,
            mouseStartEnabled: true,
            keyboardAvailable: false
        )
    }

    private static func assertRenderedConflict(
        _ presentation: OigoPopoverPresentation,
        expectedAccessibilityLabel: String
    ) throws {
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
            ) as? NSButton,
            shortcutRow.accessibilityLabel() == expectedAccessibilityLabel,
            primaryAction.isEnabled else {
                throw ContractInputError(category: "rendered-shortcut-conflict-contract")
            }
        }
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

    private static func write(receipts: [Receipt], to evidenceRoot: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(receipts)
        try data.write(to: evidenceRoot.appendingPathComponent("shortcut-copy.json"), options: .atomic)
    }
}
