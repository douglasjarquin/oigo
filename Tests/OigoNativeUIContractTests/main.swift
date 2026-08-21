import Darwin
import Foundation

do {
    let arguments = try ContractArguments.parse(Array(CommandLine.arguments.dropFirst()))
    let scenarios = NativeUIContractScenarioRegistry.discover()
    if arguments.scenario == "all" {
        for (_, scenario) in scenarios.sorted(by: { $0.key < $1.key }) {
            try scenario.run(arguments: arguments)
        }
        print("PASS all")
    } else {
        guard let scenario = scenarios[arguments.scenario] else {
            throw ContractInputError(category: "unknown-scenario")
        }
        try scenario.run(arguments: arguments)
    }
    exit(0)
} catch let error as ContractInputError {
    FileHandle.standardError.write(Data(("ERROR " + error.description + "\n").utf8))
    exit(64)
} catch {
    FileHandle.standardError.write(Data("ERROR scenario-failed\n".utf8))
    exit(1)
}
