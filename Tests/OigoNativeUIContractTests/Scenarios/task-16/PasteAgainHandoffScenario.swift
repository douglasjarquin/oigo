import Foundation
import OigoCore
import OigoInsertion

final class PasteAgainHandoffScenario: NativeUIContractScenario {
    private struct Fixture: Decodable {
        struct GeometryCaptures: Decodable {
            let dictationStart: Int
            let pasteAgainHandoff: Int
            let other: Int
            let persisted: Int
        }

        struct Resources: Decodable {
            let operations: Int
            let timers: Int
            let accessibilityObjects: Int
            let geometrySnapshots: Int
            let panels: Int
        }

        let name: String
        let operationAGeneration: UInt64
        let operationBGeneration: UInt64
        let lateAResultAfterBStart: Bool
        let expectedPublishedGenerations: [UInt64]
        let outcomes: [String]
        let terminalCategories: [String]
        let geometryCaptures: GeometryCaptures
        let resourcesAfterShutdown: Resources
        let gateReleasedAfterTimeout: Bool
        let gateReleasedAfterCancel: Bool
        let hudHideCancelledDictation: Bool
        let historyAndHUDTerminalCategoryMatch: Bool
        let dirty: Bool?
        let staleCallback: Bool?
        let handoffDelayMilliseconds: Int?
        let flakyNativeTarget: Bool?
        let reportedSuccess: Bool?
        let processExitStatus: Int?
        let interruptions: Int?
    }

    override class var scenarioName: String { "paste-again-handoff" }

    override class func run(arguments: ContractArguments) throws {
        guard arguments.defaultsSuite == "com.oigo.qa.task16" else {
            throw ContractInputError(category: "invalid-defaults-suite")
        }
        let fixture = try loadFixture(arguments.fixtureRoot.appendingPathComponent("fixture.json"))
        try validate(fixture)
        try validateGenerationAndGate(fixture)
        try validateHandoffOutcomes()
        try validateProductSource()
        print(
            "PASS paste-again-handoff fixture=" + fixture.name
                + " outcomes=success,copy-only,timeout,cancel"
                + " stale=fenced gate=released resources=0"
        )
    }

    private final class AsyncResultBox<Value>: @unchecked Sendable {
        var result: Result<Value, Error>?
    }

    private static func validateHandoffOutcomes() throws {
        try runOnMainActor {
            let target = InsertionTargetSnapshot(
                frontmostProcessIdentifier: 7,
                bundleIdentifier: "synthetic.target",
                focusedElementIdentifier: "synthetic-field",
                role: "synthetic-role",
                isSecureTextField: false
            )

            var successRecorded: [InsertionOutcome] = []
            let success = await InsertionPasteAgainFlow(
                handoff: InsertionTargetHandoff(maxAttempts: 2)
            ).run(
                capture: { target },
                paste: { _ in InsertionResult(outcome: .dispatched) },
                copyOnly: { _ in InsertionResult(outcome: .failed) },
                isCurrent: { true },
                recordOutcome: { successRecorded.append($0.outcome) }
            )

            var copyOnlyRecorded: [InsertionOutcome] = []
            let copyOnly = await InsertionPasteAgainFlow(
                handoff: InsertionTargetHandoff(maxAttempts: 2)
            ).run(
                capture: { target },
                paste: { _ in InsertionResult(outcome: .copied) },
                copyOnly: { _ in InsertionResult(outcome: .failed) },
                isCurrent: { true },
                recordOutcome: { copyOnlyRecorded.append($0.outcome) }
            )

            let invalidTarget = InsertionTargetSnapshot(
                frontmostProcessIdentifier: 0,
                bundleIdentifier: nil,
                focusedElementIdentifier: nil,
                role: nil,
                isSecureTextField: false
            )
            var timeoutRecorded: [InsertionReasonCode?] = []
            let timedOut = await InsertionPasteAgainFlow(
                handoff: InsertionTargetHandoff(maxAttempts: 2)
            ).run(
                capture: { invalidTarget },
                paste: { _ in InsertionResult(outcome: .failed) },
                copyOnly: { selection in
                    guard selection == .timedOut else {
                        return InsertionResult(outcome: .failed)
                    }
                    return InsertionResult(
                        outcome: .copied,
                        reasonCode: .targetHandoffTimedOut
                    )
                },
                isCurrent: { true },
                recordOutcome: { timeoutRecorded.append($0.reasonCode) }
            )

            var staleRecorded = false
            let stale = await InsertionPasteAgainFlow(
                handoff: InsertionTargetHandoff(maxAttempts: 2)
            ).run(
                capture: { target },
                paste: { _ in InsertionResult(outcome: .dispatched) },
                copyOnly: { _ in InsertionResult(outcome: .copied) },
                isCurrent: { false },
                recordOutcome: { _ in staleRecorded = true }
            )

            var cancelRecorded: [InsertionReasonCode?] = []
            let cancelled = await InsertionPasteAgainFlow(
                handoff: InsertionTargetHandoff(
                    maxAttempts: 2,
                    waitForDestination: {
                        withUnsafeCurrentTask { $0?.cancel() }
                        await Task.yield()
                    }
                )
            ).run(
                capture: { target },
                paste: { _ in InsertionResult(outcome: .failed) },
                copyOnly: { selection in
                    guard selection == .cancelled else {
                        return InsertionResult(outcome: .failed)
                    }
                    return InsertionResult(
                        outcome: .copied,
                        reasonCode: .targetHandoffCancelled
                    )
                },
                isCurrent: { true },
                recordOutcome: { cancelRecorded.append($0.reasonCode) }
            )

            guard success.outcome == .dispatched,
                  successRecorded == [.dispatched],
                  copyOnly.outcome == .copied,
                  copyOnlyRecorded == [.copied],
                  timedOut.reasonCode == .targetHandoffTimedOut,
                  timeoutRecorded == [.targetHandoffTimedOut],
                  stale.reasonCode == .targetHandoffCancelled,
                  !staleRecorded,
                  cancelled.reasonCode == .targetHandoffCancelled,
                  cancelRecorded == [.targetHandoffCancelled] else {
                throw ContractInputError(category: "handoff-outcome-mismatch")
            }
        }
    }

