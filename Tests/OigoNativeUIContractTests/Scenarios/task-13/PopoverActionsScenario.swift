import Darwin
import Foundation

final class PopoverActionsScenario: NativeUIContractScenario {
    private struct Fixture: Decodable {
        let name: String
        let latestLimit: Int
        let latestLoadTrigger: String
        let transcriptReadsOnOpen: Int
        let transcriptReadsAfterCopy: Int
        let staleRequestGeneration: UInt64
        let currentGeneration: UInt64
        let persistedMode: String
        let failedModeCandidate: String
        let committedModeAfterFailure: String
        let actions: [String]
        let keyboardOrder: [String]
        let popoverTasksAfterDismissal: Int
        let popoverObserversAfterDismissal: Int
        let retainedLatestSessionsAfterDismissal: Int
        let activeDictationCancelledOnDismissal: Bool
        let dirty: Bool?
        let retryDurationMilliseconds: Int?
        let eventOrder: [String]?
        let reportedSuccess: Bool?
        let processExitStatus: Int?
        let interruptions: Int?
    }

    override class var scenarioName: String { "popover-actions" }

    override class func run(arguments: ContractArguments) throws {
        guard arguments.defaultsSuite == "com.oigo.qa.task13" else {
            throw ContractInputError(category: "invalid-defaults-suite")
        }
        let fixture = try loadFixture(arguments.fixtureRoot.appendingPathComponent("fixture.json"))
        try validate(fixture)
        if let duration = fixture.retryDurationMilliseconds {
            _ = try runProcess(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: [String(Double(duration) / 1_000)],
                timeout: 0.1
            )
        }
        try validateProductContracts()
        print(
            "PASS popover-actions fixture=" + fixture.name
                + " latest-limit=1 latest-trigger=event"
                + " rollback=committed stale=ignored copy-read=invocation-only"
                + " keyboard=deterministic resources=0"
        )
    }

    private static func loadFixture(_ url: URL) throws -> Fixture {
        guard let data = try? Data(contentsOf: url) else {
            throw ContractInputError(category: "missing-fixture")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ContractInputError(category: "malformed-popover-actions-fixture")
        }
        guard !containsPrivateContent(object) else {
            throw ContractInputError(category: "forbidden-user-content")
        }
        do {
            return try JSONDecoder().decode(Fixture.self, from: data)
        } catch {
            throw ContractInputError(category: "malformed-popover-actions-fixture")
        }
    }

    private static func validate(_ fixture: Fixture) throws {
        guard fixture.staleRequestGeneration < fixture.currentGeneration else {
            throw ContractInputError(category: "stale-callback")
        }
        if fixture.dirty == true {
            throw ContractInputError(category: "dirty-worktree")
        }
        if let eventOrder = fixture.eventOrder,
           eventOrder != ["requested", "persisted", "published"] {
            throw ContractInputError(category: "flaky-event-ordering")
        }
        if fixture.reportedSuccess == true, fixture.processExitStatus != 0 {
            print("PASS decoy-only")
            throw ContractInputError(category: "misleading-success-output")
        }
        if let interruptions = fixture.interruptions, interruptions > 1 {
            throw ContractInputError(category: "repeated-interruption")
        }
        guard fixture.name == "bounded-summary-and-rollback",
              fixture.latestLimit == 1,
              fixture.latestLoadTrigger == "session-event",
              fixture.transcriptReadsOnOpen == 0,
              fixture.transcriptReadsAfterCopy == 1,
              fixture.persistedMode == "instant",
              fixture.failedModeCandidate == "clean",
              fixture.committedModeAfterFailure == fixture.persistedMode,
              fixture.actions == [
                "copy", "paste-again", "retry-transcription", "open-history",
                "open-settings", "quit", "escape", "tab", "return", "space"
              ],
              fixture.keyboardOrder == [
                "primary", "mode", "microphone", "latest", "history", "settings", "quit"
              ],
              fixture.popoverTasksAfterDismissal == 0,
              fixture.popoverObserversAfterDismissal == 0,
              fixture.retainedLatestSessionsAfterDismissal == 0,
              !fixture.activeDictationCancelledOnDismissal else {
            throw ContractInputError(category: "incomplete-popover-actions-contract")
        }
    }

