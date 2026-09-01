import Foundation

@MainActor
enum Task15AppDelegateStartupContracts {
    static func verifyProductionBridgeSequence() throws {
        let receipt = try runProbe(mode: "success")
        guard receipt.ownerIdentity == "oigo-app-delegate-keyboard-startup",
              receipt.defaultsCleaned,
              receipt.rows.count == 1,
              let row = receipt.rows.first,
              row.caseName == "ready",
              row.events == [
                "global-pressed", "durable-session", "speech-assets-ready",
                "audio-ready", "recording"
              ],
              row.startedLocaleIdentifier == "fr-FR",
              row.startedGeneration == row.generation,
              row.transcriptionStartCount == 1,
              row.captureStartCount == 1,
              row.recordingTimerStartCount == 1,
              row.allResourceCount == 0 else {
            throw ContractFailure(
                message: "AppDelegate production shortcut sequence did not emit real ordered startup events: \(receipt.rows)"
            )
        }
        print("TRACE: " + row.events.joined(separator: " -> "))
    }

    static func verifyRecoveryAndLocaleBinding() throws {
        let receipt = try runProbe(mode: "all")
        let rows = Dictionary(uniqueKeysWithValues: receipt.rows.map { ($0.caseName, $0) })
        let recovery: [String: (category: String, copy: String)] = [
            "storage-unavailable": (
                "storage-unavailable",
                "Storage is unavailable. Retry storage in Oigo Settings."
            ),
            "onboarding-incomplete": (
                "onboarding-incomplete",
                "Finish Oigo setup before starting dictation."
            ),
            "microphone-denied": (
                "microphone-denied",
                "Microphone access is required. Allow Oigo in System Settings."
            ),
            "input-unavailable": (
                "input-unavailable",
                "No selected microphone input is available. Choose an input in Oigo Settings."
            ),
            "speech-unavailable": (
                "speech-unavailable",
                "Speech recognition is unavailable. Retry after Speech support is available."
            ),
            "speech-failed": (
                "speech-failed",
                "Speech recognition failed to start. Try dictation again."
            ),
            "startup-interrupted": (
                "startup-interrupted",
                "Dictation startup was interrupted. Try dictation again."
            ),
            "startup-cancelled": (
                "startup-cancelled",
                "Dictation startup was cancelled. Try dictation again."
            )
        ]
        for (caseName, expected) in recovery {
            guard let row = rows[caseName],
                  row.recoveryCategory == expected.category,
                  row.recoveryCopy == expected.copy,
                  row.terminalizationCount == 1,
                  row.allResourceCount == 0,
                  row.recordingTimerStartCount == 0 else {
                throw ContractFailure(
                    message: "AppDelegate recovery or exact-once cleanup mismatch for \(caseName): \(String(describing: rows[caseName]))"
                )
            }
        }
        for caseName in ["stale-generation", "locale-mismatch", "speech-assets-not-ready"] {
            guard let row = rows[caseName],
                  row.transcriptionStartCount == 0,
                  row.captureStartCount == 0,
                  row.allResourceCount == 0,
                  row.terminalizationCount == 1 else {
                throw ContractFailure(message: "invalid AppDelegate locale readiness reached startup for \(caseName)")
            }
        }
        guard let ready = rows["ready"],
              ready.startedLocaleIdentifier == ready.verifiedLocaleIdentifier,
              ready.startedLocaleIdentifier == "fr-FR",
              ready.startedGeneration == ready.generation,
              ready.transcriptionStartCount == 1,
              ready.captureStartCount == 1 else {
            throw ContractFailure(message: "verified AppDelegate locale generation did not reach first dictation")
        }
        print("COUNTS: app_delegate_recovery=\(recovery.count) locale_ready=1 rejected=3 resources=0")
    }

    private static func runProbe(mode: String) throws -> Task15StartupReceipt {
        try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["swift", "build", "--product", "Oigo"],
            failure: "Oigo product did not build for the AppDelegate startup probe"
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-task15-app-delegate-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("keyboard-startup.json")
        try runProcess(
            executable: URL(fileURLWithPath: ".build/debug/Oigo"),
            arguments: [
                "--task-15-keyboard-startup-probe", mode,
                "com.oigo.qa.task15.issue82", output.path
            ],
            environment: [
                "CFFIXED_USER_HOME": root.path,
                "HOME": root.path,
                "OIGO_QA_MODE": "1"
            ],
            timeout: 8,
            failure: "AppDelegate keyboard startup production probe is unavailable or failed"
        )
        return try JSONDecoder().decode(Task15StartupReceipt.self, from: Data(contentsOf: output))
    }

    private static func runProcess(
        executable: URL,
        arguments: [String],
        environment: [String: String] = [:],
        timeout: TimeInterval? = nil,
        failure: String
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
            let detail = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw ContractFailure(message: failure + ": " + detail)
        }
    }
}

private struct Task15StartupReceipt: Decodable {
    let ownerIdentity: String
    let rows: [Task15StartupRow]
    let defaultsCleaned: Bool
}

private struct Task15StartupRow: Decodable, CustomStringConvertible {
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

    var description: String {
        "\(caseName):events=\(events),recovery=\(recoveryCategory ?? "none"),resources=\(allResourceCount)"
    }
}
