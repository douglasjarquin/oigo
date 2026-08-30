import Foundation

final class GalleryInputBoundariesScenario: NativeUIContractScenario {
    override class var scenarioName: String {
        "gallery-input-boundaries"
    }

    override class func run(arguments: ContractArguments) throws {
        guard arguments.defaultsSuite == "com.oigo.qa.task06" else {
            throw ContractInputError(category: "invalid-defaults-suite")
        }
        let qaRoot = arguments.fixtureRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtureRoot = qaRoot.appendingPathComponent("fixtures/native/task-06", isDirectory: true)
        let sessionRoot = qaRoot.appendingPathComponent("session/task-06", isDirectory: true)
        let evidenceRoot = arguments.evidenceRoot
        let outsideEvidenceRoot = evidenceRoot.deletingLastPathComponent().appendingPathComponent("task-5")
        let missingRoot = fixtureRoot.appendingPathComponent("missing-owned-directory", isDirectory: true)

        try expectContractArguments(
            [
                "--scenario", "gallery-input-boundaries",
                "--defaults-suite", "com.oigo.qa.task06",
                "--fixture-root", qaRoot.appendingPathComponent("other/native/task-06").path,
                "--evidence-root", evidenceRoot.path
            ],
            category: "invalid-fixture-root"
        )
        try expectContractArguments(
            [
                "--scenario", "gallery-input-boundaries",
                "--defaults-suite", "com.oigo.qa.task05",
                "--fixture-root", fixtureRoot.path,
                "--evidence-root", evidenceRoot.path
            ],
            category: "invalid-fixture-root"
        )
        try expectContractArguments(
            [
                "--scenario", "gallery-input-boundaries",
                "--defaults-suite", "com.oigo.qa.task06",
                "--fixture-root", missingRoot.path,
                "--evidence-root", evidenceRoot.path
            ],
            category: "missing-owned-directory"
        )
        try expectContractArguments(
            [
                "--scenario", "gallery-input-boundaries",
                "--defaults-suite", "com.oigo.qa.task06",
                "--fixture-root", fixtureRoot.path,
                "--evidence-root", outsideEvidenceRoot.path
            ],
            category: "outside-evidence-root"
        )
        try expectContractArguments(
            [
                "--scenario", "gallery-input-boundaries",
                "--defaults-suite", "invalid-suite",
                "--fixture-root", fixtureRoot.path,
                "--evidence-root", evidenceRoot.path
            ],
            category: "invalid-defaults-suite"
        )
        try expectContractArguments(
            [
                "--scenario", "gallery-input-boundaries",
                "--defaults-suite", "com.oigo.qa.task06",
                "--fixture-root", fixtureRoot.path,
                "--evidence-root", evidenceRoot.path,
                "--appearance", "vivid"
            ],
            category: "invalid-appearance"
        )
        try expectContractArguments(
            [
                "--scenario", "gallery-input-boundaries",
                "--defaults-suite", "com.oigo.qa.task06",
                "--fixture-root", fixtureRoot.path,
                "--evidence-root", evidenceRoot.path,
                "--contrast", "inverted"
            ],
            category: "invalid-contrast"
        )
        try expectContractArguments(
            [
                "--scenario", "gallery-input-boundaries",
                "--defaults-suite", "com.oigo.qa.task06",
                "--fixture-root", fixtureRoot.path,
                "--evidence-root", evidenceRoot.path,
                "--pasteboard-provider", "real"
            ],
            category: "unknown-or-duplicate-argument"
        )
        let positive = try ContractArguments.parse([
            "--scenario", "gallery-input-boundaries",
            "--defaults-suite", "com.oigo.qa.task06",
            "--fixture-root", fixtureRoot.path,
            "--evidence-root", evidenceRoot.path
        ])
        guard positive.appearance == "system", positive.contrast == "standard" else {
            throw ContractInputError(category: "default-appearance-or-contrast")
        }

        let galleryBinary = try galleryExecutable()
        let galleryOptions = [
            "--scenario", "popover-states",
            "--defaults-suite", "com.oigo.qa.task06",
            "--session-root", sessionRoot.path,
            "--fixture-root", fixtureRoot.path,
            "--evidence-root", evidenceRoot.path,
            "--pasteboard-provider", "synthetic",
            "--permission-provider", "synthetic"
        ]
        try expectGalleryInput(
            galleryBinary,
            options: replacing("--session-root", with: qaRoot.appendingPathComponent("other/session/task-06").path, in: galleryOptions),
            home: qaRoot.appendingPathComponent("home", isDirectory: true),
            category: "outside-task-root"
        )
        try expectGalleryInput(
            galleryBinary,
            options: replacing("--fixture-root", with: qaRoot.appendingPathComponent("other/fixtures/native/task-06").path, in: galleryOptions),
            home: qaRoot.appendingPathComponent("home", isDirectory: true),
            category: "outside-task-root"
        )
        try expectGalleryInput(
            galleryBinary,
            options: replacing("--session-root", with: qaRoot.appendingPathComponent("session/task-05").path, in: galleryOptions),
            home: qaRoot.appendingPathComponent("home", isDirectory: true),
            category: "outside-task-root"
        )
        let missingSessionRoot = sessionRoot.appendingPathComponent("missing-owned-directory", isDirectory: true)
        try expectGalleryInput(
            galleryBinary,
            options: replacing("--session-root", with: missingSessionRoot.path, in: galleryOptions),
            home: qaRoot.appendingPathComponent("home", isDirectory: true),
            category: "missing-owned-directory"
        )
        guard !FileManager.default.fileExists(atPath: missingSessionRoot.path) else {
            throw ContractInputError(category: "invalid-input-created-directory")
        }
        try expectGalleryInput(
            galleryBinary,
            options: replacing("--evidence-root", with: outsideEvidenceRoot.path, in: galleryOptions),
            home: qaRoot.appendingPathComponent("home", isDirectory: true),
            category: "outside-evidence-root"
        )
        try expectGalleryInput(
            galleryBinary,
            options: replacing("--defaults-suite", with: "invalid-suite", in: galleryOptions),
            home: qaRoot.appendingPathComponent("home", isDirectory: true),
            category: "invalid-defaults-suite"
        )
        try expectGalleryInput(
            galleryBinary,
            options: galleryOptions + ["--appearance", "vivid"],
            home: qaRoot.appendingPathComponent("home", isDirectory: true),
            category: "invalid-appearance"
        )
        try expectGalleryInput(
            galleryBinary,
            options: galleryOptions + ["--contrast", "inverted"],
            home: qaRoot.appendingPathComponent("home", isDirectory: true),
            category: "invalid-contrast"
        )
        try expectGalleryInput(
            galleryBinary,
            options: replacing("--pasteboard-provider", with: "real", in: galleryOptions),
            home: qaRoot.appendingPathComponent("home", isDirectory: true),
            category: "invalid-pasteboard-provider"
        )
        try expectGalleryInput(
            galleryBinary,
            options: replacing("--permission-provider", with: "real", in: galleryOptions),
            home: qaRoot.appendingPathComponent("home", isDirectory: true),
            category: "invalid-permission-provider"
        )
        try expectGalleryInput(
            galleryBinary,
            options: galleryOptions + ["--unknown", "value"],
            home: qaRoot.appendingPathComponent("home", isDirectory: true),
            category: "unknown-or-duplicate-argument"
        )
        try writeReceipt(to: evidenceRoot)
        print("PASS gallery-input-boundaries parser=positive-negative gallery=fail-closed")
    }

