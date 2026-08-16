import Darwin
import Foundation
@_spi(Testing) import OigoCore
@_spi(Testing) import OigoTranscription

private struct ContractFailure: Error, CustomStringConvertible {
    let message: String

    var description: String {
        message
    }
}

@main
@MainActor
private struct OigoIssue11PerformanceCheck {
    static func main() async {
        if let inputPath = argument(after: "--input") {
            runReleaseCheck(at: URL(fileURLWithPath: inputPath))
            return
        }
        if CommandLine.arguments.contains("--print-budgets") {
            printBudgets()
            return
        }

        let filter = CommandLine.arguments.dropFirst()
            .drop(while: { $0 != "--filter" })
            .dropFirst()
            .first
        let tests: [(String, () async throws -> Void)] = [
            ("performance event coverage", testPerformanceEventCoverage),
            ("hard budget classification", testHardBudgetClassification),
            ("lifecycle release gates", testLifecycleReleaseGates)
        ]

        var failures = 0
        var matched = 0
        for (name, test) in tests where filter == nil || name.contains(filter ?? "") {
            matched += 1
            do {
                try await test()
                print("GREEN: " + name)
            } catch {
                failures += 1
                print("FAIL: " + name + ": " + String(describing: error))
            }
        }

        let transcriptionTestName = "transcription release instrumentation"
        if #available(macOS 26.0, *) {
            if filter == nil || transcriptionTestName.contains(filter ?? "") {
                matched += 1
                do {
                    try await testTranscriptionReleaseInstrumentation()
                    print("GREEN: " + transcriptionTestName)
                } catch {
                    failures += 1
                    print("FAIL: " + transcriptionTestName + ": " + String(describing: error))
                }
            }
        } else {
            print("INCONCLUSIVE: transcription release instrumentation requires macOS 26")
        }
        if matched == 0 {
            print("FAIL: no performance contract scenario matched")
            exit(1)
        }
        if failures == 0 {
            print("GREEN: all issue #11 performance scenarios")
            exit(0)
        }
        print("FAILURES=" + String(failures))
        exit(1)
    }

    private static func argument(after flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag),
              index + 1 < CommandLine.arguments.count else {
            return nil
        }
        return CommandLine.arguments[index + 1]
    }

    private static func printBudgets() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(PerformanceBudgetCatalog.hardGates)
            print(String(decoding: data, as: UTF8.self))
        } catch {
            print("FAIL: could not encode performance budgets")
            exit(1)
        }
    }

    private static func runReleaseCheck(at url: URL) {
        do {
            let report = try PerformanceReleaseCheck.load(from: url)
            print("RELEASE_STATUS=" + report.status.rawValue)
            for result in report.results {
                let value = result.value.map { String($0) } ?? "none"
                print(
                    result.measurement.rawValue
                        + " status=" + result.status.rawValue
                        + " value=" + value
                )
            }
            switch report.status {
            case .pass:
                exit(0)
            case .fail:
                exit(1)
            case .inconclusive:
                exit(2)
            }
        } catch {
            print("FAIL: invalid performance measurement input")
            exit(1)
        }
    }

    private static func testPerformanceEventCoverage() throws {
        let expected: Set<PerformanceEvent> = [
            .shortcutReceived,
            .sessionPersisted,
            .audioEngineStartBegin,
            .audioEngineStartEnd,
            .firstAudioBuffer,
            .firstVolatileResult,
            .recordingStopped,
            .transcriptionFinalized,
            .cleanupStart,
            .cleanupEnd,
            .insertionStart,
            .insertionEnd,
            .resourcesReleased
        ]
        guard Set(PerformanceEvent.allCases) == expected else {
            throw ContractFailure(message: "required issue #11 event catalog is incomplete")
        }

        let recorder = RecordingPerformanceInstrumentation()
        recorder.mark(.shortcutReceived)
        recorder.mark(.resourcesReleased)
        guard recorder.events == [.shortcutReceived, .resourcesReleased] else {
            throw ContractFailure(message: "performance instrumentation did not remain payload-free")
        }
    }

    private static func testHardBudgetClassification() throws {
        let budgets = Dictionary(
            uniqueKeysWithValues: PerformanceBudgetCatalog.hardGates.map {
                ($0.measurement, $0)
            }
        )
        guard budgets[.idleCPUPercent]?.target == 0.2,
              budgets[.idleCPUPercent]?.hardLimit == 0.5,
              budgets[.idlePhysicalFootprintBytes]?.target == Double(65 * 1024 * 1024),
              budgets[.idlePhysicalFootprintBytes]?.hardLimit == Double(90 * 1024 * 1024),
              budgets[.shortcutToRecordingP95Milliseconds]?.hardLimit == 150,
              budgets[.firstVolatileTranscriptP95Milliseconds]?.hardLimit == 1_200,
              budgets[.stopToRawFinalTranscriptP95Milliseconds]?.hardLimit == 1_500,
              budgets[.stopToCleanInsertionP95Milliseconds]?.hardLimit == 4_000,
              budgets[.memoryAfterProcessingDeltaBytes]?.hardLimit == Double(15 * 1024 * 1024),
              budgets[.memoryDriftAfter100DictationsBytes]?.hardLimit == Double(20 * 1024 * 1024),
              budgets[.oigoInitiatedNetworkRequests]?.hardLimit == 0,
              budgets[.lostRecoverableRecordings]?.hardLimit == 0 else {
            throw ContractFailure(message: "hard performance budgets do not match issue #11")
        }

        let available = PerformanceBudgetCatalog.allMeasurements.map { measurement in
            PerformanceMeasurementRecord(measurement: measurement, value: 0)
        }
        guard PerformanceReleaseCheck.evaluate(available).status == .pass else {
            throw ContractFailure(message: "available budget evidence did not pass")
        }

        let failing = available.map { record in
            record.measurement == .idleCPUPercent
                ? PerformanceMeasurementRecord(
                    measurement: record.measurement,
                    value: 0.500_001
                )
                : record
        }
        guard PerformanceReleaseCheck.evaluate(failing).status == .fail else {
            throw ContractFailure(message: "over-budget evidence did not fail the release check")
        }

        let invalid = available.map { record in
            record.measurement == .idleCPUPercent
                ? PerformanceMeasurementRecord(
                    measurement: record.measurement,
                    value: -1
                )
                : record
        }
        guard PerformanceReleaseCheck.evaluate(invalid).status == .fail else {
            throw ContractFailure(message: "invalid negative evidence did not fail the release check")
        }

        let missingValue = available.map { record in
            record.measurement == .idleCPUPercent
                ? PerformanceMeasurementRecord(
                    measurement: record.measurement,
                    value: nil
                )
                : record
        }
        guard PerformanceReleaseCheck.evaluate(missingValue).status == .fail else {
            throw ContractFailure(message: "available evidence without a value did not fail the release check")
        }

        var duplicate = available
        duplicate.append(available[0])
        guard PerformanceReleaseCheck.evaluate(duplicate).status == .fail else {
            throw ContractFailure(message: "duplicate evidence did not fail the release check")
        }

        let missing = Array(available.dropLast())
        guard PerformanceReleaseCheck.evaluate(missing).status == .inconclusive else {
            throw ContractFailure(message: "missing host evidence was not inconclusive")
        }
    }

    private static func testLifecycleReleaseGates() throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let recorder = RecordingPerformanceInstrumentation()
        let diagnostics = DictationDiagnostics(instrumentation: recorder)
        let coordinator = DictationCoordinator(diagnostics: diagnostics)
        let store = try SessionStore(rootDirectory: root)
        let capture = ScriptedAudioCapture()

        for index in 0..<100 {
            let session = try coordinator.startRecording(
                using: capture,
                store: store,
                now: Date(timeIntervalSince1970: 100_000 + Double(index))
            )
            let terminal = try coordinator.cancelRecording(
                at: Date(timeIntervalSince1970: 100_000 + Double(index) + 0.5)
            )
            guard terminal.id == session.id,
                  terminal.metadata.state == .cancelled,
                  !capture.isActive,
                  coordinator.activeTaskCount == 0,
                  coordinator.activeResourceCount == 0,
                  !coordinator.hasActiveWork else {
                throw ContractFailure(message: "cycle \(index) retained active lifecycle resources")
            }
        }

        let releaseCount = recorder.events.filter { $0 == .resourcesReleased }.count
        guard releaseCount == 100 else {
            throw ContractFailure(message: "expected one resource-release marker per cycle, got \(releaseCount)")
        }
        let persistedCount = recorder.events.filter { $0 == .sessionPersisted }.count
        guard persistedCount == 100 else {
            throw ContractFailure(message: "expected one session-persisted marker per cycle, got \(persistedCount)")
        }
        let stoppedCount = recorder.events.filter { $0 == .recordingStopped }.count
        guard stoppedCount == 100 else {
            throw ContractFailure(message: "expected one recording-stopped marker per cycle, got \(stoppedCount)")
        }
    }

    @available(macOS 26.0, *)
    private static func testTranscriptionReleaseInstrumentation() async throws {
        let successRecorder = RecordingPerformanceInstrumentation()
        let transcription = TranscriptionService(instrumentation: successRecorder)
        _ = try await transcription.deliverFinalAtStartupBoundaryForTesting(
            range: TranscriptionRange(startMilliseconds: 0, endMilliseconds: 100),
            text: "fixture"
        )
        guard successRecorder.events == [.transcriptionFinalized, .resourcesReleased] else {
            throw ContractFailure(message: "successful transcription did not emit finalization and release markers")
        }

        let faultRecorder = RecordingPerformanceInstrumentation()
        let faults = DictationFaultInjector()
        faults.arm(.speechFailure)
        let failedTranscription = TranscriptionService(
            faultInjector: faults,
            instrumentation: faultRecorder
        )
        do {
            _ = try await failedTranscription.deliverFinalAtStartupBoundaryForTesting(
                range: TranscriptionRange(startMilliseconds: 0, endMilliseconds: 100),
                text: "fixture"
            )
            throw ContractFailure(message: "fault-injected transcription unexpectedly succeeded")
        } catch let error as TranscriptionError {
            guard case .analysisFailed = error else {
                throw ContractFailure(message: "fault-injected transcription returned the wrong error")
            }
        }
        guard faultRecorder.events == [.resourcesReleased] else {
            throw ContractFailure(message: "failed transcription did not emit a release marker")
        }
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue11-performance-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func cleanup(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
        print("CLEANUP: removed " + root.path)
    }
}

private final class ScriptedAudioCapture: AudioCapturing, @unchecked Sendable {
    private var descriptor: AudioFileDescriptor?
    private(set) var isActive = false

    func start(
        to descriptor: AudioFileDescriptor,
        onBuffer: @escaping @Sendable (AudioCaptureBuffer) -> Void,
        onFinish: @escaping @Sendable () -> Void,
        onInterruption: @escaping @Sendable (String) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) throws {
        _ = onBuffer
        _ = onFinish
        _ = onInterruption
        _ = onFailure
        self.descriptor = descriptor
        isActive = true
    }

    func stop() throws {
        cancel()
    }

    func cancel() {
        isActive = false
        descriptor?.close()
        descriptor = nil
    }
}
