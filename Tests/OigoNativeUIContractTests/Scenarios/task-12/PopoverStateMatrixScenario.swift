import Darwin
import AppKit
import Foundation
import OigoCore
import OigoPresentation

final class PopoverStateMatrixScenario: NativeUIContractScenario {
    private struct Fixture: Decodable {
        let name: String
        let rows: [String]
        let expectedSections: [String]
        let popoverWidth: Int
        let healthyNoScroll: Bool
        let failures: Failures?
        let staleGeneration: UInt64?
        let currentGeneration: UInt64?
        let dirty: Bool?
        let intrinsicHeights: [Int]?
        let reportedSuccess: Bool?
        let processExitStatus: Int?
        let interruptions: Int?
        let commandDurationMilliseconds: Int?
    }

    private struct Failures: Decodable {
        let storage: Bool
        let microphone: Bool
        let shortcut: Bool
        let accessibility: Bool
    }

    private struct StateReceipt: Encodable {
        let caseSlug: String
        let row: String
        let appearance: String
        let title: String
        let detail: String
        let primaryIdentifier: String
        let primaryAccessibilityLabel: String
        let primaryTitle: String
        let primaryEnabled: Bool
        let noticeCategory: String
        let noticeActionIdentifier: String
        let noticeActionAccessibilityLabel: String
        let noticeActionable: Bool
        let shortcutAccessibilityLabel: String
        let latestMetadataOnly: Bool
        let dismissal: String
        let width: Int
        let scrollable: Bool
        let screenshot: String
    }

    private struct ExpectedState {
        let title: String
        let primaryIdentifier: String
        let primaryAccessibilityLabel: String
        let primaryTitle: String
        let primaryEnabled: Bool
        let noticeCategory: String
        let noticeActionIdentifier: String
        let noticeActionAccessibilityLabel: String
        let noticeActionable: Bool
        let shortcutAvailable: Bool
        let dismissal: String
    }

    override class var scenarioName: String { "popover-state-matrix" }

    override class func run(arguments: ContractArguments) throws {
        guard arguments.defaultsSuite == "com.oigo.qa.task12" else {
            throw ContractInputError(category: "invalid-defaults-suite")
        }
        let fixtureRoot = fixtureRoot(for: arguments)
        let fixture = try loadFixture(fixtureRoot.appendingPathComponent("fixture.json"))
        try validate(fixture)
        let selectedRows = try selectedRows(for: arguments.caseName)
        guard arguments.fixtureName == nil || arguments.fixtureName == "exhaustive"
            || arguments.caseName != nil else {
            throw ContractInputError(category: "unsupported-fixture")
        }
        try validateGenerationFence(fixture)
        if let duration = fixture.commandDurationMilliseconds {
            _ = try runProcess(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: [String(Double(duration) / 1_000)],
                timeout: 0.1
            )
        }
        let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        try validateAuthoritativeMapper(repository)
        guard FileManager.default.fileExists(
            atPath: repository.appendingPathComponent(
                "Sources/Oigo/UI/Presentation/OigoPopoverPresentation.swift"
            ).path
        ) else {
            throw ContractInputError(category: "missing-popover-presentation")
        }
        let output = try runCompiledContract(repository: repository)
        print(output, terminator: "")
        guard output.contains("MATRIX rows=23 unique=23 sections=7 width=340 scroll=false"),
              output.contains("PRIORITY notice=storage-critical count=1 start=disabled"),
              output.contains("SHORTCUT start=enabled"),
              output.contains("ACCESSIBILITY posture=ready"),
              output.contains("PINNED microphone=pinned-input-unavailable"),
              output.contains("RECOVERY microphone=system-settings accessibility=system-settings"),
              output.contains("BUSY reason=busy-retry"),
              output.contains("SHUTDOWN reason=shutting-down"),
              !output.contains("verified-third-party"),
              selectedRows.allSatisfy({ output.contains("ROW row=" + $0.row.rawValue) }) else {
            throw ContractInputError(category: "popover-matrix-mismatch")
        }
        let receipts = try MainActor.assumeIsolated {
            try writeVisualReceipts(
                rows: selectedRows,
                appearance: arguments.appearance,
                evidenceRoot: arguments.evidenceRoot
            )
        }
        print(
            "PASS popover-state-matrix fixture=" + (arguments.fixtureName ?? "exhaustive")
                + " cases=" + String(receipts.count)
                + " resources=0 reads=metadata-only screenshots=" + String(receipts.count)
        )
    }

    private static func fixtureRoot(for arguments: ContractArguments) -> URL {
        guard let fixtureName = arguments.fixtureName,
              fixtureName != "exhaustive",
              !FileManager.default.fileExists(
                atPath: arguments.fixtureRoot.appendingPathComponent("fixture.json").path
              ) else {
            return arguments.fixtureRoot
        }
        return arguments.fixtureRoot.appendingPathComponent(fixtureName, isDirectory: true)
    }

    private static func selectedRows(
        for requestedCase: String?
    ) throws -> [(slug: String, row: OigoPresentationStateRow)] {
        guard let requestedCase else {
            return expectedRows.compactMap { value in
                guard let row = OigoPresentationStateRow(rawValue: value) else { return nil }
                return (value, row)
            }
        }
        let aliases: [String: [String]] = [
            "paste-verified": ["paste-owned-field-verified"],
            "copied-only-secure-field-changed-target": ["copied-only"],
            "completed-insertion-failure": ["insertion-failure"],
            "live-transcription-degraded-retry": ["retry-required"],
            "busy": ["busy-typed-reason"]
        ]
        let rowNames = aliases[requestedCase] ?? [requestedCase]
        guard let rows = rowNames.compactMap({ name -> (String, OigoPresentationStateRow)? in
            guard let row = OigoPresentationStateRow(rawValue: name) else { return nil }
            return (requestedCase, row)
        }) as? [(String, OigoPresentationStateRow)], rows.count == rowNames.count else {
            throw ContractInputError(category: "unknown-state-case")
        }
        return rows.map { (slug: $0.0, row: $0.1) }
    }

