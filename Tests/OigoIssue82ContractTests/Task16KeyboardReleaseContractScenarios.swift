import Foundation

@MainActor
enum Task16KeyboardReleaseContracts {
    static func verifyLifecycle() throws {
        try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["swift", "build", "--product", "Oigo"],
            failure: "Oigo product did not build for the keyboard release lifecycle probe"
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-task16-contract-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("keyboard-release.json")
        try runProcess(
            executable: URL(fileURLWithPath: ".build/debug/Oigo"),
            arguments: [
                "--task-16-keyboard-release-probe", "all",
                "com.oigo.qa.task16", output.path
            ],
            environment: [
                "CFFIXED_USER_HOME": root.path,
                "HOME": root.path,
                "OIGO_QA_MODE": "1"
            ],
            timeout: 12,
            failure: "AppDelegate keyboard release lifecycle probe failed"
        )
        let receipt = try JSONDecoder().decode(
            Task16ReleaseReceipt.self,
            from: Data(contentsOf: output)
        )
        let rows = Dictionary(uniqueKeysWithValues: receipt.rows.map { ($0.caseName, $0) })
        guard receipt.ownerIdentity == "oigo-app-delegate-keyboard-release-lifecycle",
              receipt.defaultsCleaned,
              rows.count == 4 else {
            throw ContractFailure(message: "keyboard release receipt identity or isolation failed")
        }
        try require(rows["release-before-ready"], state: "cancelled", rawBytes: 0, insertionCount: 0)
        try require(
            rows["release-during-recording"],
            state: "complete",
            durableState: "completed",
            rawBytesAtLeast: 1,
            insertionCount: 1
        )
        try require(rows["interrupt-during-audio"], state: "interrupted", rawBytesAtLeast: 1, insertionCount: 0)
        try require(
            rows["app-close-during-terminalization"],
            state: "interrupted",
            rawBytesAtLeast: 1,
            insertionCount: 0
        )
        guard rows["release-before-ready"]?.transcriptionCancelCount == 1,
              rows["release-during-recording"]?.transcriptionFinishCount == 1,
              rows["release-during-recording"]?.captureStopCount == 1,
              rows["app-close-during-terminalization"]?.transcriptionCancelCount == 1 else {
            throw ContractFailure(message: "release was not idempotent across startup and recording")
        }
        print("COUNTS: release_cases=4 terminalization=1 resources=0 duplicate_stop=0")
    }

    private static func require(
        _ row: Task16ReleaseRow?,
        state: String,
        durableState: String? = nil,
        rawBytes: Int64? = nil,
        rawBytesAtLeast: Int64? = nil,
        insertionCount: Int
    ) throws {
        guard let row,
              row.checkpoints.first == "preparation",
              row.checkpoints.suffix(2) == ["terminal", "cleanup"],
              row.terminalState == state,
              row.durableState == (durableState ?? state),
              rawBytes.map({ row.durableRawBytes == $0 }) ?? true,
              rawBytesAtLeast.map({ row.durableRawBytes >= $0 }) ?? true,
              row.terminalizationCount == 1,
              row.insertionCount == insertionCount,
              row.appResourceCount == 0,
              row.coordinatorResourceCount == 0,
              row.hudResourceCount == 0,
              row.timerResourceCount == 0 else {
            throw ContractFailure(message: "keyboard release lifecycle mismatch: \(String(describing: row))")
        }
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

private struct Task16ReleaseReceipt: Decodable {
    let ownerIdentity: String
    let rows: [Task16ReleaseRow]
    let defaultsCleaned: Bool
}

private struct Task16ReleaseRow: Decodable, CustomStringConvertible {
    let caseName: String
    let checkpoints: [String]
    let terminalState: String
    let durableState: String?
    let durableRawBytes: Int64
    let terminalizationCount: Int
    let captureStopCount: Int
    let captureCancelCount: Int
    let transcriptionFinishCount: Int
    let transcriptionCancelCount: Int
    let insertionCount: Int
    let appResourceCount: Int
    let coordinatorResourceCount: Int
    let hudResourceCount: Int
    let timerResourceCount: Int

    var description: String {
        "\(caseName):state=\(terminalState):durable=\(durableState ?? "none"):raw=\(durableRawBytes):resources=\(appResourceCount + coordinatorResourceCount + hudResourceCount + timerResourceCount)"
    }
}
