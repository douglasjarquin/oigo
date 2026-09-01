import Foundation

final class KeyboardStartupScenario: NativeUIContractScenario {
    override class var scenarioName: String { "keyboard-startup" }

    override class func run(arguments: ContractArguments) throws {
        guard arguments.defaultsSuite == "com.oigo.qa.task05" else {
            throw ContractInputError(category: "invalid-defaults-suite")
        }
        let mode = try fixtureMode(arguments.fixtureRoot)
        try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["swift", "build", "--product", "Oigo"],
            failureCategory: "keyboard-startup-app-build-failed"
        )
        let isolatedHome = arguments.evidenceRoot.appendingPathComponent("isolated-home", isDirectory: true)
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: isolatedHome) }
        let output = arguments.evidenceRoot.appendingPathComponent("keyboard-startup.json")
        try runProcess(
            executable: URL(fileURLWithPath: ".build/debug/Oigo"),
            arguments: [
                "--task-15-keyboard-startup-probe", mode,
                arguments.defaultsSuite, output.path
            ],
            environment: [
                "CFFIXED_USER_HOME": isolatedHome.path,
                "HOME": isolatedHome.path,
                "OIGO_QA_MODE": "1"
            ],
            timeout: 8,
            failureCategory: "keyboard-startup-app-delegate-probe-failed"
        )
        let receipt = try JSONDecoder().decode(
            Task15KeyboardStartupReceipt.self,
            from: Data(contentsOf: output)
        )
        try validate(receipt, mode: mode)
        print(
            "PASS keyboard-startup owner=\(receipt.ownerIdentity) cases=\(receipt.rows.count) "
                + "production-observations=bridge/recovery/locale/resources"
        )
    }

    private static func fixtureMode(_ root: URL) throws -> String {
        let fixture = root.appendingPathComponent("fixture.json")
        if FileManager.default.fileExists(atPath: fixture.path) {
            guard let data = try? Data(contentsOf: fixture),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == ["case"],
                  object["case"] as? String == "startup-success" else {
                throw ContractInputError(category: "malformed-startup-fixture")
            }
            return "success"
        }
        let cases = root.appendingPathComponent("cases.json")
        guard FileManager.default.fileExists(atPath: cases.path),
              let data = try? Data(contentsOf: cases),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["cases"],
              let names = object["cases"] as? [String],
              Set(names) == Set(Task15KeyboardStartupReceipt.failureCases) else {
            throw ContractInputError(category: "malformed-startup-fixture")
        }
        return "failure"
    }

    private static func validate(
        _ receipt: Task15KeyboardStartupReceipt,
        mode: String
    ) throws {
        guard receipt.ownerIdentity == "oigo-app-delegate-keyboard-startup",
              receipt.defaultsCleaned else {
            throw ContractInputError(category: "keyboard-startup-owner-or-defaults")
        }
        let rows = Dictionary(uniqueKeysWithValues: receipt.rows.map { ($0.caseName, $0) })
        if mode == "success" {
            guard receipt.rows.count == 1,
                  let ready = rows["ready"],
                  ready.events == [
                    "global-pressed", "durable-session", "speech-assets-ready",
                    "audio-ready", "recording"
                  ],
                  ready.startedLocaleIdentifier == "fr-FR",
                  ready.startedLocaleIdentifier == ready.verifiedLocaleIdentifier,
                  ready.startedGeneration == ready.generation,
                  ready.transcriptionStartCount == 1,
                  ready.captureStartCount == 1,
                  ready.recordingTimerStartCount == 1,
                  ready.allResourceCount == 0 else {
                throw ContractInputError(category: "keyboard-startup-production-sequence")
            }
            return
        }
        guard Set(rows.keys) == Set(Task15KeyboardStartupReceipt.failureCases) else {
            throw ContractInputError(category: "keyboard-startup-failure-matrix")
        }
        for caseName in Task15KeyboardStartupReceipt.recoveryCases {
            guard let row = rows[caseName],
                  row.recoveryCategory == caseName,
                  row.recoveryCopy == Task15KeyboardStartupReceipt.recoveryCopy[caseName],
                  row.terminalizationCount == 1,
                  row.allResourceCount == 0,
                  row.recordingTimerStartCount == 0 else {
                throw ContractInputError(category: "keyboard-startup-recovery-" + caseName)
            }
        }
        for caseName in ["stale-generation", "locale-mismatch", "speech-assets-not-ready"] {
            guard let row = rows[caseName],
                  row.transcriptionStartCount == 0,
                  row.captureStartCount == 0,
                  row.terminalizationCount == 1,
                  row.allResourceCount == 0 else {
                throw ContractInputError(category: "keyboard-startup-locale-" + caseName)
            }
        }
    }

    private static func runProcess(
        executable: URL,
        arguments: [String],
        environment: [String: String] = [:],
        timeout: TimeInterval? = nil,
        failureCategory: String
    ) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, requested in requested }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        if let timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            if process.isRunning { process.terminate() }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = output.fileHandleForReading.readDataToEndOfFile()
            FileHandle.standardError.write(detail)
            throw ContractInputError(category: failureCategory)
        }
    }
}

private struct Task15KeyboardStartupReceipt: Decodable {
    static let recoveryCases = [
        "storage-unavailable", "onboarding-incomplete", "microphone-denied",
        "input-unavailable", "speech-unavailable", "speech-failed",
        "startup-interrupted", "startup-cancelled"
    ]
    static let localeCases = ["stale-generation", "locale-mismatch", "speech-assets-not-ready"]
    static let failureCases = recoveryCases + localeCases
    static let recoveryCopy = [
        "storage-unavailable": "Storage is unavailable. Retry storage in Oigo Settings.",
        "onboarding-incomplete": "Finish Oigo setup before starting dictation.",
        "microphone-denied": "Microphone access is required. Allow Oigo in System Settings.",
        "input-unavailable": "No selected microphone input is available. Choose an input in Oigo Settings.",
        "speech-unavailable": "Speech recognition is unavailable. Retry after Speech support is available.",
        "speech-failed": "Speech recognition failed to start. Try dictation again.",
        "startup-interrupted": "Dictation startup was interrupted. Try dictation again.",
        "startup-cancelled": "Dictation startup was cancelled. Try dictation again."
    ]

    let ownerIdentity: String
    let rows: [Task15KeyboardStartupRow]
    let defaultsCleaned: Bool
}

private struct Task15KeyboardStartupRow: Decodable {
    let caseName: String
    let events: [String]
    let generation: UInt64
    let verifiedLocaleIdentifier: String?
    let startedLocaleIdentifier: String?
    let startedGeneration: UInt64?
    let recoveryCategory: String?
    let recoveryCopy: String?
    let terminalizationCount: Int
    let appDelegateResourceCount: Int
    let coordinatorResourceCount: Int
    let hudResourceCount: Int
    let timerResourceCount: Int
    let captureResourceCount: Int
    let speechResourceCount: Int
    let transcriptionStartCount: Int
    let captureStartCount: Int
    let recordingTimerStartCount: Int

    var allResourceCount: Int {
        appDelegateResourceCount + coordinatorResourceCount + hudResourceCount
            + timerResourceCount + captureResourceCount + speechResourceCount
    }
}