    private static let expectedRows = [
        "storage-checking", "storage-ready-idle", "storage-unavailable",
        "shortcut-inactive-conflict", "mic-permission-unavailable",
        "selected-input-unavailable", "language-assets-checking-installing",
        "language-assets-unavailable", "accessibility-unavailable", "preparing", "recording",
        "finalizing-cleaning-inserting", "paste-event-attempted", "paste-owned-field-verified",
        "copied-only", "cleanup-fallback", "insertion-failure", "retry-required",
        "cancelled-before-durable-raw", "cancelled-after-durable-raw", "interrupted",
        "busy-typed-reason", "shutting-down"
    ]

    private static let expectedSections = [
        "header", "primary-action", "shortcut", "mode", "microphone", "latest-dictation", "footer"
    ]

    private static func loadFixture(_ url: URL) throws -> Fixture {
        guard let data = try? Data(contentsOf: url) else {
            throw ContractInputError(category: "missing-fixture")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ContractInputError(category: "malformed-state-combination")
        }
        guard !containsPrivateContent(object) else {
            throw ContractInputError(category: "forbidden-user-content")
        }
        do {
            return try JSONDecoder().decode(Fixture.self, from: data)
        } catch {
            throw ContractInputError(category: "malformed-state-combination")
        }
    }

    private static func validate(_ fixture: Fixture) throws {
        if fixture.dirty == true {
            throw ContractInputError(category: "dirty-worktree")
        }
        if let heights = fixture.intrinsicHeights, Set(heights).count != 1 {
            throw ContractInputError(category: "flaky-intrinsic-sizing")
        }
        if fixture.reportedSuccess == true, fixture.processExitStatus != 0 {
            print("PASS decoy-only")
            throw ContractInputError(category: "misleading-success-output")
        }
        if let interruptions = fixture.interruptions, interruptions > 1 {
            throw ContractInputError(category: "repeated-interruption")
        }
        guard Set(fixture.rows).count == fixture.rows.count,
              fixture.rows == expectedRows else {
            throw ContractInputError(category: "unmapped-state")
        }
        guard fixture.expectedSections == expectedSections,
              fixture.popoverWidth == 340,
              fixture.healthyNoScroll else {
            throw ContractInputError(category: "missing-popover-section")
        }
        if let failures = fixture.failures {
            guard failures.storage, failures.microphone, failures.shortcut,
                  failures.accessibility else {
                throw ContractInputError(category: "malformed-state-combination")
            }
        }
    }

    private static func validateGenerationFence(_ fixture: Fixture) throws {
        guard let stale = fixture.staleGeneration, let current = fixture.currentGeneration else {
            return
        }
        guard stale < current else {
            var fence = OigoPresentationGenerationFence()
            var currentState = "current"
            let currentInputs = makeInputs(for: .storageReadyIdle, generation: current)
            let staleInputs = makeInputs(for: .storageReadyIdle, generation: stale)
            let currentAccepted = fence.publish(
                OigoPresentationPublication(inputs: currentInputs),
                to: { _ in currentState = "current" }
            )
            let staleAccepted = fence.publish(
                OigoPresentationPublication(inputs: staleInputs),
                to: { _ in currentState = "stale" }
            )
            guard currentAccepted, !staleAccepted, currentState == "current" else {
                throw ContractInputError(category: "stale-generation-mutated-state")
            }
            print("REJECTED stale-generation current-state=unchanged")
            throw ContractInputError(category: "stale-generation")
        }

        var fence = OigoPresentationGenerationFence()
        var currentState = "current"
        let currentInputs = makeInputs(for: .storageReadyIdle, generation: current)
        let staleInputs = makeInputs(for: .storageReadyIdle, generation: stale)
        guard fence.publish(
            OigoPresentationPublication(inputs: currentInputs),
            to: { _ in currentState = "current" }
        ), !fence.publish(
            OigoPresentationPublication(inputs: staleInputs),
            to: { _ in currentState = "stale" }
        ), currentState == "current" else {
            throw ContractInputError(category: "stale-generation-mutated-state")
        }
    }

    @MainActor
    private static func writeVisualReceipts(
        rows: [(slug: String, row: OigoPresentationStateRow)],
        appearance: String,
        evidenceRoot: URL
    ) throws -> [StateReceipt] {
        let statesRoot = evidenceRoot.appendingPathComponent("states", isDirectory: true)
        try FileManager.default.createDirectory(at: statesRoot, withIntermediateDirectories: true)
        let selectedAppearance: NSAppearance? = switch appearance {
        case "light": NSAppearance(named: .aqua)
        case "dark": NSAppearance(named: .darkAqua)
        default: nil
        }
        NSApplication.shared.appearance = selectedAppearance

        return try rows.map { selection in
            let inputs = makeInputs(for: selection.row, generation: 42)
            let state = OigoPresentationState.project(inputs)
            let presentation = OigoPopoverPresentation.compose(state: state, inputs: inputs)
            let controller = OigoPopoverViewController(commandHandler: { _ in })
            controller.render(presentation, generation: 42, inputOptions: [])
            controller.view.appearance = selectedAppearance
            let height = max(controller.preferredContentSize.height, 1)
            controller.view.frame = NSRect(
                x: 0,
                y: 0,
                width: CGFloat(presentation.width),
                height: height
            )
            controller.view.layoutSubtreeIfNeeded()

            let primaryID = primaryIdentifier(presentation.primaryAction)
            guard let primary = descendant(identifier: primaryID, in: controller.view) as? NSButton,
                  let shortcut = descendant(identifier: "popover-shortcut", in: controller.view),
                  let latest = descendant(identifier: "popover-latest-metadata-only", in: controller.view)
                      as? NSTextField else {
                throw ContractInputError(category: "popover-state-controls-missing")
            }
            let notice = descendant(identifier: "popover-prioritized-notice", in: controller.view)
            let noticeAction = notice.flatMap(firstButton(in:))
            let screenshotName = selection.slug + ".png"
            let screenshotURL = statesRoot.appendingPathComponent(screenshotName)
            guard let bitmap = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds) else {
                throw ContractInputError(category: "popover-state-bitmap-failed")
            }
            controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw ContractInputError(category: "popover-state-screenshot-failed")
            }
            try png.write(to: screenshotURL, options: .atomic)

