import Foundation
import OigoCore
import OigoPresentation

final class TranscriptionFailuresScenario: NativeUIContractScenario {
    private struct Fixture: Decodable {
        let scenario: String
        let provider: String
        let cases: [String]?
        let previousCommittedCase: String?
        let rejectedCase: String?
    }

    private struct Expectation {
        let row: OigoPresentationStateRow
        let hud: OigoHUDPolicy
        let hudState: String?
        let notice: OigoNotice?
        let primary: OigoPrimaryPresentationAction
        let actions: [OigoPresentationAction]
        let copyOnly: OigoCopyOnlyPosture
    }

    private static let caseNames = [
        "permission-denied", "input-unavailable", "speech-unavailable", "audio-failed",
        "missing-assets", "copy-only", "preserved-failure", "cancelled-before-raw",
        "cancelled-after-raw", "interrupted"
    ]

    override class var scenarioName: String { "transcription-failures" }

    override class func run(arguments: ContractArguments) throws {
        guard arguments.defaultsSuite == "com.oigo.qa.task18" else {
            throw ContractInputError(category: "invalid-defaults-suite")
        }
        let fixture = try loadFixture(from: arguments.fixtureRoot)
        guard fixture.scenario == scenarioName, fixture.provider == "synthetic" else {
            throw ContractInputError(category: "malformed-transcription-fixture")
        }
        try assertHUDBridge()
        if let cases = fixture.cases {
            guard Set(cases) == Set(caseNames), cases.count == caseNames.count else {
                throw ContractInputError(category: "incomplete-transcription-failure-fixture")
            }
            let hudStates = try caseNames.compactMap { name -> String? in
                let expectation = expectation(for: name)
                try assertProjection(for: name, expectation: expectation)
                return expectation.hudState
            }
            try assertHUDPolicies(for: hudStates)
            print("PASS transcription-failures cases=\(caseNames.count) provider=synthetic")
            return
        }
        try assertRejectedTransition(fixture)
        print("PASS transcription-failures rejected-transition=unchanged provider=synthetic")
    }