    private static func expectContractArguments(_ values: [String], category: String) throws {
        do {
            _ = try ContractArguments.parse(values)
            throw ContractInputError(category: "boundary-accepted")
        } catch let error as ContractInputError {
            guard error.category == category else {
                throw error
            }
        }
    }

    private static func galleryExecutable() throws -> URL {
        let build = Process()
        let finished = DispatchSemaphore(value: 0)
        build.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        build.arguments = ["swift", "build", "--product", "OigoUIGallery"]
        build.terminationHandler = { _ in finished.signal() }
        do {
            try build.run()
        } catch {
            throw ContractInputError(category: "gallery-build-launch")
        }
        guard finished.wait(timeout: .now() + 30) == .success else {
            build.terminate()
            throw ContractInputError(category: "gallery-build-timeout")
        }
        guard build.terminationStatus == 0 else {
            throw ContractInputError(category: "gallery-build-failed")
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let executable = root.appendingPathComponent(".build/debug/OigoUIGallery")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ContractInputError(category: "missing-gallery-executable")
        }
        return executable
    }

    private static func replacing(_ option: String, with value: String, in options: [String]) -> [String] {
        guard let index = options.firstIndex(of: option), index + 1 < options.count else {
            return options
        }
        var replaced = options
        replaced[index + 1] = value
        return replaced
    }

    private static func expectGalleryInput(
        _ executable: URL,
        options: [String],
        home: URL,
        category: String
    ) throws {
        let result = try GalleryInputBoundaryProbe.run(executable: executable, options: options, home: home)
        guard !result.timedOut,
              result.exitCode == 64,
              result.output == "ERROR rejected-input:\(category)\n" else {
            throw ContractInputError(category: "gallery-accepted-invalid-input")
        }
    }

    private static func writeReceipt(to root: URL) throws {
        let receipt = "{\"scenario\":\"gallery-input-boundaries\",\"providers\":\"synthetic\",\"result\":\"pass\"}\n"
        try Data(receipt.utf8).write(
            to: root.appendingPathComponent("gallery-input-boundaries-receipt.json"),
            options: .atomic
        )
    }
}
