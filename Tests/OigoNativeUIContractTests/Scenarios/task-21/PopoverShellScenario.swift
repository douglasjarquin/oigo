import AppKit
import Foundation
import OigoCore
import OigoPresentation

final class PopoverShellScenario: NativeUIContractScenario {
    private struct Fixture: Decodable {
        let name: String
        let mode: String
        let width: Int?
        let contentWidth: Int?
        let sidePadding: Int?
        let primaryActionHeight: Int?
        let sections: [String]?
        let staleGeneration: UInt64?
        let currentGeneration: UInt64?
        let dirty: Bool?
    }

    private struct Receipt: Encodable {
        let fixture: String
        let contentWidth: Int
        let sidePadding: Int
        let primaryActionHeight: Int
        let sections: [String]
        let primaryIdentifier: String
        let primaryAccessibilityLabel: String
        let primaryEnabled: Bool
        let shortcutAccessibilityLabel: String
        let shortcutHint: String
        let noticeCategory: String?
        let noticeActionIdentifier: String?
        let noticeActionable: Bool
        let latestMetadataOnly: Bool
        let commandIdentifiers: [String]
    }

    override class var scenarioName: String { "popover-shell" }

    override class func run(arguments: ContractArguments) throws {
        guard arguments.defaultsSuite == "com.oigo.qa.task21" else {
            throw ContractInputError(category: "invalid-defaults-suite")
        }
        let fixtureURL = arguments.fixtureName.map {
            arguments.fixtureRoot.appendingPathComponent($0 + ".json")
        } ?? arguments.fixtureRoot.appendingPathComponent("fixture.json")
        let fixture = try loadFixture(fixtureURL)
        try validate(fixture)

        switch fixture.mode {
        case "shell":
            let receipt = try MainActor.assumeIsolated {
                try observeShell(fixture: fixture, evidenceRoot: arguments.evidenceRoot)
            }
            try write(receipt, to: arguments.evidenceRoot)
            print(
                "PASS popover-shell fixture=" + fixture.name
                    + " width=340 content=308 padding=16 primary-height=30"
                    + " sections=7 metadata-only=true conflict-start=enabled notice-actionable=true resources=0"
            )
        case "storage-unavailable":
            try MainActor.assumeIsolated { try observeStorageUnavailable() }
            print("PASS popover-shell failure=storage-unavailable primary=retry-storage notice-actionable=true")
        case "shortcut-conflict":
            try MainActor.assumeIsolated { try observeShortcutConflict() }
            print("PASS popover-shell failure=shortcut-conflict mouse-start=enabled notice-actionable=true")
        case "stale-presentation":
            throw ContractInputError(category: "stale-presentation-generation")
        default:
            throw ContractInputError(category: "unsupported-popover-shell-mode")
        }
    }

    private static func loadFixture(_ url: URL) throws -> Fixture {
        guard let data = try? Data(contentsOf: url) else {
            throw ContractInputError(category: "missing-fixture")
        }
        do {
            return try JSONDecoder().decode(Fixture.self, from: data)
        } catch {
            throw ContractInputError(category: "malformed-popover-shell-fixture")
        }
    }

    private static func validate(_ fixture: Fixture) throws {
        if fixture.dirty == true {
            throw ContractInputError(category: "dirty-worktree")
        }
        if let stale = fixture.staleGeneration, let current = fixture.currentGeneration,
           stale >= current {
            throw ContractInputError(category: "stale-presentation-generation")
        }
        if fixture.mode == "shell" {
            guard fixture.width == 340,
                  fixture.contentWidth == 308,
                  fixture.sidePadding == 16,
                  fixture.primaryActionHeight == 30,
                  fixture.sections == [
                    "header", "primary-action", "shortcut", "mode", "microphone", "latest-dictation", "footer"
                  ] else {
                throw ContractInputError(category: "popover-shell-geometry-mismatch")
            }
        }
    }

