import Darwin
import Foundation

final class PopoverStateMatrixScenario: NativeUIContractScenario {
    private struct Fixture: Decodable {
        let name: String
        let rows: [String]
        let expectedSections: [String]
        let popoverWidth: Int
        let healthyNoScroll: Bool
        let failures: Failures?
        let staleGeneration: UInt64?
        let currentGeneration: UInt64?
        let dirty: Bool?
        let intrinsicHeights: [Int]?
        let reportedSuccess: Bool?
        let processExitStatus: Int?
        let interruptions: Int?
        let commandDurationMilliseconds: Int?
    }

    private struct Failures: Decodable {
        let storage: Bool
        let microphone: Bool
        let shortcut: Bool
        let accessibility: Bool
    }

    override class var scenarioName: String { "popover-state-matrix" }

    override class func run(arguments: ContractArguments) throws {
        guard arguments.defaultsSuite == "com.oigo.qa.task12" else {
            throw ContractInputError(category: "invalid-defaults-suite")
        }
        let fixture = try loadFixture(arguments.fixtureRoot.appendingPathComponent("fixture.json"))
        try validate(fixture)
        if let duration = fixture.commandDurationMilliseconds {
            _ = try runProcess(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: [String(Double(duration) / 1_000)],
                timeout: 0.1
            )
        }
        let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        guard FileManager.default.fileExists(
            atPath: repository.appendingPathComponent(
                "Sources/Oigo/UI/Presentation/OigoPopoverPresentation.swift"
            ).path
        ) else {
            throw ContractInputError(category: "missing-popover-presentation")
        }
        let output = try runCompiledContract(repository: repository)
        print(output, terminator: "")
        guard output.contains("MATRIX rows=23 unique=23 sections=7 width=340 scroll=false"),
              output.contains("PRIORITY notice=storage-critical count=1 start=disabled"),
              output.contains("SHORTCUT start=enabled"),
              output.contains("ACCESSIBILITY posture=ready"),
              output.contains("PINNED microphone=pinned-input-unavailable"),
              output.contains("RECOVERY microphone=system-settings accessibility=system-settings"),
              output.contains("BUSY reason=busy-retry"),
              output.contains("SHUTDOWN reason=shutting-down"),
              !output.contains("verified-third-party") else {
            throw ContractInputError(category: "popover-matrix-mismatch")
        }
        print("PASS popover-state-matrix resources=0 reads=metadata-only")
    }

    private static let expectedRows = [
        "storage-checking", "storage-ready-idle", "storage-unavailable",
        "shortcut-inactive-conflict", "mic-permission-unavailable",
        "selected-input-unavailable", "language-assets-checking-installing",
        "language-assets-unavailable", "accessibility-unavailable", "preparing", "recording",
        "finalizing-cleaning-inserting", "paste-event-attempted", "paste-owned-field-verified",
        "copied-only", "cleanup-fallback", "insertion-failure", "retry-required",
        "cancelled-before-durable-raw", "cancelled-after-durable-raw", "interrupted",
        "busy-typed-reason", "shutting-down"
    ]

    private static let expectedSections = [
        "header", "primary-action", "shortcut", "mode", "microphone", "latest-dictation", "footer"
    ]

    private static func loadFixture(_ url: URL) throws -> Fixture {
        guard let data = try? Data(contentsOf: url) else {
            throw ContractInputError(category: "missing-fixture")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ContractInputError(category: "malformed-state-combination")
        }
        guard !containsPrivateContent(object) else {
            throw ContractInputError(category: "forbidden-user-content")
        }
        do {
            return try JSONDecoder().decode(Fixture.self, from: data)
        } catch {
            throw ContractInputError(category: "malformed-state-combination")
        }
    }

    private static func validate(_ fixture: Fixture) throws {
        if let stale = fixture.staleGeneration, let current = fixture.currentGeneration,
           stale >= current {
            throw ContractInputError(category: "stale-generation")
        }
        if fixture.dirty == true {
            throw ContractInputError(category: "dirty-worktree")
        }
        if let heights = fixture.intrinsicHeights, Set(heights).count != 1 {
            throw ContractInputError(category: "flaky-intrinsic-sizing")
        }
        if fixture.reportedSuccess == true, fixture.processExitStatus != 0 {
            print("PASS decoy-only")
            throw ContractInputError(category: "misleading-success-output")
        }
        if let interruptions = fixture.interruptions, interruptions > 1 {
            throw ContractInputError(category: "repeated-interruption")
        }
        guard Set(fixture.rows).count == fixture.rows.count,
              fixture.rows == expectedRows else {
            throw ContractInputError(category: "unmapped-state")
        }
        guard fixture.expectedSections == expectedSections,
              fixture.popoverWidth == 340,
              fixture.healthyNoScroll else {
            throw ContractInputError(category: "missing-popover-section")
        }
        if let failures = fixture.failures {
            guard failures.storage, failures.microphone, failures.shortcut,
                  failures.accessibility else {
                throw ContractInputError(category: "malformed-state-combination")
            }
        }
    }