    private static func validateProductContracts() throws {
        let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let controllerURL = repository.appendingPathComponent("Sources/Oigo/StatusSurfaceController.swift")
        let viewURL = repository.appendingPathComponent(
            "Sources/Oigo/UI/Presentation/OigoPopoverViewController.swift"
        )
        let actionURL = repository.appendingPathComponent(
            "Sources/Oigo/UI/Presentation/OigoPopoverCommand.swift"
        )
        let delegateURL = repository.appendingPathComponent("Sources/Oigo/OigoAppDelegate.swift")
        guard let controller = try? String(contentsOf: controllerURL, encoding: .utf8),
              let view = try? String(contentsOf: viewURL, encoding: .utf8),
              let action = try? String(contentsOf: actionURL, encoding: .utf8),
              let delegate = try? String(contentsOf: delegateURL, encoding: .utf8) else {
            throw ContractInputError(category: "missing-popover-actions-source")
        }

        let commandTokens = [
            "struct OigoPopoverCommand", "enum OigoPopoverCommandIntent",
            "case presentation(OigoPresentationAction)",
            "case selectInput", "case dismiss", "case moveFocus", "case invokeFocused"
        ]
        guard commandTokens.allSatisfy(action.contains),
              controller.contains("guard command.generation == presentationGeneration"),
              controller.contains("popover.close()"),
              controller.contains("popoverDidClose"),
              view.contains("func dismiss()"),
              view.contains("focusTask?.cancel()"),
              view.contains("nextKeyView"),
              delegate.contains("listHistoryReport(\n                    limit: 1"),
              delegate.contains("applyPopoverInputSelection"),
              delegate.contains("applyPopoverMode"),
              delegate.contains("copyLatestTranscript()"),
              delegate.contains("pasteLatestTranscript()"),
              delegate.contains("retryLastTranscription()") else {
            throw ContractInputError(category: "incomplete-popover-actions-source")
        }
        guard !controller.contains("AppOperationGate"),
              !controller.contains("SessionStore"),
              !view.contains("readRawText"),
              !view.contains("readCleanText") else {
            throw ContractInputError(category: "forbidden-popover-owner")
        }
        guard let refreshRange = delegate.range(of: "private func refreshHistory()"),
              let moreRange = delegate.range(
                of: "private func loadMoreHistory()",
                range: refreshRange.upperBound..<delegate.endIndex
              ) else {
            throw ContractInputError(category: "missing-latest-summary-query")
        }
        let refresh = String(delegate[refreshRange.lowerBound..<moreRange.lowerBound])
        guard refresh.contains("listHistoryReport(\n                    limit: 1"),
              !refresh.contains("listHistory()") else {
            throw ContractInputError(category: "unbounded-latest-summary-read")
        }
    }

    @discardableResult
    private static func runProcess(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> Data {
        let process = Process()
        let finished = DispatchSemaphore(value: 0)
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            throw ContractInputError(category: "long-running-retry-cancelled")
        }
        guard process.terminationStatus == 0 else {
            throw ContractInputError(category: "adversarial-process-failed")
        }
        return Data()
    }

    private static func containsPrivateContent(_ object: Any) -> Bool {
        if let dictionary = object as? [String: Any] {
            let forbidden = Set([
                "audio", "clipboard", "dictionaryEntries", "focusedText", "identifier",
                "microphone", "pasteboard", "sessionBody", "transcript", "userPath"
            ])
            return !forbidden.isDisjoint(with: dictionary.keys)
                || dictionary.values.contains(where: containsPrivateContent)
        }
        if let array = object as? [Any] {
            return array.contains(where: containsPrivateContent)
        }
        return false
    }
}