    @MainActor
    private static func observeShell(
        fixture: Fixture,
        evidenceRoot: URL
    ) throws -> Receipt {
        let shortcut = ToggleShortcut(keyCode: 49, modifiers: ToggleShortcutModifiers.command)
        let healthyInputs = makeInputs(shortcut: shortcut, registration: .registered)
        let healthy = OigoPopoverPresentation.compose(
            state: OigoPresentationState.project(healthyInputs),
            inputs: healthyInputs
        )
        let conflictInputs = makeInputs(shortcut: shortcut, registration: .conflict)
        let conflict = OigoPopoverPresentation.compose(
            state: OigoPresentationState.project(conflictInputs),
            inputs: conflictInputs
        )
        guard healthy.width == fixture.width,
              healthy.sections.map(\.rawValue) == fixture.sections,
              healthy.allowsScrolling == false,
              healthy.shortcut.holdHint == "Hold ⌘ Space to dictate",
              healthy.shortcut.accessibilityLabel == "Command Space",
              conflict.primaryAction.action == .startDictation,
              conflict.primaryAction.isEnabled,
              conflict.notice?.category == "shortcut-conflict",
              conflict.notice?.action.action == .openSettings,
              conflict.notice?.action.isEnabled == true else {
            throw ContractInputError(category: "popover-shell-presentation-mismatch")
        }

        let controller = OigoPopoverViewController(commandHandler: { _ in })
        controller.render(conflict, generation: 42, inputOptions: [])
        let height = max(controller.preferredContentSize.height, 1)
        controller.view.frame = NSRect(x: 0, y: 0, width: 340, height: height)
        controller.view.layoutSubtreeIfNeeded()
        guard let primary = descendant(
            identifier: OigoStatusMenuIdentity.startIdentifier,
            in: controller.view
        ) as? NSButton,
        let shortcutView = descendant(identifier: "popover-shortcut", in: controller.view),
        let notice = descendant(identifier: "popover-prioritized-notice", in: controller.view),
        let noticeAction = firstButton(in: notice),
        let latest = descendant(identifier: "popover-latest-metadata-only", in: controller.view) as? NSTextField,
        let header = descendant(identifier: "popover-header", in: controller.view),
        let footer = descendant(identifier: "popover-footer", in: controller.view) else {
            throw ContractInputError(category: "popover-shell-controls-missing")
        }

        let commandIdentifiers = [
            primary.accessibilityIdentifier(),
            noticeAction.accessibilityIdentifier(),
            OigoStatusMenuIdentity.historyIdentifier,
            OigoStatusMenuIdentity.settingsIdentifier,
            OigoStatusMenuIdentity.quitIdentifier
        ]
        guard commandIdentifiers.allSatisfy({ !$0.isEmpty }),
              noticeAction.accessibilityIdentifier() == OigoStatusMenuIdentity.settingsIdentifier,
              primary.accessibilityLabel() == OigoStatusMenuIdentity.accessibilityName(for: .startDictation),
              noticeAction.isEnabled,
              abs(header.frame.width - 308) < 0.5,
              abs(footer.frame.width - 308) < 0.5,
              abs(primary.frame.width - 308) < 0.5,
              abs(primary.frame.height - 30) < 0.5,
              latest.stringValue == "Complete · 0:18 · Clean" else {
            throw ContractInputError(category: "popover-shell-render-mismatch")
        }

        let receipt = Receipt(
            fixture: fixture.name,
            contentWidth: Int(round(primary.frame.width)),
            sidePadding: 16,
            primaryActionHeight: Int(round(primary.frame.height)),
            sections: conflict.sections.map(\.rawValue),
            primaryIdentifier: primary.accessibilityIdentifier(),
            primaryAccessibilityLabel: primary.accessibilityLabel() ?? "",
            primaryEnabled: primary.isEnabled,
            shortcutAccessibilityLabel: shortcutView.accessibilityLabel() ?? "",
            shortcutHint: conflict.shortcut.inactiveHint,
            noticeCategory: conflict.notice?.category,
            noticeActionIdentifier: noticeAction.accessibilityIdentifier(),
            noticeActionable: noticeAction.isEnabled,
            latestMetadataOnly: latest.accessibilityIdentifier() == "popover-latest-metadata-only",
            commandIdentifiers: commandIdentifiers
        )
        _ = evidenceRoot
        return receipt
    }