    private static func runCompiledContract(repository: URL) throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-native-ui-redesign.task12." + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let presentation = repository.appendingPathComponent("Sources/Oigo/UI/Presentation")
        let core = repository.appendingPathComponent("Sources/OigoCore")
        let driver = root.appendingPathComponent("main.swift")
        let executable = root.appendingPathComponent("popover-state-matrix-contract")
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
            arguments: ["swiftc", "-I", root.path, "-L", root.path,
                        "-Xlinker", "-rpath", "-Xlinker", root.path,
                        presentation.appendingPathComponent("OigoPresentationInputs.swift").path,
                        presentation.appendingPathComponent("OigoPresentationState.swift").path,
                        presentation.appendingPathComponent("OigoPresentationAttributes.swift").path,
                        presentation.appendingPathComponent("OigoPresentationProjection.swift").path,
                        presentation.appendingPathComponent("OigoPopoverPresentation.swift").path,
                        driver.path, "-lOigoCore", "-o", executable.path]
        )
        let data = try runProcess(executable: executable, arguments: [])
        guard let output = String(data: data, encoding: .utf8) else {
            throw ContractInputError(category: "unexpected-contract-output")
        }
        return output
    }

    @discardableResult
    private static func runProcess(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval = 30
    ) throws -> Data {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let finished = DispatchSemaphore(value: 0)
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            throw ContractInputError(category: "contract-process-launch")
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            throw ContractInputError(category: "contract-process-timeout")
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        _ = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw ContractInputError(category: "compiled-contract-failed")
        }
        return output
    }

    private static func containsPrivateContent(_ object: Any) -> Bool {
        if let dictionary = object as? [String: Any] {
            let forbidden = Set([
                "audio", "clipboard", "dictionaryEntries", "focusedText", "pasteboard",
                "sessionBody", "transcript", "userPath"
            ])
            return !forbidden.isDisjoint(with: dictionary.keys)
                || dictionary.values.contains(where: containsPrivateContent)
        }
        if let array = object as? [Any] {
            return array.contains(where: containsPrivateContent)
        }
        return false
    }

    private static let contractDriver = #"""
    import Foundation

    let locale = OigoLocaleIdentifier("en-US")!
    func inputs(_ fixtureRow: OigoPresentationStateRow) -> OigoPresentationInputs {
        var selectedInput: OigoInputSelectionPresentationStatus = .systemDefault
        var shortcut: OigoShortcutRegistrationPresentationStatus = .registered
        var permissions = OigoPermissionsPresentationInput(microphone: .granted, accessibility: .granted)
        var storage = OigoStoragePresentationInput(status: .ready)
        var assets = OigoLocaleAssetPresentationStatus.ready
        var coordinator = OigoCoordinatorPresentationState.idle
        var terminal: OigoTerminalPresentationInput?
        var latestHasTranscript = true
        var onboarding = OigoOnboardingPresentationInput(stage: .ready, status: .passed, failure: nil)
        var busyReason: OigoOperationBusyPresentationReason?
        var shutdown = OigoShutdownPresentationStatus.inactive

        switch fixtureRow {
        case .storageChecking: storage = .init(status: .degraded)
        case .storageUnavailable: storage = .init(status: .unavailable)
        case .shortcutInactiveConflict: shortcut = .conflict
        case .microphonePermissionUnavailable: permissions = .init(microphone: .denied, accessibility: .granted)
        case .selectedInputUnavailable: selectedInput = .pinnedUnavailable
        case .languageAssetsCheckingInstalling: assets = .checking
        case .languageAssetsUnavailable: assets = .unavailable
        case .accessibilityUnavailable: permissions = .init(microphone: .granted, accessibility: .denied)
        case .preparing: coordinator = .preparing
        case .recording: coordinator = .recording
        case .finalizingCleaningInserting: coordinator = .finalizing
        case .pasteEventAttempted:
            coordinator = .complete
            terminal = .init(generation: 42, outcome: .pasteAttempted, failure: nil)
        case .pasteOwnedFieldVerified:
            coordinator = .complete
            terminal = .init(generation: 42, outcome: .pasted, failure: nil)
            onboarding = .init(stage: .test, status: .passed, failure: nil)
        case .copiedOnly:
            coordinator = .complete
            terminal = .init(generation: 42, outcome: .copied, failure: nil)
        case .cleanupFallback:
            coordinator = .complete
            terminal = .init(generation: 42, outcome: .cleanupFallback, failure: nil)
        case .insertionFailure:
            coordinator = .complete
            terminal = .init(generation: 42, outcome: .insertionFailed, failure: .insertion)
        case .retryRequired:
            coordinator = .complete
            terminal = .init(generation: 42, outcome: .retryRequired, failure: .transcription)
        case .cancelledBeforeDurableRaw:
            coordinator = .cancelled
            terminal = .init(generation: 42, outcome: .cancelled, failure: nil)
            latestHasTranscript = false
        case .cancelledAfterDurableRaw:
            coordinator = .cancelled
            terminal = .init(generation: 42, outcome: .cancelled, failure: nil)
        case .interrupted:
            coordinator = .interrupted
            terminal = .init(generation: 42, outcome: .interrupted, failure: nil)
        case .busyTypedReason: busyReason = .occupied(.retry)
        case .shuttingDown: shutdown = .requested
        case .storageReadyIdle: break
        }
        return OigoPresentationInputs(
            generation: 42,
            operationGate: .init(activeOperation: nil, busyReason: busyReason),
            coordinator: .init(state: coordinator, generation: 42),
            storage: storage,
            shortcut: .init(registration: shortcut, isConfigured: true),
            permissions: permissions,
            input: .init(selection: selectedInput, channelIndex: 0),
            localeAssets: .init(localeIdentifier: locale, status: assets, generation: 42),
            activeConfiguration: nil,
            nextConfiguration: .init(
                localeIdentifier: locale, input: selectedInput, channelIndex: 0, appliesTo: .next
            ),
            terminal: terminal,
            latestSession: .init(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
                state: .complete,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                hasAudio: true,
                hasTranscript: latestHasTranscript,
                failure: nil,
                durationSeconds: 18,
                source: .clean
            ),
            playback: .init(generation: 42, status: .idle),
            onboarding: onboarding,
            shutdown: .init(status: shutdown, fencedOperationCount: 0),
            presentationDate: Date(timeIntervalSince1970: 1_700_000_120)
        )
    }

    let rows = OigoPresentationStateRow.allCases
    let models = rows.map { row -> OigoPopoverPresentation in
        let value = inputs(row)
        return OigoPopoverPresentation.project(state: OigoPresentationState.project(value), inputs: value)
    }
    guard rows.count == 23,
          Set(rows.map(\.rawValue)).count == 23,
          models.map(\.row) == rows,
          models.allSatisfy({ $0.width == 340 && !$0.allowsScrolling }),
          models.first(where: { $0.row == .storageReadyIdle })?.sections.map(\.rawValue)
            == ["header", "primary-action", "shortcut", "mode", "microphone", "latest-dictation", "footer"] else {
        exit(1)
    }
    let priority = OigoPopoverPresentation.project(
        state: OigoPresentationState.project(inputs(.storageUnavailable)),
        inputs: inputs(.storageUnavailable)
    )
    print("MATRIX rows=\(rows.count) unique=\(Set(models.map(\.row)).count) sections=7 width=340 scroll=false")
    let priorityStartEnabled = priority.primaryAction.action == .startDictation
        && priority.primaryAction.isEnabled
    print("PRIORITY notice=\(priority.notice?.category ?? "none") count=\(priority.notice == nil ? 0 : 1) start=\(priorityStartEnabled ? "enabled" : "disabled")")
    func model(_ row: OigoPresentationStateRow) -> OigoPopoverPresentation {
        let value = inputs(row)
        return OigoPopoverPresentation.project(state: OigoPresentationState.project(value), inputs: value)
    }
    print("SHORTCUT start=\(model(.shortcutInactiveConflict).primaryAction.isEnabled ? "enabled" : "disabled")")
    print("ACCESSIBILITY posture=\(model(.accessibilityUnavailable).copyOnly.rawValue)")
    print("PINNED microphone=\(model(.selectedInputUnavailable).microphone.category)")
    guard case .openSystemSettings(let microphoneSettings)?
            = model(.microphonePermissionUnavailable).notice?.action.action,
          case .openSystemSettings(let accessibilitySettings)?
            = model(.accessibilityUnavailable).notice?.action.action,
          microphoneSettings.absoluteString.contains("Privacy_Microphone"),
          accessibilitySettings.absoluteString.contains("Privacy_Accessibility") else {
        exit(1)
    }
    print("RECOVERY microphone=system-settings accessibility=system-settings")
    print("BUSY reason=\(model(.busyTypedReason).primaryAction.disabledReason ?? "none")")
    print("SHUTDOWN reason=\(model(.shuttingDown).primaryAction.disabledReason ?? "none")")
    """#
}
