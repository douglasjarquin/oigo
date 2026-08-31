import Foundation

@MainActor
extension OigoIssue82ContractTests {
    static func testNativeQAPermissionMechanism() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-task17-contract-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let keyDriver = root.appendingPathComponent("oigo-native-key-event-driver")
        try runTask17Process(
            executable: "/usr/bin/xcrun",
            arguments: [
                "swiftc", "Scripts/oigo-native-key-event-driver.swift",
                "-framework", "ApplicationServices", "-o", keyDriver.path
            ],
            expectedStatus: 0
        )
        let keyCheck = try runTask17Process(
            executable: keyDriver.path,
            arguments: ["--check-only"],
            expectedStatus: nil
        )
        guard [0, 2].contains(keyCheck.status),
              keyCheck.output.contains("COREGRAPHICS_POST_EVENT_CHECKPOINT="),
              !keyCheck.output.contains("input-monitoring") else {
            throw ContractFailure(message: "CGEventPost preflight was mislabeled as Input Monitoring")
        }

        let permissionDriver = root.appendingPathComponent("oigo-native-permission-preflight")
        try runTask17Process(
            executable: "/usr/bin/xcrun",
            arguments: [
                "swiftc", "Scripts/oigo-native-permission-preflight.swift",
                "-framework", "AVFoundation", "-framework", "ApplicationServices",
                "-framework", "CoreGraphics", "-framework", "Speech",
                "-o", permissionDriver.path
            ],
            expectedStatus: 0
        )
        let permissionCheck = try runTask17Process(
            executable: permissionDriver.path,
            arguments: [],
            expectedStatus: 0
        )
        guard permissionCheck.output.contains("INPUT_MONITORING_CHECKPOINT=not-required-no-event-tap"),
              permissionCheck.output.contains("SCREEN_RECORDING_CHECKPOINT=not-required-oigo-owned-capture"),
              permissionCheck.output.contains("SPEECH_CHECKPOINT="),
              permissionCheck.output.contains("INPUT_CHECKPOINT=") else {
            throw ContractFailure(message: "native QA permission preflight omitted a mechanism checkpoint")
        }
    }

    @discardableResult
    private static func runTask17Process(
        executable: String,
        arguments: [String],
        expectedStatus: Int32?
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let captured = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        if let expectedStatus, process.terminationStatus != expectedStatus {
            throw ContractFailure(message: "task 17 helper failed: " + captured)
        }
        return (process.terminationStatus, captured)
    }
}
