import Darwin
import Foundation
import OigoCore

private struct ContractFailure: Error, CustomStringConvertible {
    let message: String

    var description: String {
        message
    }
}

@main
private struct OigoIssue14ContractTests {
    static let plantedTranscript = "PLANTED_TRANSCRIPT_BODY_NEVER_EXPORT"
    static let plantedAlias = "supersecret-alias-xyz"
    static let plantedCanonical = "ConsigliereLeakTerm"
    static let plantedPath = "/Users/planted-user/Library/Application Support/Oigo/Sessions/2026-secret-session"

    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("export JSON has required keys", testExportHasRequiredKeys),
            ("planted transcript alias and path do not leak", testPlantedContentDoesNotLeak),
            ("missing dictionary file still exports", testMissingDictionaryStillExports),
            ("failure codes never include associated content", testFailureCodesAreContentFree),
            ("release script fails without credentials", testReleaseScriptFailsWithoutCredentials)
        ]

        var failures = 0
        for (name, test) in tests {
            do {
                try test()
                print("GREEN: " + name)
            } catch {
                failures += 1
                print("FAIL: " + name + ": " + String(describing: error))
            }
        }

        if failures == 0 {
            print("GREEN: all issue #14 contract scenarios")
            exit(0)
        }
        print("FAILURES=" + String(failures))
        exit(1)
    }

    private static func testExportHasRequiredKeys() throws {
        let data = try makeExport(
            dictionaryEntryCount: 0,
            sessionCount: 0,
            lastFailureCode: "dictation.workAlreadyActive"
        ).jsonData()
        let object = try jsonObject(data)
        for key in OigoDiagnosticsExport.requiredKeys {
            guard object[key] != nil else {
                throw ContractFailure(message: "missing required key " + key)
            }
        }
        guard object["appVersion"] as? String == "1.0.0",
              object["build"] as? String == "1",
              object["bundleIdentifier"] as? String == "com.oigo.app",
              object["architecture"] as? String == "arm64",
              object["storageHealth"] as? String == "ready",
              object["dictationState"] as? String == "idle",
              object["lastFailureCode"] as? String == "dictation.workAlreadyActive",
              object["defaultMode"] as? String == "instant",
              object["previewEnabled"] as? Bool == true,
              object["retention"] as? String == "oneDay",
              object["keepAudioIndefinitely"] as? Bool == false,
              object["launchAtLoginLastRequested"] as? Bool == false,
              object["localeIdentifier"] as? String == "en-US",
              object["selectedInput"] as? String == "systemDefault",
              object["shortcutRegistration"] as? String == "present",
              object["dictionaryEntryCount"] as? Int == 0,
              object["sessionCount"] as? Int == 0 else {
            throw ContractFailure(message: "export JSON values were wrong")
        }
        guard let maintenance = object["lastMaintenance"] as? [String: Any],
              maintenance["inspectedDirectoryCount"] as? Int == 2,
              maintenance["skippedDirectoryCount"] as? Int == 1,
              maintenance["removedSessionCount"] as? Int == 0,
              maintenance["removedAudioCount"] as? Int == 3,
              maintenance["moreWorkRemains"] as? Bool == false else {
            throw ContractFailure(message: "maintenance counts were missing or wrong")
        }
        let json = String(decoding: data, as: UTF8.self)
        guard !json.contains("hostname"),
              !json.contains("username"),
              !json.contains("/Users/") else {
            throw ContractFailure(message: "export JSON included identifying host fields")
        }
    }

    private static func testPlantedContentDoesNotLeak() throws {
        let root = temporaryDirectory("leak")
        defer { try? FileManager.default.removeItem(at: root) }

        let dictionaryStore = try DictionaryStore(directoryURL: root)
        try dictionaryStore.save(
            DictionaryDocument(
                entries: [
                    DictionaryEntry(
                        canonical: plantedCanonical,
                        aliases: [plantedAlias]
                    )
                ]
            )
        )
        let loaded = dictionaryStore.load()
        guard loaded.document.entries.count == 1 else {
            throw ContractFailure(message: "planted dictionary did not load")
        }

        let sessions = root.appendingPathComponent("Sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let plantedSession = sessions.appendingPathComponent("2026-secret-session", isDirectory: true)
        try FileManager.default.createDirectory(at: plantedSession, withIntermediateDirectories: true)
        try Data(plantedTranscript.utf8).write(
            to: plantedSession.appendingPathComponent("raw.txt"),
            options: .atomic
        )
        try Data(plantedPath.utf8).write(
            to: plantedSession.appendingPathComponent("path.txt"),
            options: .atomic
        )

        var settings = OigoSettings.default
        settings.localeIdentifier = "en-US"
        settings.selectedInput = .pinned(uid: "planted-device-uid-should-not-export")
        settings.globalShortcut = ToggleShortcut(keyCode: 49, modifiers: 0x800)

        let export = try OigoDiagnosticsExport.make(
            OigoDiagnosticsSnapshot(
                appVersion: "1.0.0",
                build: "1",
                bundleIdentifier: "com.oigo.app",
                macOSVersion: "26.0.0",
                architecture: "arm64",
                storageHealth: .ready(
                    DurableSessionBootstrapReport(
                        recoveredSessionCount: 0,
                        historyEntryCount: 1,
                        malformedSessionCount: 0
                    )
                ),
                dictationState: .failed,
                lastFailureCode: OigoDiagnosticsFailureCode.code(
                    for: SessionStoreError.invalidSessionDirectory(URL(fileURLWithPath: plantedPath))
                ),
                settings: settings,
                shortcutRegistration: .inactive,
                shortcutDisplayName: "Right Option",
                dictionaryEntryCount: loaded.document.entries.count,
                sessionCount: 1,
                lastMaintenance: nil
            )
        ).jsonData()
        let json = String(decoding: export, as: UTF8.self)
        let leaks = [
            plantedTranscript,
            plantedAlias,
            plantedCanonical,
            plantedPath,
            "planted-user",
            "2026-secret-session",
            "planted-device-uid-should-not-export",
            dictionaryStore.fileURL.path,
            sessions.path
        ].filter { json.contains($0) }
        guard leaks.isEmpty else {
            throw ContractFailure(message: "serialized diagnostics leaked: " + leaks.joined(separator: ", "))
        }

        let object = try jsonObject(export)
        guard object["dictionaryEntryCount"] as? Int == 1,
              object["sessionCount"] as? Int == 1,
              object["selectedInput"] as? String == "pinned",
              object["lastFailureCode"] as? String == "session.invalidSessionDirectory",
              object["shortcutRegistration"] as? String == "inactive" else {
            throw ContractFailure(message: "leak-test export dropped required sanitized fields")
        }
    }

    private static func testMissingDictionaryStillExports() throws {
        let root = temporaryDirectory("missing-dictionary")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DictionaryStore(directoryURL: root)
        let loaded = store.load()
        guard loaded.document.entries.isEmpty,
              loaded.error == nil,
              !FileManager.default.fileExists(atPath: store.fileURL.path) else {
            throw ContractFailure(message: "missing dictionary did not load as empty")
        }

        let data = try makeExport(
            dictionaryEntryCount: loaded.document.entries.count,
            sessionCount: 0,
            lastFailureCode: nil
        ).jsonData()
        let object = try jsonObject(data)
        for key in OigoDiagnosticsExport.requiredKeys {
            guard object[key] != nil else {
                throw ContractFailure(message: "missing-file export omitted " + key)
            }
        }
        guard object["dictionaryEntryCount"] as? Int == 0 else {
            throw ContractFailure(message: "missing dictionary did not export a zero entry count")
        }
        let json = String(decoding: data, as: UTF8.self)
        guard !json.contains(store.fileURL.path),
              !json.contains(root.path) else {
            throw ContractFailure(message: "missing-file export leaked the dictionary path")
        }
    }

    private static func testFailureCodesAreContentFree() throws {
        let error = SessionStoreError.invalidMetadata(URL(fileURLWithPath: plantedPath))
        let code = OigoDiagnosticsFailureCode.code(for: error)
        guard code == "session.invalidMetadata" else {
            throw ContractFailure(message: "expected session.invalidMetadata, found " + code)
        }
        guard !code.contains(plantedPath),
              !code.contains("planted-user"),
              !OigoDiagnosticsFailureCode.code(
                for: DictionaryStoreError.conflictingAlias(plantedAlias)
              ).contains(plantedAlias) else {
            throw ContractFailure(message: "failure code included associated content")
        }
    }

    private static func testReleaseScriptFailsWithoutCredentials() throws {
        let root = try repositoryRoot()
        let script = root.appendingPathComponent("Scripts/package-oigo-release.sh")
        guard FileManager.default.isExecutableFile(atPath: script.path)
                || FileManager.default.fileExists(atPath: script.path) else {
            throw ContractFailure(message: "package-oigo-release.sh is missing")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [script.path]
        process.currentDirectoryURL = root
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSTemporaryDirectory()
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let errorOutput = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let output = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        guard process.terminationStatus != 0 else {
            throw ContractFailure(message: "release script succeeded without credentials")
        }
        let combined = errorOutput + output
        let requiredNames = [
            "OIGO_CODESIGN_IDENTITY",
            "OIGO_NOTARY_PROFILE",
            "OIGO_NOTARY_KEY",
            "OIGO_NOTARY_KEY_ID",
            "OIGO_NOTARY_ISSUER"
        ]
        for name in requiredNames {
            guard combined.contains(name) else {
                throw ContractFailure(message: "missing-env message did not list " + name)
            }
        }
        guard combined.contains("FAIL: missing release credentials") else {
            throw ContractFailure(message: "missing-env message was not actionable")
        }
        let secretLike = ["-----BEGIN", "private key", "notary-password"]
        for token in secretLike where combined.lowercased().contains(token.lowercased()) {
            throw ContractFailure(message: "missing-env message printed a secret-like value")
        }
    }

    private static func makeExport(
        dictionaryEntryCount: Int,
        sessionCount: Int,
        lastFailureCode: String?
    ) throws -> OigoDiagnosticsExport {
        OigoDiagnosticsExport.make(
            OigoDiagnosticsSnapshot(
                appVersion: "1.0.0",
                build: "1",
                bundleIdentifier: "com.oigo.app",
                macOSVersion: "26.0.0",
                architecture: "arm64",
                storageHealth: .ready(
                    DurableSessionBootstrapReport(
                        recoveredSessionCount: 0,
                        historyEntryCount: sessionCount,
                        malformedSessionCount: 0
                    )
                ),
                dictationState: .idle,
                lastFailureCode: lastFailureCode,
                settings: OigoSettings.default.with(localeIdentifier: "en-US"),
                shortcutRegistration: .present,
                shortcutDisplayName: "Right Option",
                dictionaryEntryCount: dictionaryEntryCount,
                sessionCount: sessionCount,
                lastMaintenance: SessionMaintenanceSummary(
                    inspectedDirectoryCount: 2,
                    skippedDirectoryCount: 1,
                    removedSessionCount: 0,
                    removedAudioCount: 3,
                    moreWorkRemains: false
                )
            )
        )
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw ContractFailure(message: "export JSON was not an object")
        }
        return dictionary
    }

    private static func temporaryDirectory(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue14-" + name + "-" + UUID().uuidString, isDirectory: true)
    }

    private static func repositoryRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<10 {
            url.deleteLastPathComponent()
            let package = url.appendingPathComponent("Package.swift")
            let script = url.appendingPathComponent("Scripts/package-oigo-release.sh")
            if FileManager.default.fileExists(atPath: package.path),
               FileManager.default.fileExists(atPath: script.path) {
                return url
            }
        }
        throw ContractFailure(message: "could not locate the repository root from " + #filePath)
    }
}