    private static func loadFixture(from root: URL) throws -> Fixture {
        let url = root.appendingPathComponent("fixture.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !containsUserContent(object),
              let fixture = try? JSONDecoder().decode(Fixture.self, from: data) else {
            throw ContractInputError(category: "malformed-transcription-fixture")
        }
        return fixture
    }

    private static func containsUserContent(_ value: Any) -> Bool {
        if let object = value as? [String: Any] {
            let forbidden = Set(["audio", "clipboard", "focusedText", "transcript", "userPath"])
            return !forbidden.isDisjoint(with: object.keys) || object.values.contains(where: containsUserContent)
        }
        return (value as? [Any])?.contains(where: containsUserContent) == true
    }

    private static func assertProjection(for name: String, expectation: Expectation) throws {
        let inputs = inputs(for: name, generation: 7)
        let state = OigoPresentationState.project(inputs)
        let popover = OigoPopoverPresentation.compose(state: state, inputs: inputs)
        let actions = popover.latest?.actions.compactMap(\.action) ?? []
        let shortcut = inputs.shortcut.copy
        let primaryEnabled: Bool = {
            if case .enabled = expectation.primary { return true }
            return false
        }()
        guard state.row == expectation.row,
              state.hud == expectation.hud,
              state.notice == expectation.notice,
              state.primaryAction == expectation.primary,
              state.copyOnly == expectation.copyOnly,
              actions == expectation.actions,
              popover.row == expectation.row,
              popover.primaryAction.isEnabled == primaryEnabled,
              popover.shortcut.isAvailable,
              popover.shortcut.holdHint == shortcut.holdHint,
              popover.shortcut.holdHint != ToggleShortcut.default.copy.holdHint,
              state.row != .recording,
              state.hud != .recording,
              state.hud != .pasteAttempted,
              state.hud != .ownedFieldVerified,
              popover.primaryAction.action != .stopDictation else {
            throw ContractInputError(category: "transcription-failure-presentation-mismatch-" + name)
        }
        if name == "copy-only" {
            guard popover.latest?.actions.map(\.action) == [.pasteAgain, .openHistory] else {
                throw ContractInputError(category: "copy-only-history-unavailable")
            }
        }
    }

    private static func assertRejectedTransition(_ fixture: Fixture) throws {
        guard fixture.previousCommittedCase == "interrupted", fixture.rejectedCase == "unknown-state" else {
            throw ContractInputError(category: "malformed-transcription-unknown-state")
        }
        let committed = OigoPresentationPublication(inputs: inputs(for: "interrupted", generation: 7))
        var fence = OigoPresentationGenerationFence()
        var published: OigoPresentationPublication?
        guard fence.publish(committed, to: { published = $0 }),
              published == committed,
              failureInput(named: fixture.rejectedCase) == nil else {
            throw ContractInputError(category: "transcription-transition-setup-failed")
        }
        guard published == committed, published?.generation == 7, published?.state.row == .interrupted else {
            throw ContractInputError(category: "rejected-transition-mutated-committed-state")
        }
    }

    private static func assertHUDBridge() throws {
        let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/Oigo/OigoAppDelegate.swift")
        guard let text = try? String(contentsOf: source, encoding: .utf8),
              text.contains("case .idle, .complete, .failed, .cancelled, .interrupted:"),
              text.contains("state = terminal.map(hudTerminalState)"),
              text.contains("case .copied:\n            .copyOnly"),
              text.contains("case .insertionFailed, .failed:\n            .preservedFailure"),
              text.contains("case .retryRequired:\n            .savedRetry"),
              text.contains("? .cancelledAfterRaw : .cancelledBeforeRaw"),
              text.contains("case .interrupted:\n            .interrupted") else {
            throw ContractInputError(category: "transcription-hud-bridge-mismatch")
        }
    }

    private static func expectation(for name: String) -> Expectation {
        switch name {
        case "permission-denied": .init(row: .microphonePermissionUnavailable, hud: .hidden, hudState: nil, notice: .microphonePermission, primary: .disabled(.startDictation, .microphoneUnavailable), actions: [], copyOnly: .inactive)
        case "input-unavailable": .init(row: .selectedInputUnavailable, hud: .hidden, hudState: nil, notice: .selectedInput, primary: .disabled(.startDictation, .selectedInputUnavailable), actions: [], copyOnly: .inactive)
        case "missing-assets": .init(row: .languageAssetsUnavailable, hud: .hidden, hudState: nil, notice: .languageAssets, primary: .disabled(.startDictation, .languageAssetsUnavailable), actions: [], copyOnly: .inactive)
        case "copy-only": .init(row: .copiedOnly, hud: .copied, hudState: "copy-only", notice: .accessibilityCopyOnly, primary: .enabled(.startDictation), actions: [.pasteAgain, .openHistory], copyOnly: .copied)
        case "cancelled-before-raw": .init(row: .cancelledBeforeDurableRaw, hud: .cancelled, hudState: "cancelled-before-raw", notice: nil, primary: .enabled(.startDictation), actions: [], copyOnly: .inactive)
        case "cancelled-after-raw": .init(row: .cancelledAfterDurableRaw, hud: .cancelled, hudState: "cancelled-after-raw", notice: nil, primary: .enabled(.startDictation), actions: [.openHistory], copyOnly: .inactive)
        case "interrupted": .init(row: .interrupted, hud: .interrupted, hudState: "interrupted", notice: .interruption, primary: .enabled(.startDictation), actions: [.openHistory], copyOnly: .inactive)
        case "speech-unavailable": .init(row: .retryRequired, hud: .retryRequired, hudState: "saved-retry", notice: .retryRequired, primary: .enabled(.retryTranscription), actions: [.retryTranscription, .openHistory], copyOnly: .inactive)
        case "audio-failed", "preserved-failure": .init(row: .retryRequired, hud: .retryRequired, hudState: "preserved-failure", notice: .retryRequired, primary: .enabled(.retryTranscription), actions: [.retryTranscription, .openHistory], copyOnly: .inactive)
        default: fatalError("validated fixture case missing expectation")
        }
    }

    private static func inputs(for name: String, generation: UInt64) -> OigoPresentationInputs {
        let input = failureInput(named: name)!
        let locale = OigoLocaleIdentifier("en-US")!
        return .init(generation: generation, operationGate: .init(activeOperation: nil, busyReason: nil), coordinator: .init(state: input.coordinator, generation: generation), storage: .init(status: .ready), shortcut: .init(registration: .registered, isConfigured: true, shortcut: .init(keyCode: 0, modifiers: ToggleShortcutModifiers.command)), permissions: .init(microphone: input.microphone, accessibility: input.accessibility), input: .init(selection: input.selection, channelIndex: 0), localeAssets: .init(localeIdentifier: locale, status: input.assets, generation: generation), activeConfiguration: nil, nextConfiguration: .init(localeIdentifier: locale, input: .systemDefault, channelIndex: 0, appliesTo: .next), terminal: input.terminal.map { .init(generation: generation, outcome: $0.0, failure: $0.1) }, latestSession: input.latest, playback: .init(generation: generation, status: .idle), onboarding: .init(stage: .complete, status: .passed, failure: nil), shutdown: .init(status: .inactive, fencedOperationCount: 0))
    }

    private static func failureInput(named name: String?) -> (coordinator: OigoCoordinatorPresentationState, microphone: OigoPermissionPresentationStatus, accessibility: OigoPermissionPresentationStatus, selection: OigoInputSelectionPresentationStatus, assets: OigoLocaleAssetPresentationStatus, terminal: (OigoTerminalPresentationOutcome, OigoTerminalPresentationFailure?)?, latest: OigoLatestSessionPresentationInput?)? {
        let latest = { (state: OigoLatestSessionPresentationState, audio: Bool, transcript: Bool) in OigoLatestSessionPresentationInput(id: UUID(uuidString: "CE882CF9-B7D9-4D8E-852D-7C1E0B703E34")!, state: state, createdAt: .distantPast, hasAudio: audio, hasTranscript: transcript, failure: nil) }
        switch name {
        case "permission-denied": return (.idle, .denied, .granted, .systemDefault, .ready, nil, nil)
        case "input-unavailable": return (.idle, .granted, .granted, .noAvailableInput, .ready, nil, nil)
        case "missing-assets": return (.idle, .granted, .granted, .systemDefault, .unavailable, nil, nil)
        case "copy-only": return (.complete, .granted, .denied, .systemDefault, .ready, (.copied, nil), latest(.complete, true, true))
        case "cancelled-before-raw": return (.cancelled, .granted, .granted, .systemDefault, .ready, (.cancelled, nil), nil)
        case "cancelled-after-raw": return (.cancelled, .granted, .granted, .systemDefault, .ready, (.cancelled, nil), latest(.cancelled, true, true))
        case "interrupted": return (.interrupted, .granted, .granted, .systemDefault, .ready, (.interrupted, nil), latest(.interrupted, true, false))
        case "speech-unavailable": return (.failed, .granted, .granted, .systemDefault, .ready, (.retryRequired, .transcription), latest(.failed, true, false))
        case "audio-failed", "preserved-failure": return (.failed, .granted, .granted, .systemDefault, .ready, (.failed, .capture), latest(.failed, true, false))
        default: return nil
        }
    }

    private static func assertHUDPolicies(for states: [String]) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oigo-task18-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let executable = root.appendingPathComponent("hud-contract")
        let driver = root.appendingPathComponent("main.swift")
        try hudDriver.write(to: driver, atomically: true, encoding: .utf8)
        try run(executable: "/usr/bin/xcrun", arguments: ["swiftc", repository.appendingPathComponent("Sources/Oigo/UI/HUD/OigoHUDState.swift").path, repository.appendingPathComponent("Sources/Oigo/UI/HUD/OigoHUDPolicy.swift").path, driver.path, "-o", executable.path])
        try run(executable: executable.path, arguments: states)
    }

    private static func run(executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ContractInputError(category: "transcription-hud-contract-failed")
        }
    }

    private static let hudDriver = """
    import Foundation

    for raw in CommandLine.arguments.dropFirst() {
        guard let state = OigoHUDState(rawValue: raw) else { exit(1) }
        let content = OigoHUDShellPolicy.content(for: state, releaseHint: "synthetic")
        guard content.isTerminal, !content.showsRecordingElapsed, !content.allowsPreview else { exit(2) }
        switch state {
        case .copyOnly: guard content.actionability == .pasteAgain, content.dismissal.seconds == 3 else { exit(3) }
        case .savedRetry: guard content.actionability == .retryTranscription, content.dismissal.seconds == 3 else { exit(4) }
        case .preservedFailure: guard content.actionability == .copyAndPasteAgain, content.dismissal.seconds == 3 else { exit(5) }
        case .cancelledBeforeRaw: guard content.actionability == .none, content.dismissal.seconds == 1.8 else { exit(6) }
        case .cancelledAfterRaw, .interrupted: guard content.actionability == .openHistory, content.dismissal.seconds == 3 else { exit(7) }
        default: exit(8)
        }
    }
    """
}
