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

    static func testNativeQATargetFieldClassification() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-task17-target-field-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let canonicalRoot = URL(fileURLWithPath: try runTask17Process(
            executable: "/bin/zsh",
            arguments: ["-c", "cd -- \"$1\" && pwd -P", "zsh", root.path],
            expectedStatus: 0
        ).output.trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true)
        let repository = canonicalRoot.appendingPathComponent("repository", isDirectory: true)
        let qaRoot = repository.appendingPathComponent("qa", isDirectory: true)
        let sourceSHA = String(repeating: "a", count: 40)
        let sourceRoot = qaRoot.appendingPathComponent("source-" + sourceSHA, isDirectory: true)
        let attempt = canonicalRoot.appendingPathComponent("attempt", isDirectory: true)
        let evidence = attempt.appendingPathComponent("target-field", isDirectory: true)
        let app = qaRoot.appendingPathComponent("Oigo.app", isDirectory: true)
        let target = qaRoot.appendingPathComponent("target.app", isDirectory: true)
        let scripts = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: attempt, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: qaRoot.appendingPathComponent("home", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target.appendingPathComponent("Contents", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: sourceRoot.appendingPathComponent("Scripts", isDirectory: true),
            withDestinationURL: scripts
        )
        let appInfo = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict/></plist>"
        let targetInfo = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>com.oigo.qa.target</string><key>OigoQATargetFieldIdentifier</key><string>different.field</string></dict></plist>"
        try appInfo.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        try targetInfo.write(to: target.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)

        let bundleHash = try runTask17Process(
            executable: "/bin/zsh",
            arguments: [sourceRoot.appendingPathComponent("Scripts/oigo-bundle-sha256.sh").path, app.path],
            expectedStatus: 0
        ).output
            .split(separator: ":")
            .last
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        guard bundleHash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw ContractFailure(message: "target-field fixture did not produce a bundle hash")
        }
        let marker: [String: Any] = [
            "qa_root": qaRoot.path,
            "attempt_dir": attempt.path,
            "repository": canonicalRoot.path,
            "reviewed_plan_sha": "4b7cf8d3e0e323b5b3d7e0f17467e5b99901682b81255ad5f06c33ad2e42a198",
            "execution_base_sha": "a8315736e9b9ebb8c8e0a4bd6caa987eb67b2c37",
            "run_uuid": "00000000-0000-4000-8000-000000000000"
        ]
        let markerData = try JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys])
        try markerData.write(to: qaRoot.appendingPathComponent("run.json"))
        let environment = ["HOME": qaRoot.appendingPathComponent("home").path, "CFFIXED_USER_HOME": qaRoot.appendingPathComponent("home").path]
        let arguments = [
            sourceRoot.appendingPathComponent("Scripts/oigo-native-qa-preflight.sh").path,
            "--source-root", sourceRoot.path,
            "--app", app.path,
            "--app-source-sha", sourceSHA,
            "--app-sha", bundleHash,
            "--qa-root", qaRoot.path,
            "--evidence-root", evidence.path,
            "--frontmost-app", target.path,
            "--target-field-id", "oigo.qa.target.text-field"
        ]
        let targetField = try runTask17Process(executable: "/bin/zsh", arguments: arguments, expectedStatus: nil, environment: environment)
        guard targetField.status == 1,
              targetField.output.contains("ERROR target-field-not-found"),
              !targetField.output.contains("INCONCLUSIVE target-field-unavailable"),
              !FileManager.default.fileExists(atPath: qaRoot.appendingPathComponent("home/Library/Preferences").path),
              !FileManager.default.fileExists(atPath: evidence.appendingPathComponent("receipt.json").path) else {
            throw ContractFailure(message: "missing target field was not a non-mutating ERROR result")
        }

        let malformed = try runTask17Process(
            executable: "/bin/zsh",
            arguments: Array(arguments.dropLast(2)),
            expectedStatus: 64,
            environment: environment
        )
        guard malformed.output.contains("ERROR missing-argument") else {
            throw ContractFailure(message: "malformed preflight input no longer fails as an error")
        }
    }

    @discardableResult
    private static func runTask17Process(
        executable: String,
        arguments: [String],
        expectedStatus: Int32?,
        environment: [String: String] = [:]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, replacement in replacement }
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
