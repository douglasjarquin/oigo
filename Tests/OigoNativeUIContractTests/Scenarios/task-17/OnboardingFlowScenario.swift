import Foundation
import OigoCore

final class OnboardingFlowScenario: NativeUIContractScenario {
    override class var scenarioName: String { "onboarding-flow" }

    override class func run(arguments: ContractArguments) throws {
        guard arguments.defaultsSuite == "com.oigo.qa.task17" else {
            throw ContractInputError(category: "invalid-defaults-suite")
        }

        let migration: [(OigoOnboardingStep, OigoOnboardingStep)] = [
            (.system, .system),
            (.language, .language),
            (.microphone, .language),
            (.shortcut, .shortcut),
            (.insertion, .shortcut),
            (.testDictation, .testDictation),
            (.recovery, .testDictation),
            (.complete, .complete)
        ]
        for (legacy, expected) in migration {
            guard legacy.migratedForFourStageFlow == expected else {
                throw ContractInputError(category: "legacy-step-migration")
            }
        }

        let legacyState = try JSONDecoder().decode(
            OigoOnboardingState.self,
            from: Data(#"{"step":"insertion"}"#.utf8)
        )
        guard legacyState.step.migratedForFourStageFlow == .shortcut,
              !legacyState.copyOnlyAccepted else {
            throw ContractInputError(category: "legacy-state-decoding")
        }

        let acceptedState = OigoOnboardingState(step: .testDictation, copyOnlyAccepted: true)
        let roundTripped = try JSONDecoder().decode(
            OigoOnboardingState.self,
            from: JSONEncoder().encode(acceptedState)
        )
        guard roundTripped.copyOnlyAccepted else {
            throw ContractInputError(category: "copy-only-persistence")
        }

        let stages = OigoOnboardingStage.allCases
        guard stages.map(\.ordinal) == [1, 2, 3, 4, 5],
              stages.map(\.title) == [
                  "Mac & Storage",
                  "Microphone & Language",
                  "Shortcut & Insertion",
                  "Try It",
                  "Done"
              ],
              OigoOnboardingStage.microphoneAndLanguage.next == .shortcutAndInsertion,
              OigoOnboardingStage.shortcutAndInsertion.next == .tryIt,
              OigoOnboardingStage.tryIt.next == .done,
              OigoOnboardingStage.done.next == nil else {
            throw ContractInputError(category: "four-stage-flow")
        }

        var evidence = OigoOnboardingEvidenceMachine()
        guard evidence.checklist.count == 9,
              evidence.checklist.allSatisfy({ $0.status == .pending }) else {
            throw ContractInputError(category: "checklist-initial-state")
        }
        evidence.setStorageHealth(
            .ready(
                DurableSessionBootstrapReport(
                    recoveredSessionCount: 0,
                    historyEntryCount: 0,
                    malformedSessionCount: 0
                )
            )
        )
        guard let generation = evidence.beginTest(destinationEditable: true),
              evidence.checklist[0].status == .succeeded,
              evidence.checklist[1].status == .active,
              evidence.checklist[2].status == .active,
              evidence.markDestinationCleared(generation: generation),
              evidence.checklist[1].status == .succeeded,
              !evidence.markDestinationCleared(generation: generation + 1) else {
            throw ContractInputError(category: "checklist-progress")
        }
        evidence.skip()
        guard evidence.outcome == .skipped,
              evidence.checklist.last?.status == .pending else {
            throw ContractInputError(category: "checklist-skip")
        }

        var blocked = OigoOnboardingEvidenceMachine()
        guard blocked.beginTest(destinationEditable: true) == nil,
              blocked.failedStage == .storage else {
            throw ContractInputError(category: "storage-gate")
        }

        var source = OigoOnboardingEvidenceMachine()
        source.setSelectedSource(input: .systemDefault, channel: 0, unavailable: true)
        let probeGeneration = source.beginSourceProbe()
        let sourceUpdate = OigoOnboardingSourceProbeUpdate(
            generation: probeGeneration,
            usedInput: .systemDefault,
            usedChannel: 0,
            acceptedCanonicalBuffer: true,
            signalHealth: .usable,
            meterLevel: 0.4
        )
        guard source.recordSourceProbe(sourceUpdate),
              source.sourceUnavailable,
              !source.microphoneCanAdvance else {
            throw ContractInputError(category: "unavailable-source")
        }
        source.leaveMicrophoneStep()
        guard !source.recordSourceProbe(sourceUpdate) else {
            throw ContractInputError(category: "stale-probe")
        }

        var copyOnly = OigoOnboardingEvidenceMachine()
        copyOnly.setStorageHealth(
            .ready(
                DurableSessionBootstrapReport(
                    recoveredSessionCount: 0,
                    historyEntryCount: 0,
                    malformedSessionCount: 0
                )
            )
        )
        guard let copyGeneration = copyOnly.beginTest(destinationEditable: true),
              copyOnly.markDestinationCleared(generation: copyGeneration) else {
            throw ContractInputError(category: "copy-only-setup")
        }
        let sessionID = UUID()
        guard copyOnly.bindSession(generation: copyGeneration, sessionID: sessionID),
              !copyOnly.bindSession(generation: copyGeneration + 1, sessionID: UUID()) else {
            throw ContractInputError(category: "stale-session")
        }
        let copyReport = OigoOnboardingProductionReport(
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
            targetValidationSucceeded: false,
            insertionOutcome: .copied,
            insertionPath: .production,
            insertionInvoked: true,
            recoverableArtifactsRetained: true,
            sessionID: sessionID
        )
        guard copyOnly.recordProductionPath(generation: copyGeneration, report: copyReport),
              copyOnly.outcome == .failed,
              copyOnly.acceptCopyOnly(),
              copyOnly.outcome == .copyOnlyAccepted,
              copyOnly.checklist.last?.status == .succeeded else {
            throw ContractInputError(category: "copy-only-outcome")
        }

        var thirdParty = OigoOnboardingEvidenceMachine()
        thirdParty.setStorageHealth(
            .ready(
                DurableSessionBootstrapReport(
                    recoveredSessionCount: 0,
                    historyEntryCount: 0,
                    malformedSessionCount: 0
                )
            )
        )
        guard let thirdPartyGeneration = thirdParty.beginTest(destinationEditable: true),
              thirdParty.applyProgrammaticFieldAssignment(
                  generation: thirdPartyGeneration,
                  nonemptyTranscript: true
              ),
              thirdParty.outcome == .failed,
              thirdParty.checklist.last?.status == .failed else {
            throw ContractInputError(category: "third-party-verification")
        }

        let persistenceSuite = "com.oigo.qa.task17.persistence"
        guard let defaults = UserDefaults(suiteName: persistenceSuite) else {
            throw ContractInputError(category: "persistence-suite")
        }
        defaults.removePersistentDomain(forName: persistenceSuite)
        let store = OigoOnboardingStore(defaults: defaults)
        store.save(OigoOnboardingState(step: .shortcut, copyOnlyAccepted: true))
        store.markCompleted()
        guard store.load().isComplete, store.load().copyOnlyAccepted else {
            throw ContractInputError(category: "completion-persistence")
        }
        store.rerun()
        guard store.load().step == .system, !store.load().copyOnlyAccepted else {
            throw ContractInputError(category: "rerun-persistence")
        }
        defaults.removePersistentDomain(forName: persistenceSuite)

        print("PASS onboarding-flow stages=4+done migration=8 legacy-steps checklist=9")
    }
}
