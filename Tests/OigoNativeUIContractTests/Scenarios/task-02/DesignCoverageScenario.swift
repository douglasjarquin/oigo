import Foundation

final class DesignCoverageScenario: NativeUIContractScenario {
    override class var scenarioName: String {
        "design-coverage"
    }

    override class func run(arguments: ContractArguments) throws {
        guard arguments.defaultsSuite == "com.oigo.qa.task02" else {
            throw ContractInputError(category: "invalid-defaults-suite")
        }
        guard FileManager.default.fileExists(atPath: arguments.fixtureRoot.path) else {
            throw ContractInputError(category: "missing-fixture-root")
        }

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let checker = root.appendingPathComponent("Scripts/check-oigo-native-design-coverage.py")
        let manifest = root.appendingPathComponent("docs/native-design-coverage.json")
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/env"),
              FileManager.default.fileExists(atPath: checker.path),
              FileManager.default.fileExists(atPath: manifest.path) else {
            throw ContractInputError(category: "missing-design-coverage-checker")
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", checker.path, manifest.path]
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ContractInputError(category: "design-coverage-launch-failed")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0,
              let result = String(data: data, encoding: .utf8),
              result.contains("PASS native-design-coverage surfaces=6 hud_states=18 state_matrix_rows=23"),
              result.contains("processing=252x38 recording=252x54 preview=252x73 terminal=252x58") else {
            throw ContractInputError(category: "design-coverage-check-failed")
        }

        print("PASS design-coverage")
    }
}
