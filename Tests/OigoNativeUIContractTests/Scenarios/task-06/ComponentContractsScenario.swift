import Foundation

final class ComponentContractsScenario: NativeUIContractScenario {
    private struct Fixture: Decodable {
        struct Component: Decodable {
            let kind: String
            let tone: String?
            let iconRole: String?
            let label: String?
            let ownedResource: String
        }

        struct Result: Decodable {
            let reportedSuccess: Bool
            let processExitStatus: Int
        }

        let appearance: String
        let increasedContrast: Bool
        let reducedMotion: Bool
        let components: [Component]
        let observations: [String]
        let dirty: Bool?
        let result: Result?
    }

    override class var scenarioName: String {
        "component-contracts"
    }

    override class func run(arguments: ContractArguments) throws {
        guard arguments.defaultsSuite == "com.oigo.qa.task06" else {
            throw ContractInputError(category: "invalid-defaults-suite")
        }
        let fixture = try loadFixture(from: arguments.fixtureRoot)
        try validate(fixture)

        let fixtureSources = arguments.fixtureRoot.appendingPathComponent("Sources", isDirectory: true)
        let sourceRoot: URL
        if FileManager.default.fileExists(atPath: fixtureSources.path) {
            sourceRoot = fixtureSources
        } else {
            sourceRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Sources/MacUtilityUI", isDirectory: true)
        }
        let sources = try swiftSources(in: sourceRoot)
        try validateImports(in: sources)
        let runtime = try compileAndRun(sources)
        guard runtime == "COMPONENTS 13 lifecycle=stopped panel=nonactivating transcript=clearable\n" else {
            throw ContractInputError(category: "unexpected-component-runtime")
        }
        print(
            "PASS component-contracts appearance=\(fixture.appearance) "
                + "contrast=\(fixture.increasedContrast) reduced-motion=\(fixture.reducedMotion)"
        )
    }

    private static func loadFixture(from root: URL) throws -> Fixture {
        let url = root.appendingPathComponent("fixture.json")
        guard let data = try? Data(contentsOf: url) else {
            throw ContractInputError(category: "missing-fixture")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ContractInputError(category: "malformed-component-metadata")
        }
        if containsPrivateContent(in: object) {
            throw ContractInputError(category: "forbidden-user-content")
        }
        do {
            return try JSONDecoder().decode(Fixture.self, from: data)
        } catch {
            throw ContractInputError(category: "malformed-component-metadata")
        }
    }

    private static func validate(_ fixture: Fixture) throws {
        guard ["light", "dark"].contains(fixture.appearance) else {
            throw ContractInputError(category: "malformed-component-metadata")
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
        guard Set(fixture.observations).count == 1 else {
            throw ContractInputError(category: "flaky-appearance-fixture")
        }

        let requiredKinds = Set([
            "status-row", "inline-notice", "status-badge", "form-row", "loading-state",
            "empty-state", "permission-row", "storage-row", "transcript-view", "floating-panel",
            "destructive-confirmation", "shortcut-presentation", "help-text"
        ])
        let componentsByKind = Dictionary(grouping: fixture.components, by: \.kind)
        guard Set(componentsByKind.keys) == requiredKinds,
              componentsByKind.values.allSatisfy({ $0.count == 1 }) else {
            throw ContractInputError(category: "incomplete-component-set")
        }
        for kind in ["status-row", "inline-notice", "status-badge"] {
            guard let component = componentsByKind[kind]?.first,
                  let tone = component.tone,
                  ["neutral", "informational", "success", "warning", "critical", "recording"]
                    .contains(tone),
                  let iconRole = component.iconRole,
                  !iconRole.isEmpty,
                  let label = component.label,
                  !label.isEmpty,
                  label.count <= 48,
                  !label.contains("\n") else {
                throw ContractInputError(category: "status-missing-semantics")
            }
        }
        guard componentsByKind["loading-state"]?.first?.ownedResource == "visible-spinner",
              componentsByKind["floating-panel"]?.first?.ownedResource == "terminal-release",
              fixture.components.filter({ !["loading-state", "floating-panel"].contains($0.kind) })
                .allSatisfy({ $0.ownedResource == "none" }) else {
            throw ContractInputError(category: "invalid-component-lifecycle")
        }
    }

    private static func containsPrivateContent(in object: Any) -> Bool {
        if let dictionary = object as? [String: Any] {
            let forbidden = Set([
                "transcript", "audio", "clipboard", "focusedText", "dictionaryEntries", "userPath"
            ])
            return !forbidden.isDisjoint(with: dictionary.keys)
                || dictionary.values.contains(where: containsPrivateContent(in:))
        }
        if let array = object as? [Any] {
            return array.contains(where: containsPrivateContent(in:))
        }
        return false
    }

    private static func swiftSources(in root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            throw ContractInputError(category: "missing-component-sources")
        }
        let sources = enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
        guard !sources.isEmpty else {
            throw ContractInputError(category: "missing-component-sources")
        }
        return sources
    }

