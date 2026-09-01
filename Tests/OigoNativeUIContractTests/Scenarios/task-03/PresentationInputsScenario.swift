import Foundation

final class PresentationInputsScenario: NativeUIContractScenario {
    private struct Fixture: Decodable {
        let snapshot: Snapshot
        let generations: Generations?
        let dirty: Bool?
        let result: Result?
        let repeatCount: Int?
    }

    private struct Snapshot: Decodable {
        let generation: UInt64
        let storage: String
    }

    private struct Generations: Decodable {
        let current: UInt64
        let candidate: UInt64
    }

    private struct Result: Decodable {
        let reportedSuccess: Bool
        let processExitStatus: Int
    }

    override class var scenarioName: String {
        "presentation-inputs"
    }

    override class func run(arguments: ContractArguments) throws {
        let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/Oigo/UI/Presentation/OigoPresentationInputs.swift")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ContractInputError(category: "missing-presentation-inputs")
        }
        try validateSourceBoundary(source)
        guard arguments.defaultsSuite == "com.oigo.qa.task03" else {
            throw ContractInputError(category: "invalid-defaults-suite")
        }
        let fixture = try loadFixture(from: arguments.fixtureRoot)
        if let generations = fixture.generations,
           generations.candidate < generations.current {
            throw ContractInputError(category: "stale-generation")
        }
        if fixture.dirty == true {
            throw ContractInputError(category: "dirty-worktree")
        }
        if let result = fixture.result,
           result.reportedSuccess,
           result.processExitStatus != 0 {
            print("PASS decoy-only")
            throw ContractInputError(category: "misleading-success-output")
        }
        let repeatCount = fixture.repeatCount ?? 2
        guard (1...20).contains(repeatCount) else {
            throw ContractInputError(category: "malformed-snapshot")
        }
        let contractOutput = try runCompiledContract(source: source, repeatCount: repeatCount)
        print(contractOutput, terminator: "")
        print("PASS presentation-inputs resources=0")
    }

    private static func loadFixture(from root: URL) throws -> Fixture {
        let fixtureURL = root.appendingPathComponent("fixture.json", isDirectory: false)
        guard let data = try? Data(contentsOf: fixtureURL) else {
            throw ContractInputError(category: "missing-fixture")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ContractInputError(category: "malformed-snapshot")
        }
        if containsForbiddenField(in: object) {
            throw ContractInputError(category: "forbidden-field")
        }
        let fixture: Fixture
        do {
            fixture = try JSONDecoder().decode(Fixture.self, from: data)
        } catch {
            throw ContractInputError(category: "malformed-snapshot")
        }
        guard fixture.snapshot.generation > 0,
              ["ready", "degraded", "unavailable"].contains(fixture.snapshot.storage) else {
            throw ContractInputError(category: "malformed-snapshot")
        }
        return fixture
    }

    private static func containsForbiddenField(in object: Any) -> Bool {
        if let dictionary = object as? [String: Any] {
            let forbidden = Set([
                "userPath", "transcript", "audio", "clipboard", "focusedText", "dictionaryEntries"
            ])
            if !forbidden.isDisjoint(with: dictionary.keys) {
                return true
            }
            return dictionary.values.contains(where: containsForbiddenField(in:))
        }
        if let array = object as? [Any] {
            return array.contains(where: containsForbiddenField(in:))
        }
        return false
    }

    private static func validateSourceBoundary(_ source: URL) throws {
        guard let text = try? String(contentsOf: source, encoding: .utf8) else {
            throw ContractInputError(category: "unreadable-presentation-inputs")
        }
        let forbiddenTokens = [
            "import AppKit", "import AVFAudio", "import ApplicationServices", "Codable",
            "URL", "Data", "NSView", "NSWindow", "AXUIElement", "NSPasteboard",
            "DictionaryEntry", "audioData", "transcriptBody", "clipboardValue", "userPath",
            "[OigoLatestSessionPresentationInput]"
        ]
        guard !forbiddenTokens.contains(where: text.contains) else {
            throw ContractInputError(category: "forbidden-field")
        }
    }

    private static func runCompiledContract(source: URL, repeatCount: Int) throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-native-ui-redesign.task03." + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let driver = root.appendingPathComponent("main.swift")
        let executable = root.appendingPathComponent("presentation-input-contract")
        let core = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/OigoCore")
        let coreSources = try FileManager.default.contentsOfDirectory(
            at: core,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
        guard !coreSources.isEmpty else {
            throw ContractInputError(category: "missing-core-source")
        }
        try contractDriver.write(to: driver, atomically: true, encoding: .utf8)
        try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["swiftc"] + coreSources.map(\.path) + [
                "-emit-module", "-emit-library", "-module-name", "OigoCore",
                "-o", root.appendingPathComponent("libOigoCore.dylib").path,
                "-emit-module-path", root.appendingPathComponent("OigoCore.swiftmodule").path
            ]
        )
        try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: [
                "swiftc", "-I", root.path, "-L", root.path,
                "-Xlinker", "-rpath", "-Xlinker", root.path,
                source.path, driver.path, "-lOigoCore", "-o", executable.path
            ]
        )

        var expected: Data?
        for _ in 0..<repeatCount {
            let output = try runProcess(executable: executable, arguments: [])
            guard let text = String(data: output, encoding: .utf8) else {
                throw ContractInputError(category: "unexpected-contract-output")
            }
            let lines = text.split(separator: "\n").map(String.init)
            guard lines.count == 2,
                  lines[0].hasPrefix("EQUAL presentation-inputs-v1|"),
                  lines[1].hasPrefix("MUTATED presentation-inputs-v1|"),
                  lines[0].contains("storage=ready"),
                  lines[1].contains("storage=unavailable"),
                  lines[0] != lines[1],
                  !text.contains("en-US"),
                  !text.contains("00000000") else {
                throw ContractInputError(category: "unexpected-contract-output")
            }
            if let expected, expected != output {
                throw ContractInputError(category: "nondeterministic-output")
            }
            expected = output
        }
        guard let expected, let output = String(data: expected, encoding: .utf8) else {
            throw ContractInputError(category: "unexpected-contract-output")
        }
        return output
    }

    @discardableResult
    private static func runProcess(executable: URL, arguments: [String]) throws -> Data {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ContractInputError(category: "contract-process-launch")
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        _ = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw ContractInputError(category: "compiled-contract-failed")
        }
        return output
    }

    private static let contractDriver = #"""
    import Foundation

    func requireSendable<T: Sendable>(_: T.Type) {}
    requireSendable(OigoPresentationInputs.self)
    requireSendable(OigoLatestSessionPresentationInput.self)
    guard OigoLocaleIdentifier("/synthetic/private/session") == nil else {
        exit(1)
    }

    func makeSnapshot(storage: OigoStoragePresentationStatus) -> OigoPresentationInputs {
        let operation = OigoOperationGatePresentationInput(
            activeOperation: .init(generation: 41, kind: .dictation),
            busyReason: .occupied(.dictation)
        )
        let configuration = OigoDictationConfigurationPresentationInput(
            localeIdentifier: OigoLocaleIdentifier("en-US")!,
            input: .pinnedAvailable,
            channelIndex: 1,
            appliesTo: .active
        )
        return OigoPresentationInputs(
            generation: 42,
            operationGate: operation,
            coordinator: .init(state: .recording, generation: 41),
            storage: .init(status: storage),
            shortcut: .init(
                registration: .registered,
                isConfigured: true,
                shortcut: .default
            ),
            permissions: .init(microphone: .granted, accessibility: .denied),
            input: .init(selection: .pinnedAvailable, channelIndex: 1),
            localeAssets: .init(
                localeIdentifier: OigoLocaleIdentifier("en-US")!,
                status: .ready,
                generation: 9
            ),
            activeConfiguration: configuration,
            nextConfiguration: .init(
                localeIdentifier: OigoLocaleIdentifier("es-US")!,
                input: .systemDefault,
                channelIndex: 0,
                appliesTo: .next
            ),
            terminal: .init(generation: 40, outcome: .copied, failure: nil),
            latestSession: .init(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                state: .complete,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                hasAudio: true,
                hasTranscript: true,
                failure: nil
            ),
            playback: .init(generation: 7, status: .playing),
            onboarding: .init(stage: .test, status: .running, failure: nil),
            shutdown: .init(status: .inactive, fencedOperationCount: 0)
        )
    }

    let first = makeSnapshot(storage: .ready)
    let second = makeSnapshot(storage: .ready)
    let mutated = makeSnapshot(storage: .unavailable)
    guard first == second,
          first.sanitizedContractOutput == second.sanitizedContractOutput,
          first.sanitizedContractOutput != mutated.sanitizedContractOutput,
          first.operationGate.activeOperation?.generation == 41,
          first.operationGate.busyReason == .occupied(.dictation),
          first.latestSession?.hasTranscript == true else {
        exit(1)
    }
    print("EQUAL " + first.sanitizedContractOutput)
    print("MUTATED " + mutated.sanitizedContractOutput)
    """#
}
