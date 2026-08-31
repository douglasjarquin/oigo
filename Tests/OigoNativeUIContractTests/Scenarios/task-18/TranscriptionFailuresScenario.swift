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
        let hudState: OigoTerminalHUDPresentationState?
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
        if let cases = fixture.cases {
            guard Set(cases) == Set(caseNames), cases.count == caseNames.count else {
                throw ContractInputError(category: "incomplete-transcription-failure-fixture")
            }
            let hudStates = try caseNames.compactMap { name -> OigoTerminalHUDPresentationState? in
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
        let inputs = try inputs(for: name, generation: 7)
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
        if let terminal = inputs.terminal {
            let hudState = OigoSessionPresentationProjection.terminalHUDState(
                for: terminal,
                latestSession: inputs.latestSession
            )
            guard hudState == expectation.hudState,
                  hudState != .pasteAttempted,
                  hudState != .terminal else {
                throw ContractInputError(category: "transcription-hud-bridge-mismatch-" + name)
            }
        } else if expectation.hudState != nil {
            throw ContractInputError(category: "transcription-hud-bridge-missing-" + name)
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
        let committed = OigoPresentationPublication(inputs: try inputs(for: "interrupted", generation: 7))
        var fence = OigoPresentationGenerationFence()
        var published: OigoPresentationPublication?
        guard fence.publish(committed, to: { published = $0 }),
              published == committed,
              !caseNames.contains(fixture.rejectedCase ?? "") else {
            throw ContractInputError(category: "transcription-transition-setup-failed")
        }
        guard published == committed, published?.generation == 7, published?.state.row == .interrupted else {
            throw ContractInputError(category: "rejected-transition-mutated-committed-state")
        }
    }

    private static func expectation(for name: String) -> Expectation {
        switch name {
        case "permission-denied": .init(row: .microphonePermissionUnavailable, hud: .hidden, hudState: nil, notice: .microphonePermission, primary: .disabled(.startDictation, .microphoneUnavailable), actions: [], copyOnly: .inactive)
        case "input-unavailable": .init(row: .selectedInputUnavailable, hud: .hidden, hudState: nil, notice: .selectedInput, primary: .disabled(.startDictation, .selectedInputUnavailable), actions: [], copyOnly: .inactive)
        case "missing-assets": .init(row: .languageAssetsUnavailable, hud: .hidden, hudState: nil, notice: .languageAssets, primary: .disabled(.startDictation, .languageAssetsUnavailable), actions: [], copyOnly: .inactive)
        case "copy-only": .init(row: .copiedOnly, hud: .copied, hudState: .copyOnly, notice: .accessibilityCopyOnly, primary: .enabled(.startDictation), actions: [.pasteAgain, .openHistory], copyOnly: .copied)
        case "cancelled-before-raw": .init(row: .cancelledBeforeDurableRaw, hud: .cancelled, hudState: .cancelledBeforeRaw, notice: nil, primary: .enabled(.startDictation), actions: [], copyOnly: .inactive)
        case "cancelled-after-raw": .init(row: .cancelledAfterDurableRaw, hud: .cancelled, hudState: .cancelledAfterRaw, notice: nil, primary: .enabled(.startDictation), actions: [.openHistory], copyOnly: .inactive)
        case "interrupted": .init(row: .interrupted, hud: .interrupted, hudState: .interrupted, notice: .interruption, primary: .enabled(.startDictation), actions: [.openHistory], copyOnly: .inactive)
        case "speech-unavailable": .init(row: .retryRequired, hud: .retryRequired, hudState: .savedRetry, notice: .retryRequired, primary: .enabled(.retryTranscription), actions: [.retryTranscription, .openHistory], copyOnly: .inactive)
        case "audio-failed", "preserved-failure": .init(row: .retryRequired, hud: .retryRequired, hudState: .preservedFailure, notice: .retryRequired, primary: .enabled(.retryTranscription), actions: [.retryTranscription, .openHistory], copyOnly: .inactive)
        default: fatalError("validated fixture case missing expectation")
        }
    }

    private static func inputs(for name: String, generation: UInt64) throws -> OigoPresentationInputs {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-task18-session-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try failureInput(named: name, persistenceRoot: root)!
        let locale = OigoLocaleIdentifier("en-US")!
        return .init(generation: generation, operationGate: .init(activeOperation: nil, busyReason: nil), coordinator: .init(state: input.coordinator, generation: generation), storage: .init(status: .ready), shortcut: .init(registration: .registered, isConfigured: true, shortcut: .init(keyCode: 0, modifiers: ToggleShortcutModifiers.command)), permissions: .init(microphone: input.microphone, accessibility: input.accessibility), input: .init(selection: input.selection, channelIndex: 0), localeAssets: .init(localeIdentifier: locale, status: input.assets, generation: generation), activeConfiguration: nil, nextConfiguration: .init(localeIdentifier: locale, input: .systemDefault, channelIndex: 0, appliesTo: .next), terminal: input.terminal.map { .init(generation: generation, outcome: $0.0, failure: $0.1) }, latestSession: input.latest, playback: .init(generation: generation, status: .idle), onboarding: .init(stage: .complete, status: .passed, failure: nil), shutdown: .init(status: .inactive, fencedOperationCount: 0))
    }

    private static func failureInput(named name: String?, persistenceRoot: URL) throws -> (coordinator: OigoCoordinatorPresentationState, microphone: OigoPermissionPresentationStatus, accessibility: OigoPermissionPresentationStatus, selection: OigoInputSelectionPresentationStatus, assets: OigoLocaleAssetPresentationStatus, terminal: (OigoTerminalPresentationOutcome, OigoTerminalPresentationFailure?)?, latest: OigoLatestSessionPresentationInput?)? {
        let latest = try persistedLatestSession(for: name, root: persistenceRoot)
        switch name {
        case "permission-denied": return (.idle, .denied, .granted, .systemDefault, .ready, nil, latest)
        case "input-unavailable": return (.idle, .granted, .granted, .noAvailableInput, .ready, nil, latest)
        case "missing-assets": return (.idle, .granted, .granted, .systemDefault, .unavailable, nil, latest)
        case "copy-only": return (.complete, .granted, .denied, .systemDefault, .ready, (.copied, nil), latest)
        case "cancelled-before-raw": return (.cancelled, .granted, .granted, .systemDefault, .ready, (.cancelled, nil), latest)
        case "cancelled-after-raw": return (.cancelled, .granted, .granted, .systemDefault, .ready, (.cancelled, nil), latest)
        case "interrupted": return (.interrupted, .granted, .granted, .systemDefault, .ready, (.interrupted, nil), latest)
        case "speech-unavailable": return (.failed, .granted, .granted, .systemDefault, .ready, (.retryRequired, .transcription), latest)
        case "audio-failed", "preserved-failure": return (.failed, .granted, .granted, .systemDefault, .ready, (.failed, .capture), latest)
        default: return nil
        }
    }

    private static func persistedLatestSession(
        for name: String?,
        root: URL
    ) throws -> OigoLatestSessionPresentationInput? {
        let store = try SessionStore(rootDirectory: root)
        guard let name, !["permission-denied", "input-unavailable", "missing-assets"].contains(name) else {
            guard try store.listSessions().isEmpty, try store.listHistory().isEmpty else {
                throw ContractInputError(category: "failed-start-created-durable-session")
            }
            return nil
        }

        let finalState: DictationSessionState
        let failureCode: DictationFailureCode?
        let hasAudio: Bool
        let rawText: String?
        let insertionOutcome: InsertionOutcome?
        switch name {
        case "copy-only":
            (finalState, failureCode, hasAudio, rawText, insertionOutcome) = (.completed, nil, true, "durable copy-only transcript", .copied)
        case "cancelled-before-raw":
            (finalState, failureCode, hasAudio, rawText, insertionOutcome) = (.cancelled, .cancelled, false, nil, nil)
        case "cancelled-after-raw":
            (finalState, failureCode, hasAudio, rawText, insertionOutcome) = (.cancelled, .cancelled, true, "durable cancelled transcript", nil)
        case "interrupted":
            (finalState, failureCode, hasAudio, rawText, insertionOutcome) = (.interrupted, .applicationQuit, true, nil, nil)
        case "speech-unavailable":
            (finalState, failureCode, hasAudio, rawText, insertionOutcome) = (.failed, .transcriptionFailed, true, nil, nil)
        case "audio-failed":
            (finalState, failureCode, hasAudio, rawText, insertionOutcome) = (.failed, .audioEngineStartFailed, true, nil, nil)
        case "preserved-failure":
            (finalState, failureCode, hasAudio, rawText, insertionOutcome) = (.failed, .audioInputConfigurationChanged, true, "durable preserved transcript", nil)
        default:
            throw ContractInputError(category: "unknown-durable-transcription-case")
        }

        var session = try store.createSession(now: Date(timeIntervalSince1970: 1_700_000_000))
        if hasAudio {
            let audio = Data([0x43, 0x41, 0x46, 0x01])
            try audio.write(to: session.audioURL, options: [.atomic])
            session = try store.update(session, state: .preparing, audioByteCount: Int64(audio.count))
        }
        if let rawText {
            session = try store.appendRawText(rawText, for: session)
        }
        session = try store.update(
            session,
            state: finalState,
            failureReason: failureCode == nil ? nil : "synthetic failure",
            failureCode: failureCode,
            insertionOutcome: insertionOutcome
        )

        let reopened = try SessionStore(rootDirectory: root)
        let persisted = try reopened.load(id: session.id)
        let audioData = try? Data(contentsOf: persisted.audioURL)
        let persistedRawText = try? reopened.readRawText(for: persisted)
        let history = try reopened.listHistory()
        guard try reopened.listSessions().map(\.id) == [session.id],
              history.map(\.session.id) == [session.id],
              persisted.metadata.state == finalState,
              (audioData?.isEmpty == false) == hasAudio,
              (persistedRawText?.isEmpty == false) == (rawText != nil),
              persisted.metadata.audioByteCount == (hasAudio ? Int64(audioData?.count ?? 0) : nil),
              persisted.metadata.rawTextByteCount == (rawText.map { Int64($0.utf8.count) }) else {
            throw ContractInputError(category: "durable-transcription-outcome-mismatch-" + name)
        }
        let latest = OigoSessionPresentationProjection.latestSession(persisted)
        let expectedLatestState: OigoLatestSessionPresentationState = switch finalState {
        case .preparing: .preparing
        case .recording: .recording
        case .stopping: .stopping
        case .retrying: .retrying
        case .completed: .complete
        case .failed: .failed
        case .cancelled: .cancelled
        case .interrupted: .interrupted
        }
        guard latest.hasAudio == hasAudio,
              latest.hasTranscript == (rawText != nil),
              latest.state == expectedLatestState else {
            throw ContractInputError(category: "durable-transcription-projection-mismatch-" + name)
        }
        return latest
    }

    private static func assertHUDPolicies(for states: [OigoTerminalHUDPresentationState]) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oigo-task18-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let executable = root.appendingPathComponent("hud-contract")
        let driver = root.appendingPathComponent("main.swift")
        try hudDriver.write(to: driver, atomically: true, encoding: .utf8)
        try run(executable: "/usr/bin/xcrun", arguments: ["swiftc", repository.appendingPathComponent("Sources/Oigo/UI/HUD/OigoHUDState.swift").path, repository.appendingPathComponent("Sources/Oigo/UI/HUD/OigoHUDPolicy.swift").path, driver.path, "-o", executable.path])
        try run(executable: executable.path, arguments: states.map(\.rawValue))
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
