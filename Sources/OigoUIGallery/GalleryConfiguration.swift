import Foundation

struct GalleryConfiguration {
    let scenario: String
    let defaultsSuite: String
    let sessionRoot: URL
    let fixtureRoot: URL
    let evidenceRoot: URL
    let appearance: String

    static func parse(_ arguments: [String], environment: [String: String]) throws -> GalleryConfiguration {
        let values = try parseOptions(arguments)
        let scenario = try required("scenario", in: values)
        guard scenario.range(of: #"^[a-z][a-z0-9-]*$"#, options: .regularExpression) != nil else {
            throw GalleryInputError(category: "invalid-scenario")
        }
        let defaultsSuite = try required("defaults-suite", in: values)
        guard defaultsSuite.range(
            of: #"^com\.oigo\.qa\.task[0-9]+$"#,
            options: .regularExpression
        ) != nil else {
            throw GalleryInputError(category: "invalid-defaults-suite")
        }
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

        guard let home = environment["HOME"], !home.isEmpty else {
            throw GalleryInputError(category: "missing-home")
        }
        let homeRoot = canonicalURL(home)
        guard homeRoot.lastPathComponent == "home" else {
            throw GalleryInputError(category: "invalid-home")
        }
        let taskRoot = homeRoot.deletingLastPathComponent()
        guard taskRoot.lastPathComponent.hasPrefix("oigo-native-ui-redesign."),
              taskRoot.deletingLastPathComponent().lastPathComponent == "T" else {
            throw GalleryInputError(category: "invalid-home")
        }

        let sessionRoot = canonicalURL(try required("session-root", in: values))
        let fixtureRoot = canonicalURL(try required("fixture-root", in: values))
        guard isDescendant(sessionRoot, of: taskRoot), isDescendant(fixtureRoot, of: taskRoot) else {
            throw GalleryInputError(category: "outside-task-root")
        }

        let evidenceRoot = canonicalURL(try required("evidence-root", in: values))
        let repositoryRoot = canonicalURL(FileManager.default.currentDirectoryPath)
        let approvedEvidenceRoot = repositoryRoot
            .appendingPathComponent(".omo/evidence/oigo-native-ui-redesign", isDirectory: true)
        guard isDescendant(evidenceRoot, of: approvedEvidenceRoot) else {
            throw GalleryInputError(category: "outside-evidence-root")
        }

        for directory in [homeRoot, sessionRoot, fixtureRoot, evidenceRoot] {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw GalleryInputError(category: "missing-owned-directory")
            }
        }

        return GalleryConfiguration(
            scenario: scenario,
            defaultsSuite: defaultsSuite,
            sessionRoot: sessionRoot,
            fixtureRoot: fixtureRoot,
            evidenceRoot: evidenceRoot,
            appearance: appearance
        )
    }

    private static func parseOptions(_ arguments: [String]) throws -> [String: String] {
        let allowed = Set([
            "scenario", "defaults-suite", "session-root", "fixture-root", "evidence-root",
            "pasteboard-provider", "permission-provider", "appearance"
        ])
        guard arguments.count == (allowed.count - 1) * 2 || arguments.count == allowed.count * 2 else {
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

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        candidate.path.hasPrefix(root.path + "/")
    }
}

struct GalleryInputError: Error, CustomStringConvertible {
    let category: String

    var description: String {
        "rejected-input:" + category
    }
}
