import Foundation

final class DictionaryInlineScenario: NativeUIContractScenario {
    override class var scenarioName: String { "dictionary-inline" }

    override class func run(arguments: ContractArguments) throws {
        try run(evidenceRoot: arguments.evidenceRoot)
    }

    static func run(evidenceRoot: URL) throws {
        let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let root = evidenceRoot.appendingPathComponent("dictionary-inline-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("dictionary-contract")
        let build = repository.appendingPathComponent(".build/arm64-apple-macosx/debug")
        let objects = try ["MacUtilityUI", "OigoCore", "OigoHotKey"].flatMap { name in
            try FileManager.default.contentsOfDirectory(at: build.appendingPathComponent(name + ".build"), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "o" }.map(\.path)
        }
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["swiftc", "-parse-as-library", "-target", "arm64-apple-macosx26.0",
                              "-I", build.appendingPathComponent("Modules").path,
                              "Sources/Oigo/OigoUtilityWindow.swift",
                              "Sources/Oigo/SettingsWindowController.swift",
                              "Tests/OigoNativeUIContractTests/Support/DictionaryInlineDriver.swift",
                              "-framework", "AppKit", "-framework", "Carbon", "-framework", "UniformTypeIdentifiers",
                              "-o", executable.path] + objects
        try compiler.run()
        compiler.waitUntilExit()
        guard compiler.terminationStatus == 0 else { throw ContractInputError(category: "dictionary-inline-build") }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-oigo.settings.selected-pane", "dictionary"]
        var environment = ProcessInfo.processInfo.environment
        environment["CFFIXED_USER_HOME"] = root.path
        environment["OIGO_DICTIONARY_EVIDENCE_ROOT"] = root.path
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ContractInputError(category: "dictionary-inline-runtime") }
    }
}