    private static func runOnMainActor(
        _ operation: @escaping @MainActor () async throws -> Void
    ) throws {
        let box = AsyncResultBox<Void>()
        Task { @MainActor in
            do {
                try await operation()
                box.result = .success(())
            } catch {
                box.result = .failure(error)
            }
        }
        let deadline = Date().addingTimeInterval(5)
        while box.result == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        guard let result = box.result else {
            throw ContractInputError(category: "handoff-runtime-timeout")
        }
        try result.get()
    }

    private static func validateGenerationAndGate(_ fixture: Fixture) throws {
        guard Thread.isMainThread else {
            throw ContractInputError(category: "off-main-operation-gate")
        }
        try MainActor.assumeIsolated {
            let gate = AppOperationGate()
            guard case .success(let operationA) = gate.begin(.pasteAgain),
                  operationA.generation == 1 else {
                throw ContractInputError(category: "operation-a-not-started")
            }
            let operationB = gate.preempt(.pasteAgain)
            var publishedGenerations: [UInt64] = []
            if gate.isCurrent(operationA) {
                publishedGenerations.append(fixture.operationAGeneration)
            }
            if gate.isCurrent(operationB) {
                publishedGenerations.append(fixture.operationBGeneration)
            }
            guard publishedGenerations == fixture.expectedPublishedGenerations else {
                throw ContractInputError(category: "late-a-mutated-b")
            }
            gate.complete(operationB)
            guard gate.isIdle, gate.activeOwnedCount == 0 else {
                throw ContractInputError(category: "operation-gate-not-released")
            }
        }
    }

    private static func loadFixture(_ url: URL) throws -> Fixture {
        guard let data = try? Data(contentsOf: url) else {
            throw ContractInputError(category: "missing-fixture")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ContractInputError(category: "malformed-paste-again-handoff")
        }
        guard !containsPrivateContent(object) else {
            throw ContractInputError(category: "forbidden-user-content")
        }
        do {
            return try JSONDecoder().decode(Fixture.self, from: data)
        } catch {
            throw ContractInputError(category: "malformed-paste-again-handoff")
        }
    }