    private static func validateImports(in sources: [URL]) throws {
        for source in sources {
            guard let text = try? String(contentsOf: source, encoding: .utf8) else {
                throw ContractInputError(category: "unreadable-component-source")
            }
            for line in text.split(separator: "\n") {
                let fields = line.split(whereSeparator: \.isWhitespace)
                if fields.first == "import",
                   fields.count >= 2,
                   !["AppKit", "Foundation"].contains(String(fields[1])) {
                    throw ContractInputError(category: "forbidden-component-import")
                }
            }
        }
    }

    private static func compileAndRun(_ sources: [URL]) throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-native-ui-redesign.task06." + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let driver = root.appendingPathComponent("main.swift")
        let executable = root.appendingPathComponent("component-contract")
        try runtimeDriver.write(to: driver, atomically: true, encoding: .utf8)
        let process = Process()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swiftc"] + sources.map(\.path) + [driver.path, "-o", executable.path]
        process.standardOutput = Pipe()
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ContractInputError(category: "component-compiler-launch")
        }
        let diagnostics = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            FileHandle.standardError.write(diagnostics)
            throw ContractInputError(category: "component-compile-failed")
        }
        let runtime = Process()
        let stdout = Pipe()
        runtime.executableURL = executable
        runtime.standardOutput = stdout
        runtime.standardError = Pipe()
        try runtime.run()
        runtime.waitUntilExit()
        guard runtime.terminationStatus == 0,
              let output = String(
                data: stdout.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
              ) else {
            throw ContractInputError(category: "component-runtime-failed")
        }
        return output
    }

    private static let runtimeDriver = #"""
    import AppKit

    MainActor.assumeIsolated {
    let status = MacUIStatusContent(tone: .success, iconRole: .confirmation, label: "Ready")
    let row = MacUIStatusRow(content: status, title: "Service", trailingValue: status.label)
    let notice = MacUIInlineNotice(content: status, body: "The service is ready.")
    let badge = MacUIStatusBadge(content: status)
    let form = MacUIFormRow(label: "Name", control: NSTextField(string: "Synthetic"))
    let loading = MacUILoadingView(label: "Loading")
    let replacedLoading = MacUILoadingView(label: "Replacing")
    let terminalLoading = MacUILoadingView(label: "Terminal")
    let empty = MacUIEmptyStateView(message: "Nothing here")
    let permission = MacUIPermissionRow(name: "Permission", status: status, action: {})
    let storage = MacUIStorageHealthRow(name: "Storage", status: status, action: {})
    let transcript = MacUITranscriptView(maximumLength: 4)
    transcript.setTranscript("synthetic")
    guard transcript.transcript == "synt" else { exit(1) }
    transcript.clear()
    let panel = MacUIFloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 80))
    let alert = MacUIDestructiveConfirmation.makeAlert(
        title: "Delete item?", message: "This cannot be undone.", confirmTitle: "Delete"
    )
    let shortcut = MacUIShortcutPresentation(glyphs: ["⌘", "D"], accessibilityLabel: "Command D")
    let help = MacUIFieldHelpText("Synthetic help")
    loading.shutdown()
    replacedLoading.terminalize(replacingWith: NSView())
    terminalLoading.terminalize()
    guard !loading.isAnimating, !replacedLoading.isAnimating, !terminalLoading.isAnimating,
          !panel.canBecomeKey, !panel.canBecomeMain,
          transcript.transcript.isEmpty, alert.alertStyle == .critical else { exit(2) }
    panel.terminalize()
    withExtendedLifetime([row, notice, badge, form, empty, permission, storage, shortcut, help]) {}
    print("COMPONENTS 13 lifecycle=stopped panel=nonactivating transcript=clearable")
    }
    """#
}
