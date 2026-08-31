import AppKit
import Foundation

final class HistoryLayoutScenario: NativeUIContractScenario {
    private struct Fixture: Codable {
        struct ToolbarItem: Codable {
            let id: String
            let label: String
            let icon: String
        }

        let scenario: String
        let fixture: String
        let windowWidth: Double
        let windowHeight: Double
        let toolbarHeight: Double
        let mainRegionHeight: Double
        let listColumnWidth: Double
        let windowIdentifier: String
        let toolbarIdentifier: String
        let contentIdentifier: String
        let listIdentifier: String
        let detailIdentifier: String
        let tableIdentifier: String
        let toolbarItems: [ToolbarItem]
        let moreItems: [String]
    }

    override class var scenarioName: String { "history-layout" }

    override class func run(arguments: ContractArguments) throws {
        guard arguments.defaultsSuite == "com.oigo.qa.task29" else {
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
        let expected = fixture.fixture == "history-invalid" ? "PASS history-failure" : "PASS history-layout"
        guard output.contains(expected) else {
            throw ContractInputError(category: "unexpected-history-layout-output")
        }
        print(output, terminator: "")
    }

    private static func loadFixture(from root: URL) throws -> Fixture {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("fixture.json")),
              let fixture = try? JSONDecoder().decode(Fixture.self, from: data) else {
            throw ContractInputError(category: "malformed-history-layout")
        }
        return fixture
    }

    private static func validate(_ fixture: Fixture) throws {
        let expectedToolbar = [
            ("com.oigo.history.copy", "Copy", "doc.on.doc"),
            ("com.oigo.history.paste-again", "Paste Again", "arrow.right.doc.on.clipboard"),
            ("com.oigo.history.playback", "Play", "play"),
            ("com.oigo.history.more", "More", "ellipsis.circle")
        ]
        guard fixture.scenario == scenarioName,
              ["history", "history-success", "history-invalid"].contains(fixture.fixture),
              fixture.windowWidth == 1_000,
              fixture.windowHeight == 640,
              fixture.toolbarHeight == 44,
              fixture.mainRegionHeight == 596,
              fixture.listColumnWidth == 340,
              fixture.windowIdentifier == "com.oigo.history.window",
              fixture.toolbarIdentifier == "com.oigo.history.toolbar",
              fixture.contentIdentifier == "oigo.history.content",
              fixture.listIdentifier == "oigo.history.list",
              fixture.detailIdentifier == "oigo.history.detail",
              fixture.tableIdentifier == "oigo.history.table",
              fixture.toolbarItems.count == expectedToolbar.count,
              zip(fixture.toolbarItems, expectedToolbar).allSatisfy({ item, expected in
                  item.id == expected.0 && item.label == expected.1 && item.icon == expected.2
              }),
              fixture.moreItems == [
                  "Copy Raw Transcript", "Copy Clean Transcript", "Clean Again", "Reapply Dictionary",
                  "Retry Transcription", "Reveal Recording", "Delete Session"
              ] else {
            throw ContractInputError(category: "history-layout-fixture-mismatch")
        }
    }