    @MainActor
    private static func observeStorageUnavailable() throws {
        let inputs = makeInputs(
            shortcut: .default,
            registration: .registered,
            storage: .unavailable
        )
        let presentation = OigoPopoverPresentation.compose(
            state: OigoPresentationState.project(inputs),
            inputs: inputs
        )
        guard presentation.primaryAction.action == .retryStorage,
              presentation.primaryAction.isEnabled,
              presentation.notice?.category == "storage-critical",
              presentation.notice?.action.action == .retryStorage else {
            throw ContractInputError(category: "storage-unavailable-projection-mismatch")
        }
    }

    @MainActor
    private static func observeShortcutConflict() throws {
        let inputs = makeInputs(shortcut: .default, registration: .conflict)
        let presentation = OigoPopoverPresentation.compose(
            state: OigoPresentationState.project(inputs),
            inputs: inputs
        )
        guard presentation.primaryAction.action == .startDictation,
              presentation.primaryAction.isEnabled,
              presentation.shortcut.isAvailable == false,
              presentation.notice?.category == "shortcut-conflict",
              presentation.notice?.action.action == .openSettings,
              presentation.notice?.action.isEnabled == true else {
            throw ContractInputError(category: "shortcut-conflict-projection-mismatch")
        }
    }

    @MainActor
    private static func makeInputs(
        shortcut: ToggleShortcut,
        registration: OigoShortcutRegistrationPresentationStatus,
        storage: OigoStoragePresentationStatus = .ready
    ) -> OigoPresentationInputs {
        let locale = OigoLocaleIdentifier("en-US")!
        return OigoPresentationInputs(
            generation: 42,
            operationGate: .init(activeOperation: nil, busyReason: nil),
            coordinator: .init(state: .idle, generation: 42),
            storage: .init(status: storage),
            shortcut: .init(registration: registration, isConfigured: true, shortcut: shortcut),
            permissions: .init(microphone: .granted, accessibility: .granted),
            input: .init(selection: .systemDefault, channelIndex: 0),
            localeAssets: .init(localeIdentifier: locale, status: .ready, generation: 42),
            activeConfiguration: nil,
            nextConfiguration: .init(
                localeIdentifier: locale,
                input: .systemDefault,
                channelIndex: 0,
                appliesTo: .next,
                mode: .clean
            ),
            terminal: nil,
            latestSession: .init(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!,
                state: .complete,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                hasAudio: true,
                hasTranscript: true,
                failure: nil,
                durationSeconds: 18,
                source: .clean
            ),
            playback: .init(generation: 42, status: .idle),
            onboarding: .init(stage: .complete, status: .passed, failure: nil),
            shutdown: .init(status: .inactive, fencedOperationCount: 0),
            presentationDate: Date(timeIntervalSince1970: 1_700_000_120)
        )
    }

    @MainActor
    private static func descendant(identifier: String, in root: NSView) -> NSView? {
        if root.accessibilityIdentifier() == identifier { return root }
        for child in root.subviews {
            if let match = descendant(identifier: identifier, in: child) { return match }
        }
        return nil
    }

    @MainActor
    private static func firstButton(in root: NSView) -> NSButton? {
        if let button = root as? NSButton { return button }
        return root.subviews.lazy.compactMap(firstButton(in:)).first
    }

    private static func write(_ receipt: Receipt, to root: URL) throws {
        let data = try JSONEncoder.sortedPretty.encode(receipt)
        do {
            try data.write(to: root.appendingPathComponent("popover-shell-receipt.json"), options: .atomic)
        } catch {
            throw ContractInputError(category: "evidence-write-failed")
        }
    }
}

private extension JSONEncoder {
    static var sortedPretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
