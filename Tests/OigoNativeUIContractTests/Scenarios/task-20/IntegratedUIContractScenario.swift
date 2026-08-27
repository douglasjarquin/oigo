import Foundation
import OigoCore

final class IntegratedUIContractScenario: NativeUIContractScenario {
    override class var scenarioName: String { "integrated-ui" }

    override class func run(arguments: ContractArguments) throws {
        guard arguments.defaultsSuite == "com.oigo.qa.task20" else {
            throw ContractInputError(category: "invalid-defaults-suite")
        }
        guard OigoUIIntegrationPolicy.commandKeyEquivalents[.settings] == ",",
              OigoUIIntegrationPolicy.commandKeyEquivalents[.quit] == "q",
              OigoUIIntegrationPolicy.escapePriority == [
                  .cancelEditor,
                  .dismissConfirmation,
                  .dismissPopover,
                  .closeUtilityWindow,
                  .stopOnboardingProbe,
                  .cancelBoundedHandoff
              ],
              OigoUIIntegrationPolicy.restorationIdentifiers == [
                  "com.oigo.settings.window",
                  "com.oigo.history.window",
                  "com.oigo.history.split"
              ] else {
            throw ContractInputError(category: "integrated-ui-policy")
        }

        let clamped = OigoRestoredWindowGeometry(
            x: -500,
            y: 2_000,
            width: 1_400,
            height: 400
        ).clamped(
            to: OigoVisibleFrame(x: 0, y: 0, width: 1_920, height: 1_080),
            minimumWidth: 880,
            minimumHeight: 520
        )
        guard clamped.x >= 0,
              clamped.y >= 0,
              clamped.width == 1_400,
              clamped.height == 520,
              OigoUIIntegrationPolicy.forbiddenIdleBehaviors == [
                  "recurring-timer",
                  "global-monitor",
                  "permission-polling",
                  "history-polling",
                  "transcript-preload",
                  "model-prewarm"
              ] else {
            throw ContractInputError(category: "integrated-ui-geometry")
        }
        print("PASS integrated-ui commands=menu+copy+select-all escape=6 restoration=3 idle=event-driven")
    }
}
