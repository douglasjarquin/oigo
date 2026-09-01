import Foundation

final class AppDelegatePublicationScenario: NativeUIContractScenario {
    private struct Fixture: Decodable {
        struct Event: Decodable {
            let generation: UInt64
            let delayMilliseconds: UInt64
            let storage: String
        }

        struct Result: Decodable {
            let reportedSuccess: Bool
            let processExitStatus: Int
        }

        let mode: String
        let events: [Event]
        let surfaceCount: Int
        let repeatCount: Int?
        let dirty: Bool?
        let result: Result?
    }

    override class var scenarioName: String {
        "app-delegate-publication"
    }

    override class func run(arguments: ContractArguments) throws {
        guard arguments.defaultsSuite == "com.oigo.qa.task05" else {
            throw ContractInputError(category: "invalid-defaults-suite")
        }
        let fixture = try loadFixture(from: arguments.fixtureRoot)
        try validate(fixture)

        let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let presentationRoot = repository
            .appendingPathComponent("Sources/Oigo/UI/Presentation", isDirectory: true)
        let publicationSource = presentationRoot
            .appendingPathComponent("OigoPresentationPublication.swift")
        let delegateSource = repository.appendingPathComponent("Sources/Oigo/OigoAppDelegate.swift")
        let onboardingSource = repository.appendingPathComponent("Sources/Oigo/OnboardingWindowController.swift")
        let statusSurfaceSource = repository.appendingPathComponent("Sources/Oigo/StatusSurfaceController.swift")
        guard FileManager.default.fileExists(atPath: publicationSource.path) else {
            try demonstrateUngatedRepaint(fixture)
            throw ContractInputError(category: "missing-publication-boundary")
        }
        try validateDelegateBoundary(delegateSource)
        try validatePermissionRefreshBoundary(
            delegate: delegateSource,
            onboarding: onboardingSource
        )
        try validateMicrophoneStartupGrantBoundary(delegate: delegateSource)
        try validateOigoEntitlementsBoundary(
            project: repository.appendingPathComponent("Oigo.xcodeproj/project.pbxproj"),
            entitlements: repository.appendingPathComponent("Oigo/Oigo.entitlements"),
            installScript: repository.appendingPathComponent("Scripts/install-oigo-dev.sh")
        )
        try validatePopoverPermissionRefreshBoundary(
            delegate: delegateSource,
            statusSurface: statusSurfaceSource
        )

        let sources = [
            presentationRoot.appendingPathComponent("OigoPresentationInputs.swift"),
            presentationRoot.appendingPathComponent("OigoPresentationState.swift"),
            presentationRoot.appendingPathComponent("OigoPresentationProjection.swift"),
            presentationRoot.appendingPathComponent("OigoPresentationAttributes.swift"),
            publicationSource
        ]
        let output = try runCompiledContract(sources: sources, fixture: fixture)
        print(output, terminator: "")
        print("PASS app-delegate-publication resources=0")
    }

    private static func loadFixture(from root: URL) throws -> Fixture {
        let fixtureURL = root.appendingPathComponent("fixture.json")
        guard let data = try? Data(contentsOf: fixtureURL) else {
            throw ContractInputError(category: "missing-fixture")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ContractInputError(category: "malformed-publication")
        }
        if containsForbiddenField(in: object) {
            throw ContractInputError(category: "forbidden-field")
        }
        do {
            return try JSONDecoder().decode(Fixture.self, from: data)
        } catch {
            throw ContractInputError(category: "malformed-publication")
        }
    }

