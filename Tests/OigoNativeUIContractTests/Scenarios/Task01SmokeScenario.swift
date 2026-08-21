import Foundation

final class Task01SmokeScenario: NativeUIContractScenario {
    override class var scenarioName: String {
        "smoke"
    }

    override class func run(arguments: ContractArguments) throws {
        guard FileManager.default.fileExists(atPath: arguments.fixtureRoot.path) else {
            throw ContractInputError(category: "missing-fixture-root")
        }
        print("PASS smoke")
    }
}
