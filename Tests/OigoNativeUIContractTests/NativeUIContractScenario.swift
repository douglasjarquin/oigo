import Foundation
import ObjectiveC

struct ContractArguments {
    let scenario: String
    let defaultsSuite: String
    let fixtureRoot: URL
    let fixtureName: String?
    let evidenceRoot: URL
    let appearance: String
    let contrast: String

    static func parse(_ arguments: [String]) throws -> ContractArguments {
        let values = try parseOptions(arguments)
        let scenario = try required("scenario", in: values)
        guard scenario.range(of: #"^[a-z][a-z0-9-]*$"#, options: .regularExpression) != nil else {
            throw ContractInputError(category: "invalid-scenario")
        }

        let defaultsSuite = try required("defaults-suite", in: values)
        guard defaultsSuite.range(
            of: #"^com\.oigo\.qa\.task[0-9]{2}$"#,
            options: .regularExpression
        ) != nil else {
            throw ContractInputError(category: "invalid-defaults-suite")
        }
        let taskNumber = try taskNumber(for: defaultsSuite)
        let taskRootIdentifier = "task-" + defaultsSuite.suffix(2)
        let evidenceTaskIdentifier = "task-\(taskNumber)"

        let fixtureRoot = canonicalURL(try required("fixture-root", in: values))
        guard let qaRoot = markedQARoot(containing: fixtureRoot) else {
            throw ContractInputError(category: "invalid-fixture-root")
        }
        let repositoryRoot = qaRoot.deletingLastPathComponent().deletingLastPathComponent()
        let approvedEvidenceRoot = repositoryRoot
            .appendingPathComponent(".omo/evidence/oigo-shortcut-transcription-design-fidelity", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        try validateRunMarker(at: qaRoot, evidenceRoot: approvedEvidenceRoot)
        let approvedFixtureRoot = qaRoot
            .appendingPathComponent("fixtures/native/\(taskRootIdentifier)", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard isWithin(fixtureRoot, of: approvedFixtureRoot) else {
            throw ContractInputError(category: "invalid-fixture-root")
        }
        let evidenceRoot = canonicalURL(try required("evidence-root", in: values))
        let approvedTaskEvidenceRoot = approvedEvidenceRoot
            .appendingPathComponent(evidenceTaskIdentifier, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard isWithin(evidenceRoot, of: approvedTaskEvidenceRoot) else {
            throw ContractInputError(category: "outside-evidence-root")
        }
        guard isDirectory(fixtureRoot) else {
            throw ContractInputError(category: "missing-owned-directory")
        }
        do {
            try FileManager.default.createDirectory(at: evidenceRoot, withIntermediateDirectories: true)
        } catch {
            throw ContractInputError(category: "missing-owned-directory")
        }
        guard isDirectory(evidenceRoot) else {
            throw ContractInputError(category: "missing-owned-directory")
        }

        let fixtureName: String?
        if let requestedFixture = values["fixture"] {
            guard requestedFixture.range(of: #"^[a-z][a-z0-9-]*$"#, options: .regularExpression) != nil else {
                throw ContractInputError(category: "invalid-fixture")
            }
            fixtureName = requestedFixture
        } else {
            fixtureName = nil
        }

        let appearance = values["appearance"] ?? "system"
        guard ["light", "dark", "system"].contains(appearance) else {
            throw ContractInputError(category: "invalid-appearance")
        }
        let contrast = values["contrast"] ?? "standard"
        guard ["standard", "increased"].contains(contrast) else {
            throw ContractInputError(category: "invalid-contrast")
        }

        return ContractArguments(
            scenario: scenario,
            defaultsSuite: defaultsSuite,
            fixtureRoot: fixtureRoot,
            fixtureName: fixtureName,
            evidenceRoot: evidenceRoot,
            appearance: appearance,
            contrast: contrast
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
            let allowed = [
                "scenario", "defaults-suite", "fixture-root", "fixture", "evidence-root",
                "appearance", "contrast"
            ]
            guard allowed.contains(key), values[key] == nil else {
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

    private static func canonicalURL(_ path: String) -> URL {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func isWithin(_ candidate: URL, of root: URL) -> Bool {
        candidate.path == root.path || candidate.path.hasPrefix(root.path + "/")
    }

    private static func taskNumber(for defaultsSuite: String) throws -> Int {
        guard let taskNumber = Int(defaultsSuite.suffix(2)) else {
            throw ContractInputError(category: "invalid-defaults-suite")
        }
        return taskNumber
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var directory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    private static func markedQARoot(containing url: URL) -> URL? {
        var candidate = url
        while candidate.path != "/" {
            if candidate.lastPathComponent == "oigo-shortcut-transcription-design-fidelity.qa",
               candidate.deletingLastPathComponent().lastPathComponent == "T" {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    private static func validateRunMarker(at qaRoot: URL, evidenceRoot: URL) throws {
        let repositoryRoot = qaRoot.deletingLastPathComponent().deletingLastPathComponent()
        let marker = qaRoot.appendingPathComponent("run.json")
        guard let data = try? Data(contentsOf: marker),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["qa_root"] as? String == qaRoot.path,
              object["attempt_dir"] as? String == evidenceRoot.path,
              object["repository"] as? String == repositoryRoot.path,
              object["reviewed_plan_sha"] as? String == "4b7cf8d3e0e323b5b3d7e0f17467e5b99901682b81255ad5f06c33ad2e42a198",
              object["execution_base_sha"] as? String == "a8315736e9b9ebb8c8e0a4bd6caa987eb67b2c37",
              let runUUID = object["run_uuid"] as? String,
              UUID(uuidString: runUUID) != nil else {
            throw ContractInputError(category: "invalid-run-marker")
        }
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