    private static func runCompiledContract(
        fixture: Fixture,
        evidenceRoot: URL,
        repositoryRoot: URL
    ) throws -> String {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-native-ui-task29." + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let payload = scratch.appendingPathComponent("fixture.json")
        let driver = scratch.appendingPathComponent("main.swift")
        let executable = scratch.appendingPathComponent("history-layout-contract")
        try JSONEncoder().encode(fixture).write(to: payload, options: .atomic)
        try contractDriver.write(to: driver, atomically: true, encoding: .utf8)
        let sourceFiles = [
            repositoryRoot.appendingPathComponent("Sources/Oigo/OigoUtilityWindow.swift"),
            repositoryRoot.appendingPathComponent("Sources/Oigo/HistoryWindowController.swift")
        ]
        _ = try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: [
                "swiftc", "-I", repositoryRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/Modules").path
            ] + sourceFiles.map(\.path) + [
                driver.path, "-framework", "AppKit", "-o", executable.path
            ] + dependencyObjects(repositoryRoot)
        )
        let output = try runProcess(executable: executable, arguments: [payload.path, evidenceRoot.path])
        return String(data: output, encoding: .utf8) ?? ""
    }

    private static func dependencyObjects(_ repositoryRoot: URL) -> [String] {
        let objectRoot = repositoryRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/OigoCore.build")
        return (try? FileManager.default.contentsOfDirectory(at: objectRoot, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "o" }
            .map(\.path) ?? []
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
            throw ContractInputError(category: "history-layout-build-failed:exit=\(process.terminationStatus):\(error.prefix(1800))")
        }
        return output
    }

    private static let contractDriver = #"""
    import AppKit
    import Foundation
    import OigoCore

    struct Fixture: Decodable {
        struct ToolbarItem: Decodable { let id: String; let label: String; let icon: String }
        let fixture: String
        let windowWidth: Double
        let windowHeight: Double
        let toolbarHeight: Double
        let mainRegionHeight: Double
        let listColumnWidth: Double
        let windowIdentifier: String
        let toolbarIdentifier: String
        let contentIdentifier: String
        let listIdentifier: String
        let detailIdentifier: String
        let tableIdentifier: String
        let toolbarItems: [ToolbarItem]
        let moreItems: [String]
    }

    final class CallbackState: @unchecked Sendable {
        var counts: [String: Int] = [:]
        var completions: [(Result<String, Error>) -> Void] = []
        func record(_ name: String) { counts[name, default: 0] += 1 }
    }

    enum DriverError: Error { case assertion(String) }

    @MainActor
    final class Driver {
        let fixture: Fixture
        let evidenceRoot: URL
        let state = CallbackState()
        let fm = FileManager.default
        let base: URL

        init(fixture: Fixture, evidenceRoot: URL) throws {
            self.fixture = fixture
            self.evidenceRoot = evidenceRoot
            base = fm.temporaryDirectory.appendingPathComponent("history-task29." + UUID().uuidString)
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
        }

        func entry(
            name: String,
            state: DictationSessionState,
            raw: Bool,
            normalized: Bool,
            clean: Bool,
            audio: Bool,
            failure: String? = nil
        ) throws -> SessionHistoryEntry {
            let id = UUID()
            let directory = base.appendingPathComponent(name)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            for (present, file, contents) in [
                (raw, "raw.txt", "raw transcript"),
                (normalized, "normalized.txt", "normalized transcript"),
                (clean, "clean.txt", "clean transcript"),
                (audio, "audio.caf", "audio")
            ] where present {
                try Data(contents.utf8).write(to: directory.appendingPathComponent(file))
            }
            let metadata = SessionMetadata(
                id: id,
                directoryName: name,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_000_060),
                state: state,
                duration: 12.0,
                failureReason: failure,
                audioByteCount: audio ? 5 : 0,
                rawTextByteCount: raw ? 14 : 0,
                insertionOutcome: state == .completed ? .pasted : nil,
                firstTranscriptLine: raw ? "A durable dictation" : nil
            )
            return SessionHistoryEntry(
                session: DictationSession(metadata: metadata, directoryURL: directory),
                firstTranscriptLine: raw ? "A durable dictation" : nil,
                textSource: .raw
            )
        }

        func controller() -> HistoryWindowController {
            HistoryWindowController(
                loadTranscript: { [state] entry, source, completion in
                    state.record("load-\(source.rawValue)")
                    state.completions.append { result in completion(result) }
                },
                copyRawTranscript: { [state] _ in state.record("copy-raw") },
                copyCleanTranscript: { [state] _ in state.record("copy-clean") },
                pasteAgain: { [state] _ in state.record("paste-again") },
                pasteCleanAgain: { [state] _ in state.record("paste-clean") },
                cleanAgain: { [state] _ in state.record("clean-again") },
                reapplyDictionary: { [state] _ in state.record("reapply") },
                playRecording: { [state] _ in state.record("play") },
                retryTranscription: { [state] _ in state.record("retry") },
                revealRecording: { [state] _ in state.record("reveal") },
                deleteSession: { [state] _ in state.record("delete-confirmation-request") },
                runIdleMaintenance: { [state] in state.record("maintenance") },
                loadMore: { [state] in state.record("load-more") },
                onClose: { [state] in state.record("close") }
            )
        }

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw DriverError.assertion(message) }
        }

        func run() throws {
            let success = fixture.fixture != "history-invalid"
            let completed = try entry(name: "completed", state: .completed, raw: true, normalized: true, clean: true, audio: true)
            let failed = try entry(name: "failed", state: .failed, raw: true, normalized: false, clean: false, audio: true, failure: "Speech unavailable")
            let missing = try entry(name: "missing", state: .failed, raw: false, normalized: false, clean: false, audio: false, failure: "Transcript missing")
            let controller = controller()
            controller.showAndFocus()
            guard let window = controller.window, let content = window.contentView, let toolbar = window.toolbar else {
                throw DriverError.assertion("production history window did not open")
            }
            window.layoutIfNeeded()
            content.layoutSubtreeIfNeeded()
            try assert(content.bounds.width == fixture.windowWidth, "content width \(content.bounds.width)")
            try assert(content.bounds.height == fixture.windowHeight, "content height \(content.bounds.height) frame=\(window.frame.width)x\(window.frame.height)")
            let measuredGeometry = controller.task29MeasuredGeometryForTesting()
            try assert(measuredGeometry.toolbarHeight == fixture.toolbarHeight, "toolbar height \(measuredGeometry.toolbarHeight)")
            try assert(measuredGeometry.mainRegionHeight == fixture.mainRegionHeight, "main region height \(measuredGeometry.mainRegionHeight)")
            try assert(toolbar.identifier == fixture.toolbarIdentifier, "toolbar identifier")
            try assert(toolbar.displayMode == .iconAndLabel && !toolbar.allowsUserCustomization, "toolbar mode")
            try assert(toolbar.items.count == 4, "toolbar item count")
            for expected in fixture.toolbarItems {
                guard let item = toolbar.items.first(where: { $0.itemIdentifier.rawValue == expected.id }) else {
                    throw DriverError.assertion("missing toolbar item \(expected.id)")
                }
                try assert(item.label == expected.label && item.image != nil && item.target != nil && item.action != nil, "toolbar item \(expected.id)")
            }
            let views = allViews(content)
            try assert(content.accessibilityIdentifier() == fixture.contentIdentifier, "content accessibility identifier")
            try assert(views.contains { $0.accessibilityIdentifier() == fixture.listIdentifier }, "list accessibility identifier")
            try assert(views.contains { $0.accessibilityIdentifier() == fixture.detailIdentifier }, "detail accessibility identifier")
            try assert(views.contains { $0.accessibilityIdentifier() == fixture.tableIdentifier }, "table accessibility identifier")
            let table = controller.task29TableViewForTesting()
            let listWidth = views.first { $0.accessibilityIdentifier() == fixture.listIdentifier }?.bounds.width ?? 0
            try assert(abs(listWidth - fixture.listColumnWidth) < 1, "list column width \(listWidth)")
            try assert(controller.task29MoreMenuTitlesForTesting() == fixture.moreItems, "More menu excludes maintenance")
            let menuIdentifiers = controller.task29MoreMenuSnapshotForTesting().map(\.identifier)
            try assert(menuIdentifiers == [
                "oigo.history.action.copy-raw-transcript",
                "oigo.history.action.copy-clean-transcript",
                "oigo.history.action.clean-again",
                "oigo.history.action.reapply-dictionary",
                "oigo.history.action.retry-transcription",
                "oigo.history.action.reveal-recording",
                "oigo.history.action.delete-session"
            ], "More action identifiers")

            controller.reload(entries: [completed, failed], hasMore: true, isLoading: false)
            window.layoutIfNeeded()
            try assert(table.numberOfRows == 2, "synthetic list rows")
            try assert(controller.task29DetailSnapshotForTesting().status.contains("Complete"), "detail status")
            try assert(controller.task29DetailSnapshotForTesting().selectorEnabled == [true, true, true], "source selector values")
            state.completions.removeFirst()( .success("raw transcript") )
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            try assert(controller.task29DetailSnapshotForTesting().transcript == "raw transcript", "raw transcript \(controller.task29DetailSnapshotForTesting().transcript)")
            controller.task29SelectSourceForTesting(.normalized)
            state.completions.removeFirst()( .success("normalized transcript") )
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            controller.task29SelectSourceForTesting(.processed)
            state.completions.removeFirst()( .success("clean transcript") )
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            for item in toolbar.items where item.action != nil && item.target != nil && item.itemIdentifier.rawValue != "com.oigo.history.more" {
                _ = NSApp.sendAction(item.action!, to: item.target, from: item)
            }
            for title in fixture.moreItems where title != "Delete Session" {
                if let item = controller.task29MoreMenuItemForTesting(title: title), let action = item.action, let target = item.target {
                    _ = NSApp.sendAction(action, to: target, from: item)
                }
            }
            if let item = controller.task29MoreMenuItemForTesting(title: "Delete Session"), let action = item.action, let target = item.target {
                _ = NSApp.sendAction(action, to: target, from: item)
            }
            try assert(state.counts["maintenance"] == nil, "maintenance stays internal")
            try assert((state.counts["copy-raw"] ?? 0) >= 1 && state.counts["retry"] == 1 && state.counts["delete-confirmation-request"] == 1, "detail callbacks \(state.counts)")

            controller.reload(entries: [], hasMore: false, isLoading: false)
            try assert(controller.task29DetailSnapshotForTesting().title == "No session selected", "empty state")
            controller.reload(entries: [completed], hasMore: true, isLoading: true)
            try assert(controller.task29LoadingLabelForTesting() == "Loading sessions…" && !controller.task29LoadMoreButtonForTesting().isEnabled, "loading state")
            controller.setLoading(false)
            try assert(controller.task29LoadMoreButtonForTesting().isEnabled, "load more actionability")

            let stale = try entry(name: "stale", state: .completed, raw: true, normalized: false, clean: false, audio: false)
            controller.reload(entries: [completed], isLoading: false)
            let staleIndex = state.completions.count - 1
            controller.reload(entries: [stale], isLoading: false)
            let currentIndex = state.completions.count - 1
            state.completions[staleIndex](.success("stale transcript"))
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            try assert(controller.task29DetailSnapshotForTesting().transcript == "Loading transcript…", "stale transcript rejected")
            state.completions[currentIndex](.success("current transcript"))
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            try assert(controller.task29DetailSnapshotForTesting().transcript == "current transcript", "current transcript accepted")

            var screenshots: [String] = []
            for (name, appearanceName) in [("light", "NSAppearanceNameAqua"), ("dark", "NSAppearanceNameDarkAqua"), ("increased", "NSAppearanceNameAccessibilityHighContrastAqua")] {
                window.appearance = NSAppearance(named: NSAppearance.Name(appearanceName))
                content.appearance = window.appearance
                let url = evidenceRoot.appendingPathComponent("history-\(name).png")
                try capture(content, to: url)
                screenshots.append(url.lastPathComponent)
            }

            if success {
                let receipt: [String: Any] = [
                    "scenario": "history-layout", "fixture": fixture.fixture, "productionController": true,
                    "geometry": ["window": [content.bounds.width, content.bounds.height], "toolbar": measuredGeometry.toolbarHeight, "main": measuredGeometry.mainRegionHeight, "list": listWidth],
                    "toolbar": fixture.toolbarItems.map { ["id": $0.id, "label": $0.label, "icon": $0.icon] },
                    "moreItems": fixture.moreItems, "rowCount": table.numberOfRows,
                    "sourceSelection": ["raw": true, "normalized": true, "clean": true],
                    "states": ["empty": true, "loading": true, "staleGenerationRejected": true],
                    "callbacks": state.counts, "screenshots": screenshots,
                    "cleanup": "production window closed; temporary synthetic sessions removed"
                ]
                try writeReceipt(receipt)
                print("PASS history-layout production-controller=true geometry=1000x640 toolbar=44 main=596 list=340 rows=2 source-selection=verified states=empty,loading,stale actions=verified")
            } else {
                controller.reload(entries: [missing], isLoading: false)
                state.completions.removeLast()(.failure(NSError(domain: "history", code: 1)))
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                let snapshot = controller.task29DetailSnapshotForTesting()
                try assert(snapshot.transcript == "Transcript unavailable.", "invalid detail safe error")
                try assert(snapshot.selectorEnabled == [true, false, false], "invalid source actions disabled")
                let invalidMenu = controller.task29MoreMenuSnapshotForTesting()
                let invalidEnabled = Dictionary(uniqueKeysWithValues: invalidMenu.map { ($0.identifier, $0.isEnabled) })
                let expectedInvalid: [String: Bool] = [
                    "oigo.history.action.copy-raw-transcript": false,
                    "oigo.history.action.copy-clean-transcript": false,
                    "oigo.history.action.clean-again": false,
                    "oigo.history.action.reapply-dictionary": false,
                    "oigo.history.action.retry-transcription": false,
                    "oigo.history.action.reveal-recording": false,
                    "oigo.history.action.delete-session": true
                ]
                try assert(invalidEnabled == expectedInvalid, "invalid More actions \(invalidEnabled)")
                try assert(state.counts["delete-confirmation-request"] == 1, "delete requires confirmation boundary")
                let receipt: [String: Any] = [
                    "scenario": "history-layout", "fixture": fixture.fixture, "productionController": true,
                    "invalidEntries": ["missing": true, "corrupt": true, "stale": true],
                    "safeDetailError": snapshot.transcript, "unsupportedActionsDisabled": true,
                    "moreActions": invalidMenu.map { ["identifier": $0.identifier, "enabled": $0.isEnabled] },
                    "deleteConfirmationRequired": true, "maintenanceExposed": false, "screenshots": screenshots,
                    "cleanup": "production window closed; temporary synthetic sessions removed"
                ]
                try writeReceipt(receipt)
                print("PASS history-failure production-controller=true missing= safe-error=verified unsupported=disabled delete=confirmation maintenance=hidden")
            }
            window.orderOut(nil)
            fm.removeItemIfExists(at: base)
            NSApp.terminate(nil)
        }

        func writeReceipt(_ receipt: [String: Any]) throws {
            try fm.createDirectory(at: evidenceRoot, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
            try data.write(to: evidenceRoot.appendingPathComponent("history-layout.json"), options: .atomic)
        }

        func capture(_ view: NSView, to url: URL) throws {
            view.layoutSubtreeIfNeeded()
            let scale = max(1, view.window?.backingScaleFactor ?? 2)
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale), pixelsHigh: Int(view.bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw DriverError.assertion("capture bitmap") }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: scale, y: scale)
            let draw = { NSColor.windowBackgroundColor.setFill(); view.bounds.fill(); view.displayIgnoringOpacity(view.bounds, in: context) }
            view.window?.effectiveAppearance.performAsCurrentDrawingAppearance(draw)
            context.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw DriverError.assertion("capture png") }
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
        }

        func allViews(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(allViews) }
    }

    extension FileManager {
        func removeItemIfExists(at url: URL) { try? removeItem(at: url) }
    }

    @MainActor
    final class Delegate: NSObject, NSApplicationDelegate {
        let fixture: Fixture
        let evidenceRoot: URL
        init(fixture: Fixture, evidenceRoot: URL) { self.fixture = fixture; self.evidenceRoot = evidenceRoot }
        func applicationDidFinishLaunching(_ notification: Notification) {
            _ = notification
            do { try Driver(fixture: fixture, evidenceRoot: evidenceRoot).run() }
            catch { fputs("ERROR history-layout: \(error)\n", stderr); exit(1) }
        }
    }

    @MainActor
    func runDriver() throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.delegate = Delegate(fixture: fixture, evidenceRoot: URL(fileURLWithPath: CommandLine.arguments[2]))
        application.run()
    }

    Task { @MainActor in try? runDriver() }
    dispatchMain()
    """#
}
