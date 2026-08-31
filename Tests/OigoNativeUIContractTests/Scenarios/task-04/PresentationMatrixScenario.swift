import Foundation

final class PresentationMatrixScenario: NativeUIContractScenario {
    private struct Fixture: Decodable {
        let mode: String
        let rows: [String]
        let generations: Generations?
        let dirty: Bool?
        let enumeration: [String]?
        let result: Result?
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
        "presentation-matrix"
    }

    override class func run(arguments: ContractArguments) throws {
        guard arguments.defaultsSuite == "com.oigo.qa.task04" else {
            throw ContractInputError(category: "invalid-defaults-suite")
        }
        let fixture = try loadFixture(from: arguments.fixtureRoot)
        try validate(fixture)

        let sourceRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/Oigo/UI/Presentation", isDirectory: true)
        let stateSource = sourceRoot.appendingPathComponent("OigoPresentationState.swift")
        let projectionSource = sourceRoot.appendingPathComponent("OigoPresentationProjection.swift")
        let attributesSource = sourceRoot.appendingPathComponent("OigoPresentationAttributes.swift")
        guard FileManager.default.fileExists(atPath: stateSource.path),
              FileManager.default.fileExists(atPath: projectionSource.path),
              FileManager.default.fileExists(atPath: attributesSource.path) else {
            throw ContractInputError(category: "missing-presentation-output")
        }
        try validateSourceBoundary([stateSource, projectionSource, attributesSource])
        let output = try runCompiledContract(
            sources: [
                sourceRoot.appendingPathComponent("OigoPresentationInputs.swift"),
                stateSource,
                projectionSource,
                attributesSource
            ],
            mode: fixture.mode
        )
        print(output, terminator: "")
        print("PASS presentation-matrix resources=0")
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

    private static func loadFixture(from root: URL) throws -> Fixture {
        let fixtureURL = root.appendingPathComponent("fixture.json", isDirectory: false)
        guard let data = try? Data(contentsOf: fixtureURL) else {
            throw ContractInputError(category: "missing-fixture")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ContractInputError(category: "malformed-state-combination")
        }
        if containsForbiddenField(in: object) {
            throw ContractInputError(category: "forbidden-field")
        }
        do {
            return try JSONDecoder().decode(Fixture.self, from: data)
        } catch {
            throw ContractInputError(category: "malformed-state-combination")
        }
    }

    private static func validate(_ fixture: Fixture) throws {
        guard ["exhaustive", "conflict"].contains(fixture.mode) else {
            throw ContractInputError(category: "malformed-state-combination")
        }
        let uniqueRows = Set(fixture.rows)
        guard uniqueRows.count == fixture.rows.count else {
            throw ContractInputError(category: "malformed-state-combination")
        }
        guard uniqueRows == Set(expectedRows), fixture.rows.count == expectedRows.count else {
            throw ContractInputError(category: "unmapped-state")
        }
        if let generations = fixture.generations,
           generations.candidate < generations.current {
            throw ContractInputError(category: "stale-generation")
        }
        if fixture.dirty == true {
            throw ContractInputError(category: "dirty-worktree")
        }
        if let enumeration = fixture.enumeration,
           Set(enumeration).count != 1 {
            throw ContractInputError(category: "flaky-enumeration")
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
                "userPath", "transcript", "audio", "clipboard", "focusedText", "dictionaryEntries",
                "userContent"
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

    private static func validateSourceBoundary(_ sources: [URL]) throws {
        let text = try sources.map { source -> String in
            guard let value = try? String(contentsOf: source, encoding: .utf8) else {
                throw ContractInputError(category: "unreadable-presentation-output")
            }
            return value
        }.joined(separator: "\n")
        let forbiddenTokens = [
            "import AppKit", "import AVFAudio", "import ApplicationServices", "Task<", "Timer",
            "NotificationCenter", "NSView", "NSWindow", "AXUIElement", "NSPasteboard",
            "AVAudio", "transcriptBody", "clipboardValue", "userPath", "DictionaryEntry", "Codable"
        ]
        guard !forbiddenTokens.contains(where: text.contains) else {
            throw ContractInputError(category: "forbidden-output-dependency")
        }
    }

    private static func runCompiledContract(sources: [URL], mode: String) throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-native-ui-redesign.task04." + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let driver = root.appendingPathComponent("main.swift")
        let executable = root.appendingPathComponent("presentation-matrix-contract")
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
        let data = try runProcess(executable: executable, arguments: [mode])
        guard let output = String(data: data, encoding: .utf8),
              output.contains("MATRIX rows=23 unique=23"),
              !output.contains("verified-third-party"),
              !output.contains("en-US"),
              !output.contains("00000000") else {
            throw ContractInputError(category: "unexpected-contract-output")
        }
        if mode == "conflict" {
            guard output.contains("CONFLICT notice=storage-critical count=1"),
                  output.contains("start=disabled") else {
                throw ContractInputError(category: "notice-priority-failed")
            }
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
    requireSendable(OigoPresentationState.self)
    requireSendable(OigoPresentationStateRow.self)

    let locale = OigoLocaleIdentifier("en-US")!
    let activeConfiguration = OigoDictationConfigurationPresentationInput(
        localeIdentifier: locale,
        input: .pinnedAvailable,
        channelIndex: 0,
        appliesTo: .active
    )

    func makeInputs(
        _ row: OigoPresentationStateRow,
        ownedField: Bool = true
    ) -> OigoPresentationInputs {
        let storage: OigoStoragePresentationStatus
        let shortcut: OigoShortcutRegistrationPresentationStatus
        let microphone: OigoPermissionPresentationStatus
        let accessibility: OigoPermissionPresentationStatus
        let input: OigoInputSelectionPresentationStatus
        let assets: OigoLocaleAssetPresentationStatus
        let coordinator: OigoCoordinatorPresentationState
        let busy: OigoOperationBusyPresentationReason?
        let shutdown: OigoShutdownPresentationStatus
        let terminal: OigoTerminalPresentationOutcome?
        let hasDurableRaw: Bool

        switch row {
        case .storageChecking:
            (storage, shortcut, microphone, accessibility, input, assets, coordinator, busy, shutdown,
             terminal, hasDurableRaw) =
                (.degraded, .registered, .granted, .granted, .pinnedAvailable, .ready, .idle, nil,
                 .inactive, nil, false)
        case .storageUnavailable:
            (storage, shortcut, microphone, accessibility, input, assets, coordinator, busy, shutdown,
             terminal, hasDurableRaw) =
                (.unavailable, .registered, .granted, .granted, .pinnedAvailable, .ready, .idle, nil,
                 .inactive, nil, false)
        case .shortcutInactiveConflict:
            (storage, shortcut, microphone, accessibility, input, assets, coordinator, busy, shutdown,
             terminal, hasDurableRaw) =
                (.ready, .conflict, .granted, .granted, .pinnedAvailable, .ready, .idle, nil,
                 .inactive, nil, false)
        case .microphonePermissionUnavailable:
            (storage, shortcut, microphone, accessibility, input, assets, coordinator, busy, shutdown,
             terminal, hasDurableRaw) =
                (.ready, .registered, .denied, .granted, .pinnedAvailable, .ready, .idle, nil,
                 .inactive, nil, false)
        case .selectedInputUnavailable:
            (storage, shortcut, microphone, accessibility, input, assets, coordinator, busy, shutdown,
             terminal, hasDurableRaw) =
                (.ready, .registered, .granted, .granted, .pinnedUnavailable, .ready, .idle, nil,
                 .inactive, nil, false)
        case .languageAssetsCheckingInstalling:
            (storage, shortcut, microphone, accessibility, input, assets, coordinator, busy, shutdown,
             terminal, hasDurableRaw) =
                (.ready, .registered, .granted, .granted, .pinnedAvailable, .installing, .idle, nil,
                 .inactive, nil, false)
        case .languageAssetsUnavailable:
            (storage, shortcut, microphone, accessibility, input, assets, coordinator, busy, shutdown,
             terminal, hasDurableRaw) =
                (.ready, .registered, .granted, .granted, .pinnedAvailable, .unavailable, .idle, nil,
                 .inactive, nil, false)
        case .accessibilityUnavailable:
            (storage, shortcut, microphone, accessibility, input, assets, coordinator, busy, shutdown,
             terminal, hasDurableRaw) =
                (.ready, .registered, .granted, .denied, .pinnedAvailable, .ready, .idle, nil,
                 .inactive, nil, false)
        case .preparing:
            (storage, shortcut, microphone, accessibility, input, assets, coordinator, busy, shutdown,
             terminal, hasDurableRaw) =
                (.ready, .registered, .granted, .granted, .pinnedAvailable, .ready, .preparing, nil,
                 .inactive, nil, false)
        case .recording:
            (storage, shortcut, microphone, accessibility, input, assets, coordinator, busy, shutdown,
             terminal, hasDurableRaw) =
                (.ready, .registered, .granted, .granted, .pinnedAvailable, .ready, .recording, nil,
                 .inactive, nil, false)
        case .finalizingCleaningInserting:
            (storage, shortcut, microphone, accessibility, input, assets, coordinator, busy, shutdown,
             terminal, hasDurableRaw) =
                (.ready, .registered, .granted, .granted, .pinnedAvailable, .ready, .cleaning, nil,
                 .inactive, nil, false)
        case .pasteEventAttempted:
            (storage, shortcut, microphone, accessibility, input, assets, coordinator, busy, shutdown,
             terminal, hasDurableRaw) =
                (.ready, .registered, .granted, .granted, .pinnedAvailable, .ready, .complete, nil,
                 .inactive, .pasteAttempted, true)
        case .pasteOwnedFieldVerified:
            (storage, shortcut, microphone, accessibility, input, assets, coordinator, busy, shutdown,
             terminal, hasDurableRaw) =
                (.ready, .registered, .granted, .granted, .pinnedAvailable, .ready, .complete, nil,
                 .inactive, .pasted, true)
        case .copiedOnly:
            (storage, shortcut, microphone, accessibility, input, assets, coordinator, busy, shutdown,
             terminal, hasDurableRaw) =
                (.ready, .registered, .granted, .granted, .pinnedAvailable, .ready, .complete, nil,
                 .inactive, .copied, true)
        case .cleanupFallback:
            (storage, shortcut, microphone, accessibility, input, assets, coordinator, busy, shutdown,
             terminal, hasDurableRaw) =
                (.ready, .registered, .granted, .granted, .pinnedAvailable, .ready, .complete, nil,
                 .inactive, .cleanupFallback, true)
        case .insertionFailure:
            (storage, shortcut, microphone, accessibility, input, assets, coordinator, busy, shutdown,
             terminal, hasDurableRaw) =
                (.ready, .registered, .granted, .granted, .pinnedAvailable, .ready, .failed, nil,
                 .inactive, .insertionFailed, true)
        case .retryRequired:
            (storage, shortcut, microphone, accessibility, input, assets, coordinator, busy, shutdown,
             terminal, hasDurableRaw) =
                (.ready, .registered, .granted, .granted, .pinnedAvailable, .ready, .failed, nil,
                 .inactive, .retryRequired, true)
        case .cancelledBeforeDurableRaw:
            (storage, shortcut, microphone, accessibility, input, assets, coordinator, busy, shutdown,
             terminal, hasDurableRaw) =
                (.ready, .registered, .granted, .granted, .pinnedAvailable, .ready, .cancelled, nil,
                 .inactive, .cancelled, false)
        case .cancelledAfterDurableRaw:
            (storage, shortcut, microphone, accessibility, input, assets, coordinator, busy, shutdown,
             terminal, hasDurableRaw) =
                (.ready, .registered, .granted, .granted, .pinnedAvailable, .ready, .cancelled, nil,
                 .inactive, .cancelled, true)
        case .interrupted:
            (storage, shortcut, microphone, accessibility, input, assets, coordinator, busy, shutdown,
             terminal, hasDurableRaw) =
                (.ready, .registered, .granted, .granted, .pinnedAvailable, .ready, .interrupted, nil,
                 .inactive, .interrupted, true)
        case .busyTypedReason:
            (storage, shortcut, microphone, accessibility, input, assets, coordinator, busy, shutdown,
             terminal, hasDurableRaw) =
                (.ready, .registered, .granted, .granted, .pinnedAvailable, .ready, .idle,
                 .occupied(.retry), .inactive, nil, false)
        case .shuttingDown:
            (storage, shortcut, microphone, accessibility, input, assets, coordinator, busy, shutdown,
             terminal, hasDurableRaw) =
                (.ready, .registered, .granted, .granted, .pinnedAvailable, .ready, .idle, nil,
                 .requested, nil, false)
        case .storageReadyIdle:
            (storage, shortcut, microphone, accessibility, input, assets, coordinator, busy, shutdown,
             terminal, hasDurableRaw) =
                (.ready, .registered, .granted, .granted, .pinnedAvailable, .ready, .idle, nil,
                 .inactive, nil, false)
        }

        let nextInput: OigoInputSelectionPresentationStatus =
            row == .selectedInputUnavailable ? .pinnedUnavailable : .pinnedAvailable
        return OigoPresentationInputs(
            generation: 42,
            operationGate: .init(activeOperation: nil, busyReason: busy),
            coordinator: .init(state: coordinator, generation: 42),
            storage: .init(status: storage),
            shortcut: .init(
                registration: shortcut,
                isConfigured: shortcut == .registered,
                shortcut: .default
            ),
            permissions: .init(microphone: microphone, accessibility: accessibility),
            input: .init(selection: input, channelIndex: 0),
            localeAssets: .init(localeIdentifier: locale, status: assets, generation: 42),
            activeConfiguration: activeConfiguration,
            nextConfiguration: .init(
                localeIdentifier: locale,
                input: nextInput,
                channelIndex: 0,
                appliesTo: .next
            ),
            terminal: terminal.map { .init(generation: 42, outcome: $0, failure: nil) },
            latestSession: .init(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
                state: coordinator == .interrupted ? .interrupted : .complete,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                hasAudio: true,
                hasTranscript: hasDurableRaw,
                failure: nil
            ),
            playback: .init(generation: 1, status: .idle),
            onboarding: .init(
                stage: row == .pasteOwnedFieldVerified && ownedField ? .test : .ready,
                status: .passed,
                failure: nil
            ),
            shutdown: .init(status: shutdown, fencedOperationCount: 0)
        )
    }

    let rows = OigoPresentationStateRow.allCases
    let states = rows.map { OigoPresentationState.project(makeInputs($0)) }
    guard rows.count == 23,
          Set(rows.map(\.rawValue)).count == 23,
          states.map(\.row) == rows,
          states.first(where: { $0.row == .shortcutInactiveConflict })?.primaryAction
            == .enabled(.startDictation),
          states.first(where: { $0.row == .accessibilityUnavailable })?.copyOnly == .ready,
          states.first(where: { $0.row == .selectedInputUnavailable })?.nextDictation
            == .pinnedInputUnavailable,
          states.first(where: { $0.row == .busyTypedReason })?.availability.initiatorsEnabled == false,
          states.first(where: { $0.row == .shuttingDown })?.availability.commandsEnabled == false,
          states.first(where: { $0.row == .pasteEventAttempted })?.terminal
            == .pasteAttempted,
          states.first(where: { $0.row == .pasteOwnedFieldVerified })?.terminal
            == .ownedFieldVerified,
          OigoPresentationState.project(
            makeInputs(.pasteOwnedFieldVerified, ownedField: false)
          ).row == .pasteEventAttempted else {
        exit(1)
    }

    let terminalRows = states.compactMap(\.terminal)
    guard Set(terminalRows.map(\.category)).count == terminalRows.count else { exit(1) }
    for state in states {
        print(state.sanitizedDescription)
    }
    print("MATRIX rows=\(rows.count) unique=\(Set(states.map(\.row)).count)")

    if CommandLine.arguments.dropFirst().first == "conflict" {
        var conflict = makeInputs(.storageUnavailable)
        conflict = OigoPresentationInputs(
            generation: conflict.generation,
            operationGate: conflict.operationGate,
            coordinator: conflict.coordinator,
            storage: conflict.storage,
            shortcut: .init(
                registration: .conflict,
                isConfigured: true,
                shortcut: .default
            ),
            permissions: .init(microphone: .denied, accessibility: .denied),
            input: .init(selection: .pinnedUnavailable, channelIndex: 0),
            localeAssets: .init(localeIdentifier: locale, status: .unavailable, generation: 42),
            activeConfiguration: conflict.activeConfiguration,
            nextConfiguration: conflict.nextConfiguration,
            terminal: conflict.terminal,
            latestSession: conflict.latestSession,
            playback: conflict.playback,
            onboarding: conflict.onboarding,
            shutdown: conflict.shutdown
        )
        let conflictState = OigoPresentationState.project(conflict)
        let count = conflictState.notice == nil ? 0 : 1
        let start = conflictState.primaryAction == .enabled(.startDictation) ? "enabled" : "disabled"
        print("CONFLICT notice=\(conflictState.notice?.category ?? "none") count=\(count) start=\(start)")
    }
    """#
}