    private static func validate(_ fixture: Fixture) throws {
        let modes = Set(["fanout", "delayed", "shutdown", "cancel-resume", "interruptions"])
        guard modes.contains(fixture.mode),
              (1...12).contains(fixture.surfaceCount),
              (1...40).contains(fixture.repeatCount ?? 1),
              !fixture.events.isEmpty,
              fixture.events.allSatisfy({ $0.generation > 0 && $0.delayMilliseconds <= 250 }),
              fixture.events.allSatisfy({ ["ready", "degraded", "unavailable"].contains($0.storage) }) else {
            throw ContractInputError(category: "malformed-publication")
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
    }

    private static func containsForbiddenField(in object: Any) -> Bool {
        if let dictionary = object as? [String: Any] {
            let forbidden = Set([
                "transcript", "audio", "clipboard", "focusedText", "dictionaryEntries", "userPath"
            ])
            return !forbidden.isDisjoint(with: dictionary.keys)
                || dictionary.values.contains(where: containsForbiddenField(in:))
        }
        if let array = object as? [Any] {
            return array.contains(where: containsForbiddenField(in:))
        }
        return false
    }

    private static func demonstrateUngatedRepaint(_ fixture: Fixture) throws {
        let ordered = fixture.events.sorted { $0.delayMilliseconds < $1.delayMilliseconds }
        var elapsed: UInt64 = 0
        var painted: UInt64 = 0
        for event in ordered {
            Thread.sleep(forTimeInterval: Double(event.delayMilliseconds - elapsed) / 1_000)
            elapsed = event.delayMilliseconds
            painted = event.generation
        }
        guard let newest = fixture.events.map(\.generation).max(), painted < newest else {
            throw ContractInputError(category: "red-fixture-did-not-repaint")
        }
        print("RED stale snapshot repainted generation=\(painted) after generation=\(newest)")
    }

    private static func validateDelegateBoundary(_ source: URL) throws {
        guard let text = try? String(contentsOf: source, encoding: .utf8),
              text.contains("capturePresentationInputs"),
              text.contains("OigoPresentationState.project"),
              text.contains("publishPresentation"),
              text.contains("presentationPublicationFence.shutdown()") else {
            throw ContractInputError(category: "missing-app-delegate-publication")
        }
    }

    private static func validatePermissionRefreshBoundary(
        delegate: URL,
        onboarding: URL
    ) throws {
        guard let text = try? String(contentsOf: delegate, encoding: .utf8),
              let activeStart = text.range(of: "func applicationDidBecomeActive"),
              let activeEnd = text.range(
                  of: "func applicationShouldTerminate",
                  range: activeStart.upperBound..<text.endIndex
              ) else {
            throw ContractInputError(category: "missing-permission-presentation-refresh")
        }
        let activeMethod = text[activeStart.lowerBound..<activeEnd.lowerBound]
        guard activeMethod.contains("refreshPermissionPresentation()"),
              let refreshStart = text.range(of: "private func refreshPermissionPresentation"),
              let refreshEnd = text.range(
                  of: "private func waitForDestinationHandoff",
                  range: refreshStart.upperBound..<text.endIndex
              ) else {
            throw ContractInputError(category: "missing-permission-presentation-refresh")
        }
        let refreshMethod = text[refreshStart.lowerBound..<refreshEnd.lowerBound]
        guard refreshMethod.contains("refreshPermissionSurface()"),
              !refreshMethod.contains("requestMicrophonePermission()") else {
            throw ContractInputError(category: "missing-permission-presentation-refresh")
        }
        guard let onboardingText = try? String(contentsOf: onboarding, encoding: .utf8),
              onboardingText.contains("func refreshPermissions("),
              onboardingText.contains("microphoneState = microphone"),
              onboardingText.contains("accessibilityState = accessibility"),
              onboardingText.contains("render()") else {
            throw ContractInputError(category: "missing-onboarding-permission-refresh")
        }
    }

    private static func validateMicrophoneStartupGrantBoundary(delegate: URL) throws {
        guard let text = try? String(contentsOf: delegate, encoding: .utf8),
              !text.contains("microphoneStateBeforeRequest"),
              let performStart = text.range(of: "private func performStartDictation"),
              let performEnd = text.range(
                  of: "private func presentKeyboardStartupRecovery",
                  range: performStart.upperBound..<text.endIndex
              ) else {
            throw ContractInputError(category: "stale-microphone-grant-guard")
        }
        let performMethod = text[performStart.lowerBound..<performEnd.lowerBound]
        guard performMethod.contains("ensureMicrophonePermission()"),
              performMethod.contains("microphonePermissionState() == .granted") else {
            throw ContractInputError(category: "stale-microphone-grant-guard")
        }
        guard let ensureStart = text.range(of: "private func ensureMicrophonePermission"),
              let ensureEnd = text.range(
                  of: "private func openSystemSettings",
                  range: ensureStart.upperBound..<text.endIndex
              ) else {
            throw ContractInputError(category: "redundant-microphone-prompt")
        }
        let ensureMethod = text[ensureStart.lowerBound..<ensureEnd.lowerBound]
        guard ensureMethod.contains("case .unknown:"),
              ensureMethod.contains("requestMicrophonePermission()"),
              !ensureMethod.contains("Allow Microphone") else {
            throw ContractInputError(category: "redundant-microphone-prompt")
        }
    }

    private static func validateOigoEntitlementsBoundary(
        project: URL,
        entitlements: URL,
        installScript: URL
    ) throws {
        guard FileManager.default.fileExists(atPath: entitlements.path),
              FileManager.default.fileExists(atPath: installScript.path),
              let entitlementsText = try? String(contentsOf: entitlements, encoding: .utf8),
              entitlementsText.contains("com.apple.security.device.audio-input"),
              let projectText = try? String(contentsOf: project, encoding: .utf8),
              projectText.contains("CODE_SIGN_ENTITLEMENTS = Oigo/Oigo.entitlements"),
              let installScriptText = try? String(contentsOf: installScript, encoding: .utf8),
              installScriptText.contains("codesign --force --sign - --entitlements") else {
            throw ContractInputError(category: "missing-oigo-audio-input-entitlement")
        }
    }

    private static func validatePopoverPermissionRefreshBoundary(
        delegate: URL,
        statusSurface: URL
    ) throws {
        guard let delegateText = try? String(contentsOf: delegate, encoding: .utf8),
              delegateText.contains("onPopoverWillShow:"),
              delegateText.contains("refreshPermissionPresentation()"),
              let statusSurfaceText = try? String(contentsOf: statusSurface, encoding: .utf8),
              statusSurfaceText.contains("onPopoverWillShow"),
              statusSurfaceText.contains("onPopoverWillShow()") else {
            throw ContractInputError(category: "missing-popover-permission-refresh")
        }
    }

    private static func runCompiledContract(sources: [URL], fixture: Fixture) throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-native-ui-redesign.task05." + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let driver = root.appendingPathComponent("main.swift")
        let executable = root.appendingPathComponent("publication-contract")
        try contractDriver.write(to: driver, atomically: true, encoding: .utf8)
        let buildRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/arm64-apple-macosx/debug")
        let modules = buildRoot.appendingPathComponent("Modules").path
        let coreObjects = (try? FileManager.default.contentsOfDirectory(
            at: buildRoot.appendingPathComponent("OigoCore.build"),
            includingPropertiesForKeys: nil
        ))?.filter { $0.pathExtension == "o" }.map(\.path) ?? []
        try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["swiftc", "-I", modules] + sources.map(\.path)
                + [driver.path, "-o", executable.path] + coreObjects
        )
        let eventArgument = fixture.events.map {
            "\($0.generation),\($0.delayMilliseconds),\($0.storage)"
        }.joined(separator: ";")
        var expected: Data?
        for _ in 0..<(fixture.repeatCount ?? 1) {
            let output = try runProcess(
                executable: executable,
                arguments: [fixture.mode, String(fixture.surfaceCount), eventArgument]
            )
            if let expected, expected != output {
                throw ContractInputError(category: "flaky-main-actor-ordering")
            }
            expected = output
        }
        guard let expected, let text = String(data: expected, encoding: .utf8),
              text.contains("resources=0") else {
            throw ContractInputError(category: "retained-publication-resources")
        }
        return text
    }

    @discardableResult
    private static func runProcess(executable: URL, arguments: [String]) throws -> Data {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ContractInputError(category: "contract-process-launch")
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw ContractInputError(category: "compiled-contract-failed")
        }
        return output
    }

    private static let contractDriver = #"""
    import Foundation

    final class Weak<T: AnyObject> {
        weak var value: T?

        init(_ value: T) {
            self.value = value
        }
    }

    final class Surface {
        var generation: UInt64 = 0
    }

    func inputs(_ generation: UInt64, _ storage: OigoStoragePresentationStatus) -> OigoPresentationInputs {
        let locale = OigoLocaleIdentifier("en-US")!
        return OigoPresentationInputs(
            generation: generation,
            operationGate: .init(activeOperation: nil, busyReason: nil),
            coordinator: .init(state: .idle, generation: generation),
            storage: .init(status: storage),
            shortcut: .init(
                registration: .registered,
                isConfigured: true,
                shortcut: .default
            ),
            permissions: .init(microphone: .granted, accessibility: .granted),
            input: .init(selection: .systemDefault, channelIndex: 0),
            localeAssets: .init(localeIdentifier: locale, status: .ready, generation: generation),
            activeConfiguration: nil,
            nextConfiguration: .init(
                localeIdentifier: locale, input: .systemDefault, channelIndex: 0, appliesTo: .next
            ),
            terminal: nil,
            latestSession: nil,
            playback: .init(generation: generation, status: .idle),
            onboarding: .init(stage: .complete, status: .passed, failure: nil),
            shutdown: .init(status: .inactive, fencedOperationCount: 0)
        )
    }

    let mode = CommandLine.arguments[1]
    let count = Int(CommandLine.arguments[2])!
    let events = CommandLine.arguments[3].split(separator: ";").map { token -> (UInt64, UInt64, String) in
        let fields = token.split(separator: ",")
        return (UInt64(fields[0])!, UInt64(fields[1])!, String(fields[2]))
    }.sorted { $0.1 < $1.1 }
    var surfaces: [Surface]? = (0..<count).map { _ in Surface() }
    let weakSurfaces = surfaces!.map { Weak($0) }
    var fence = OigoPresentationGenerationFence()
    var elapsed: UInt64 = 0
    var accepted = 0
    for event in events {
        Thread.sleep(forTimeInterval: Double(event.1 - elapsed) / 1_000)
        elapsed = event.1
        if mode == "shutdown" { fence.shutdown() }
        let storage = OigoStoragePresentationStatus(rawValue: event.2)!
        let publication = OigoPresentationPublication(inputs: inputs(event.0, storage))
        if fence.publish(publication, to: { value in
            surfaces?.forEach { $0.generation = value.generation }
        }) {
            accepted += 1
        }
    }
    let newest = mode == "shutdown" ? 0 : events.map(\.0).max()!
    guard surfaces!.allSatisfy({ $0.generation == newest }) else { exit(2) }
    if mode == "shutdown" { fence.shutdown() }
    surfaces = nil
    guard weakSurfaces.allSatisfy({ $0.value == nil }) else { exit(3) }
    print("PUBLICATION mode=\(mode) generation=\(newest) accepted=\(accepted) surfaces=\(count) resources=0")
    """#
}
