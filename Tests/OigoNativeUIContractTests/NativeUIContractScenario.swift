import Foundation
import ObjectiveC

struct ContractArguments {
    let scenario: String
    let defaultsSuite: String
    let fixtureRoot: URL
    let fixtureName: String?

    static func parse(_ arguments: [String]) throws -> ContractArguments {
        let values = try parseOptions(arguments)
        let scenario = try required("scenario", in: values)
        guard scenario.range(of: #"^[a-z][a-z0-9-]*$"#, options: .regularExpression) != nil else {
            throw ContractInputError(category: "invalid-scenario")
        }

        let defaultsSuite: String
        let fixtureRoot: URL
        let fixtureName: String?
        if let requestedFixture = values["fixture"] {
            guard values.count == 2,
                  requestedFixture.range(of: #"^[a-z][a-z0-9-]*$"#, options: .regularExpression) != nil else {
                throw ContractInputError(category: "invalid-fixture")
            }
            switch scenario {
            case "popover-routing":
                defaultsSuite = "com.oigo.qa.task11"
                fixtureRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("Tests/OigoNativeUIContractFixtures/task-11", isDirectory: true)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                fixtureName = requestedFixture
            case "popover-state-matrix":
                defaultsSuite = "com.oigo.qa.task12"
                fixtureRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("Tests/OigoNativeUIContractFixtures/task-12", isDirectory: true)
                    .appendingPathComponent(requestedFixture, isDirectory: true)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                fixtureName = nil
            case "popover-actions":
                defaultsSuite = "com.oigo.qa.task13"
                fixtureRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("Tests/OigoNativeUIContractFixtures/task-13", isDirectory: true)
                    .appendingPathComponent(requestedFixture, isDirectory: true)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                fixtureName = nil
            default:
                throw ContractInputError(category: "invalid-fixture")
            }
        } else {
            defaultsSuite = try required("defaults-suite", in: values)
            guard defaultsSuite.range(
                of: #"^com\.oigo\.qa\.task[0-9]+$"#,
                options: .regularExpression
            ) != nil else {
                throw ContractInputError(category: "invalid-defaults-suite")
            }

            fixtureRoot = URL(fileURLWithPath: try required("fixture-root", in: values))
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard fixtureRoot.path.hasPrefix("/"), isOwnedTaskPath(fixtureRoot) else {
                throw ContractInputError(category: "invalid-fixture-root")
            }
            fixtureName = nil
        }

        return ContractArguments(
            scenario: scenario,
            defaultsSuite: defaultsSuite,
            fixtureRoot: fixtureRoot,
            fixtureName: fixtureName
        )
    }

    private static func parseOptions(_ arguments: [String]) throws -> [String: String] {
        guard arguments.count.isMultiple(of: 2) else {
            throw ContractInputError(category: "malformed-arguments")
        }
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            let value = arguments[index + 1]
            guard option.hasPrefix("--"), !value.hasPrefix("--") else {
                throw ContractInputError(category: "malformed-arguments")
            }
            let key = String(option.dropFirst(2))
            guard ["scenario", "defaults-suite", "fixture-root", "fixture"].contains(key), values[key] == nil else {
                throw ContractInputError(category: "unknown-or-duplicate-argument")
            }
            values[key] = value
            index += 2
        }
        return values
    }

    private static func required(_ key: String, in values: [String: String]) throws -> String {
        guard let value = values[key], !value.isEmpty else {
            throw ContractInputError(category: "missing-argument")
        }
        return value
    }

    private static func isOwnedTaskPath(_ url: URL) -> Bool {
        var candidate = url
        while candidate.path != "/" {
            if candidate.lastPathComponent.hasPrefix("oigo-native-ui-redesign.") {
                return candidate.deletingLastPathComponent().lastPathComponent == "T"
                    && url.path.hasPrefix(candidate.path + "/")
            }
            candidate.deleteLastPathComponent()
        }
        return false
    }
}

struct ContractInputError: Error, CustomStringConvertible {
    let category: String

    var description: String {
        "rejected-input:" + category
    }
}

@objcMembers
class NativeUIContractScenario: NSObject {
    class var scenarioName: String {
        fatalError("scenario subclasses must provide a name")
    }

    class func run(arguments: ContractArguments) throws {
        fatalError("scenario subclasses must implement run")
    }
}

enum NativeUIContractScenarioRegistry {
    static func discover() -> [String: NativeUIContractScenario.Type] {
        let expectedSuperclass: AnyClass = NativeUIContractScenario.self
        let count = objc_getClassList(nil, 0)
        let classes = UnsafeMutablePointer<AnyClass?>.allocate(capacity: Int(count))
        defer { classes.deallocate() }
        let loadedCount = objc_getClassList(AutoreleasingUnsafeMutablePointer(classes), count)
        var scenarios: [String: NativeUIContractScenario.Type] = [:]
        for index in 0..<Int(loadedCount) {
            guard let candidate = classes[index], class_getSuperclass(candidate) === expectedSuperclass,
                  let scenarioType = candidate as? NativeUIContractScenario.Type else {
                continue
            }
            scenarios[scenarioType.scenarioName] = scenarioType
        }
        return scenarios
    }
}
