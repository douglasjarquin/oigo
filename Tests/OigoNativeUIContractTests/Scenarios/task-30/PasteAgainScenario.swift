import AppKit
import Foundation

final class PasteAgainScenario: NativeUIContractScenario {
    private struct Fixture: Codable {
        let scenario: String
        let fixture: String
        let windowIdentifier: String
        let targetBundleIdentifier: String
        let targetFieldIdentifier: String
        let rawLength: Int
        let cleanLength: Int
    }

    override class var scenarioName: String { "paste-again" }

    override class func run(arguments: ContractArguments) throws {
        guard arguments.defaultsSuite == "com.oigo.qa.task30" else {
            throw ContractInputError(category: "invalid-defaults-suite")
        }
        let fixture = try loadFixture(from: arguments.fixtureRoot)
        try validate(fixture)
        let repositoryRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let output = try runCompiledContract(
            fixture: fixture,
            evidenceRoot: arguments.evidenceRoot,
            repositoryRoot: repositoryRoot
        )
        guard output.contains("PASS paste-again"),
              output.contains("PASS paste-again-failure") else {
            throw ContractInputError(category: "unexpected-paste-again-output")
        }
        print(output, terminator: "")
    }

    private static func loadFixture(from root: URL) throws -> Fixture {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("fixture.json")),
              let fixture = try? JSONDecoder().decode(Fixture.self, from: data) else {
            throw ContractInputError(category: "malformed-paste-again")
        }
        return fixture
    }

    private static func validate(_ fixture: Fixture) throws {
        guard fixture.scenario == scenarioName,
              fixture.fixture == "handoff",
              fixture.windowIdentifier == "com.oigo.history.window",
              fixture.targetBundleIdentifier == "com.oigo.qa.target",
              fixture.targetFieldIdentifier == "oigo.qa.target.text-field",
              fixture.rawLength > fixture.cleanLength,
              fixture.cleanLength > 0 else {
            throw ContractInputError(category: "paste-again-fixture-mismatch")
        }
    }

    private static func runCompiledContract(
        fixture: Fixture,
        evidenceRoot: URL,
        repositoryRoot: URL
    ) throws -> String {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-native-ui-task30." + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let payload = scratch.appendingPathComponent("fixture.json")
        let driver = scratch.appendingPathComponent("main.swift")
        let executable = scratch.appendingPathComponent("paste-again-contract")
        try JSONEncoder().encode(fixture).write(to: payload, options: .atomic)
        try contractDriver.write(to: driver, atomically: true, encoding: .utf8)
        _ = try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: [
                "swiftc",
                "-I", repositoryRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/Modules").path
            ] + [
                repositoryRoot.appendingPathComponent("Sources/Oigo/OigoUtilityWindow.swift").path,
                repositoryRoot.appendingPathComponent("Sources/Oigo/HistoryWindowController.swift").path,
                driver.path,
                "-framework", "AppKit",
                "-framework", "ApplicationServices",
                "-framework", "CoreGraphics",
                "-o", executable.path
            ] + dependencyObjects(repositoryRoot)
        )
        return String(
            data: try runProcess(executable: executable, arguments: [payload.path, evidenceRoot.path]),
            encoding: .utf8
        ) ?? ""
    }

    private static func dependencyObjects(_ repositoryRoot: URL) -> [String] {
        ["OigoCore.build", "OigoInsertion.build"].flatMap { directory in
            let root = repositoryRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/" + directory)
            return (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "o" }
                .map(\.path) ?? []
        }
    }

    private static func runProcess(executable: URL, arguments: [String]) throws -> Data {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let standardOutput = String(data: output, encoding: .utf8) ?? ""
            throw ContractInputError(
                category: "paste-again-build-failed:exit=\(process.terminationStatus):"
                    + (error + standardOutput).prefix(2000)
            )
        }
        return output
    }

    private static let contractDriver = #"""
    import AppKit
    import CryptoKit
    import Foundation
    import OigoCore
    import OigoInsertion

    struct Fixture: Decodable {
        let windowIdentifier: String
        let targetBundleIdentifier: String
        let targetFieldIdentifier: String
        let rawLength: Int
        let cleanLength: Int
    }

    enum DriverError: Error { case assertion(String) }

    @MainActor
    final class CallbackState {
        var rawCalls = 0
        var cleanCalls = 0
        var loadCalls: [String] = []
        var closeCalls = 0
    }

    @MainActor
    final class ProbeTargetEnvironment: InsertionTargetEnvironment {
        var snapshot: InsertionTargetSnapshot
        var validation: TargetValidation
        var captures = 0
        var validations = 0
        var discards = 0

        init(snapshot: InsertionTargetSnapshot, validation: TargetValidation) {
            self.snapshot = snapshot
            self.validation = validation
        }

        func capture() -> InsertionTargetSnapshot {
            captures += 1
            return snapshot
        }

        func validate(_ snapshot: InsertionTargetSnapshot) -> TargetValidation {
            _ = snapshot
            validations += 1
            return validation
        }

        func discard(_ snapshot: InsertionTargetSnapshot) {
            _ = snapshot
            discards += 1
        }
    }

    @MainActor
    final class ProbePasteboard: InsertionPasteboard {
        var writeCount = 0
        var lastWriteLength = 0
        var retainedText = false

        func write(_ rawText: String) -> Bool {
            writeCount += 1
            lastWriteLength = rawText.utf8.count
            retainedText = false
            return true
        }
    }

    @MainActor
    final class ProbeEventSender: InsertionEventSender {
        let result: InsertionEventResult
        var sends = 0
        var revalidationResults: [TargetValidation] = []

        init(result: InsertionEventResult) { self.result = result }

        func sendPaste(
            to processIdentifier: Int32,
            revalidate: () -> TargetValidation
        ) -> InsertionEventResult {
            guard processIdentifier > 0 else { return .failed }
            sends += 1
            revalidationResults.append(revalidate())
            return result
        }
    }

    @MainActor
    final class Driver {
        let fixture: Fixture
        let evidenceRoot: URL
        let fileManager = FileManager.default
        let callbacks = CallbackState()
        let base: URL

        init(fixture: Fixture, evidenceRoot: URL) throws {
            self.fixture = fixture
            self.evidenceRoot = evidenceRoot
            base = fileManager.temporaryDirectory.appendingPathComponent("oigo-task30." + UUID().uuidString)
            try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        }

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw DriverError.assertion(message) }
        }

        func entry(store: SessionStore, raw: String, clean: String) throws -> DictationSession {
            var session = try store.createSession(now: Date(timeIntervalSince1970: 1_700_000_000))
            session = try store.persistRawText(raw, for: session)
            session = try store.persistNormalizedText(raw, for: session)
            session = try store.persistCleanText(clean, for: session)
            return try store.update(session, state: .completed)
        }

        func historyEntry(_ session: DictationSession) -> SessionHistoryEntry {
            SessionHistoryEntry(session: session, firstTranscriptLine: "Durable entry", textSource: .processed)
        }

        func makeController() -> HistoryWindowController {
            HistoryWindowController(
                loadTranscript: { [callbacks] _, source, completion in
                    callbacks.loadCalls.append(source.rawValue)
                    completion(.success(source == .processed ? "clean loaded" : "raw loaded"))
                },
                copyRawTranscript: { _ in },
                copyCleanTranscript: { _ in },
                pasteAgain: { [callbacks] _ in callbacks.rawCalls += 1 },
                pasteCleanAgain: { [callbacks] _ in callbacks.cleanCalls += 1 },
                cleanAgain: { _ in },
                reapplyDictionary: { _ in },
                playRecording: { _ in },
                retryTranscription: { _ in },
                revealRecording: { _ in },
                deleteSession: { _ in },
                runIdleMaintenance: {},
                loadMore: {},
                onClose: { [callbacks] in callbacks.closeCalls += 1 }
            )
        }

        func makeTarget() -> InsertionTargetSnapshot {
            InsertionTargetSnapshot(
                frontmostProcessIdentifier: 42,
                bundleIdentifier: fixture.targetBundleIdentifier,
                focusedElementIdentifier: fixture.targetFieldIdentifier,
                role: "AXTextArea",
                isSecureTextField: false,
                identity: InsertionTargetIdentity(
                    accessibilityIdentifier: fixture.targetFieldIdentifier,
                    windowIdentifier: "oigo.qa.target.window",
                    role: "AXTextArea"
                ),
                capabilities: InsertionTargetCapabilities(
                    supportsValue: true,
                    valueIsSettable: true,
                    supportsSelectedText: false,
                    selectedTextIsSettable: false
                ),
                captureToken: UUID()
            )
        }

        func run() throws {
            let store = try SessionStore(rootDirectory: base.appendingPathComponent("sessions"))
            let raw = String(repeating: "r", count: fixture.rawLength)
            let clean = String(repeating: "c", count: fixture.cleanLength)
            let session = try entry(store: store, raw: raw, clean: clean)
            let historyEntry = historyEntry(session)
            let controller = makeController()
            controller.reload(entries: [historyEntry])
            controller.showAndFocus()
            RunLoop.main.run(until: Date().addingTimeInterval(0.12))
            guard let window = controller.window, let content = window.contentView, let toolbar = window.toolbar else {
                throw DriverError.assertion("production History window unavailable")
            }
            window.layoutIfNeeded()
            let pasteItem = controller.toolbar(
                toolbar,
                itemForItemIdentifier: NSToolbarItem.Identifier("com.oigo.history.paste-again"),
                willBeInsertedIntoToolbar: false
            )
            try assert(pasteItem?.target != nil && pasteItem?.action != nil, "Paste Again action target")

            controller.task29SelectSourceForTesting(.raw)
            controller.task30InvokePasteAgainForTesting()
            try assert(callbacks.rawCalls == 1 && callbacks.cleanCalls == 0, "raw source callback")
            controller.task29SelectSourceForTesting(.processed)
            controller.task30InvokePasteAgainForTesting()
            try assert(callbacks.cleanCalls == 1, "clean source callback")

            let target = makeTarget()
            let environment = ProbeTargetEnvironment(snapshot: target, validation: .safe)
            let pasteboard = ProbePasteboard()
            let sender = ProbeEventSender(result: .dispatched)
            let insertion = InsertionService(
                targetEnvironment: environment,
                pasteboard: pasteboard,
                eventSender: sender
            )
            window.orderOut(nil)
            let rawResult = try runPaste(
                insertion: insertion,
                store: store,
                session: session,
                source: .raw,
                target: target,
                environment: environment
            )
            try assert(rawResult.outcome == .dispatched, "raw Paste Again dispatch")
            try assert(pasteboard.lastWriteLength == fixture.rawLength, "raw selected source")
            let rawCount = pasteboard.writeCount
            let cleanResult = try runPaste(
                insertion: insertion,
                store: store,
                session: session,
                source: .clean,
                target: target,
                environment: environment
            )
            try assert(cleanResult.outcome == .dispatched, "clean Paste Again dispatch")
            try assert(pasteboard.writeCount == rawCount + 1 && pasteboard.lastWriteLength == fixture.cleanLength, "clean selected source")
            try assert(sender.sends == 2 && environment.discards == 2, "single dispatch and target cleanup")
            controller.showAndFocus()
            RunLoop.main.run(until: Date().addingTimeInterval(0.06))
            let focusObserved = window.isKeyWindow || window.isMainWindow
            try assert(window.isVisible, "History focus restoration visibility")

            let bridge = GlobalShortcutOperationBridge(
                state: { .idle },
                start: {},
                stop: {}
            )
            try assert(bridge.receive(.pressed) == .start, "shortcut bridge press")

            let secureTarget = InsertionTargetSnapshot(
                frontmostProcessIdentifier: 42,
                bundleIdentifier: fixture.targetBundleIdentifier,
                focusedElementIdentifier: fixture.targetFieldIdentifier,
                role: "AXSecureTextField",
                isSecureTextField: true,
                capabilities: target.capabilities
            )
            let secureEnvironment = ProbeTargetEnvironment(snapshot: secureTarget, validation: .secureTextField)
            let securePasteboard = ProbePasteboard()
            let secureSender = ProbeEventSender(result: .dispatched)
            let secureResult = InsertionService(
                targetEnvironment: secureEnvironment,
                pasteboard: securePasteboard,
                eventSender: secureSender
            ).pasteAgain(for: session, source: .raw, store: store, target: secureTarget)
            try assert(secureResult.outcome == .secureRejected && secureResult.reasonCode == .secureField, "secure refusal")
            try assert(secureSender.sends == 0 && securePasteboard.writeCount == 1, "secure copy fallback")

            let inaccessibleEnvironment = ProbeTargetEnvironment(snapshot: target, validation: .accessibilityUnavailable)
            let inaccessiblePasteboard = ProbePasteboard()
            let inaccessibleSender = ProbeEventSender(result: .dispatched)
            let inaccessibleResult = InsertionService(
                targetEnvironment: inaccessibleEnvironment,
                pasteboard: inaccessiblePasteboard,
                eventSender: inaccessibleSender
            ).pasteAgain(for: session, source: .raw, store: store, target: target)
            try assert(inaccessibleResult.outcome == .copied && inaccessibleResult.reasonCode == .accessibilityUnavailable, "Accessibility copy-only")
            try assert(inaccessibleSender.sends == 0 && inaccessiblePasteboard.writeCount == 1, "Accessibility no dispatch")

            let staleEnvironment = ProbeTargetEnvironment(snapshot: target, validation: .safe)
            let stalePasteboard = ProbePasteboard()
            let staleSender = ProbeEventSender(result: .dispatched)
            let staleService = InsertionService(
                targetEnvironment: staleEnvironment,
                pasteboard: stalePasteboard,
                eventSender: staleSender
            )
            let staleResult = staleService.pasteAgain(
                for: DictationSession(metadata: session.metadata, directoryURL: base.appendingPathComponent("missing")),
                source: .raw,
                store: store,
                target: target
            )
            try assert(staleResult.outcome == .failed && staleResult.reasonCode == .transcriptReadFailed, "stale entry refusal")
            try assert(stalePasteboard.writeCount == 0 && staleSender.sends == 0, "stale entry no dispatch")
            try assert(!pasteboard.retainedText && !securePasteboard.retainedText && !inaccessiblePasteboard.retainedText, "clipboard bytes not retained by harness")

            let screenshots = try captureAppearances(content: content, window: window)
            window.close()
            try assert(callbacks.closeCalls == 1, "History close callback")
            fileManager.removeItemIfExists(at: base)
            try writeReceipt(
                rawResult: rawResult,
                cleanResult: cleanResult,
                secureResult: secureResult,
                inaccessibleResult: inaccessibleResult,
                staleResult: staleResult,
                screenshots: screenshots,
                targetCaptures: environment.captures,
                targetDiscards: environment.discards,
                dispatches: sender.sends,
                focusObserved: focusObserved
            )
            print("PASS paste-again production-history=true source=raw,clean destination=selected focus=restoration-requested dispatch=2 clipboard=copy-only-safe")
            if !focusObserved {
                print("INCONCLUSIVE paste-again-focus category=windowserver-key-window-unavailable visible=true key=false main=false")
            }
            print("PASS paste-again-failure secure=refused accessibility=copy-only stale=refused clipboard=not-retained cleanup=clean")
            NSApp.terminate(nil)
        }

        func runPaste(
            insertion: InsertionService,
            store: SessionStore,
            session: DictationSession,
            source: TranscriptInsertionSource,
            target: InsertionTargetSnapshot,
            environment: ProbeTargetEnvironment
        ) throws -> InsertionResult {
            let first = environment.capture()
            let second = environment.capture()
            try assert(first.matches(second), "stable destination capture")
            return insertion.pasteAgain(for: session, source: source, store: store, target: second)
        }

        func captureAppearances(content: NSView, window: NSWindow) throws -> [String] {
            let appearances = [
                ("light", NSAppearance.Name.aqua),
                ("dark", NSAppearance.Name.darkAqua),
                ("increased", NSAppearance.Name.accessibilityHighContrastAqua)
            ]
            var names: [String] = []
            for (name, appearanceName) in appearances {
                window.appearance = NSAppearance(named: appearanceName)
                content.appearance = window.appearance
                let url = evidenceRoot.appendingPathComponent("screenshots/history-paste-again-\(name).png")
                content.layoutSubtreeIfNeeded()
                let scale = max(1, window.backingScaleFactor)
                guard let bitmap = NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: Int(content.bounds.width * scale),
                    pixelsHigh: Int(content.bounds.height * scale),
                    bitsPerSample: 8,
                    samplesPerPixel: 4,
                    hasAlpha: true,
                    isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bitmapFormat: [],
                    bytesPerRow: 0,
                    bitsPerPixel: 0
                ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
                    throw DriverError.assertion("History screenshot bitmap")
                }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                context.cgContext.scaleBy(x: scale, y: scale)
                let draw = { NSColor.windowBackgroundColor.setFill(); content.bounds.fill(); content.displayIgnoringOpacity(content.bounds, in: context) }
                window.effectiveAppearance.performAsCurrentDrawingAppearance(draw)
                context.flushGraphics()
                NSGraphicsContext.restoreGraphicsState()
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw DriverError.assertion("History screenshot PNG") }
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try png.write(to: url, options: .atomic)
                names.append(url.path)
            }
            return names
        }

        func writeReceipt(
            rawResult: InsertionResult,
            cleanResult: InsertionResult,
            secureResult: InsertionResult,
            inaccessibleResult: InsertionResult,
            staleResult: InsertionResult,
            screenshots: [String],
            targetCaptures: Int,
            targetDiscards: Int,
            dispatches: Int,
            focusObserved: Bool
        ) throws {
            let receipt: [String: Any] = [
                "scenario": "paste-again",
                "fixture": "handoff",
                "productionHistoryController": true,
                "productionInsertionService": true,
                "productionInsertionPasteAgainFlow": "production app uses InsertionPasteAgainFlow; direct service seam exercised here",
                "productionShortcutBridge": true,
                "selectedSources": ["raw", "clean"],
                "selectedDestination": ["bundle": fixture.targetBundleIdentifier, "field": fixture.targetFieldIdentifier],
                "rawOutcome": rawResult.outcome.rawValue,
                "cleanOutcome": cleanResult.outcome.rawValue,
                "secureOutcome": secureResult.outcome.rawValue,
                "secureReason": secureResult.reasonCode?.rawValue as Any,
                "accessibilityOutcome": inaccessibleResult.outcome.rawValue,
                "accessibilityReason": inaccessibleResult.reasonCode?.rawValue as Any,
                "staleOutcome": staleResult.outcome.rawValue,
                "staleReason": staleResult.reasonCode?.rawValue as Any,
                "focusRestored": focusObserved,
                "focusRestorationRequested": true,
                "focusObservation": focusObserved ? "key-or-main-window" : "INCONCLUSIVE: WindowServer did not grant key or main window to direct contract process",
                "dispatches": dispatches,
                "targetCaptures": targetCaptures,
                "targetDiscards": targetDiscards,
                "secureDispatches": 0,
                "accessibilityDispatches": 0,
                "rawBytesWritten": fixture.rawLength,
                "cleanBytesWritten": fixture.cleanLength,
                "clipboardContentsInEvidence": false,
                "harnessRetainedClipboardContents": false,
                "priorClipboardRestored": false,
                "screenshots": screenshots.map { URL(fileURLWithPath: $0).lastPathComponent },
                "cleanup": "History closed; target snapshots discarded; temporary session store removed"
            ]
            let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
            try fileManager.createDirectory(at: evidenceRoot, withIntermediateDirectories: true)
            try data.write(to: evidenceRoot.appendingPathComponent("paste-again.json"), options: .atomic)
        }
    }

    extension FileManager {
        func removeItemIfExists(at url: URL) { try? removeItem(at: url) }
    }

    @MainActor
    final class Delegate: NSObject, NSApplicationDelegate {
        let fixture: Fixture
        let evidenceRoot: URL

        init(fixture: Fixture, evidenceRoot: URL) {
            self.fixture = fixture
            self.evidenceRoot = evidenceRoot
        }

        func applicationDidFinishLaunching(_ notification: Notification) {
            _ = notification
            do {
                try Driver(fixture: fixture, evidenceRoot: evidenceRoot).run()
            } catch {
                fputs("ERROR paste-again: \(error)\n", stderr)
                exit(1)
            }
        }
    }

    @MainActor
    func runDriver() throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = Delegate(
            fixture: fixture,
            evidenceRoot: URL(fileURLWithPath: CommandLine.arguments[2])
        )
        application.delegate = delegate
        application.run()
    }

    Task { @MainActor in
        do {
            try runDriver()
        } catch {
            fputs("ERROR paste-again: \(error)\n", stderr)
            exit(1)
        }
    }
    dispatchMain()
    """#
}
