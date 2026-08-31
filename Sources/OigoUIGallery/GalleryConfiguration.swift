import Foundation

struct GalleryConfiguration {
    let scenario: String
    let defaultsSuite: String
    let sessionRoot: URL
    let fixtureRoot: URL
    let evidenceRoot: URL
    let appearance: String
    let contrast: String

    static func parse(_ arguments: [String], environment: [String: String]) throws -> GalleryConfiguration {
        let values = try parseOptions(arguments)
        let scenario = try required("scenario", in: values)
        guard scenario.range(of: #"^[a-z][a-z0-9-]*$"#, options: .regularExpression) != nil else {
            throw GalleryInputError(category: "invalid-scenario")
        }
        let defaultsSuite = try required("defaults-suite", in: values)
        guard defaultsSuite.range(
            of: #"^com\.oigo\.qa\.task[0-9]{2}$"#,
            options: .regularExpression
        ) != nil else {
            throw GalleryInputError(category: "invalid-defaults-suite")
        }
        let taskNumber = try taskNumber(for: defaultsSuite)
        let taskRootIdentifier = "task-" + defaultsSuite.suffix(2)
        let evidenceTaskIdentifier = "task-\(taskNumber)"
        guard try required("pasteboard-provider", in: values) == "synthetic" else {
            throw GalleryInputError(category: "invalid-pasteboard-provider")
        }
        guard try required("permission-provider", in: values) == "synthetic" else {
            throw GalleryInputError(category: "invalid-permission-provider")
        }
        let appearance = values["appearance"] ?? "system"
        guard ["system", "light", "dark"].contains(appearance) else {
            throw GalleryInputError(category: "invalid-appearance")
        }
        let contrast = values["contrast"] ?? "standard"
        guard ["standard", "increased"].contains(contrast) else {
            throw GalleryInputError(category: "invalid-contrast")
        }

        guard let home = environment["HOME"], !home.isEmpty else {
            throw GalleryInputError(category: "missing-home")
        }
        let homeRoot = canonicalURL(home)
        guard homeRoot.lastPathComponent == "home" else {
            throw GalleryInputError(category: "invalid-home")
        }
        let taskRoot = homeRoot.deletingLastPathComponent()
        guard taskRoot.lastPathComponent == "oigo-shortcut-transcription-design-fidelity.qa",
              taskRoot.deletingLastPathComponent().lastPathComponent == "T" else {
            throw GalleryInputError(category: "invalid-home")
        }

        let repositoryRoot = taskRoot.deletingLastPathComponent().deletingLastPathComponent()

        let sessionRoot = canonicalURL(try required("session-root", in: values))
        let fixtureRoot = canonicalURL(try required("fixture-root", in: values))
        let approvedSessionRoot = taskRoot
            .appendingPathComponent("session/\(taskRootIdentifier)", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let approvedFixtureRoot = taskRoot
            .appendingPathComponent("fixtures/native/\(taskRootIdentifier)", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard isWithin(sessionRoot, of: approvedSessionRoot),
              isWithin(fixtureRoot, of: approvedFixtureRoot) else {
            throw GalleryInputError(category: "outside-task-root")
        }

        let evidenceRoot = canonicalURL(try required("evidence-root", in: values))
        let approvedEvidenceRoot = repositoryRoot
            .appendingPathComponent(".omo/evidence/oigo-shortcut-transcription-design-fidelity", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        var approvedTaskEvidenceRoots = [approvedEvidenceRoot
            .appendingPathComponent(evidenceTaskIdentifier, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        ]
        if scenario == "components", taskNumber == 7 {
            approvedTaskEvidenceRoots.append(approvedEvidenceRoot
                .appendingPathComponent("task-19", isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath())
        }
        if scenario == "popover-states", taskNumber == 12 {
            approvedTaskEvidenceRoots.append(approvedEvidenceRoot
                .appendingPathComponent("task-21", isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath())
        }
        if scenario == "hud-states", taskNumber == 15 {
            approvedTaskEvidenceRoots.append(approvedEvidenceRoot
                .appendingPathComponent("task-23", isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath())
        }
        if scenario == "hud-placement", taskNumber == 14 {
            approvedTaskEvidenceRoots.append(approvedEvidenceRoot
                .appendingPathComponent("task-24", isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath())
        }
        guard approvedTaskEvidenceRoots.contains(where: { isWithin(evidenceRoot, of: $0) }) else {
            throw GalleryInputError(category: "outside-evidence-root")
        }

        try validateRunMarker(at: taskRoot, evidenceRoot: approvedEvidenceRoot)
        for directory in [homeRoot, sessionRoot, fixtureRoot, evidenceRoot] {
            guard isDirectory(directory) else {
                throw GalleryInputError(category: "missing-owned-directory")
            }
        }

        return GalleryConfiguration(
            scenario: scenario,
            defaultsSuite: defaultsSuite,
            sessionRoot: sessionRoot,
            fixtureRoot: fixtureRoot,
            evidenceRoot: evidenceRoot,
            appearance: appearance,
            contrast: contrast
        )
    }

    private static func parseOptions(_ arguments: [String]) throws -> [String: String] {
        let allowed = Set([
            "scenario", "defaults-suite", "session-root", "fixture-root", "evidence-root",
            "pasteboard-provider", "permission-provider", "appearance", "contrast"
        ])
        guard arguments.count.isMultiple(of: 2) else {
            throw GalleryInputError(category: "malformed-arguments")
        }
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            let value = arguments[index + 1]
            guard option.hasPrefix("--"), !value.hasPrefix("--") else {
                throw GalleryInputError(category: "malformed-arguments")
            }
            let key = String(option.dropFirst(2))
            guard allowed.contains(key), values[key] == nil else {
                throw GalleryInputError(category: "unknown-or-duplicate-argument")
            }
            values[key] = value
            index += 2
        }
        return values
    }

    private static func required(_ key: String, in values: [String: String]) throws -> String {
        guard let value = values[key], !value.isEmpty else {
            throw GalleryInputError(category: "missing-argument")
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
            throw GalleryInputError(category: "invalid-defaults-suite")
        }
        return taskNumber
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var directory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
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
            throw GalleryInputError(category: "invalid-run-marker")
        }
    }
}

struct GalleryInputError: Error, CustomStringConvertible {
    let category: String

    var description: String {
        "rejected-input:" + category
    }
}