    private static func validate(_ fixture: Fixture) throws {
        if fixture.dirty == true {
            throw ContractInputError(category: "dirty-worktree")
        }
        if fixture.staleCallback == true {
            throw ContractInputError(category: "stale-callback")
        }
        if let delay = fixture.handoffDelayMilliseconds, delay > 100 {
            throw ContractInputError(category: "long-running-timeout-cancel")
        }
        if fixture.flakyNativeTarget == true {
            throw ContractInputError(category: "flaky-native-target")
        }
        if fixture.reportedSuccess == true, fixture.processExitStatus != 0 {
            print("PASS decoy-only")
            throw ContractInputError(category: "misleading-success-output")
        }
        if let interruptions = fixture.interruptions, interruptions > 1 {
            throw ContractInputError(category: "repeated-interruption")
        }
        let resources = fixture.resourcesAfterShutdown
        guard fixture.name == "success-copy-only-timeout-cancel",
              fixture.operationAGeneration < fixture.operationBGeneration,
              fixture.lateAResultAfterBStart,
              fixture.expectedPublishedGenerations == [fixture.operationBGeneration],
              fixture.outcomes == [
                "paste-attempted", "copy-only", "target-handoff-timed-out",
                "target-handoff-cancelled"
              ],
              fixture.terminalCategories == ["paste-attempted", "copied", "copied", "copied"],
              fixture.geometryCaptures.dictationStart == 1,
              fixture.geometryCaptures.pasteAgainHandoff == 1,
              fixture.geometryCaptures.other == 0,
              fixture.geometryCaptures.persisted == 0,
              [resources.operations, resources.timers, resources.accessibilityObjects,
               resources.geometrySnapshots, resources.panels].allSatisfy({ $0 == 0 }),
              fixture.gateReleasedAfterTimeout,
              fixture.gateReleasedAfterCancel,
              !fixture.hudHideCancelledDictation,
              fixture.historyAndHUDTerminalCategoryMatch else {
            throw ContractInputError(category: "incomplete-paste-again-handoff")
        }
    }

    private static func validateProductSource() throws {
        let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let delegateURL = repository.appendingPathComponent("Sources/Oigo/OigoAppDelegate.swift")
        let statusURL = repository.appendingPathComponent("Sources/Oigo/StatusSurfaceController.swift")
        let handoffURL = repository.appendingPathComponent(
            "Sources/OigoInsertion/InsertionTargetHandoff.swift"
        )
        let geometryURL = repository.appendingPathComponent(
            "Sources/Oigo/UI/HUD/HUDTargetGeometrySession.swift"
        )
        guard let delegate = try? String(contentsOf: delegateURL, encoding: .utf8),
              let status = try? String(contentsOf: statusURL, encoding: .utf8),
              let handoff = try? String(contentsOf: handoffURL, encoding: .utf8),
              let geometry = try? String(contentsOf: geometryURL, encoding: .utf8) else {
            throw ContractInputError(category: "missing-paste-again-handoff-source")
        }
        guard let pasteAgainStart = delegate.range(of: "private func beginPasteAgain("),
              let pasteAgainEnd = delegate.range(
                  of: "\n    private func ",
                  range: pasteAgainStart.upperBound..<delegate.endIndex
              ) else {
            throw ContractInputError(category: "missing-paste-again-handoff-source")
        }
        let pasteAgainSource = String(delegate[pasteAgainStart.lowerBound..<pasteAgainEnd.lowerBound])
        guard delegate.contains("operationGate.isCurrent(handle)"),
              occurrences(of: "hudGeometrySession.beginDictation(", in: delegate) == 1,
              occurrences(of: "hudGeometrySession.beginPasteAgain(", in: delegate) == 1,
              delegate.contains("hudGeometrySession.beginDictation("),
              delegate.contains("hudGeometrySession.beginPasteAgain("),
              delegate.contains("hudGeometrySession.shutdown()"),
              delegate.contains("clearHUDGeometry(generation: handle.generation)"),
              delegate.contains("statusSurface.presentHUD"),
              delegate.contains("statusSurface.shutdownHUD()"),
              delegate.contains("terminal: terminal"),
              delegate.contains("terminal.map(hudTerminalState)"),
              status.contains("private let hudController = OigoHUDController()"),
              status.contains("func presentHUD("),
              status.contains("func shutdownHUD()"),
              handoff.contains("isCurrent: @escaping @MainActor () -> Bool"),
              handoff.contains("guard isCurrent() else"),
              geometry.contains("func beginPasteAgain(generation: UInt64)") else {
            throw ContractInputError(category: "incomplete-paste-again-handoff-source")
        }
        guard pasteAgainSource.contains("operationGate.run(handle, completes: false)"),
              pasteAgainSource.contains("self.operationGate.complete(handle)") else {
            throw ContractInputError(category: "paste-again-terminal-before-gate-release")
        }
        guard !delegate.contains("frontmostApplication =="),
              !delegate.contains("AppOperationGate()\n    private let operationGate"),
              !status.contains("AppOperationGate"),
              !status.contains("cancelCurrent()"),
              !geometry.contains("UserDefaults"),
              !geometry.contains("Timer") else {
            throw ContractInputError(category: "forbidden-paste-again-handoff-owner")
        }
    }

    private static func occurrences(of token: String, in source: String) -> Int {
        source.components(separatedBy: token).count - 1
    }

    private static func containsPrivateContent(_ object: Any) -> Bool {
        if let dictionary = object as? [String: Any] {
            let forbidden = Set([
                "audio", "clipboard", "coordinates", "credentials", "dictionary",
                "focusedText", "identifier", "targetFrame", "transcript", "userPath"
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
