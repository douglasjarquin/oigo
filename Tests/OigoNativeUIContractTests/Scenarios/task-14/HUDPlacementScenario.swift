import Foundation

final class HUDPlacementScenario: NativeUIContractScenario {
    private enum FixtureNumber: Codable {
        case finite(Double)
        case nan
        case positiveInfinity
        case negativeInfinity

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Double.self) {
                guard value.isFinite else {
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "non-finite numbers must use an explicit sentinel"
                    )
                }
                self = .finite(value)
                return
            }

            guard let token = try? container.decode(String.self) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "geometry must be a number or supported sentinel"
                )
            }
            if let value = Double(token), value.isFinite {
                self = .finite(value)
                return
            }
            switch token.lowercased() {
            case "nan":
                self = .nan
            case "infinity":
                self = .positiveInfinity
            case "-infinity":
                self = .negativeInfinity
            default:
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "unsupported geometry token"
                )
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case let .finite(value):
                try container.encode(value)
            case .nan:
                try container.encode("nan")
            case .positiveInfinity:
                try container.encode("infinity")
            case .negativeInfinity:
                try container.encode("-infinity")
            }
        }

        var value: Double {
            switch self {
            case let .finite(value): value
            case .nan: .nan
            case .positiveInfinity: .infinity
            case .negativeInfinity: -.infinity
            }
        }
    }

    private enum ExpectedStrategy: String, Codable {
        case belowField = "below-field"
        case aboveField = "above-field"
        case windowEdge = "window-edge"
        case screenBottom = "screen-bottom"
        case mainScreen = "main-screen"
    }

    private struct Fixture: Codable {
        let name: String
        let currentGeneration: UInt64
        let panelSize: [FixtureNumber]
        let gap: FixtureNumber
        let screenInset: FixtureNumber
        let displays: [Display]
        let mainDisplayID: UInt32?
        let frontmostDisplayID: UInt32?
        let cases: [Case]
        let repeatCount: Int
        let interruptionCount: Int
        let displaySequenceHashes: [String]?
        let dirty: Bool?
        let reportedSuccess: Bool?
        let processExitStatus: Int?
    }

    private struct Display: Codable {
        let id: UInt32
        let visibleFrame: [FixtureNumber]
    }

    private struct Case: Codable {
        let name: String
        let snapshotGeneration: UInt64
        let targetDisplayID: UInt32?
        let fieldFrame: [FixtureNumber]?
        let windowFrame: [FixtureNumber]?
        let expectedStrategy: ExpectedStrategy
        let expectedFrame: [FixtureNumber]
    }

    private struct ResourceReceipt {
        let captureCalls: Int
        let syntheticAXWrappersCreated: Int
        let syntheticAXWrappersReleased: Int
        let retainedAXObjects: Int
        let pollingTimers: Int
        let coordinateLogs: Int
        let sessionReleased: Bool
    }

    private struct CompiledContractOutput {
        let text: String
        let resources: ResourceReceipt
    }

    override class var scenarioName: String {
        "hud-placement"
    }

    override class func run(arguments: ContractArguments) throws {
        guard arguments.defaultsSuite == "com.oigo.qa.task14" else {
            throw ContractInputError(category: "invalid-defaults-suite")
        }
        let fixture = try loadFixture(root: arguments.fixtureRoot)
        guard fixture.name == "multi-display-negative-origin",
              (1...20).contains(fixture.repeatCount),
              (0...20).contains(fixture.interruptionCount),
              !fixture.cases.isEmpty,
              fixture.panelSize.count == 2,
              fixture.displays.allSatisfy({ $0.visibleFrame.count == 4 }),
              fixture.cases.allSatisfy({ item in
                  item.name.range(
                      of: #"^[a-z][a-z0-9-]{0,63}$"#,
                      options: .regularExpression
                  ) != nil
                      && item.expectedFrame.count == 4
                      && (item.fieldFrame == nil || item.fieldFrame?.count == 4)
                      && (item.windowFrame == nil || item.windowFrame?.count == 4)
              }) else {
            throw ContractInputError(category: "malformed-geometry")
        }
        if fixture.dirty == true {
            throw ContractInputError(category: "dirty-worktree")
        }
        if let hashes = fixture.displaySequenceHashes, Set(hashes).count > 1 {
            throw ContractInputError(category: "flaky-display-fixture")
        }
        if fixture.reportedSuccess == true, fixture.processExitStatus != 0 {
            throw ContractInputError(category: "misleading-success-output")
        }

        let repositoryRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let geometrySource = repositoryRoot
            .appendingPathComponent("Sources/Oigo/UI/HUD/HUDTargetGeometry.swift")
        let captureSource = repositoryRoot
            .appendingPathComponent("Sources/Oigo/UI/HUD/AccessibilityHUDGeometryCapture.swift")
        let sessionSource = repositoryRoot
            .appendingPathComponent("Sources/Oigo/UI/HUD/HUDTargetGeometrySession.swift")
        guard FileManager.default.fileExists(atPath: geometrySource.path) else {
            throw ContractInputError(category: "missing-hud-geometry")
        }
        guard FileManager.default.fileExists(atPath: captureSource.path) else {
            throw ContractInputError(category: "missing-hud-capture")
        }
        guard FileManager.default.fileExists(atPath: sessionSource.path) else {
            throw ContractInputError(category: "missing-hud-session")
        }
        try validatePrivacyBoundary(captureSource)
        let output = try runCompiledContract(
            sources: [geometrySource, captureSource, sessionSource],
            fixture: fixture
        )
        try writeGalleryReceipt(output: output, fixture: fixture, root: arguments.fixtureRoot)
        print(output.text, terminator: "")
        let resources = output.resources
        print(
            "PASS hud-placement fixture=" + fixture.name
                + " capture-calls=\(resources.captureCalls)"
                + " wrappers-created=\(resources.syntheticAXWrappersCreated)"
                + " wrappers-released=\(resources.syntheticAXWrappersReleased)"
                + " retained-ax=\(resources.retainedAXObjects)"
                + " polling-timers=\(resources.pollingTimers)"
                + " coordinate-logs=\(resources.coordinateLogs)"
                + " session-released=\(resources.sessionReleased)"
        )
    }

    private static func loadFixture(root: URL) throws -> Fixture {
        let provided = root.appendingPathComponent("fixture.json")
        let bundled = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(
                "Fixtures/native-ui/task-14/multi-display-negative-origin.json"
            )
        let fixtureURL = FileManager.default.fileExists(atPath: provided.path) ? provided : bundled
        guard let data = try? Data(contentsOf: fixtureURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              !containsForbiddenContent(object),
              let fixture = try? JSONDecoder().decode(Fixture.self, from: data) else {
            throw ContractInputError(category: "malformed-geometry")
        }
        return fixture
    }

    private static func containsForbiddenContent(_ object: Any) -> Bool {
        if let dictionary = object as? [String: Any] {
            let forbidden = Set([
                "coordinates", "focusedText", "transcript", "clipboard", "userPath",
                "elementValue", "elementTitle", "label"
            ])
            return !forbidden.isDisjoint(with: dictionary.keys)
                || dictionary.values.contains(where: containsForbiddenContent)
        }
        if let array = object as? [Any] {
            return array.contains(where: containsForbiddenContent)
        }
        return false
    }

    private static func validatePrivacyBoundary(_ source: URL) throws {
        guard let text = try? String(contentsOf: source, encoding: .utf8) else {
            throw ContractInputError(category: "unreadable-hud-capture")
        }
        let required = [
            "AXUIElementCreateApplication", "kAXFocusedUIElementAttribute",
            "kAXPositionAttribute", "kAXSizeAttribute", "kAXWindowAttribute"
        ]
        let forbidden = [
            "Timer", "scheduledTimer", "Codable", "UserDefaults", "FileManager",
            "OSLog", "Logger", "print(", "kAXValueAttribute", "kAXTitleAttribute",
            "kAXDescriptionAttribute", "kAXSelectedTextAttribute"
        ]
        guard required.allSatisfy(text.contains), !forbidden.contains(where: text.contains) else {
            throw ContractInputError(category: "unsafe-hud-capture-boundary")
        }
    }

    private static func writeGalleryReceipt(
        output: CompiledContractOutput,
        fixture: Fixture,
        root: URL
    ) throws {
        let cases = output.text.split(separator: "\n").compactMap { line -> (Int, String)? in
            let parts = line.split(separator: " ").map(String.init)
            guard parts.count == 4,
                  parts[0] == "RECT",
                  let index = Int(parts[1]),
                  parts[2] == "PASS",
                  parts[3].hasPrefix("strategy=") else {
                return nil
            }
            return (index, String(parts[3].dropFirst("strategy=".count)))
        }
        guard cases.count == fixture.cases.count,
              Set(cases.map(\.0)) == Set(fixture.cases.indices),
              cases.allSatisfy({ index, strategy in
                  fixture.cases[index].expectedStrategy.rawValue == strategy
              }) else {
            throw ContractInputError(category: "unexpected-placement")
        }
        let orderedCases = cases.sorted { $0.0 < $1.0 }.map { index, strategy in
            [
                "name": fixture.cases[index].name,
                "strategy": strategy
            ]
        }
        let resources = output.resources
        let receipt: [String: Any] = [
            "scenario": "hud-placement",
            "fixture": fixture.name,
            "cases": orderedCases,
            "captureCalls": resources.captureCalls,
            "syntheticAXWrappersCreated": resources.syntheticAXWrappersCreated,
            "syntheticAXWrappersReleased": resources.syntheticAXWrappersReleased,
            "retainedAXObjects": resources.retainedAXObjects,
            "pollingTimers": resources.pollingTimers,
            "coordinateLogs": resources.coordinateLogs,
            "sessionReleased": resources.sessionReleased
        ]
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
        try data.write(to: root.appendingPathComponent("placement-results.json"), options: .atomic)
    }

    private static func runCompiledContract(
        sources: [URL],
        fixture: Fixture
    ) throws -> CompiledContractOutput {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-native-ui-redesign.task14." + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let driver = root.appendingPathComponent("main.swift")
        let payload = root.appendingPathComponent("fixture.json")
        let executable = root.appendingPathComponent("hud-placement-contract")
        let encodedFixture = try JSONEncoder().encode(fixture)
        try encodedFixture.write(to: payload, options: .atomic)
        try contractDriverSource.write(to: driver, atomically: true, encoding: .utf8)
        try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["swiftc"] + sources.map(\.path) + [driver.path, "-o", executable.path]
        )
        var expectedOutput: Data?
        for _ in 0..<fixture.repeatCount {
            let output = try runProcess(executable: executable, arguments: [payload.path])
            guard expectedOutput == nil || expectedOutput == output else {
                throw ContractInputError(category: "nondeterministic-placement")
            }
            expectedOutput = output
        }
        guard let output = expectedOutput,
              let text = String(data: output, encoding: .utf8),
              text.contains("CAPTURE one-shot PASS"),
              !text.lowercased().contains("nan") else {
            throw ContractInputError(category: "unexpected-placement")
        }
        return CompiledContractOutput(text: text, resources: try parseResources(from: text))
    }

    private static func parseResources(from text: String) throws -> ResourceReceipt {
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("RESOURCE ") }) else {
            throw ContractInputError(category: "missing-resource-receipt")
        }
        let fields = line.split(separator: " ").dropFirst().compactMap { field -> (String, String)? in
            let parts = field.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return (parts[0], parts[1])
        }
        let values = Dictionary(uniqueKeysWithValues: fields)
        guard values.count == 7,
              let captureCalls = values["capture-calls"].flatMap(Int.init),
              let wrappersCreated = values["wrappers-created"].flatMap(Int.init),
              let wrappersReleased = values["wrappers-released"].flatMap(Int.init),
              let retainedAXObjects = values["retained-ax"].flatMap(Int.init),
              let pollingTimers = values["polling-timers"].flatMap(Int.init),
              let coordinateLogs = values["coordinate-logs"].flatMap(Int.init),
              let sessionReleased = values["session-released"].flatMap(Bool.init) else {
            throw ContractInputError(category: "malformed-resource-receipt")
        }
        guard captureCalls == 1,
              wrappersCreated == wrappersReleased,
              retainedAXObjects == 0,
              pollingTimers == 0,
              coordinateLogs == 0,
              sessionReleased else {
            throw ContractInputError(category: "unsafe-resource-lifecycle")
        }
        return ResourceReceipt(
            captureCalls: captureCalls,
            syntheticAXWrappersCreated: wrappersCreated,
            syntheticAXWrappersReleased: wrappersReleased,
            retainedAXObjects: retainedAXObjects,
            pollingTimers: pollingTimers,
            coordinateLogs: coordinateLogs,
            sessionReleased: sessionReleased
        )
    }

    private static let contractDriverSource = #"""
    import AppKit
    import Darwin
    import Dispatch
    import Foundation

    private enum FixtureNumber: Decodable, Sendable {
        case finite(Double)
        case nan
        case positiveInfinity
        case negativeInfinity

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Double.self) {
                guard value.isFinite else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "non-finite number") }
                self = .finite(value)
                return
            }
            guard let token = try? container.decode(String.self) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid geometry")
            }
            switch token.lowercased() {
            case "nan": self = .nan
            case "infinity": self = .positiveInfinity
            case "-infinity": self = .negativeInfinity
            default: throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported geometry token")
            }
        }

        var value: Double {
            switch self {
            case let .finite(value): value
            case .nan: .nan
            case .positiveInfinity: .infinity
            case .negativeInfinity: -.infinity
            }
        }
    }

    private struct ExecutableFixture: Decodable, Sendable {
        struct Display: Decodable, Sendable {
            let id: UInt32
            let visibleFrame: [FixtureNumber]
        }

        struct Case: Decodable, Sendable {
            let snapshotGeneration: UInt64
            let targetDisplayID: UInt32?
            let fieldFrame: [FixtureNumber]?
            let windowFrame: [FixtureNumber]?
            let expectedStrategy: String
            let expectedFrame: [FixtureNumber]
        }

        let currentGeneration: UInt64
        let panelSize: [FixtureNumber]
        let gap: FixtureNumber
        let screenInset: FixtureNumber
        let displays: [Display]
        let mainDisplayID: UInt32?
        let frontmostDisplayID: UInt32?
        let cases: [Case]
        let interruptionCount: Int
    }

    private final class SyntheticAXWrapper {}

    @MainActor
    private final class SyntheticCaptureProbe {
        private var liveAXWrapperIDs: Set<ObjectIdentifier> = []
        private var pollingTimerIDs: Set<UUID> = []
        private var coordinateLogEvents: [UUID] = []
        private(set) var captureCalls = 0
        private(set) var wrappersCreated = 0
        private(set) var wrappersReleased = 0

        var retainedAXObjects: Int { liveAXWrapperIDs.count }
        var pollingTimers: Int { pollingTimerIDs.count }
        var coordinateLogs: Int { coordinateLogEvents.count }

        func capture(generation: UInt64) -> HUDTargetGeometrySnapshot {
            captureCalls += 1
            wrappersCreated += 1
            let wrapper = SyntheticAXWrapper()
            liveAXWrapperIDs.insert(ObjectIdentifier(wrapper))
            defer {
                liveAXWrapperIDs.remove(ObjectIdentifier(wrapper))
                wrappersReleased += 1
            }
            return HUDTargetGeometrySnapshot(
                generation: generation,
                captureToken: UUID(uuidString: "00000000-0000-0000-0000-000000000014")!,
                fieldFrame: nil,
                windowFrame: nil,
                targetDisplayID: nil
            )
        }
    }

    private func requireSendable<T: Sendable>(_: T.Type) {}

    private func rect(_ values: [FixtureNumber]) -> HUDRect {
        guard values.count == 4 else { return .invalid }
        return HUDRect(
            x: values[0].value,
            y: values[1].value,
            width: values[2].value,
            height: values[3].value
        )
    }

    private func size(_ values: [FixtureNumber]) -> HUDSize {
        guard values.count == 2 else { return HUDSize(width: 0, height: 0) }
        return HUDSize(width: values[0].value, height: values[1].value)
    }

    @MainActor
    private func runContract(_ fixture: ExecutableFixture) {
        requireSendable(HUDTargetGeometrySnapshot.self)
        requireSendable(HUDPlacementInput.self)
        requireSendable(HUDPlacementResult.self)

        let probe = SyntheticCaptureProbe()
        weak var weakSession: HUDTargetGeometrySession?
        do {
            let geometrySession = AccessibilityHUDGeometryCapture.makeSession(
                capture: { generation in probe.capture(generation: generation) }
            )
            weakSession = geometrySession
            let generation = fixture.currentGeneration
            guard geometrySession.beginDictation(generation: generation) != nil,
                  geometrySession.beginDictation(generation: generation) != nil,
                  probe.captureCalls == 1,
                  geometrySession.currentSnapshot?.generation == generation else {
                exit(1)
            }
            let staleGeneration = generation == 0 ? 0 : generation - 1
            geometrySession.endDictation(generation: staleGeneration)
            guard geometrySession.currentSnapshot?.generation == generation else { exit(1) }
            geometrySession.endDictation(generation: generation)
            guard geometrySession.currentSnapshot == nil else { exit(1) }
            geometrySession.shutdown()
        }

        let resources = (
            captureCalls: probe.captureCalls,
            wrappersCreated: probe.wrappersCreated,
            wrappersReleased: probe.wrappersReleased,
            retainedAXObjects: probe.retainedAXObjects,
            pollingTimers: probe.pollingTimers,
            coordinateLogs: probe.coordinateLogs,
            sessionReleased: weakSession == nil
        )
        guard resources.captureCalls == 1,
              resources.wrappersCreated == resources.wrappersReleased,
              resources.retainedAXObjects == 0,
              resources.pollingTimers == 0,
              resources.coordinateLogs == 0,
              resources.sessionReleased else {
            exit(1)
        }
        print("CAPTURE one-shot PASS")
        print(
            "RESOURCE capture-calls=\(resources.captureCalls)"
                + " wrappers-created=\(resources.wrappersCreated)"
                + " wrappers-released=\(resources.wrappersReleased)"
                + " retained-ax=\(resources.retainedAXObjects)"
                + " polling-timers=\(resources.pollingTimers)"
                + " coordinate-logs=\(resources.coordinateLogs)"
                + " session-released=\(resources.sessionReleased)"
        )

        let displays = fixture.displays.map {
            HUDDisplayGeometry(id: $0.id, visibleFrame: rect($0.visibleFrame))
        }
        for iteration in 0...fixture.interruptionCount {
            for (index, item) in fixture.cases.enumerated() {
                let snapshot = HUDTargetGeometrySnapshot(
                    generation: item.snapshotGeneration,
                    captureToken: UUID(uuidString: "00000000-0000-0000-0000-000000000014")!,
                    fieldFrame: item.fieldFrame.map(rect),
                    windowFrame: item.windowFrame.map(rect),
                    targetDisplayID: item.targetDisplayID
                )
                let input = HUDPlacementInput(
                    snapshot: snapshot,
                    currentGeneration: fixture.currentGeneration,
                    displays: displays,
                    frontmostDisplayID: fixture.frontmostDisplayID,
                    mainDisplayID: fixture.mainDisplayID,
                    panelSize: size(fixture.panelSize),
                    gap: fixture.gap.value,
                    screenInset: fixture.screenInset.value
                )
                guard let expectedStrategy = HUDPlacementStrategy(rawValue: item.expectedStrategy),
                      let result = HUDPlacement.place(input),
                      result.strategy == expectedStrategy,
                      result.frame == rect(item.expectedFrame),
                      result.frame.isValid else {
                    exit(1)
                }
                if iteration == 0 {
                    print("RECT \(index) PASS strategy=\(result.strategy.rawValue)")
                }
            }
        }
        exit(0)
    }

    guard CommandLine.arguments.count == 2 else { exit(64) }
    do {
        let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let fixture = try JSONDecoder().decode(
            ExecutableFixture.self,
            from: Data(contentsOf: fixtureURL)
        )
        Task { @MainActor in runContract(fixture) }
        dispatchMain()
    } catch {
        exit(64)
    }
    """#

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
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            if let message = String(data: errorOutput, encoding: .utf8), !message.isEmpty {
                FileHandle.standardError.write(Data(message.utf8))
            }
            throw ContractInputError(category: "compiled-contract-failed")
        }
        return output
    }
}
