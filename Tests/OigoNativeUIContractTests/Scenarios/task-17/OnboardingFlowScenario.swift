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