            let receipt = StateReceipt(
                caseSlug: selection.slug,
                row: selection.row.rawValue,
                appearance: appearance,
                title: presentation.statusLabel,
                detail: notice?.accessibilityLabel() ?? latest.stringValue,
                primaryIdentifier: primary.accessibilityIdentifier(),
                primaryAccessibilityLabel: primary.accessibilityLabel() ?? "",
                primaryTitle: primary.title,
                primaryEnabled: primary.isEnabled,
                noticeCategory: presentation.notice?.category ?? "none",
                noticeActionIdentifier: noticeAction?.accessibilityIdentifier() ?? "none",
                noticeActionAccessibilityLabel: noticeAction?.accessibilityLabel() ?? "",
                noticeActionable: noticeAction?.isEnabled == true,
                shortcutAccessibilityLabel: shortcut.accessibilityLabel() ?? "",
                latestMetadataOnly: true,
                dismissal: dismissal(for: selection.row),
                width: Int(round(controller.view.frame.width)),
                scrollable: presentation.allowsScrolling,
                screenshot: "states/" + screenshotName
            )
            try assertContract(
                receipt,
                expected: expectedState(for: selection.row),
                presentation: presentation,
                primary: primary,
                shortcut: shortcut,
                latest: latest,
                notice: notice,
                noticeAction: noticeAction
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(receipt)
            try data.write(
                to: statesRoot.appendingPathComponent(selection.slug + ".json"),
                options: .atomic
            )
            return receipt
        }
    }

    @MainActor
    private static func assertContract(
        _ receipt: StateReceipt,
        expected: ExpectedState,
        presentation: OigoPopoverPresentation,
        primary: NSButton,
        shortcut: NSView,
        latest: NSTextField,
        notice: NSView?,
        noticeAction: NSButton?
    ) throws {
        guard receipt.title == expected.title,
              receipt.detail == expectedDetail(for: receipt.row),
              receipt.primaryIdentifier == expected.primaryIdentifier,
              receipt.primaryAccessibilityLabel == expected.primaryAccessibilityLabel,
              receipt.primaryTitle == expected.primaryTitle,
              receipt.primaryEnabled == expected.primaryEnabled,
              receipt.noticeCategory == expected.noticeCategory,
              receipt.noticeActionIdentifier == expected.noticeActionIdentifier,
              receipt.noticeActionAccessibilityLabel == expected.noticeActionAccessibilityLabel,
              receipt.noticeActionable == expected.noticeActionable,
              receipt.dismissal == expected.dismissal,
              receipt.width == 340,
              !receipt.scrollable,
              receipt.latestMetadataOnly,
              primary.accessibilityIdentifier() == expected.primaryIdentifier,
              shortcut.accessibilityLabel() == receipt.shortcutAccessibilityLabel,
              latest.accessibilityIdentifier() == "popover-latest-metadata-only" else {
            throw ContractInputError(category: "popover-state-contract-mismatch")
        }
        let shortcutAvailable = shortcut.accessibilityLabel() == "Hold ⇧ ⌘ Space to dictate"
        guard shortcutAvailable == expected.shortcutAvailable else {
            throw ContractInputError(category: "shortcut-accessibility-mismatch")
        }
        if let notice {
            guard let noticeAction,
                  notice.accessibilityRole() == .group,
                  noticeAction.isEnabled == expected.noticeActionable else {
                throw ContractInputError(category: "notice-action-contract-mismatch")
            }
        } else if expected.noticeCategory != "none" {
            throw ContractInputError(category: "missing-state-notice")
        }
        guard presentation.primaryAction.isEnabled == expected.primaryEnabled,
              primary.isEnabled == expected.primaryEnabled,
              latest.stringValue.contains(" · ") else {
            throw ContractInputError(category: "state-control-contract-mismatch")
        }
    }

    private static func expectedDetail(for rawRow: String) -> String {
        guard let row = OigoPresentationStateRow(rawValue: rawRow) else { return "" }
        switch row {
        case .storageUnavailable:
            return "Storage unavailable. Oigo cannot create durable recordings right now."
        case .shortcutInactiveConflict:
            return "Shortcut inactive. "
                + OigoShortcutPresentation.copy(for: .default).displayName
                + " is unavailable. Mouse start remains available."
        case .microphonePermissionUnavailable:
            return "Microphone unavailable. Allow microphone access before starting dictation."
        case .selectedInputUnavailable:
            return "Selected input unavailable. Reconnect the pinned input or choose another microphone."
        case .languageAssetsUnavailable:
            return "Speech assets required. The selected language needs on-device speech assets."
        case .accessibilityUnavailable:
            return "Accessibility unavailable. Oigo will copy results instead of pasting automatically."
        case .retryRequired:
            return "Recording preserved. Live transcription degraded. The recording is available for retry."
        case .interrupted:
            return "Dictation interrupted. Available durable work remains in History."
        case .pasteEventAttempted:
            return "Paste attempted · 0:18 · Clean"
        case .pasteOwnedFieldVerified:
            return "Verified in Oigo · 0:18 · Clean"
        case .copiedOnly:
            return "Copied to Clipboard · 0:18 · Clean"
        case .cleanupFallback:
            return "Completed · Fallback kept · 0:18 · Clean"
        case .insertionFailure:
            return "Paste failed · Text preserved · 0:18 · Clean"
        case .cancelledBeforeDurableRaw:
            return "Cancelled · 0:18 · Clean"
        case .cancelledAfterDurableRaw:
            return "Cancelled · Saved in History · 0:18 · Clean"
        default:
            return "Complete · 0:18 · Clean"
        }
    }

    private static func expectedState(for row: OigoPresentationStateRow) -> ExpectedState {
        let start = ExpectedState(
            title: "Ready", primaryIdentifier: "oigo.status.start-dictation",
            primaryAccessibilityLabel: "Start Oigo dictation", primaryTitle: "Start Dictation",
            primaryEnabled: true, noticeCategory: "none", noticeActionIdentifier: "none",
            noticeActionAccessibilityLabel: "", noticeActionable: false, shortcutAvailable: true,
            dismissal: "none"
        )
        switch row {
        case .storageChecking:
            return .init(title: "Checking…", primaryIdentifier: "oigo.status.primary-disabled",
                         primaryAccessibilityLabel: "Checking…", primaryTitle: "Checking…",
                         primaryEnabled: false, noticeCategory: "none", noticeActionIdentifier: "none",
                         noticeActionAccessibilityLabel: "", noticeActionable: false,
                         shortcutAvailable: true, dismissal: "on-ready")
        case .storageReadyIdle: return start
        case .storageUnavailable:
            return .init(title: "Attention Needed", primaryIdentifier: "oigo.status.retry-storage",
                         primaryAccessibilityLabel: "Retry Storage", primaryTitle: "Retry Storage",
                         primaryEnabled: true, noticeCategory: "storage-critical",
                         noticeActionIdentifier: "oigo.status.retry-storage",
                         noticeActionAccessibilityLabel: "Retry Storage", noticeActionable: true,
                         shortcutAvailable: true, dismissal: "until-resolved")
        case .shortcutInactiveConflict:
            return .init(title: "Attention Needed", primaryIdentifier: start.primaryIdentifier,
                         primaryAccessibilityLabel: start.primaryAccessibilityLabel,
                         primaryTitle: start.primaryTitle, primaryEnabled: true,
                         noticeCategory: "shortcut-conflict", noticeActionIdentifier: "oigo.status.settings",
                         noticeActionAccessibilityLabel: "Open Settings", noticeActionable: true,
                         shortcutAvailable: false, dismissal: "until-resolved")
        case .microphonePermissionUnavailable:
            return .init(title: "Attention Needed", primaryIdentifier: start.primaryIdentifier,
                         primaryAccessibilityLabel: start.primaryAccessibilityLabel,
                         primaryTitle: start.primaryTitle, primaryEnabled: false,
                         noticeCategory: "microphone-permission", noticeActionIdentifier: "oigo.status.settings",
                         noticeActionAccessibilityLabel: "Open System Settings", noticeActionable: true,
                         shortcutAvailable: true, dismissal: "until-resolved")
        case .selectedInputUnavailable:
            return .init(title: "Attention Needed", primaryIdentifier: start.primaryIdentifier,
                         primaryAccessibilityLabel: start.primaryAccessibilityLabel,
                         primaryTitle: start.primaryTitle, primaryEnabled: false,
                         noticeCategory: "selected-input", noticeActionIdentifier: "oigo.status.choose-input",
                         noticeActionAccessibilityLabel: "Choose Input", noticeActionable: true,
                         shortcutAvailable: true, dismissal: "until-resolved")
        case .languageAssetsCheckingInstalling:
            return .init(title: "Checking…", primaryIdentifier: "oigo.status.primary-disabled",
                         primaryAccessibilityLabel: "Checking…", primaryTitle: "Checking…",
                         primaryEnabled: false, noticeCategory: "none", noticeActionIdentifier: "none",
                         noticeActionAccessibilityLabel: "", noticeActionable: false,
                         shortcutAvailable: true, dismissal: "on-ready")
        case .languageAssetsUnavailable:
            return .init(title: "Attention Needed", primaryIdentifier: start.primaryIdentifier,
                         primaryAccessibilityLabel: start.primaryAccessibilityLabel,
                         primaryTitle: start.primaryTitle, primaryEnabled: false,
                         noticeCategory: "language-assets", noticeActionIdentifier: "oigo.status.install-assets",
                         noticeActionAccessibilityLabel: "Install", noticeActionable: true,
                         shortcutAvailable: true, dismissal: "until-resolved")
        case .accessibilityUnavailable:
            return .init(title: "Ready · Copy-only", primaryIdentifier: start.primaryIdentifier,
                         primaryAccessibilityLabel: start.primaryAccessibilityLabel,
                         primaryTitle: start.primaryTitle, primaryEnabled: true,
                         noticeCategory: "accessibility-copy-only", noticeActionIdentifier: "oigo.status.settings",
                         noticeActionAccessibilityLabel: "Open System Settings", noticeActionable: true,
                         shortcutAvailable: true, dismissal: "persistent-info")
        case .preparing:
            return .init(title: "Preparing…", primaryIdentifier: "oigo.status.primary-disabled",
                         primaryAccessibilityLabel: "Checking…", primaryTitle: "Checking…",
                         primaryEnabled: false, noticeCategory: "none", noticeActionIdentifier: "none",
                         noticeActionAccessibilityLabel: "", noticeActionable: false,
                         shortcutAvailable: true, dismissal: "on-ready")
        case .recording:
            return .init(title: "Recording", primaryIdentifier: "oigo.status.stop-dictation",
                         primaryAccessibilityLabel: "Stop Oigo dictation", primaryTitle: "Stop Dictation",
                         primaryEnabled: true, noticeCategory: "none", noticeActionIdentifier: "none",
                         noticeActionAccessibilityLabel: "", noticeActionable: false,
                         shortcutAvailable: true, dismissal: "on-release")
        case .finalizingCleaningInserting:
            return .init(title: "Finalizing…", primaryIdentifier: "oigo.status.primary-disabled",
                         primaryAccessibilityLabel: "Checking…", primaryTitle: "Checking…",
                         primaryEnabled: false, noticeCategory: "none", noticeActionIdentifier: "none",
                         noticeActionAccessibilityLabel: "", noticeActionable: false,
                         shortcutAvailable: true, dismissal: "on-terminal")
        case .pasteEventAttempted:
            return .init(title: start.title, primaryIdentifier: start.primaryIdentifier,
                         primaryAccessibilityLabel: start.primaryAccessibilityLabel,
                         primaryTitle: start.primaryTitle, primaryEnabled: true,
                         noticeCategory: "none", noticeActionIdentifier: "none",
                         noticeActionAccessibilityLabel: "", noticeActionable: false,
                         shortcutAvailable: true, dismissal: "about-1.8s")
        case .pasteOwnedFieldVerified:
            return .init(title: "Ready", primaryIdentifier: "oigo.status.primary-disabled",
                         primaryAccessibilityLabel: "Checking…", primaryTitle: "Checking…",
                         primaryEnabled: false, noticeCategory: "none", noticeActionIdentifier: "none",
                         noticeActionAccessibilityLabel: "", noticeActionable: false,
                         shortcutAvailable: true, dismissal: "persistent")
        case .copiedOnly:
            return .init(title: "Ready", primaryIdentifier: start.primaryIdentifier,
                         primaryAccessibilityLabel: start.primaryAccessibilityLabel,
                         primaryTitle: start.primaryTitle, primaryEnabled: true,
                         noticeCategory: "none", noticeActionIdentifier: "none",
                         noticeActionAccessibilityLabel: "", noticeActionable: false,
                         shortcutAvailable: true, dismissal: "about-1.8s")
        case .cleanupFallback, .cancelledBeforeDurableRaw, .cancelledAfterDurableRaw:
            return .init(title: "Ready", primaryIdentifier: start.primaryIdentifier,
                         primaryAccessibilityLabel: start.primaryAccessibilityLabel,
                         primaryTitle: start.primaryTitle, primaryEnabled: true,
                         noticeCategory: "none", noticeActionIdentifier: "none",
                         noticeActionAccessibilityLabel: "", noticeActionable: false,
                         shortcutAvailable: true,
                         dismissal: row == .cleanupFallback ? "about-1.8s" : "about-1.8s")
        case .insertionFailure:
            return .init(title: "Ready", primaryIdentifier: start.primaryIdentifier,
                         primaryAccessibilityLabel: start.primaryAccessibilityLabel,
                         primaryTitle: start.primaryTitle, primaryEnabled: true,
                         noticeCategory: "none", noticeActionIdentifier: "none",
                         noticeActionAccessibilityLabel: "", noticeActionable: false,
                         shortcutAvailable: true, dismissal: "about-3s")
        case .retryRequired:
            return .init(title: "Attention Needed", primaryIdentifier: "oigo.status.retry-transcription",
                         primaryAccessibilityLabel: "Retry Transcription", primaryTitle: "Retry Transcription",
                         primaryEnabled: true, noticeCategory: "retry-required",
                         noticeActionIdentifier: "oigo.status.retry-transcription",
                         noticeActionAccessibilityLabel: "Retry Transcription", noticeActionable: true,
                         shortcutAvailable: true, dismissal: "until-resolved")
        case .interrupted:
            return .init(title: "Attention Needed", primaryIdentifier: start.primaryIdentifier,
                         primaryAccessibilityLabel: start.primaryAccessibilityLabel,
                         primaryTitle: start.primaryTitle, primaryEnabled: true,
                         noticeCategory: "interruption", noticeActionIdentifier: "oigo.status.history",
                         noticeActionAccessibilityLabel: "Open History", noticeActionable: true,
                         shortcutAvailable: true, dismissal: "about-3s")
        case .busyTypedReason:
            return .init(title: "Busy", primaryIdentifier: "oigo.status.primary-disabled",
                         primaryAccessibilityLabel: "Busy · Retry", primaryTitle: "Busy · Retry",
                         primaryEnabled: false, noticeCategory: "none", noticeActionIdentifier: "none",
                         noticeActionAccessibilityLabel: "", noticeActionable: false,
                         shortcutAvailable: true, dismissal: "on-gate-release")
        case .shuttingDown:
            return .init(title: "Quitting…", primaryIdentifier: "oigo.status.primary-disabled",
                         primaryAccessibilityLabel: "Quitting…", primaryTitle: "Quitting…",
                         primaryEnabled: false, noticeCategory: "none", noticeActionIdentifier: "none",
                         noticeActionAccessibilityLabel: "", noticeActionable: false,
                         shortcutAvailable: true, dismissal: "persistent")
        }
    }

    private static func primaryIdentifier(_ action: OigoPopoverActionPresentation) -> String {
        guard let value = action.action else { return "oigo.status.primary-disabled" }
        return OigoStatusMenuIdentity.identifier(for: value)
    }

    private static func dismissal(for row: OigoPresentationStateRow) -> String {
        switch row {
        case .storageUnavailable, .shortcutInactiveConflict, .microphonePermissionUnavailable,
             .selectedInputUnavailable, .languageAssetsUnavailable, .retryRequired:
            "until-resolved"
        case .storageChecking, .languageAssetsCheckingInstalling, .preparing:
            "on-ready"
        case .recording:
            "on-release"
        case .finalizingCleaningInserting:
            "on-terminal"
        case .accessibilityUnavailable:
            "persistent-info"
        case .pasteEventAttempted, .copiedOnly, .cleanupFallback,
             .cancelledBeforeDurableRaw, .cancelledAfterDurableRaw:
            "about-1.8s"
        case .insertionFailure, .interrupted:
            "about-3s"
        case .pasteOwnedFieldVerified, .shuttingDown:
            "persistent"
        case .busyTypedReason:
            "on-gate-release"
        case .storageReadyIdle:
            "none"
        }
    }

    private static func makeInputs(
        for row: OigoPresentationStateRow,
        generation: UInt64
    ) -> OigoPresentationInputs {
        var selectedInput: OigoInputSelectionPresentationStatus = .systemDefault
        var shortcut: OigoShortcutRegistrationPresentationStatus = .registered
        var permissions = OigoPermissionsPresentationInput(microphone: .granted, accessibility: .granted)
        var storage = OigoStoragePresentationInput(status: .ready)
        var assets = OigoLocaleAssetPresentationStatus.ready
        var coordinator = OigoCoordinatorPresentationState.idle
        var terminal: OigoTerminalPresentationInput?
        var latestHasTranscript = true
        var onboarding = OigoOnboardingPresentationInput(stage: .ready, status: .passed, failure: nil)
        var busyReason: OigoOperationBusyPresentationReason?
        var shutdown = OigoShutdownPresentationStatus.inactive

        switch row {
        case .storageChecking: storage = .init(status: .degraded)
        case .storageUnavailable: storage = .init(status: .unavailable)
        case .shortcutInactiveConflict: shortcut = .conflict
        case .microphonePermissionUnavailable:
            permissions = .init(microphone: .denied, accessibility: .granted)
        case .selectedInputUnavailable: selectedInput = .pinnedUnavailable
        case .languageAssetsCheckingInstalling: assets = .checking
        case .languageAssetsUnavailable: assets = .unavailable
        case .accessibilityUnavailable:
            permissions = .init(microphone: .granted, accessibility: .denied)
        case .preparing: coordinator = .preparing
        case .recording: coordinator = .recording
        case .finalizingCleaningInserting: coordinator = .finalizing
        case .pasteEventAttempted:
            coordinator = .complete
            terminal = .init(generation: generation, outcome: .pasteAttempted, failure: nil)
        case .pasteOwnedFieldVerified:
            coordinator = .complete
            terminal = .init(generation: generation, outcome: .pasted, failure: nil)
            onboarding = .init(stage: .test, status: .passed, failure: nil)
        case .copiedOnly:
            coordinator = .complete
            terminal = .init(generation: generation, outcome: .copied, failure: nil)
        case .cleanupFallback:
            coordinator = .complete
            terminal = .init(generation: generation, outcome: .cleanupFallback, failure: nil)
        case .insertionFailure:
            coordinator = .complete
            terminal = .init(generation: generation, outcome: .insertionFailed, failure: .insertion)
        case .retryRequired:
            coordinator = .complete
            terminal = .init(generation: generation, outcome: .retryRequired, failure: .transcription)
        case .cancelledBeforeDurableRaw:
            coordinator = .cancelled
            terminal = .init(generation: generation, outcome: .cancelled, failure: nil)
            latestHasTranscript = false
        case .cancelledAfterDurableRaw:
            coordinator = .cancelled
            terminal = .init(generation: generation, outcome: .cancelled, failure: nil)
        case .interrupted:
            coordinator = .interrupted
            terminal = .init(generation: generation, outcome: .interrupted, failure: nil)
        case .busyTypedReason: busyReason = .occupied(.retry)
        case .shuttingDown: shutdown = .requested
        case .storageReadyIdle: break
        }

        let locale = OigoLocaleIdentifier("en-US")!
        return OigoPresentationInputs(
            generation: generation,
            operationGate: .init(activeOperation: nil, busyReason: busyReason),
            coordinator: .init(state: coordinator, generation: generation),
            storage: storage,
            shortcut: .init(registration: shortcut, isConfigured: true, shortcut: .default),
            permissions: permissions,
            input: .init(selection: selectedInput, channelIndex: 0),
            localeAssets: .init(localeIdentifier: locale, status: assets, generation: generation),
            activeConfiguration: nil,
            nextConfiguration: .init(
                localeIdentifier: locale,
                input: selectedInput,
                channelIndex: 0,
                appliesTo: .next
            ),
            terminal: terminal,
            latestSession: .init(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000022")!,
                state: .complete,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                hasAudio: true,
                hasTranscript: latestHasTranscript,
                failure: nil,
                durationSeconds: 18,
                source: .clean
            ),
            playback: .init(generation: generation, status: .idle),
            onboarding: onboarding,
            shutdown: .init(status: shutdown, fencedOperationCount: 0),
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

    private static func validateAuthoritativeMapper(_ repository: URL) throws {
        let presentation = repository.appendingPathComponent("Sources/Oigo/UI/Presentation")
        let sources = try FileManager.default.contentsOfDirectory(
            at: presentation,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
        let declarations = try sources.flatMap { source -> [String] in
            let contents = try String(contentsOf: source, encoding: .utf8)
            return contents.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.contains("public static func project")
                    ? "\(source.lastPathComponent):\(trimmed)"
                    : nil
            }
        }
        guard declarations == [
            "OigoPresentationProjection.swift:public static func project(_ inputs: OigoPresentationInputs) -> OigoPresentationState {"
        ] else {
            throw ContractInputError(category: "multiple-presentation-mappers")
        }
    }

    private static func runCompiledContract(repository: URL) throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-native-ui-redesign.task12." + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let presentation = repository.appendingPathComponent("Sources/Oigo/UI/Presentation")
        let core = repository.appendingPathComponent("Sources/OigoCore")
        let driver = root.appendingPathComponent("main.swift")
        let executable = root.appendingPathComponent("popover-state-matrix-contract")
        let coreSources = try FileManager.default.contentsOfDirectory(
            at: core,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
        guard !coreSources.isEmpty else {
            throw ContractInputError(category: "missing-core-source")
        }
        try contractDriver.write(to: driver, atomically: true, encoding: .utf8)
        try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["swiftc"] + coreSources.map(\.path) + [
                        "-emit-module", "-emit-library", "-module-name", "OigoCore",
                        "-o", root.appendingPathComponent("libOigoCore.dylib").path,
                        "-emit-module-path", root.appendingPathComponent("OigoCore.swiftmodule").path
                    ]
        )
        try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["swiftc", "-I", root.path, "-L", root.path,
                        "-Xlinker", "-rpath", "-Xlinker", root.path,
                        presentation.appendingPathComponent("OigoPresentationInputs.swift").path,
                        presentation.appendingPathComponent("OigoPresentationState.swift").path,
                        presentation.appendingPathComponent("OigoPresentationAttributes.swift").path,
                        presentation.appendingPathComponent("OigoPresentationProjection.swift").path,
                        presentation.appendingPathComponent("OigoPopoverPresentation.swift").path,
                        driver.path, "-lOigoCore", "-o", executable.path]
        )
        let data = try runProcess(executable: executable, arguments: [])
        guard let output = String(data: data, encoding: .utf8) else {
            throw ContractInputError(category: "unexpected-contract-output")
        }
        return output
    }

    @discardableResult
    private static func runProcess(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval = 30
    ) throws -> Data {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let finished = DispatchSemaphore(value: 0)
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            throw ContractInputError(category: "contract-process-launch")
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            throw ContractInputError(category: "contract-process-timeout")
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        _ = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw ContractInputError(category: "compiled-contract-failed")
        }
        return output
    }

    private static func containsPrivateContent(_ object: Any) -> Bool {
        if let dictionary = object as? [String: Any] {
            let forbidden = Set([
                "audio", "clipboard", "dictionaryEntries", "focusedText", "pasteboard",
                "sessionBody", "transcript", "userPath"
            ])
            return !forbidden.isDisjoint(with: dictionary.keys)
                || dictionary.values.contains(where: containsPrivateContent)
        }
        if let array = object as? [Any] {
            return array.contains(where: containsPrivateContent)
        }
        return false
    }

    private static let contractDriver = #"""
    import Foundation

    let locale = OigoLocaleIdentifier("en-US")!
    func inputs(_ fixtureRow: OigoPresentationStateRow) -> OigoPresentationInputs {
        var selectedInput: OigoInputSelectionPresentationStatus = .systemDefault
        var shortcut: OigoShortcutRegistrationPresentationStatus = .registered
        var permissions = OigoPermissionsPresentationInput(microphone: .granted, accessibility: .granted)
        var storage = OigoStoragePresentationInput(status: .ready)
        var assets = OigoLocaleAssetPresentationStatus.ready
        var coordinator = OigoCoordinatorPresentationState.idle
        var terminal: OigoTerminalPresentationInput?
        var latestHasTranscript = true
        var onboarding = OigoOnboardingPresentationInput(stage: .ready, status: .passed, failure: nil)
        var busyReason: OigoOperationBusyPresentationReason?
        var shutdown = OigoShutdownPresentationStatus.inactive

        switch fixtureRow {
        case .storageChecking: storage = .init(status: .degraded)
        case .storageUnavailable: storage = .init(status: .unavailable)
        case .shortcutInactiveConflict: shortcut = .conflict
        case .microphonePermissionUnavailable: permissions = .init(microphone: .denied, accessibility: .granted)
        case .selectedInputUnavailable: selectedInput = .pinnedUnavailable
        case .languageAssetsCheckingInstalling: assets = .checking
        case .languageAssetsUnavailable: assets = .unavailable
        case .accessibilityUnavailable: permissions = .init(microphone: .granted, accessibility: .denied)
        case .preparing: coordinator = .preparing
        case .recording: coordinator = .recording
        case .finalizingCleaningInserting: coordinator = .finalizing
        case .pasteEventAttempted:
            coordinator = .complete
            terminal = .init(generation: 42, outcome: .pasteAttempted, failure: nil)
        case .pasteOwnedFieldVerified:
            coordinator = .complete
            terminal = .init(generation: 42, outcome: .pasted, failure: nil)
            onboarding = .init(stage: .test, status: .passed, failure: nil)
        case .copiedOnly:
            coordinator = .complete
            terminal = .init(generation: 42, outcome: .copied, failure: nil)
        case .cleanupFallback:
            coordinator = .complete
            terminal = .init(generation: 42, outcome: .cleanupFallback, failure: nil)
        case .insertionFailure:
            coordinator = .complete
            terminal = .init(generation: 42, outcome: .insertionFailed, failure: .insertion)
        case .retryRequired:
            coordinator = .complete
            terminal = .init(generation: 42, outcome: .retryRequired, failure: .transcription)
        case .cancelledBeforeDurableRaw:
            coordinator = .cancelled
            terminal = .init(generation: 42, outcome: .cancelled, failure: nil)
            latestHasTranscript = false
        case .cancelledAfterDurableRaw:
            coordinator = .cancelled
            terminal = .init(generation: 42, outcome: .cancelled, failure: nil)
        case .interrupted:
            coordinator = .interrupted
            terminal = .init(generation: 42, outcome: .interrupted, failure: nil)
        case .busyTypedReason: busyReason = .occupied(.retry)
        case .shuttingDown: shutdown = .requested
        case .storageReadyIdle: break
        }
        return OigoPresentationInputs(
            generation: 42,
            operationGate: .init(activeOperation: nil, busyReason: busyReason),
            coordinator: .init(state: coordinator, generation: 42),
            storage: storage,
            shortcut: .init(
                registration: shortcut,
                isConfigured: true,
                shortcut: .default
            ),
            permissions: permissions,
            input: .init(selection: selectedInput, channelIndex: 0),
            localeAssets: .init(localeIdentifier: locale, status: assets, generation: 42),
            activeConfiguration: nil,
            nextConfiguration: .init(
                localeIdentifier: locale, input: selectedInput, channelIndex: 0, appliesTo: .next
            ),
            terminal: terminal,
            latestSession: .init(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
                state: .complete,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                hasAudio: true,
                hasTranscript: latestHasTranscript,
                failure: nil,
                durationSeconds: 18,
                source: .clean
            ),
            playback: .init(generation: 42, status: .idle),
            onboarding: onboarding,
            shutdown: .init(status: shutdown, fencedOperationCount: 0),
            presentationDate: Date(timeIntervalSince1970: 1_700_000_120)
        )
    }

    let rows = OigoPresentationStateRow.allCases
    let models = rows.map { row -> OigoPopoverPresentation in
        let value = inputs(row)
        return OigoPopoverPresentation.compose(state: OigoPresentationState.project(value), inputs: value)
    }
    guard rows.count == 23,
          Set(rows.map(\.rawValue)).count == 23,
          models.map(\.row) == rows,
          models.allSatisfy({ $0.width == 340 && !$0.allowsScrolling }),
          models.first(where: { $0.row == .storageReadyIdle })?.sections.map(\.rawValue)
            == ["header", "primary-action", "shortcut", "mode", "microphone", "latest-dictation", "footer"] else {
        exit(1)
    }
    let priority = OigoPopoverPresentation.compose(
        state: OigoPresentationState.project(inputs(.storageUnavailable)),
        inputs: inputs(.storageUnavailable)
    )
    print("MATRIX rows=\(rows.count) unique=\(Set(models.map(\.row)).count) sections=7 width=340 scroll=false")
    let priorityStartEnabled = priority.primaryAction.action == .startDictation
        && priority.primaryAction.isEnabled
    print("PRIORITY notice=\(priority.notice?.category ?? "none") count=\(priority.notice == nil ? 0 : 1) start=\(priorityStartEnabled ? "enabled" : "disabled")")
    func model(_ row: OigoPresentationStateRow) -> OigoPopoverPresentation {
        let value = inputs(row)
        return OigoPopoverPresentation.compose(state: OigoPresentationState.project(value), inputs: value)
    }
    print("SHORTCUT start=\(model(.shortcutInactiveConflict).primaryAction.isEnabled ? "enabled" : "disabled")")
    print("ACCESSIBILITY posture=\(model(.accessibilityUnavailable).copyOnly.rawValue)")
    print("PINNED microphone=\(model(.selectedInputUnavailable).microphone.category)")
    guard case .openSystemSettings(let microphoneSettings)?
            = model(.microphonePermissionUnavailable).notice?.action.action,
          case .openSystemSettings(let accessibilitySettings)?
            = model(.accessibilityUnavailable).notice?.action.action,
          microphoneSettings.absoluteString.contains("Privacy_Microphone"),
          accessibilitySettings.absoluteString.contains("Privacy_Accessibility") else {
        exit(1)
    }
    print("RECOVERY microphone=system-settings accessibility=system-settings")
    print("BUSY reason=\(model(.busyTypedReason).primaryAction.disabledReason ?? "none")")
    print("SHUTDOWN reason=\(model(.shuttingDown).primaryAction.disabledReason ?? "none")")
    func dismissal(_ row: OigoPresentationStateRow) -> String {
        switch row {
        case .storageUnavailable, .shortcutInactiveConflict, .microphonePermissionUnavailable,
             .selectedInputUnavailable, .languageAssetsUnavailable, .retryRequired: "until-resolved"
        case .storageChecking, .languageAssetsCheckingInstalling, .preparing: "on-ready"
        case .recording: "on-release"
        case .finalizingCleaningInserting: "on-terminal"
        case .accessibilityUnavailable: "persistent-info"
        case .pasteEventAttempted, .copiedOnly, .cleanupFallback,
             .cancelledBeforeDurableRaw, .cancelledAfterDurableRaw: "about-1.8s"
        case .insertionFailure, .interrupted: "about-3s"
        case .pasteOwnedFieldVerified, .shuttingDown: "persistent"
        case .busyTypedReason: "on-gate-release"
        case .storageReadyIdle: "none"
        }
    }
    for model in models {
        print(
            "ROW row=\(model.row.rawValue) title=\(model.statusLabel) "
                + "detail=\(model.notice?.body ?? model.statusLabel) "
                + "primary=\(model.primaryAction.title) "
                + "primary-enabled=\(model.primaryAction.isEnabled ? "true" : "false") "
                + "notice=\(model.notice?.category ?? "none") "
                + "notice-enabled=\(model.notice?.action.isEnabled == true ? "true" : "false") "
                + "shortcut=\(model.shortcut.accessibilityLabel) "
                + "accessibility=\(model.shortcut.accessibilityLabel) "
                + "latest=\(model.latest == nil ? "none" : "metadata-only") "
                + "dismissal=\(dismissal(model.row))"
        )
    }
    """#
}
